package mempool

import "core:slice"
import "core:time"
import "../chain"
import "../consensus"
import "../crypto"
import "../script"
import "../storage"
import "../wire"

Hash256 :: crypto.Hash256

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
}

Mempool_Entry :: struct {
	tx:       wire.Tx,
	txid:     Hash256,
	fee:      i64,
	vsize:    int,
	fee_rate: Fee_Rate,
	time:     i64,
}

Mempool :: struct {
	entries:         map[Hash256]^Mempool_Entry,
	spent_outpoints: map[wire.Outpoint]Hash256,
	chain:           ^chain.Chain_State,
	params:          ^consensus.Chain_Params,
	max_size:        int,
}

mempool_init :: proc(mp: ^Mempool, cs: ^chain.Chain_State, params: ^consensus.Chain_Params) {
	mp.entries = make(map[Hash256]^Mempool_Entry, 256)
	mp.spent_outpoints = make(map[wire.Outpoint]Hash256, 1024)
	mp.chain = cs
	mp.params = params
	mp.max_size = MAX_MEMPOOL_ENTRIES
}

mempool_destroy :: proc(mp: ^Mempool) {
	for _, entry in mp.entries {
		_free_tx(&entry.tx)
		free(entry)
	}
	delete(mp.entries)
	delete(mp.spent_outpoints)
}

// Dry-run validation of a transaction against mempool rules (steps 1-8).
// Returns fee and vsize on success, or a Mempool_Error.
mempool_validate :: proc(mp: ^Mempool, tx: ^wire.Tx) -> (fee: i64, vsize: int, err: Mempool_Error) {
	// 1. Compute txid, check not already in mempool
	txid := wire.tx_id(tx)
	if txid in mp.entries {
		return 0, 0, .Tx_Already_Exists
	}

	// 2. Reject coinbase transactions
	if consensus.is_coinbase_tx(tx) {
		return 0, 0, .Coinbase_Not_Allowed
	}

	// 3. Run standard policy checks
	policy_err := check_tx_policy(tx)
	if policy_err != .None {
		return 0, 0, policy_err
	}

	// 4. Context-free consensus sanity
	sanity_err := consensus.check_tx_sanity(tx)
	if sanity_err != .None {
		return 0, 0, .Non_Standard
	}

	// 5. Verify all inputs exist and gather spent output info
	height := chain.chain_height(mp.chain)
	input_sum: i64 = 0
	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)

	for in_idx in 0 ..< len(tx.inputs) {
		prev_out := tx.inputs[in_idx].previous_output

		// Check confirmed UTXOs first
		coin, found := chain.coins_cache_get(&mp.chain.coins, prev_out)
		if found {
			// Check coinbase maturity
			if coin.is_coinbase {
				if (height + 1) - int(coin.height) < consensus.COINBASE_MATURITY {
					return 0, 0, .Coinbase_Not_Mature
				}
			}

			spent_outputs[in_idx] = wire.Tx_Out {
				value         = coin.amount,
				script_pubkey = coin.script,
			}
			input_sum += coin.amount
		} else {
			// Check if output is from another mempool transaction
			mp_coin, mp_found := _get_mempool_output(mp, prev_out)
			if !mp_found {
				return 0, 0, .Missing_Inputs
			}
			spent_outputs[in_idx] = mp_coin
			input_sum += mp_coin.value
		}
	}

	// 6. Check no double-spends
	for in_idx in 0 ..< len(tx.inputs) {
		prev_out := tx.inputs[in_idx].previous_output
		if prev_out in mp.spent_outpoints {
			return 0, 0, .Double_Spend
		}
	}

	// 7. Calculate fees, verify minimum relay fee
	output_sum: i64 = 0
	for out_idx in 0 ..< len(tx.outputs) {
		output_sum += tx.outputs[out_idx].value
	}
	tx_fee := input_sum - output_sum
	if tx_fee < 0 {
		return 0, 0, .Insufficient_Fee
	}

	tx_vsize := consensus.get_tx_vsize(tx)
	min_fee := (MIN_RELAY_TX_FEE * i64(tx_vsize)) / 1000
	if min_fee == 0 {
		min_fee = 1
	}
	if tx_fee < min_fee {
		return 0, 0, .Insufficient_Fee
	}

	// 8. Run script verification for each input
	script_flags := consensus.get_script_flags(height + 1, mp.params)
	// Add standard policy flags
	script_flags += script.STANDARD_FLAGS

	for in_idx in 0 ..< len(tx.inputs) {
		verifier := script.Script_Verifier {
			tx            = tx,
			input_idx     = in_idx,
			amount        = spent_outputs[in_idx].value,
			flags         = script_flags,
			spent_outputs = spent_outputs,
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
			return 0, 0, .Failed_Script
		}
	}

	return tx_fee, tx_vsize, .None
}

// Full validation and addition of a transaction to the mempool.
mempool_add :: proc(mp: ^Mempool, tx: ^wire.Tx) -> Mempool_Error {
	// 0. Check mempool capacity
	if len(mp.entries) >= mp.max_size {
		return .Mempool_Full
	}

	// Validate (steps 1-8)
	tx_fee, vsize, val_err := mempool_validate(mp, tx)
	if val_err != .None {
		return val_err
	}

	// 9. Clone tx, create entry, add to maps
	txid := wire.tx_id(tx)
	fr := fee_rate(tx_fee, vsize)
	cloned := _clone_tx(tx)
	entry := new(Mempool_Entry)
	entry.tx = cloned
	entry.txid = txid
	entry.fee = tx_fee
	entry.vsize = vsize
	entry.fee_rate = fr
	entry.time = time.to_unix_seconds(time.now())

	mp.entries[txid] = entry

	// Record spent outpoints
	for in_idx in 0 ..< len(tx.inputs) {
		mp.spent_outpoints[tx.inputs[in_idx].previous_output] = txid
	}

	return .None
}

// Remove a single transaction from the mempool.
mempool_remove :: proc(mp: ^Mempool, txid: Hash256) {
	entry, found := mp.entries[txid]
	if !found {
		return
	}

	// Remove spent outpoints
	for in_idx in 0 ..< len(entry.tx.inputs) {
		delete_key(&mp.spent_outpoints, entry.tx.inputs[in_idx].previous_output)
	}

	_free_tx(&entry.tx)
	free(entry)
	delete_key(&mp.entries, txid)
}

// Remove all confirmed transactions and any conflicting transactions.
mempool_remove_for_block :: proc(mp: ^Mempool, block: ^wire.Block) {
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
