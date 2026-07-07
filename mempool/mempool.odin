package mempool

import "core:slice"
import "core:time"
import "../chain"
import "../consensus"
import crypto "../crypto"
import "../script"
import "../wire"

Hash256 :: crypto.Hash256

Mempool_Config :: struct {
	max_mempool_mb:          int,    // --maxmempool (default: 300)
	mempool_expiry_hours:    int,    // --mempoolexpiry (default: 336)
	limit_ancestor_count:    int,    // --limitancestorcount (default: 25)
	limit_ancestor_size_kb:  int,    // --limitancestorsize (default: 101)
	limit_descendant_count:  int,    // --limitdescendantcount (default: 25)
	limit_descendant_size_kb:int,    // --limitdescendantsize (default: 101)
	min_relay_tx_fee:        i64,    // --minrelaytxfee in sat/kvB (default: 1000)
	incremental_relay_fee:   i64,    // --incrementalrelayfee in sat/kvB (default: 1000)
	dust_relay_fee:          i64,    // --dustrelayfee in sat/kvB (default: 3000)
	datacarrier:             bool,   // --datacarrier (default: true)
	datacarrier_size:        int,    // --datacarriersize (default: 83)
	permit_bare_multisig:    bool,   // --permitbaremultisig (default: true)
	fullrbf:                 bool,   // --mempoolfullrbf (default: true)
	max_rbf_evictions:       int,    // (internal, default: 100)
	persist_mempool:         bool,   // --persistmempool (default: true)
	blocks_only:             bool,   // --blocksonly (default: false)
}

mempool_config_default :: proc() -> Mempool_Config {
	return Mempool_Config{
		max_mempool_mb          = 300,
		mempool_expiry_hours    = 336,
		limit_ancestor_count    = 25,
		limit_ancestor_size_kb  = 101,
		limit_descendant_count  = 25,
		limit_descendant_size_kb= 101,
		min_relay_tx_fee        = 1000,
		incremental_relay_fee   = 1000,
		dust_relay_fee          = 3000,
		datacarrier             = true,
		datacarrier_size        = 83,
		permit_bare_multisig    = true,
		fullrbf                 = true,
		max_rbf_evictions       = 100,
		persist_mempool         = true,
		blocks_only             = false,
	}
}

Mempool_Error :: enum {
	None,
	Tx_Already_Exists,
	Double_Spend,
	Missing_Inputs,
	Coinbase_Not_Allowed,
	Coinbase_Not_Mature,
	Non_Standard,
	Insufficient_Fee,
	Too_Many_Sigops,
	Failed_Script,
	Mempool_Full,
	RBF_Not_Signaling,
	RBF_New_Unconfirmed,
	RBF_Insufficient_Fee,
	RBF_Fee_Too_Low,
	RBF_Too_Many_Evictions,
	Non_Final,
	Chain_Limit_Exceeded,
}

Mempool_Entry :: struct {
	tx:       wire.Tx,
	txid:     Hash256,
	wtxid:    Hash256,
	fee:      i64,
	vsize:    int,
	fee_rate: Fee_Rate,
	time:     i64,
	height:   int, // chain tip height when accepted
}

Mempool :: struct {
	entries:         map[Hash256]^Mempool_Entry,
	spent_outpoints: map[wire.Outpoint]Hash256,
	wtxid_index:     map[Hash256]Hash256, // BIP339: wtxid → txid
	chain:           ^chain.Chain_State,
	params:          ^consensus.Chain_Params,
	config:          Mempool_Config,
	usage:           int,   // Total vsize bytes of all entries
	min_fee:         i64,   // Dynamic minimum fee (sat/kvB) when mempool is full
	tip_height:      int,   // Current chain tip height (updated on block connect)
	tip_mtp:         u32,   // MTP at current tip (updated on block connect)
	estimator:       Fee_Estimator, // confirmation-tracking fee estimation
	// prioritisetransaction fee deltas (sats), applied during block-template
	// selection. Kept for txids not (yet) in the mempool, like Core.
	fee_deltas:      map[Hash256]i64,
}

// Set (accumulate) a mining-priority fee delta for a txid.
mempool_prioritise :: proc(mp: ^Mempool, txid: Hash256, delta_sat: i64) {
	new_delta := mp.fee_deltas[txid] + delta_sat
	if new_delta == 0 {
		delete_key(&mp.fee_deltas, txid)
	} else {
		mp.fee_deltas[txid] = new_delta
	}
}

// Effective fee for template selection: real fee + any prioritisation delta.
mempool_selection_fee :: proc(mp: ^Mempool, entry: ^Mempool_Entry) -> i64 {
	return entry.fee + mp.fee_deltas[entry.txid]
}

mempool_init :: proc(mp: ^Mempool, cs: ^chain.Chain_State, params: ^consensus.Chain_Params, config: Mempool_Config = {}) {
	mp.entries = make(map[Hash256]^Mempool_Entry, 256)
	mp.spent_outpoints = make(map[wire.Outpoint]Hash256, 1024)
	mp.wtxid_index = make(map[Hash256]Hash256, 256)
	mp.chain = cs
	mp.params = params
	// Use provided config, or default if zero-value
	if config.max_mempool_mb == 0 {
		mp.config = mempool_config_default()
	} else {
		mp.config = config
	}
	mp.min_fee = mp.config.min_relay_tx_fee
	mp.fee_deltas = make(map[Hash256]i64, 16)
	estimator_init(&mp.estimator)
	mempool_update_tip(mp)
	mp.estimator.best_height = max(mp.tip_height, 0)
}

// Update tip_height and tip_mtp from current chain state. Call after connecting/disconnecting blocks.
mempool_update_tip :: proc(mp: ^Mempool) {
	_, tip_height := chain.chain_tip(mp.chain)
	mp.tip_height = tip_height
	if tip_height >= 0 {
		tip_hash := mp.chain.active_chain[tip_height]
		tip_entry, found := mp.chain.block_index.entries[tip_hash]
		if found {
			mp.tip_mtp = chain.get_median_time_past(tip_entry)
		}
	}
}

mempool_destroy :: proc(mp: ^Mempool) {
	for _, entry in mp.entries {
		_free_tx(&entry.tx)
		free(entry)
	}
	delete(mp.entries)
	delete(mp.spent_outpoints)
	delete(mp.wtxid_index)
	delete(mp.fee_deltas)
	estimator_destroy(&mp.estimator)
}

// Dry-run validation of a transaction against mempool rules (steps 1-8).
// Returns fee and vsize on success, or a Mempool_Error.
// For testmempoolaccept: does not return conflict info.
mempool_validate :: proc(mp: ^Mempool, tx: ^wire.Tx) -> (fee: i64, vsize: int, err: Mempool_Error) {
	tx_fee, tx_vsize, _, val_err := _mempool_validate_internal(mp, tx)
	return tx_fee, tx_vsize, val_err
}

// Internal validation that returns the full conflict set for RBF eviction.
_mempool_validate_internal :: proc(mp: ^Mempool, tx: ^wire.Tx) -> (
	fee: i64, vsize: int, conflict_set: [dynamic]Hash256, err: Mempool_Error,
) {
	// 1. Compute txid, check not already in mempool
	txid := wire.tx_id(tx)
	if txid in mp.entries {
		return 0, 0, {}, .Tx_Already_Exists
	}

	// 2. Reject coinbase transactions
	if consensus.is_coinbase_tx(tx) {
		return 0, 0, {}, .Coinbase_Not_Allowed
	}

	// 3. Run standard policy checks
	policy_err := check_tx_policy(tx, &mp.config)
	if policy_err != .None {
		return 0, 0, {}, policy_err
	}

	// 4. Context-free consensus sanity
	sanity_err := consensus.check_tx_sanity(tx)
	if sanity_err != .None {
		return 0, 0, {}, .Non_Standard
	}

	// 4b. BIP 113: Check tx finality for next block
	{
		next_height := mp.tip_height + 1
		if !consensus.is_tx_final(tx, next_height, mp.tip_mtp) {
			return 0, 0, {}, .Non_Final
		}
	}

	// 5. Verify all inputs exist and gather spent output info
	height := chain.chain_height(mp.chain)
	input_sum: i64 = 0
	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
	input_heights := make([]int, len(tx.inputs), context.temp_allocator)

	for in_idx in 0 ..< len(tx.inputs) {
		prev_out := tx.inputs[in_idx].previous_output

		// Check confirmed UTXOs first
		coin, found := chain.coins_cache_get(&mp.chain.coins, prev_out)
		if found {
			// Check coinbase maturity
			if coin.is_coinbase {
				if (height + 1) - int(coin.height) < consensus.COINBASE_MATURITY {
					return 0, 0, {}, .Coinbase_Not_Mature
				}
			}

			spent_outputs[in_idx] = wire.Tx_Out {
				value         = coin.amount,
				script_pubkey = coin.script,
			}
			input_heights[in_idx] = int(coin.height)
			input_sum += coin.amount
		} else {
			// Check if output is from another mempool transaction
			mp_coin, mp_found := _get_mempool_output(mp, prev_out)
			if !mp_found {
				return 0, 0, {}, .Missing_Inputs
			}
			spent_outputs[in_idx] = mp_coin
			// Mempool txs are treated as mined at tip+1 for sequence lock purposes
			input_heights[in_idx] = height + 1
			input_sum += mp_coin.value
		}
	}

	// 5b. BIP 68: Check sequence locks for next block
	if height + 1 >= mp.params.csv_height {
		if !chain.check_sequence_locks(mp.chain, tx, height + 1, input_heights, mp.tip_mtp) {
			return 0, 0, {}, .Non_Final
		}
	}

	// 5c. Chain limits (ancestor/descendant count and size)
	chain_err := _check_chain_limits(mp, tx, consensus.get_tx_vsize(tx))
	if chain_err != .None {
		return 0, 0, {}, chain_err
	}

	// 6. Conflict detection + RBF
	direct_conflicts, has_conflicts := _find_conflicts(mp, tx)
	if has_conflicts {
		cs := _get_conflict_set(mp, direct_conflicts[:])
		// Check non-fee rules first (signaling, new unconfirmed, eviction count)
		rbf_preflight := _check_rbf_rules_preflight(mp, tx, direct_conflicts[:], cs[:])
		if rbf_preflight != .None {
			return 0, 0, {}, rbf_preflight
		}
		// Fee-dependent rules checked after fee computation below
		conflict_set = cs
	} else {
		// No conflicts — verify no double-spends
		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output
			if prev_out in mp.spent_outpoints {
				return 0, 0, {}, .Double_Spend
			}
		}
	}

	// 7. Calculate fees, verify minimum relay fee
	output_sum: i64 = 0
	for out_idx in 0 ..< len(tx.outputs) {
		output_sum += tx.outputs[out_idx].value
	}
	tx_fee := input_sum - output_sum
	if tx_fee < 0 {
		return 0, 0, {}, .Insufficient_Fee
	}

	tx_vsize := consensus.get_tx_vsize(tx)
	effective_min_rate := max(mp.config.min_relay_tx_fee, mp.min_fee)
	min_fee := (effective_min_rate * i64(tx_vsize)) / 1000
	if min_fee == 0 {
		min_fee = 1
	}
	if tx_fee < min_fee {
		return 0, 0, {}, .Insufficient_Fee
	}

	// 6b. RBF fee rules (now that we have fee + vsize)
	if has_conflicts {
		rbf_fee_err := _check_rbf_fee_rules(mp, tx_fee, tx_vsize, conflict_set[:])
		if rbf_fee_err != .None {
			return 0, 0, {}, rbf_fee_err
		}
	}

	// 8. Run script verification for each input
	script_flags := consensus.get_script_flags(height + 1, mp.params)
	// Add standard policy flags
	script_flags += script.STANDARD_FLAGS

	sighash_cache: script.Sighash_Cache
	for in_idx in 0 ..< len(tx.inputs) {
		verifier := script.Script_Verifier {
			tx            = tx,
			input_idx     = in_idx,
			amount        = spent_outputs[in_idx].value,
			flags         = script_flags,
			spent_outputs = spent_outputs,
			sighash_cache = &sighash_cache,
		}

		witness: [][]byte
		if len(tx.witness) > in_idx {
			witness = tx.witness[in_idx]
		}

		serr := script.verify_script(
			&verifier,
			tx.inputs[in_idx].script_sig,
			spent_outputs[in_idx].script_pubkey,
			witness,
		)
		if serr != .None {
			return 0, 0, {}, .Failed_Script
		}
	}

	return tx_fee, tx_vsize, conflict_set, .None
}

// Full validation and addition of a transaction to the mempool.
mempool_add :: proc(mp: ^Mempool, tx: ^wire.Tx) -> Mempool_Error {
	// Validate (steps 1-8), get conflict set for RBF
	tx_fee, vsize, conflict_set, val_err := _mempool_validate_internal(mp, tx)
	if val_err != .None {
		return val_err
	}

	// Evict conflicting txs + descendants before adding replacement
	for txid in conflict_set {
		mempool_remove(mp, txid)
	}

	// 9. Clone tx, create entry, add to maps
	txid := wire.tx_id(tx)
	wtxid := wire.tx_witness_id(tx)
	fr := fee_rate(tx_fee, vsize)
	cloned := _clone_tx(tx)
	entry := new(Mempool_Entry)
	entry.tx = cloned
	entry.txid = txid
	entry.wtxid = wtxid
	entry.fee = tx_fee
	entry.vsize = vsize
	entry.fee_rate = fr
	entry.time = time.to_unix_seconds(time.now())
	entry.height = mp.tip_height

	estimator_process_tx(&mp.estimator, txid, mp.tip_height, fee_rate_per_kvb(fr))

	mp.entries[txid] = entry
	mp.wtxid_index[wtxid] = txid
	mp.usage += vsize

	// Record spent outpoints
	for in_idx in 0 ..< len(tx.inputs) {
		mp.spent_outpoints[tx.inputs[in_idx].previous_output] = txid
	}

	// Evict lowest fee-rate entries if over memory limit
	_mempool_limit_size(mp, txid)

	return .None
}

// Remove a single transaction from the mempool.
mempool_remove :: proc(mp: ^Mempool, txid: Hash256) {
	entry, found := mp.entries[txid]
	if !found {
		return
	}

	// Failure accounting: this path is eviction/expiry/replacement/conflict.
	// Block confirmations are untracked by estimator_process_block BEFORE
	// mempool_remove_for_block gets here, so they never register as failures.
	estimator_remove_tx(&mp.estimator, txid)

	// Remove spent outpoints
	for in_idx in 0 ..< len(entry.tx.inputs) {
		delete_key(&mp.spent_outpoints, entry.tx.inputs[in_idx].previous_output)
	}

	// Remove wtxid index entry
	delete_key(&mp.wtxid_index, entry.wtxid)

	mp.usage -= entry.vsize
	_free_tx(&entry.tx)
	free(entry)
	delete_key(&mp.entries, txid)
}

// Remove all confirmed transactions and any conflicting transactions.
mempool_remove_for_block :: proc(mp: ^Mempool, block: ^wire.Block) {
	// Fee estimation: record confirmations at the block's height (the chain
	// has already connected it) before the entries disappear.
	{
		confirmed := make([dynamic]Hash256, 0, len(block.txs), context.temp_allocator)
		for tx_idx in 1 ..< len(block.txs) {
			tx := block.txs[tx_idx]
			append(&confirmed, wire.tx_id(&tx))
		}
		estimator_process_block(&mp.estimator, chain.chain_height(mp.chain), confirmed[:])
	}

	// Collect txids to remove (confirmed + conflicting)
	to_remove := make([dynamic]Hash256, 0, len(block.txs), context.temp_allocator)

	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]

		// Remove the confirmed tx itself
		tx_hash := wire.tx_id(&tx)
		if tx_hash in mp.entries {
			append(&to_remove, tx_hash)
		}

		// Remove any mempool tx that spends the same inputs (conflict)
		if !consensus.is_coinbase_tx(&tx) {
			for in_idx in 0 ..< len(tx.inputs) {
				prev_out := tx.inputs[in_idx].previous_output
				conflicting, cfound := mp.spent_outpoints[prev_out]
				if cfound && conflicting != tx_hash {
					append(&to_remove, conflicting)
				}
			}
		}
	}

	for hash in to_remove {
		mempool_remove(mp, hash)
	}

	// Reset dynamic min fee if usage dropped below limit
	if mp.usage < mp.config.max_mempool_mb * 1_000_000 {
		mp.min_fee = mp.config.min_relay_tx_fee
	}

	// Expire old transactions
	mempool_expire(mp)
}

// Look up a mempool entry by txid.
mempool_get :: proc(mp: ^Mempool, txid: Hash256) -> (^Mempool_Entry, bool) {
	entry, found := mp.entries[txid]
	return entry, found
}

// Return entries sorted by descending fee rate.
mempool_get_sorted :: proc(mp: ^Mempool, allocator := context.allocator) -> []^Mempool_Entry {
	if len(mp.entries) == 0 {
		return nil
	}

	result := make([]^Mempool_Entry, len(mp.entries), allocator)
	i := 0
	for _, entry in mp.entries {
		result[i] = entry
		i += 1
	}

	// Sort descending by fee rate
	slice.sort_by(result, proc(a, b: ^Mempool_Entry) -> bool {
		// b < a for descending order
		return fee_rate_less(b.fee_rate, a.fee_rate)
	})

	return result
}

// Current entry count.
mempool_count :: proc(mp: ^Mempool) -> int {
	return len(mp.entries)
}

// Check if a transaction is in the mempool.
mempool_has :: proc(mp: ^Mempool, txid: Hash256) -> bool {
	return txid in mp.entries
}

// Check if a transaction is in the mempool by wtxid (BIP339).
mempool_has_wtxid :: proc(mp: ^Mempool, wtxid: Hash256) -> bool {
	return wtxid in mp.wtxid_index
}

// Look up a mempool entry by wtxid (BIP339).
mempool_get_by_wtxid :: proc(mp: ^Mempool, wtxid: Hash256) -> (^Mempool_Entry, bool) {
	txid, found := mp.wtxid_index[wtxid]
	if !found {
		return nil, false
	}
	return mempool_get(mp, txid)
}

// Get all in-mempool ancestors of a transaction (BFS upward through inputs).
mempool_get_ancestors :: proc(mp: ^Mempool, txid: Hash256) -> [dynamic]Hash256 {
	seen := make(map[Hash256]bool, 32, context.temp_allocator)
	queue := make([dynamic]Hash256, 0, 32, context.temp_allocator)

	// Seed with the target tx's parents
	entry, found := mp.entries[txid]
	if !found {
		return make([dynamic]Hash256, 0, 0, context.temp_allocator)
	}

	for in_idx in 0 ..< len(entry.tx.inputs) {
		prev_txid := entry.tx.inputs[in_idx].previous_output.hash
		if prev_txid in mp.entries && !(prev_txid in seen) {
			seen[prev_txid] = true
			append(&queue, prev_txid)
		}
	}

	// BFS: for each ancestor, also check its parents
	qi := 0
	for qi < len(queue) {
		anc_txid := queue[qi]
		qi += 1
		anc_entry, anc_found := mp.entries[anc_txid]
		if !anc_found { continue }
		for in_idx in 0 ..< len(anc_entry.tx.inputs) {
			prev_txid := anc_entry.tx.inputs[in_idx].previous_output.hash
			if prev_txid in mp.entries && !(prev_txid in seen) {
				seen[prev_txid] = true
				append(&queue, prev_txid)
			}
		}
	}

	return queue
}

// Get all in-mempool descendants of a transaction (BFS downward through spent_outpoints).
mempool_get_descendants :: proc(mp: ^Mempool, txid: Hash256) -> [dynamic]Hash256 {
	seen := make(map[Hash256]bool, 32, context.temp_allocator)
	queue := make([dynamic]Hash256, 0, 32, context.temp_allocator)

	// Seed with the target tx's children
	entry, found := mp.entries[txid]
	if !found {
		return make([dynamic]Hash256, 0, 0, context.temp_allocator)
	}

	for out_idx in 0 ..< len(entry.tx.outputs) {
		child_outpoint := wire.Outpoint{hash = txid, index = u32(out_idx)}
		child_txid, child_exists := mp.spent_outpoints[child_outpoint]
		if child_exists && !(child_txid in seen) {
			seen[child_txid] = true
			append(&queue, child_txid)
		}
	}

	// BFS: for each descendant, also check its children
	qi := 0
	for qi < len(queue) {
		desc_txid := queue[qi]
		qi += 1
		desc_entry, desc_found := mp.entries[desc_txid]
		if !desc_found { continue }
		for out_idx in 0 ..< len(desc_entry.tx.outputs) {
			child_outpoint := wire.Outpoint{hash = desc_txid, index = u32(out_idx)}
			child_txid, child_exists := mp.spent_outpoints[child_outpoint]
			if child_exists && !(child_txid in seen) {
				seen[child_txid] = true
				append(&queue, child_txid)
			}
		}
	}

	return queue
}

// --- Size limiting ---

// Evict lowest fee-rate entries until usage is within the memory limit.
// Never evicts the just-added tx (protect_txid).
_mempool_limit_size :: proc(mp: ^Mempool, protect_txid: Hash256) {
	limit_bytes := mp.config.max_mempool_mb * 1_000_000
	if mp.usage <= limit_bytes {
		return
	}

	// Sort entries ascending by fee rate
	sorted := mempool_get_sorted(mp, context.temp_allocator)
	// sorted is descending — iterate from the end (lowest fee rate)
	idx := len(sorted) - 1
	for idx >= 0 && mp.usage > limit_bytes {
		entry := sorted[idx]
		idx -= 1
		if entry.txid == protect_txid {
			continue
		}
		// Update min_fee to the evicted entry's fee rate
		evicted_rate := fee_rate_per_kvb(entry.fee_rate)
		if evicted_rate > mp.min_fee {
			mp.min_fee = evicted_rate
		}
		mempool_remove(mp, entry.txid)
	}
}

// --- Transaction expiry ---

// Remove transactions older than mempool_expiry_hours. Returns count removed.
mempool_expire :: proc(mp: ^Mempool) -> int {
	if mp.config.mempool_expiry_hours <= 0 {
		return 0
	}

	now := time.to_unix_seconds(time.now())
	expiry_secs := i64(mp.config.mempool_expiry_hours) * 3600
	to_remove := make([dynamic]Hash256, 0, 16, context.temp_allocator)

	for txid, entry in mp.entries {
		if now - entry.time > expiry_secs {
			append(&to_remove, txid)
		}
	}

	for txid in to_remove {
		mempool_remove(mp, txid)
	}
	return len(to_remove)
}

// --- Chain limits ---

// Check ancestor/descendant chain limits for a transaction about to be added.
// tx_vsize is the vsize of the new tx. ancestors must be pre-computed.
_check_chain_limits :: proc(mp: ^Mempool, tx: ^wire.Tx, tx_vsize: int) -> Mempool_Error {
	txid := wire.tx_id(tx)

	// Check ancestor limits (including self)
	ancestors := mempool_get_ancestors(mp, txid)
	// For a new tx not yet in mempool, compute ancestors from its inputs
	if len(ancestors) == 0 {
		// BFS from inputs
		seen := make(map[Hash256]bool, 32, context.temp_allocator)
		queue := make([dynamic]Hash256, 0, 32, context.temp_allocator)
		for in_idx in 0 ..< len(tx.inputs) {
			prev_txid := tx.inputs[in_idx].previous_output.hash
			if prev_txid in mp.entries && !(prev_txid in seen) {
				seen[prev_txid] = true
				append(&queue, prev_txid)
			}
		}
		qi := 0
		for qi < len(queue) {
			anc_txid := queue[qi]
			qi += 1
			anc_entry, anc_found := mp.entries[anc_txid]
			if !anc_found { continue }
			for in_idx in 0 ..< len(anc_entry.tx.inputs) {
				prev_txid := anc_entry.tx.inputs[in_idx].previous_output.hash
				if prev_txid in mp.entries && !(prev_txid in seen) {
					seen[prev_txid] = true
					append(&queue, prev_txid)
				}
			}
		}
		ancestors = queue
	}

	if len(ancestors) + 1 > mp.config.limit_ancestor_count {
		return .Chain_Limit_Exceeded
	}

	ancestor_vsize := tx_vsize
	for anc_txid in ancestors {
		if anc_entry, found := mp.entries[anc_txid]; found {
			ancestor_vsize += anc_entry.vsize
		}
	}
	if ancestor_vsize > mp.config.limit_ancestor_size_kb * 1000 {
		return .Chain_Limit_Exceeded
	}

	// Check descendant limits — for each ancestor already in mempool,
	// verify adding this tx won't push any ancestor's descendant count/size over limits.
	checked := make(map[Hash256]bool, 32, context.temp_allocator)
	for anc_txid in ancestors {
		if anc_txid in checked { continue }
		checked[anc_txid] = true

		descs := mempool_get_descendants(mp, anc_txid)
		// +1 for the new tx being added
		if len(descs) + 1 > mp.config.limit_descendant_count {
			return .Chain_Limit_Exceeded
		}
		desc_vsize := tx_vsize
		for desc_txid in descs {
			if desc_entry, found := mp.entries[desc_txid]; found {
				desc_vsize += desc_entry.vsize
			}
		}
		if desc_vsize > mp.config.limit_descendant_size_kb * 1000 {
			return .Chain_Limit_Exceeded
		}
	}
	// Also check direct parents not already in ancestors list
	for in_idx in 0 ..< len(tx.inputs) {
		parent_txid := tx.inputs[in_idx].previous_output.hash
		if parent_txid in mp.entries && !(parent_txid in checked) {
			checked[parent_txid] = true
			descs := mempool_get_descendants(mp, parent_txid)
			if len(descs) + 1 > mp.config.limit_descendant_count {
				return .Chain_Limit_Exceeded
			}
			desc_vsize := tx_vsize
			for desc_txid in descs {
				if desc_entry, found := mp.entries[desc_txid]; found {
					desc_vsize += desc_entry.vsize
				}
			}
			if desc_vsize > mp.config.limit_descendant_size_kb * 1000 {
				return .Chain_Limit_Exceeded
			}
		}
	}

	return .None
}

// --- RBF (BIP125) helpers ---

// Check if a transaction signals replaceability (nSequence < 0xfffffffe on any input).
tx_signals_rbf :: proc(tx: ^wire.Tx) -> bool {
	for in_idx in 0 ..< len(tx.inputs) {
		if tx.inputs[in_idx].sequence < 0xfffffffe {
			return true
		}
	}
	return false
}

// Find mempool txs that directly conflict with tx (spend the same outpoints).
_find_conflicts :: proc(mp: ^Mempool, tx: ^wire.Tx) -> (conflicts: [dynamic]Hash256, found: bool) {
	conflicts = make([dynamic]Hash256, 0, 16, context.temp_allocator)
	seen := make(map[Hash256]bool, 16, context.temp_allocator)
	for in_idx in 0 ..< len(tx.inputs) {
		prev_out := tx.inputs[in_idx].previous_output
		existing_txid, exists := mp.spent_outpoints[prev_out]
		if exists && !(existing_txid in seen) {
			append(&conflicts, existing_txid)
			seen[existing_txid] = true
		}
	}
	return conflicts, len(conflicts) > 0
}

// Compute the full eviction set: direct conflicts + all in-mempool descendants.
_get_conflict_set :: proc(mp: ^Mempool, direct_conflicts: []Hash256) -> [dynamic]Hash256 {
	evict_set := make(map[Hash256]bool, 64, context.temp_allocator)
	queue := make([dynamic]Hash256, 0, 64, context.temp_allocator)

	// Seed with direct conflicts
	for txid in direct_conflicts {
		evict_set[txid] = true
		append(&queue, txid)
	}

	// BFS to find all descendants
	qi := 0
	for qi < len(queue) {
		txid := queue[qi]
		qi += 1
		entry, entry_found := mp.entries[txid]
		if !entry_found {
			continue
		}
		// Check each output — is it spent by another mempool tx?
		for out_idx in 0 ..< len(entry.tx.outputs) {
			child_outpoint := wire.Outpoint{hash = txid, index = u32(out_idx)}
			child_txid, child_exists := mp.spent_outpoints[child_outpoint]
			if child_exists && !(child_txid in evict_set) {
				evict_set[child_txid] = true
				append(&queue, child_txid)
			}
		}
	}

	// Convert to list
	result := make([dynamic]Hash256, 0, len(evict_set), context.temp_allocator)
	for txid in evict_set {
		append(&result, txid)
	}
	return result
}

// Check non-fee RBF rules: signaling (rule 1), new unconfirmed (rule 2), max evictions (rule 5).
_check_rbf_rules_preflight :: proc(
	mp: ^Mempool, tx: ^wire.Tx,
	direct_conflicts: []Hash256, conflict_set: []Hash256,
) -> Mempool_Error {
	// Rule 1: Signaling (only when fullrbf=false)
	if !mp.config.fullrbf {
		for txid in direct_conflicts {
			entry, found := mp.entries[txid]
			if !found { continue }
			if !tx_signals_rbf(&entry.tx) {
				return .RBF_Not_Signaling
			}
		}
	}

	// Rule 2: No new unconfirmed parents
	conflict_unconfirmed := make(map[wire.Outpoint]bool, 64, context.temp_allocator)
	for txid in direct_conflicts {
		entry, found := mp.entries[txid]
		if !found { continue }
		for in_idx in 0 ..< len(entry.tx.inputs) {
			prev := entry.tx.inputs[in_idx].previous_output
			if prev.hash in mp.entries {
				conflict_unconfirmed[prev] = true
			}
		}
	}
	for in_idx in 0 ..< len(tx.inputs) {
		prev := tx.inputs[in_idx].previous_output
		if prev.hash in mp.entries {
			if !(prev in conflict_unconfirmed) {
				return .RBF_New_Unconfirmed
			}
		}
	}

	// Rule 5: Max evictions
	if len(conflict_set) > mp.config.max_rbf_evictions {
		return .RBF_Too_Many_Evictions
	}

	return .None
}

// Check fee-dependent RBF rules: higher absolute fee (rule 3), bandwidth fee (rule 4).
_check_rbf_fee_rules :: proc(
	mp: ^Mempool, tx_fee: i64, tx_vsize: int,
	conflict_set: []Hash256,
) -> Mempool_Error {
	// Rule 3: Higher absolute fee than entire conflict set
	conflict_fee: i64 = 0
	for txid in conflict_set {
		entry, found := mp.entries[txid]
		if !found { continue }
		conflict_fee += entry.fee
	}
	if tx_fee <= conflict_fee {
		return .RBF_Insufficient_Fee
	}

	// Rule 4: Additional fee covers own bandwidth (uses incremental relay fee)
	additional_fee := tx_fee - conflict_fee
	min_additional := (mp.config.incremental_relay_fee * i64(tx_vsize)) / 1000
	if min_additional == 0 {
		min_additional = 1
	}
	if additional_fee < min_additional {
		return .RBF_Fee_Too_Low
	}

	return .None
}

// Look up a mempool transaction output (for unconfirmed chain / CPFP).
_get_mempool_output :: proc(mp: ^Mempool, outpoint: wire.Outpoint) -> (wire.Tx_Out, bool) {
	entry, found := mp.entries[outpoint.hash]
	if !found {
		return {}, false
	}
	idx := int(outpoint.index)
	if idx >= len(entry.tx.outputs) {
		return {}, false
	}
	return entry.tx.outputs[idx], true
}

// Deep-clone a transaction: inputs, outputs, witness, and scripts.
_clone_tx :: proc(tx: ^wire.Tx) -> wire.Tx {
	result: wire.Tx
	result.version = tx.version
	result.locktime = tx.locktime

	// Clone inputs
	if len(tx.inputs) > 0 {
		result.inputs = make([]wire.Tx_In, len(tx.inputs))
		for i in 0 ..< len(tx.inputs) {
			result.inputs[i].previous_output = tx.inputs[i].previous_output
			result.inputs[i].sequence = tx.inputs[i].sequence
			if len(tx.inputs[i].script_sig) > 0 {
				result.inputs[i].script_sig = make([]byte, len(tx.inputs[i].script_sig))
				copy(result.inputs[i].script_sig, tx.inputs[i].script_sig)
			}
		}
	}

	// Clone outputs
	if len(tx.outputs) > 0 {
		result.outputs = make([]wire.Tx_Out, len(tx.outputs))
		for i in 0 ..< len(tx.outputs) {
			result.outputs[i].value = tx.outputs[i].value
			if len(tx.outputs[i].script_pubkey) > 0 {
				result.outputs[i].script_pubkey = make([]byte, len(tx.outputs[i].script_pubkey))
				copy(result.outputs[i].script_pubkey, tx.outputs[i].script_pubkey)
			}
		}
	}

	// Clone witness
	if len(tx.witness) > 0 {
		result.witness = make([][][]byte, len(tx.witness))
		for i in 0 ..< len(tx.witness) {
			if len(tx.witness[i]) > 0 {
				result.witness[i] = make([][]byte, len(tx.witness[i]))
				for j in 0 ..< len(tx.witness[i]) {
					if len(tx.witness[i][j]) > 0 {
						result.witness[i][j] = make([]byte, len(tx.witness[i][j]))
						copy(result.witness[i][j], tx.witness[i][j])
					}
				}
			}
		}
	}

	return result
}

// Free all owned memory in a cloned transaction.
_free_tx :: proc(tx: ^wire.Tx) {
	for i in 0 ..< len(tx.inputs) {
		delete(tx.inputs[i].script_sig)
	}
	delete(tx.inputs)

	for i in 0 ..< len(tx.outputs) {
		delete(tx.outputs[i].script_pubkey)
	}
	delete(tx.outputs)

	for i in 0 ..< len(tx.witness) {
		for j in 0 ..< len(tx.witness[i]) {
			delete(tx.witness[i][j])
		}
		delete(tx.witness[i])
	}
	delete(tx.witness)
}
