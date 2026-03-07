package chain

import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "../consensus"
import crypto "../crypto"
import "../script"
import "../storage"
import "../wire"

Chain_State :: struct {
	block_index:    Block_Index,
	store:          storage.LDB_Store,
	index_db:       storage.Index_DB,
	block_db:       storage.Block_DB,
	utxo_db:        storage.UTXO_DB,
	coins:          Coins_Cache,
	active_chain:   [dynamic]Hash256,
	undo_files:     storage.Flat_File_Manager,
	params:         ^consensus.Chain_Params,
	// Per-input verification arena: heap-allocated once, reset between inputs (serial path).
	verify_buf:     []byte,
	verify_arena:   mem.Arena,
	verify_alloc:   mem.Allocator,
	// Parallel script verification
	verify_pool:    thread.Pool,
	verify_wg:      sync.Wait_Group,
	script_threads: int, // >= 2 = parallel (pool active), < 2 = serial (no pool)
	// Arena buffer pool for parallel workers (avoids alloc/free per check)
	arena_pool_bufs:  [][]byte,    // pre-allocated 8MB buffers, one per worker thread
	arena_pool_stack: [dynamic]int, // indices of available buffers (protected by mutex)
	arena_pool_mu:    sync.Mutex,
	// BIP 158 compact block filter index (nil when disabled)
	filter_db: ^storage.Filter_DB,
	// Performance profiling counters (cumulative, logged every 1000 blocks)
	prof: Block_Profile,
}

Block_Profile :: struct {
	blocks:      int,          // blocks since last log
	t_read:      time.Duration, // disk read + deserialize
	t_txid:      time.Duration, // txid computation
	t_utxo:      time.Duration, // Phase 1: UTXO lookups + spends + adds
	t_scripts:   time.Duration, // Phase 2: script verification
	t_undo:      time.Duration, // undo data write
	t_index:     time.Duration, // index update + chain append
	t_total:     time.Duration, // total connect_block time
}

// Initialize chain state. Caller allocates Chain_State and passes pointer.
// script_threads: 0 or 1 = serial verification, >= 2 = parallel with N worker threads.
chain_state_init :: proc(cs: ^Chain_State, data_dir: string, params: ^consensus.Chain_Params, db_cache_mb: int = 450, script_threads: int = 0) -> Chain_Error {
	cs.params = params

	// Ensure data_dir exists
	os.make_directory(data_dir)

	// Open shared LevelDB store (chainstate + block index)
	store, store_err := storage.ldb_open(data_dir, db_cache_mb)
	if store_err != .None {
		return .Storage_Error
	}
	cs.store = store

	// Init Index DB (backed by LevelDB)
	idx_db, idx_err := storage.index_db_init(&cs.store)
	if idx_err != .None {
		storage.ldb_close(&cs.store)
		return .Storage_Error
	}
	cs.index_db = idx_db

	// Open block DB (flat files — unchanged)
	blk_db, blk_err := storage.block_db_open(data_dir, params.network_magic)
	if blk_err != .None {
		storage.index_db_close(&cs.index_db)
		storage.ldb_close(&cs.store)
		return .Storage_Error
	}
	cs.block_db = blk_db

	// Init UTXO DB (backed by LevelDB)
	cs.utxo_db = storage.utxo_db_init(&cs.store)

	// Initialize coins cache with budget from LevelDB store's cache split
	cs.coins = coins_cache_init(&cs.utxo_db, cs.store.coins_cache_budget)

	// Open undo flat files
	undo_files, undo_err := storage.flat_file_open(data_dir, "rev")
	if undo_err != .None {
		storage.index_db_close(&cs.index_db)
		storage.block_db_close(&cs.block_db)
		storage.ldb_close(&cs.store)
		return .Storage_Error
	}
	cs.undo_files = undo_files

	// Build in-memory block index
	cs.block_index = block_index_init()
	block_index_load(&cs.block_index, &cs.index_db)

	// Free the redundant in-memory records map — all data is now in block_index.entries.
	storage.index_db_clear_records(&cs.index_db)

	// Seed genesis block header if not already in index
	if cs.block_index.genesis == nil {
		genesis_hdr := params.genesis_header
		entry := block_index_add(&cs.block_index, &genesis_hdr, 0, {.Valid_Header})
		rec := block_index_to_record(entry)
		storage.index_db_put(&cs.index_db, rec)
	}

	// Rebuild active chain from genesis to tip
	cs.active_chain = make([dynamic]Hash256, 0, 1024)

	// Crash recovery: read meta tip and truncate active chain if needed
	_recover_from_meta(cs)

	_rebuild_active_chain(cs)

	// Compute cumulative chain_tx for the active chain
	_compute_chain_tx(cs)

	// Allocate persistent per-input verification arena (4 MB, reused across blocks)
	cs.verify_buf = make([]byte, 4 * 1024 * 1024)
	mem.arena_init(&cs.verify_arena, cs.verify_buf)
	cs.verify_alloc = mem.arena_allocator(&cs.verify_arena)

	// Initialize parallel script verification thread pool
	cs.script_threads = script_threads
	if script_threads >= 2 {
		thread.pool_init(&cs.verify_pool, context.allocator, script_threads)
		thread.pool_start(&cs.verify_pool)

		// Pre-allocate arena buffers for workers (avoids alloc/free per check).
		cs.arena_pool_bufs = make([][]byte, script_threads)
		cs.arena_pool_stack = make([dynamic]int, 0, script_threads)
		for i in 0 ..< script_threads {
			cs.arena_pool_bufs[i] = make([]byte, 8 * 1024 * 1024)
			append(&cs.arena_pool_stack, i)
		}
	}

	// Connect any stored-but-not-connected blocks from a previous session.
	pending_connected, _ := connect_pending_blocks(cs)
	if pending_connected > 0 {
		_, tip_height := chain_tip(cs)
		log.infof("Connected %d pending blocks on startup (tip now at height %d)", pending_connected, tip_height)
	}

	return .None
}

// Destroy chain state, flushing everything to disk.
chain_state_destroy :: proc(cs: ^Chain_State) {
	// Shut down parallel verification pool before flushing
	if cs.script_threads >= 2 {
		thread.pool_join(&cs.verify_pool)
		thread.pool_destroy(&cs.verify_pool)
		for buf in cs.arena_pool_bufs {
			delete(buf)
		}
		delete(cs.arena_pool_bufs)
		delete(cs.arena_pool_stack)
	}

	tip_hash, tip_height := chain_tip(cs)
	coins_cache_flush(&cs.coins, tip_hash, tip_height)
	coins_cache_destroy(&cs.coins)
	if cs.filter_db != nil {
		storage.filter_db_close(cs.filter_db)
		free(cs.filter_db)
		cs.filter_db = nil
	}
	storage.utxo_db_close(&cs.utxo_db)
	storage.block_db_close(&cs.block_db)
	storage.index_db_close(&cs.index_db)
	storage.ldb_close(&cs.store)
	storage.flat_file_close(&cs.undo_files)
	block_index_destroy(&cs.block_index)
	delete(cs.active_chain)
	if cs.verify_buf != nil {
		delete(cs.verify_buf)
	}
}

// Get current tip hash and height.
chain_tip :: proc(cs: ^Chain_State) -> (Hash256, int) {
	if len(cs.active_chain) == 0 {
		return HASH_ZERO, -1
	}
	tip_hash := cs.active_chain[len(cs.active_chain) - 1]
	return tip_hash, len(cs.active_chain) - 1
}

// Get current chain height.
chain_height :: proc(cs: ^Chain_State) -> int {
	return len(cs.active_chain) - 1
}

// Get the best header height (may be ahead of validated blocks during sync).
chain_header_height :: proc(cs: ^Chain_State) -> int {
	if cs.block_index.best_header != nil {
		return cs.block_index.best_header.height
	}
	return chain_height(cs)
}

// Connect a block to the active chain tip.
connect_block :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry, precomputed_txids: []Hash256 = nil) -> Chain_Error {
	height := entry.height
	t_start := time.tick_now()

	// Use pre-computed txids (from raw-byte hashing during deserialization) when available.
	// Otherwise, compute by re-serializing each tx (slower fallback for accept_block path).
	txids: []Hash256
	if len(precomputed_txids) > 0 && len(precomputed_txids) == len(block.txs) {
		txids = precomputed_txids
	} else {
		computed := make([]Hash256, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			tx := block.txs[i]
			computed[i] = wire.tx_id(&tx)
		}
		txids = computed
	}

	// 1. Context-free validation (pass txids to avoid recomputing for Merkle root)
	block_val := block^
	cerr := consensus.check_block(&block_val, height, cs.params, txids)
	if cerr != .None {
		log.errorf("check_block failed at height %d: %v", height, cerr)
		return .Consensus_Error
	}
	t_txid := time.tick_now()

	// 2. Check duplicate txids within block
	{
		seen := make(map[Hash256]bool, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			if txids[i] in seen {
				return .Duplicate_Tx
			}
			seen[txids[i]] = true
		}
	}

	// 3. BIP30: Check no unspent UTXOs with same txids. After BIP34 activation,
	// duplicate txids are impossible (coinbase includes height), so skip the check.
	// Exception: blocks 91842 and 91880 on mainnet contain known duplicate coinbase
	// txids (duplicating blocks 91722 and 91812). Bitcoin Core exempts these two blocks.
	enforce_bip30 := height < cs.params.bip34_height && height != 91842 && height != 91880
	if enforce_bip30 {
		for i in 0 ..< len(block.txs) {
			tx := block.txs[i]
			for j in 0 ..< len(tx.outputs) {
				op := wire.Outpoint{hash = txids[i], index = u32(j)}
				if coins_cache_has(&cs.coins, op) {
					return .Bip30_Violation
				}
			}
		}
	}

	// 3b. BIP 113: Check transaction finality using MTP after csv_height.
	parent_entry: ^Block_Index_Entry
	mtp_current: u32
	if height > 0 {
		parent_entry = cs.block_index.entries[entry.prev_hash]
	}
	{
		block_time: u32
		if height >= cs.params.csv_height && parent_entry != nil {
			mtp_current = get_median_time_past(parent_entry)
			block_time = mtp_current
		} else {
			block_time = block.header.timestamp
		}
		for tx_idx in 0 ..< len(block.txs) {
			tx := block.txs[tx_idx]
			if !consensus.is_tx_final(&tx, height, block_time) {
				return .Non_Final_Tx
			}
		}
	}

	// 4. Two-phase block validation:
	//    Phase 1: Process UTXO updates sequentially (spend inputs, add outputs, collect fees).
	//             Collect script checks for deferred verification.
	//    Phase 2: Verify all script checks (parallel or serial).
	//    On failure, all UTXO changes are rolled back atomically.
	total_fees: i64 = 0
	script_flags := consensus.get_script_flags(height, cs.params)
	skip_scripts := cs.params.assumevalid_height > 0 && height <= cs.params.assumevalid_height

	undo_coins := make([dynamic]Undo_Coin, 0, 64, context.temp_allocator)
	applied_tx_indices := make([dynamic]int, 0, len(block.txs), context.temp_allocator)

	// Collect spent scriptPubKeys for BIP158 filter building.
	all_spent_scripts: [dynamic][]byte
	if cs.filter_db != nil {
		all_spent_scripts = make([dynamic][]byte, 0, 64, context.temp_allocator)
	}

	// Script check batch: pre-allocate capacity to avoid reallocation (keeps pointers stable).
	batch: Script_Check_Batch
	if !skip_scripts {
		batch.checks = make([dynamic]Script_Check, 0, 256, context.temp_allocator)
		batch.caches = make([dynamic]script.Sighash_Cache, 0, len(block.txs), context.temp_allocator)
	}

	// --- Phase 1: UTXO processing + check collection ---
	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]

		if consensus.is_coinbase_tx(&tx) {
			continue
		}

		// 4a. Look up inputs
		spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
		input_heights := make([]int, len(tx.inputs), context.temp_allocator)
		input_sum: i64 = 0

		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output
			coin, found := coins_cache_get(&cs.coins, prev_out)
			if !found {
				_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
				return .Inputs_Unavailable
			}

			if coin.is_coinbase {
				if height - int(coin.height) < consensus.COINBASE_MATURITY {
					_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
					return .Coinbase_Not_Mature
				}
			}

			input_heights[in_idx] = int(coin.height)

			// Clone script to temp_allocator — coins_cache_spend (step 4d)
			// frees the cache-owned script, so we need a copy that survives
			// through Phase 2 script verification.
			script_clone := make([]byte, len(coin.script), context.temp_allocator)
			copy(script_clone, coin.script)
			spent_outputs[in_idx] = wire.Tx_Out {
				value         = coin.amount,
				script_pubkey = script_clone,
			}
			input_sum += coin.amount

			// Collect for BIP158 filter.
			if cs.filter_db != nil {
				append(&all_spent_scripts, script_clone)
			}
		}

		// 4a2. BIP 68: Check relative lock-time (sequence locks)
		if height >= cs.params.csv_height {
			if !check_sequence_locks(cs, &tx, height, input_heights, mtp_current) {
				_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
				return .Non_Final_Tx
			}
		}

		// 4b. Collect script checks (skipped under assumevalid)
		if !skip_scripts {
			cache_idx := len(batch.caches)
			append(&batch.caches, script.Sighash_Cache{})
			script.sighash_cache_precompute(&batch.caches[cache_idx], &block.txs[tx_idx], spent_outputs)

			for in_idx in 0 ..< len(tx.inputs) {
				witness: [][]byte
				if len(tx.witness) > in_idx {
					witness = tx.witness[in_idx]
				}
				append(&batch.checks, Script_Check{
					tx            = &block.txs[tx_idx],
					input_idx     = in_idx,
					amount        = spent_outputs[in_idx].value,
					flags         = script_flags,
					spent_outputs = spent_outputs,
					sighash_cache = &batch.caches[cache_idx],
					script_sig    = tx.inputs[in_idx].script_sig,
					script_pubkey = spent_outputs[in_idx].script_pubkey,
					witness       = witness,
					tx_idx        = tx_idx,
					height        = height,
				})
			}
		}

		// 4c. Fees
		output_sum: i64 = 0
		for out_idx in 0 ..< len(tx.outputs) {
			output_sum += tx.outputs[out_idx].value
		}
		total_fees += input_sum - output_sum

		// 4d. Spend inputs and collect undo coins
		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output
			spent_coin, ok := coins_cache_spend(&cs.coins, prev_out)
			if !ok {
				_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
				return .Invalid_State
			}
			append(&undo_coins, Undo_Coin{outpoint = prev_out, coin = spent_coin})
		}

		// 4e. Add outputs (available for later txs in same block)
		for out_idx in 0 ..< len(tx.outputs) {
			op := wire.Outpoint{hash = txids[tx_idx], index = u32(out_idx)}
			coin := storage.UTXO_Coin {
				height      = u32(height),
				is_coinbase = false,
				amount      = tx.outputs[out_idx].value,
				script      = tx.outputs[out_idx].script_pubkey,
			}
			coins_cache_add(&cs.coins, op, coin)
		}

		append(&applied_tx_indices, tx_idx)
	}

	t_utxo := time.tick_now()

	// --- Phase 2: Script verification (all checks at once) ---
	if !skip_scripts && len(batch.checks) > 0 {
		serr: script.Script_Error
		if cs.script_threads >= 2 && len(batch.checks) >= PARALLEL_THRESHOLD {
			serr = verify_checks_parallel(cs, &cs.verify_pool, &cs.verify_wg, batch.checks[:], height)
		} else {
			serr = verify_checks_serial(cs, batch.checks[:], height)
		}
		if serr != .None {
			_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
			return .Bad_Script
		}
	}

	t_scripts := time.tick_now()

	// 5. Verify coinbase value <= subsidy + total_fees
	{
		coinbase := block.txs[0]
		coinbase_value: i64 = 0
		for i in 0 ..< len(coinbase.outputs) {
			coinbase_value += coinbase.outputs[i].value
		}
		max_coinbase := consensus.get_block_subsidy(height, cs.params) + total_fees
		if coinbase_value > max_coinbase {
			return .Bad_Coinbase_Value
		}
	}

	// 6. Add coinbase outputs
	{
		coinbase := block.txs[0]
		for out_idx in 0 ..< len(coinbase.outputs) {
			op := wire.Outpoint{hash = txids[0], index = u32(out_idx)}
			coin := storage.UTXO_Coin {
				height      = u32(height),
				is_coinbase = true,
				amount      = coinbase.outputs[out_idx].value,
				script      = coinbase.outputs[out_idx].script_pubkey,
			}
			coins_cache_add(&cs.coins, op, coin)
		}
	}

	// 7. Write undo data
	undo := Block_Undo{spent_coins = undo_coins[:]}
	uerr := write_block_undo(&cs.undo_files, entry, undo)
	if uerr != .None {
		return uerr
	}

	t_undo := time.tick_now()

	// 8. Update entry status and append to active chain
	entry.status += {.Valid_Transactions, .Valid_Chain}
	entry.num_tx = u32(len(block.txs))
	prev_chain_tx: i64 = 0
	if entry.prev != nil {
		prev_chain_tx = entry.prev.chain_tx
	}
	entry.chain_tx = prev_chain_tx + i64(entry.num_tx)

	// Persist updated index record
	rec := block_index_to_record(entry)
	storage.index_db_put(&cs.index_db, rec)

	append(&cs.active_chain, entry.hash)

	// 9. Build and store BIP158 compact block filter (if enabled).
	if cs.filter_db != nil {
		_connect_block_filter(cs, block, entry, all_spent_scripts[:])
	}

	t_end := time.tick_now()

	// Accumulate profiling data.
	cs.prof.blocks += 1
	cs.prof.t_txid    += time.tick_diff(t_start, t_txid)
	cs.prof.t_utxo    += time.tick_diff(t_txid, t_utxo)
	cs.prof.t_scripts += time.tick_diff(t_utxo, t_scripts)
	cs.prof.t_undo    += time.tick_diff(t_scripts, t_undo)
	cs.prof.t_index   += time.tick_diff(t_undo, t_end)
	cs.prof.t_total   += time.tick_diff(t_start, t_end)

	return .None
}

// Disconnect the tip block from the active chain.
disconnect_block :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry) -> Chain_Error {
	// 1. Read undo data
	undo, uerr := read_block_undo(&cs.undo_files, entry, context.temp_allocator)
	if uerr != .None {
		return uerr
	}

	// 2. Remove outputs added by this block (in reverse order)
	for tx_idx := len(block.txs) - 1; tx_idx >= 0; tx_idx -= 1 {
		tx := block.txs[tx_idx]
		txid := wire.tx_id(&tx)
		for out_idx := len(tx.outputs) - 1; out_idx >= 0; out_idx -= 1 {
			op := wire.Outpoint{hash = txid, index = u32(out_idx)}
			coins_cache_spend(&cs.coins, op)
		}
	}

	// 3. Restore spent UTXOs from undo data
	for i in 0 ..< len(undo.spent_coins) {
		uc := undo.spent_coins[i]
		coins_cache_restore(&cs.coins, uc.outpoint, uc.coin)
	}

	// 4. Delete BIP158 filter on disconnect.
	_disconnect_block_filter(cs, entry.hash)

	// 5. Update entry status and pop active chain
	entry.status -= {.Valid_Chain}

	pop(&cs.active_chain)

	return .None
}

// BIP 68 sequence lock constants (duplicated from script/interpreter.odin to avoid cross-package dep).
SEQUENCE_LOCKTIME_DISABLE_FLAG :: u32(1 << 31)
SEQUENCE_LOCKTIME_TYPE_FLAG    :: u32(1 << 22)
SEQUENCE_LOCKTIME_MASK         :: u32(0x0000ffff)
SEQUENCE_LOCKTIME_GRANULARITY  :: 512 // seconds per sequence unit for time-based locks

// Compute median-time-past (MTP) of the previous 11 blocks.
// Used by BIP 113 for nLockTime evaluation and BIP 68 for sequence locks.
get_median_time_past :: proc(entry: ^Block_Index_Entry) -> u32 {
	timestamps: [11]u32
	count := 0
	current := entry
	for count < 11 && current != nil {
		timestamps[count] = current.timestamp
		count += 1
		current = current.prev
	}

	// Insertion sort for <= 11 elements
	for i in 1 ..< count {
		key := timestamps[i]
		j := i - 1
		for j >= 0 && timestamps[j] > key {
			timestamps[j + 1] = timestamps[j]
			j -= 1
		}
		timestamps[j + 1] = key
	}

	return timestamps[count / 2]
}

// BIP 68: Check relative lock-time (sequence locks) for a non-coinbase transaction.
// input_heights contains the height at which each input's coin was mined.
// parent_entry is the block *before* the block being connected.
check_sequence_locks :: proc(cs: ^Chain_State, tx: ^wire.Tx, height: int,
	input_heights: []int, mtp_current: u32) -> bool {
	// BIP 68 only applies to version 2+ transactions
	if tx.version < 2 {
		return true
	}

	for i in 0 ..< len(tx.inputs) {
		seq := tx.inputs[i].sequence

		// If disable flag set, this input has no relative lock constraint
		if seq & SEQUENCE_LOCKTIME_DISABLE_FLAG != 0 {
			continue
		}

		if seq & SEQUENCE_LOCKTIME_TYPE_FLAG != 0 {
			// Time-based relative lock
			// Need MTP at the block *before* the one containing the coin
			coin_height := input_heights[i]
			if coin_height <= 0 {
				return false
			}
			// Look up the entry at coin_height - 1 to get its MTP
			coin_prev_height := coin_height - 1
			if coin_prev_height < 0 || coin_prev_height >= len(cs.active_chain) {
				return false
			}
			coin_prev_hash := cs.active_chain[coin_prev_height]
			coin_prev_entry, found := cs.block_index.entries[coin_prev_hash]
			if !found {
				return false
			}
			mtp_coin := get_median_time_past(coin_prev_entry)
			required_seconds := i64(seq & SEQUENCE_LOCKTIME_MASK) * SEQUENCE_LOCKTIME_GRANULARITY
			if i64(mtp_current) - i64(mtp_coin) < required_seconds {
				return false
			}
		} else {
			// Height-based relative lock
			required_height := int(seq & SEQUENCE_LOCKTIME_MASK)
			if height - input_heights[i] < required_height {
				return false
			}
		}
	}

	return true
}

// Compute the expected nBits for a new block on top of parent_entry.
// Implements Bitcoin Core's GetNextWorkRequired logic including the testnet
// 20-minute minimum difficulty rule and BIP94 (testnet4) variant.
get_next_work_required :: proc(cs: ^Chain_State, parent_entry: ^Block_Index_Entry, block_timestamp: u32) -> u32 {
	params := cs.params
	new_height := parent_entry.height + 1

	if params.pow_no_retargeting {
		return parent_entry.bits
	}

	// At a retarget boundary (new_height % retarget_interval == 0)?
	at_retarget := new_height % params.retarget_interval == 0

	if !at_retarget {
		// Not at retarget — check testnet 20-minute rule
		if params.allow_min_difficulty {
			// If >20 minutes since parent, allow minimum difficulty
			if block_timestamp > parent_entry.timestamp + params.target_spacing * 2 {
				return params.pow_limit_bits
			}
			// Otherwise, walk back to find last non-min-difficulty block
			current := parent_entry
			for current.prev != nil && current.height % params.retarget_interval != 0 && current.bits == params.pow_limit_bits {
				current = current.prev
			}
			return current.bits
		}
		return parent_entry.bits
	}

	// At a retarget boundary. Compute new difficulty.
	// Find the first block of the current retarget period.
	first_height := new_height - params.retarget_interval
	first_entry := block_index_get_ancestor(parent_entry, first_height)
	if first_entry == nil {
		return parent_entry.bits
	}

	// BIP94 (testnet4): use the first block of the period's nBits
	// (which is always real difficulty, never min-difficulty) instead of
	// the last block's nBits (which could be min-difficulty).
	reference_bits := parent_entry.bits
	if params.enforce_bip94 {
		reference_bits = first_entry.bits
	}

	return consensus.calculate_next_work_required(
		first_entry.timestamp,
		parent_entry.timestamp,
		reference_bits,
		params,
	)
}

// Accept a block header: validate and add to block index.
accept_block_header :: proc(cs: ^Chain_State, header: ^wire.Block_Header) -> (^Block_Index_Entry, Chain_Error) {
	hash := wire.block_header_hash(header)

	// Check if already known
	existing, found := cs.block_index.entries[hash]
	if found {
		return existing, .None
	}

	// Validate PoW
	hdr := header^
	cerr := consensus.check_block_header(&hdr, cs.params)
	if cerr != .None {
		return nil, .Consensus_Error
	}

	// Link to parent
	parent_height := -1
	parent_entry: ^Block_Index_Entry
	if header.prev_hash != HASH_ZERO {
		parent, parent_found := cs.block_index.entries[header.prev_hash]
		if !parent_found {
			return nil, .Invalid_Prev_Block
		}
		parent_entry = parent
		parent_height = parent.height
	}

	// Validate difficulty (skip genesis block which has no parent)
	if parent_entry != nil {
		expected_bits := get_next_work_required(cs, parent_entry, header.timestamp)
		if header.bits != expected_bits {
			log.warnf("Bad difficulty at height %d: expected %08x, got %08x", parent_height + 1, expected_bits, header.bits)
			return nil, .Bad_Difficulty
		}
	}

	new_height := parent_height + 1
	status := storage.Block_Status{.Valid_Header}

	entry := block_index_add(&cs.block_index, header, new_height, status)

	// Persist to index DB
	rec := block_index_to_record(entry)
	storage.index_db_put(&cs.index_db, rec)

	return entry, .None
}

// Accept a batch of block headers in a single atomic WriteBatch.
// Returns the number accepted and the best new header height.
accept_block_headers_batch :: proc(cs: ^Chain_State, headers: []wire.Block_Header) -> (accepted: int, best_height: int) {
	best_height = cs.block_index.best_header != nil ? cs.block_index.best_header.height : -1

	if len(headers) == 0 {
		return 0, best_height
	}

	batch := storage.ldb_batch_create()
	defer storage.ldb_batch_destroy(batch)

	for i in 0 ..< len(headers) {
		hdr := headers[i]
		hash := wire.block_header_hash(&hdr)

		// Skip already-known headers.
		if hash in cs.block_index.entries {
			continue
		}

		// Validate PoW.
		cerr := consensus.check_block_header(&hdr, cs.params)
		if cerr != .None {
			continue
		}

		// Link to parent.
		parent_height := -1
		batch_parent: ^Block_Index_Entry
		if hdr.prev_hash != HASH_ZERO {
			parent, parent_found := cs.block_index.entries[hdr.prev_hash]
			if !parent_found {
				continue
			}
			batch_parent = parent
			parent_height = parent.height
		}

		// Validate difficulty (skip genesis).
		if batch_parent != nil {
			expected_bits := get_next_work_required(cs, batch_parent, hdr.timestamp)
			if hdr.bits != expected_bits {
				log.warnf("Bad difficulty at height %d: expected %08x, got %08x", parent_height + 1, expected_bits, hdr.bits)
				continue
			}
		}

		new_height := parent_height + 1
		status := storage.Block_Status{.Valid_Header}

		entry := block_index_add(&cs.block_index, &hdr, new_height, status)
		rec := block_index_to_record(entry)

		storage.index_db_batch_put(&cs.index_db, batch, rec)

		accepted += 1
		if new_height > best_height {
			best_height = new_height
		}
	}

	// Commit the entire batch atomically.
	if accepted > 0 {
		cerr := storage.ldb_batch_write(cs.store.index_db, cs.store.sync_opts, batch)
		if cerr != .None {
			log.errorf("Failed to commit header batch: %v", cerr)
			return 0, best_height
		}
	}

	return accepted, best_height
}

// Accept a full block: accept header, store block data, connect to chain.
accept_block :: proc(cs: ^Chain_State, block: ^wire.Block) -> Chain_Error {
	// Accept header
	header := block.header
	entry, herr := accept_block_header(cs, &header)
	if herr != .None {
		return herr
	}

	// Store block data
	blk := block^
	loc, serr := storage.block_db_store(&cs.block_db, &blk)
	if serr != .None {
		return .Storage_Error
	}

	entry.file_num = loc.file_num
	entry.data_offset = loc.data_offset
	entry.data_size = loc.data_size
	entry.status += {.Has_Data}

	// Connect block
	return connect_block(cs, block, entry)
}

// Store a block to disk without connecting it to the active chain.
// Used during sync to buffer out-of-order blocks.
store_block :: proc(cs: ^Chain_State, block: ^wire.Block) -> Chain_Error {
	header := block.header
	entry, herr := accept_block_header(cs, &header)
	if herr != .None {
		return herr
	}

	// Already stored — skip.
	if .Has_Data in entry.status {
		return .None
	}

	blk := block^
	loc, serr := storage.block_db_store(&cs.block_db, &blk)
	if serr != .None {
		return .Storage_Error
	}

	entry.file_num = loc.file_num
	entry.data_offset = loc.data_offset
	entry.data_size = loc.data_size
	entry.status += {.Has_Data}

	// In-memory index is updated; LevelDB persist deferred to connect_block
	// which writes the final status (Has_Data + Valid_Chain). On crash,
	// un-persisted blocks are re-downloaded — connect_pending_blocks handles this.

	return .None
}

// Try to connect the next block(s) at tip+1. Reads stored blocks from disk.
// Returns the number of blocks connected and hashes of any blocks that need re-download.
connect_pending_blocks :: proc(cs: ^Chain_State, redownload: ^[dynamic]Hash256 = nil) -> (connected: int, err: Chain_Error) {
	// Per-block scratch arena: each block deserialization allocates txs, scripts,
	// and witness data. Without per-iteration cleanup, connecting thousands of
	// blocks leaks gigabytes into the caller's temp_allocator.
	block_arena_buf := make([]byte, 64 * 1024 * 1024) // 64 MB scratch
	defer delete(block_arena_buf)
	block_arena: mem.Arena
	mem.arena_init(&block_arena, block_arena_buf)
	block_alloc := mem.arena_allocator(&block_arena)

	// Limit blocks per call so the caller (P2P thread) isn't blocked too long.
	// Remaining blocks are picked up on the next incoming block message.
	MAX_CONNECT_BATCH :: 256

	// Bootstrap genesis: peers don't serve genesis via getdata (it's hardcoded),
	// so it never gets Has_Data from download. If the chain is empty and block 1
	// has data waiting, promote genesis directly so the chain can advance.
	if len(cs.active_chain) == 0 && cs.block_index.genesis != nil && .Valid_Chain not_in cs.block_index.genesis.status {
		genesis_hash := cs.block_index.genesis.hash
		// Check if block 1 (child of genesis) exists and has data.
		child := cs.block_index.by_prev[genesis_hash]
		if child != nil && .Has_Data in child.status {
			cs.block_index.genesis.status += {.Valid_Chain}
			append(&cs.active_chain, genesis_hash)
			rec := block_index_to_record(cs.block_index.genesis)
			storage.index_db_put(&cs.index_db, rec)
			log.infof("Genesis block bootstrapped into active chain")
			connected += 1
		}
	}

	for connected < MAX_CONNECT_BATCH {
		tip_hash, _ := chain_tip(cs)

		// O(1) child lookup via by_prev index.
		next_entry := cs.block_index.by_prev[tip_hash]
		if next_entry == nil || .Has_Data not_in next_entry.status || .Valid_Chain in next_entry.status {
			return connected, .None
		}

		// Reset arena for this block — frees block data AND connect_block's
		// temp allocations (seen map, undo_coins, spent_outputs) from prev iteration.
		mem.arena_free_all(&block_arena)
		context.temp_allocator = block_alloc

		// Read block from disk (with pre-computed txids from raw bytes).
		t_read_start := time.tick_now()
		loc := storage.Block_Location{
			file_num    = next_entry.file_num,
			data_offset = next_entry.data_offset,
			data_size   = next_entry.data_size,
		}
		block, txids, rerr := storage.block_db_read_with_txids(&cs.block_db, loc, block_alloc)
		if rerr != .None {
			// Corrupt/truncated flat file data — strip Has_Data so it gets re-downloaded.
			log.warnf("Pending block at height %d unreadable — marking for re-download", next_entry.height)
			next_entry.status -= {.Has_Data}
			rec := block_index_to_record(next_entry)
			storage.index_db_put(&cs.index_db, rec)
			if redownload != nil {
				append(redownload, next_entry.hash)
			}
			return connected, .None
		}
		cs.prof.t_read += time.tick_diff(t_read_start, time.tick_now())

		cerr := connect_block(cs, &block, next_entry, txids)
		if cerr != .None {
			if cerr == .Storage_Error {
				// Storage/read error — strip Has_Data so it gets re-downloaded.
				log.warnf("Pending block at height %d storage error — marking for re-download", next_entry.height)
				next_entry.status -= {.Has_Data}
				rec := block_index_to_record(next_entry)
				storage.index_db_put(&cs.index_db, rec)
				if redownload != nil {
					append(redownload, next_entry.hash)
				}
			} else {
				// Validation error (Bad_Script, Consensus_Error, etc.) — re-downloading
				// won't help. Log and stop connecting; block stays stored but unconnected.
				log.errorf("Block validation FAILED at height %d: %v — halting chain progress", next_entry.height, cerr)
			}
			return connected, cerr
		}

		connected += 1

		// Log profiling data every 1000 blocks.
		if cs.prof.blocks >= 1000 {
			p := &cs.prof
			// Wall time = read (disk+deserialize+txid) + connect_block phases.
			wall_ms := time.duration_milliseconds(p.t_read + p.t_total)
			if wall_ms > 0 {
				read_ms    := time.duration_milliseconds(p.t_read)
				valid_ms   := time.duration_milliseconds(p.t_txid) // check_block + txid (near-zero with precomputed)
				utxo_ms    := time.duration_milliseconds(p.t_utxo)
				scripts_ms := time.duration_milliseconds(p.t_scripts)
				undo_ms    := time.duration_milliseconds(p.t_undo)
				index_ms   := time.duration_milliseconds(p.t_index)
				log.infof(
					"PROFILE %d blks @ height %d: wall=%.0fms (%.1fms/blk) | read=%.0fms (%.0f%%) valid=%.0fms (%.0f%%) utxo=%.0fms (%.0f%%) scripts=%.0fms (%.0f%%) undo=%.0fms (%.0f%%) index=%.0fms (%.0f%%)",
					p.blocks, next_entry.height,
					wall_ms, wall_ms / f64(p.blocks),
					read_ms, read_ms / wall_ms * 100,
					valid_ms, valid_ms / wall_ms * 100,
					utxo_ms, utxo_ms / wall_ms * 100,
					scripts_ms, scripts_ms / wall_ms * 100,
					undo_ms, undo_ms / wall_ms * 100,
					index_ms, index_ms / wall_ms * 100,
				)
			}
			p.blocks = 0
			p.t_read = {}
			p.t_txid = {}
			p.t_utxo = {}
			p.t_scripts = {}
			p.t_undo = {}
			p.t_index = {}
			p.t_total = {}
		}
	}

	return connected, .None
}

// Roll back UTXO cache changes from a partially-applied block.
// Processes applied transactions in reverse order: first removes outputs,
// then restores spent inputs. This handles intra-block spending correctly
// because reversing in order ensures outputs are restored before being removed.
_rollback_applied_txs :: proc(cs: ^Chain_State, block: ^wire.Block, applied: []int, undo_coins: []Undo_Coin) {
	if len(applied) == 0 {
		return
	}

	// Walk applied txs in reverse, undoing outputs then restoring inputs.
	undo_offset := len(undo_coins)

	for i := len(applied) - 1; i >= 0; i -= 1 {
		tx_idx := applied[i]
		tx := block.txs[tx_idx]

		// Remove this tx's outputs (they were added as Fresh, so spending removes them).
		txid := wire.tx_id(&tx)
		for out_idx := len(tx.outputs) - 1; out_idx >= 0; out_idx -= 1 {
			op := wire.Outpoint{hash = txid, index = u32(out_idx)}
			coins_cache_spend(&cs.coins, op)
		}

		// Restore this tx's spent inputs.
		num_inputs := len(tx.inputs)
		undo_offset -= num_inputs
		for j in 0 ..< num_inputs {
			uc := undo_coins[undo_offset + j]
			coins_cache_restore(&cs.coins, uc.outpoint, uc.coin)
		}
	}
}

// Read the meta tip (hash + height) from LevelDB. On crash recovery, if the
// block index has entries marked Valid_Chain beyond the meta tip, strip
// those flags so connect_pending_blocks can replay them.
_recover_from_meta :: proc(cs: ^Chain_State) {
	meta_hash, meta_height, ok := _read_meta_tip(&cs.store)
	if !ok {
		// No meta tip yet (fresh DB) — nothing to recover.
		return
	}

	// Find the highest Valid_Chain entry in the block index.
	best_valid: ^Block_Index_Entry = nil
	for _, entry in cs.block_index.entries {
		if .Valid_Chain in entry.status {
			if best_valid == nil || entry.height > best_valid.height {
				best_valid = entry
			}
		}
	}

	if best_valid == nil {
		return
	}

	// If the block index extends beyond the meta tip, strip Valid_Chain
	// from entries above meta_height so they get replayed.
	if best_valid.height > meta_height {
		log.infof("Crash recovery: index tip %d > meta tip %d, rolling back %d blocks",
			best_valid.height, meta_height, best_valid.height - meta_height)

		for _, entry in cs.block_index.entries {
			if .Valid_Chain in entry.status && entry.height > meta_height {
				entry.status -= {.Valid_Chain}
			}
		}
	}
}

// Read chain tip metadata from LevelDB chainstate database.
// Returns (hash, height, ok).
_read_meta_tip :: proc(store: ^storage.LDB_Store) -> (Hash256, int, bool) {
	key_str := "tip"
	key := transmute([]byte)key_str
	data, found := storage.ldb_get(store.chainstate_db, store.read_opts, key, context.temp_allocator)
	if !found || len(data) < 36 {
		return HASH_ZERO, -1, false
	}

	hash: Hash256
	for i in 0 ..< 32 {
		hash[i] = data[i]
	}
	height := int(u32(data[32]) | u32(data[33]) << 8 | u32(data[34]) << 16 | u32(data[35]) << 24)
	return hash, height, true
}

// Add chain tip metadata to a WriteBatch (committed atomically with UTXOs).
write_meta_tip :: proc(store: ^storage.LDB_Store, batch: storage.LDB_WriteBatch, tip_hash: Hash256, tip_height: int) {
	key_str := "tip"
	key := transmute([]byte)key_str

	// Value: hash[32] + height[4 LE] = 36 bytes
	val: [36]byte
	h := tip_hash
	for i in 0 ..< 32 {
		val[i] = h[i]
	}
	ht := u32(tip_height)
	val[32] = byte(ht)
	val[33] = byte(ht >> 8)
	val[34] = byte(ht >> 16)
	val[35] = byte(ht >> 24)

	storage.ldb_batch_put(batch, key, val[:])
}

// Rebuild active chain by walking from genesis through prev pointers.
_rebuild_active_chain :: proc(cs: ^Chain_State) {
	if cs.block_index.genesis == nil {
		return
	}

	// Find the tip: entry with highest height that has Valid_Chain status
	tip: ^Block_Index_Entry = nil
	for _, entry in cs.block_index.entries {
		if .Valid_Chain in entry.status {
			if tip == nil || entry.height > tip.height {
				tip = entry
			}
		}
	}

	if tip == nil {
		return
	}

	// Walk from tip to genesis to collect the chain
	chain_len := tip.height + 1
	resize(&cs.active_chain, chain_len)

	current := tip
	for current != nil {
		if current.height >= 0 && current.height < chain_len {
			cs.active_chain[current.height] = current.hash
		}
		current = current.prev
	}
}

// Walk the active chain forward (genesis → tip) and compute cumulative chain_tx.
_compute_chain_tx :: proc(cs: ^Chain_State) {
	running_total: i64 = 0
	for i in 0 ..< len(cs.active_chain) {
		entry, found := cs.block_index.entries[cs.active_chain[i]]
		if !found { continue }
		running_total += i64(entry.num_tx)
		entry.chain_tx = running_total
	}
}
