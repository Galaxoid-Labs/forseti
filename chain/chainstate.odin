package chain

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "../consensus"
import crypto "../crypto"
import "../drivechain"
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
	// Per-input verification arena (growing, serial path). BIP342 tapscripts have
	// no script size cap, so a fixed arena can be exhausted by a single input
	// (mainnet 899747: 3.95MB single-input tx) — silent alloc failures then panic.
	verify_arena:   virtual.Arena,
	verify_alloc:   mem.Allocator,
	// Parallel script verification
	verify_pool:    thread.Pool,
	verify_wg:      sync.Wait_Group,
	script_threads: int, // >= 2 = parallel (pool active), < 2 = serial (no pool)
	// Growing-arena pool for parallel workers (avoids alloc/free per check)
	arena_pool_arenas: []virtual.Arena, // one growing arena per worker thread
	arena_pool_stack:  [dynamic]int,    // indices of available arenas (protected by mutex)
	arena_pool_mu:     sync.Mutex,
	// BIP 158 compact block filter index (nil when disabled)
	filter_db: ^storage.Filter_DB,
	// Transaction index (--txindex; nil when disabled, prune-incompatible)
	tx_index: ^storage.Tx_Index_DB,
	// Performance profiling counters (cumulative, logged every 1000 blocks)
	prof: Block_Profile,
	// Pruning: target bytes for blk+rev files (0 = keep everything);
	// prune_height = lowest height whose block data is still on disk;
	// last_flush_height = durable UTXO state (never prune above it).
	prune_target:      int,
	prune_height:      int,
	last_flush_height: int,
	last_halt_log_height: int, // rate-limits the validation-halt error log
	halt_height: int,         // 0 = healthy; else validation is stuck at this height
	halt_error:  Chain_Error, // why
	recovery_failed: bool, // crash recovery could not reconcile — refuse to run
	// BIP300/301 drivechain (off = zero-cost, no state touched)
	dc_mode:  drivechain.Mode,
	dc_state: drivechain.State,
}

Block_Profile :: struct {
	blocks:      int,          // blocks since last log
	t_read:      time.Duration, // disk read + deserialize
	t_prefetch:  time.Duration, // UTXO prefetch (parallel LevelDB reads)
	t_txid:      time.Duration, // txid computation
	t_utxo:      time.Duration, // Phase 1: UTXO lookups + spends + adds
	t_scripts:   time.Duration, // Phase 2: script verification
	t_undo:      time.Duration, // undo data write
	t_index:     time.Duration, // index update + chain append
	t_total:     time.Duration, // total connect_block time
}

// Initialize chain state. Caller allocates Chain_State and passes pointer.
// script_threads: 0 or 1 = serial verification, >= 2 = parallel with N worker threads.
// Live startup stage for loading screens. cstring of static literals only —
// a single aligned pointer store/load is atomic on our targets, so the GUI
// thread reads it lock-free while init runs.
Boot_Stage: cstring = ""

// Recovery rollback progress for loading screens (plain ints — single
// writer, torn reads impossible on aligned word stores).
Boot_Rollback_Done: int
Boot_Rollback_Total: int

chain_state_init :: proc(cs: ^Chain_State, data_dir: string, params: ^consensus.Chain_Params, db_cache_mb: int = 450, script_threads: int = 0, prune_target: int = 0, dc_mode: drivechain.Mode = .Off) -> Chain_Error {
	cs.params = params
	cs.prune_target = prune_target
	cs.dc_mode = dc_mode

	// Ensure data_dir exists
	os.make_directory(data_dir)

	// Open shared LevelDB store (chainstate + block index)
	Boot_Stage = "Opening databases (replaying write-ahead log if needed)"
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

	// Build in-memory block index — pre-allocate maps to avoid rehashing.
	cs.block_index = block_index_init(capacity = len(cs.index_db.records) * 2)
	Boot_Stage = "Building block index"
	log.infof("Building block index (%d records)...", len(cs.index_db.records))
	block_index_load(&cs.block_index, &cs.index_db)
	log.infof("Block index loaded: %d entries, best header height %d",
		len(cs.block_index.entries),
		cs.block_index.best_header != nil ? cs.block_index.best_header.height : 0)

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
	Boot_Stage = "Rebuilding active chain"
	_recover_from_meta(cs)
	if cs.recovery_failed {
		return .Storage_Error
	}

	_rebuild_active_chain(cs)
	log.infof("Active chain rebuilt: %d blocks", len(cs.active_chain))

	// The recovered tip IS the durable flush point (pending blocks connected
	// below are beyond it and must not be pruned until the next flush).
	{
		_, flushed_h := chain_tip(cs)
		cs.last_flush_height = flushed_h
	}

	// Compute cumulative chain_tx for the active chain
	_compute_chain_tx(cs)

	// Load drivechain state (must precede connect_pending_blocks, which
	// re-applies blocks above the flush point through connect_block).
	Boot_Stage = "Loading drivechain state"
	_dc_load(cs)

	// Rolling UTXO stats: the persisted counters are atomic with the meta
	// tip (same batch), so after recovery they match the rebuilt chain and
	// the pending-block replay advances them through the normal cache hooks.
	// Fresh datadirs track from genesis; legacy datadirs (no key, non-empty
	// chain) keep the slow-scan gettxoutsetinfo until a resync.
	{
		key := transmute([]byte)string(UTXO_STATS_KEY)
		blob, found := storage.ldb_get(cs.store.chainstate_db, cs.store.read_opts, key, context.temp_allocator)
		_, stats_tip := chain_tip(cs)
		if found && len(blob) >= 16 {
			c, a := u64(0), u64(0)
			for i in 0 ..< 8 {
				c |= u64(blob[i]) << uint(i * 8)
				a |= u64(blob[8 + i]) << uint(i * 8)
			}
			cs.coins.stat_count = transmute(i64)c
			cs.coins.stat_amount = transmute(i64)a
			cs.coins.stats_valid = true
			log.infof("UTXO stats loaded: %d coins, %d sat", cs.coins.stat_count, cs.coins.stat_amount)
		} else if stats_tip < 0 {
			cs.coins.stats_valid = true // fresh datadir — tracked from genesis
		} else {
			log.info("UTXO stats: not tracked for this datadir (predates rolling stats); gettxoutsetinfo will scan — resync to enable instant stats")
		}
	}

	// Persistent per-input verification arena (growing; starts at 8 MB, grows for
	// oversized tapscripts, overflow blocks released on each free_all)
	if verr := virtual.arena_init_growing(&cs.verify_arena, 8 * 1024 * 1024); verr != nil {
		return .Storage_Error
	}
	cs.verify_alloc = virtual.arena_allocator(&cs.verify_arena)

	// Initialize parallel script verification thread pool
	cs.script_threads = script_threads
	if script_threads >= 2 {
		thread.pool_init(&cs.verify_pool, context.allocator, script_threads)
		thread.pool_start(&cs.verify_pool)

		// Pre-initialize growing arenas for workers (avoids alloc/free per check).
		cs.arena_pool_arenas = make([]virtual.Arena, script_threads)
		cs.arena_pool_stack = make([dynamic]int, 0, script_threads)
		for i in 0 ..< script_threads {
			if verr := virtual.arena_init_growing(&cs.arena_pool_arenas[i], 8 * 1024 * 1024); verr != nil {
				return .Storage_Error
			}
			append(&cs.arena_pool_stack, i)
		}
	}

	// Connect any stored-but-not-connected blocks from a previous session.
	Boot_Stage = "Connecting pending blocks"
	log.infof("Connecting pending blocks (if any)...")
	pending_connected, _ := connect_pending_blocks(cs)
	if pending_connected > 0 {
		_, tip_height := chain_tip(cs)
		log.infof("Connected %d pending blocks on startup (tip now at height %d)", pending_connected, tip_height)
	}

	// Reclaim disk from any files that became prunable before the last shutdown.
	Boot_Stage = "Pruning old block files"
	prune_block_files(cs, cs.last_flush_height)

	Boot_Stage = ""
	return .None
}

// Destroy chain state, flushing everything to disk.
chain_state_destroy :: proc(cs: ^Chain_State) {
	// Shut down parallel verification pool before flushing
	if cs.script_threads >= 2 {
		thread.pool_join(&cs.verify_pool)
		thread.pool_destroy(&cs.verify_pool)
		for &arena in cs.arena_pool_arenas {
			virtual.arena_destroy(&arena)
		}
		delete(cs.arena_pool_arenas)
		delete(cs.arena_pool_stack)
	}

	tip_hash, tip_height := chain_tip(cs)
	dc_blob := dc_flush_blob(cs, context.temp_allocator)
	coins_cache_flush(&cs.coins, tip_hash, tip_height, dc_blob)
	coins_cache_destroy(&cs.coins)
	drivechain.state_destroy(&cs.dc_state)
	// LevelDB close can trigger compaction after a large flush — log so a slow
	// shutdown here doesn't look like a hang.
	Boot_Stage = "Closing databases"
	log.info("Closing databases...")
	if cs.filter_db != nil {
		storage.filter_db_close(cs.filter_db)
		free(cs.filter_db)
		cs.filter_db = nil
	}
	if cs.tx_index != nil {
		storage.tx_index_db_close(cs.tx_index)
		free(cs.tx_index)
		cs.tx_index = nil
	}
	storage.utxo_db_close(&cs.utxo_db)
	storage.block_db_close(&cs.block_db)
	storage.index_db_close(&cs.index_db)
	storage.ldb_close(&cs.store)
	storage.flat_file_close(&cs.undo_files)
	block_index_destroy(&cs.block_index)
	delete(cs.active_chain)
	virtual.arena_destroy(&cs.verify_arena)
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
	// Single pass: look up, validate, spend, collect script checks, add outputs.
	// Merges the separate get+spend into one operation to avoid double map lookups.
	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]

		if consensus.is_coinbase_tx(&tx) {
			continue
		}

		// 4a. Look up + spend inputs in a single pass
		spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
		input_heights := make([]int, len(tx.inputs), context.temp_allocator)
		input_sum: i64 = 0

		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output

			// coins_cache_spend does the lookup+spend atomically.
			// The returned coin's script is cloned to temp_allocator.
			spent_coin, ok := coins_cache_spend(&cs.coins, prev_out)
			if !ok {
				_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
				return .Inputs_Unavailable
			}

			if spent_coin.is_coinbase {
				if height - int(spent_coin.height) < consensus.COINBASE_MATURITY {
					// Restore the spent coin before rolling back
					coins_cache_restore(&cs.coins, prev_out, spent_coin)
					_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
					return .Coinbase_Not_Mature
				}
			}

			input_heights[in_idx] = int(spent_coin.height)

			// Script is already on temp_allocator from coins_cache_spend
			spent_outputs[in_idx] = wire.Tx_Out {
				value         = spent_coin.amount,
				script_pubkey = spent_coin.script,
			}
			input_sum += spent_coin.amount

			// Collect undo coins immediately
			append(&undo_coins, Undo_Coin{outpoint = prev_out, coin = spent_coin})

			// Collect for BIP158 filter.
			if cs.filter_db != nil {
				append(&all_spent_scripts, spent_coin.script)
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

		// 4d. Add outputs (available for later txs in same block)
		for out_idx in 0 ..< len(tx.outputs) {
			if _is_unspendable(tx.outputs[out_idx].script_pubkey) {
				continue
			}
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

	// 4e. Drivechain (BIP300/301): validate against + apply to D1/D2. In
	// enforce mode a violation rejects the block (DC state already restored
	// inside the hook; UTXO changes rolled back here).
	if cs.dc_mode != .Off {
		if !_dc_connect(cs, block, entry, txids) {
			_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
			return .Drivechain_Violation
		}
	}

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
			if _is_unspendable(coinbase.outputs[out_idx].script_pubkey) {
				continue
			}
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

	// 9b. Transaction index (if enabled).
	if cs.tx_index != nil {
		_tx_index_connect(cs, entry, txids)
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

	// 4b. Restore drivechain state to the pre-block snapshot (if this block
	// changed it).
	if cs.dc_mode != .Off {
		_dc_disconnect(cs, entry)
	}

	// 4c. Unwind the transaction index (if enabled).
	if cs.tx_index != nil {
		_tx_index_disconnect(cs, block, entry)
	}

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
			log.warnf("Header PoW reject at batch idx %d: %v", i, cerr)
			continue
		}

		// Link to parent.
		parent_height := -1
		batch_parent: ^Block_Index_Entry
		if hdr.prev_hash != HASH_ZERO {
			parent, parent_found := cs.block_index.entries[hdr.prev_hash]
			if !parent_found {
				log.warnf("Header orphan reject at batch idx %d (parent unknown)", i)
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

// Bitcoin Core parity: provably-unspendable outputs (OP_RETURN, oversized
// scripts) are never added to the UTXO set — they can't be spent, and
// storing them bloated mainnet chainstate by tens of millions of entries.
_is_unspendable :: proc(spk: []byte) -> bool {
	return len(spk) > 10_000 || (len(spk) >= 1 && spk[0] == 0x6a)
}

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

		// Prefetch UTXOs: parallel LevelDB reads to warm coins cache.
		// Reuses the script verification thread pool (idle under assumevalid).
		if cs.script_threads >= 2 {
			t_pf_start := time.tick_now()
			_prefetch_block_utxos(cs, &block, block_alloc)
			cs.prof.t_prefetch += time.tick_diff(t_pf_start, time.tick_now())
		}

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
				if cs.last_halt_log_height != next_entry.height {
					cs.last_halt_log_height = next_entry.height
					log.errorf("Block validation FAILED at height %d: %v — halting chain progress", next_entry.height, cerr)
				}
				cs.halt_height = next_entry.height
				cs.halt_error = cerr
			}
			return connected, cerr
		}

		connected += 1
		cs.halt_height = 0 // progress clears any prior halt state

		// Log profiling data every 1000 blocks.
		if cs.prof.blocks >= 1000 {
			p := &cs.prof
			// Wall time = read + prefetch + connect_block phases.
			wall_ms := time.duration_milliseconds(p.t_read + p.t_prefetch + p.t_total)
			if wall_ms > 0 {
				read_ms     := time.duration_milliseconds(p.t_read)
				prefetch_ms := time.duration_milliseconds(p.t_prefetch)
				valid_ms    := time.duration_milliseconds(p.t_txid) // check_block + txid (near-zero with precomputed)
				utxo_ms     := time.duration_milliseconds(p.t_utxo)
				scripts_ms  := time.duration_milliseconds(p.t_scripts)
				undo_ms     := time.duration_milliseconds(p.t_undo)
				index_ms    := time.duration_milliseconds(p.t_index)
				log.infof(
					"PROFILE %d blks @ height %d: wall=%.0fms (%.1fms/blk) | read=%.0fms (%.0f%%) prefetch=%.0fms (%.0f%%) valid=%.0fms (%.0f%%) utxo=%.0fms (%.0f%%) scripts=%.0fms (%.0f%%) undo=%.0fms (%.0f%%) index=%.0fms (%.0f%%)",
					p.blocks, next_entry.height,
					wall_ms, wall_ms / f64(p.blocks),
					read_ms, read_ms / wall_ms * 100,
					prefetch_ms, prefetch_ms / wall_ms * 100,
					valid_ms, valid_ms / wall_ms * 100,
					utxo_ms, utxo_ms / wall_ms * 100,
					scripts_ms, scripts_ms / wall_ms * 100,
					undo_ms, undo_ms / wall_ms * 100,
					index_ms, index_ms / wall_ms * 100,
				)
			}
			p.blocks = 0
			p.t_read = {}
			p.t_prefetch = {}
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

// Prefetch a block's input UTXOs from LevelDB in parallel to warm the coins cache.
// Collects all input outpoints not already cached, dispatches parallel LevelDB reads
// across the script verification thread pool, then merges results into the cache.
_prefetch_block_utxos :: proc(cs: ^Chain_State, block: ^wire.Block, block_alloc: mem.Allocator) {
	// Count total non-coinbase inputs.
	total_inputs := 0
	for tx_idx in 0 ..< len(block.txs) {
		if consensus.is_coinbase_tx(&block.txs[tx_idx]) { continue }
		total_inputs += len(block.txs[tx_idx].inputs)
	}

	if total_inputs < PARALLEL_THRESHOLD {
		return
	}

	// Collect outpoints not already in the cache.
	outpoints := make([dynamic]wire.Outpoint, 0, total_inputs, block_alloc)
	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]
		if consensus.is_coinbase_tx(&tx) { continue }
		for in_idx in 0 ..< len(tx.inputs) {
			op := tx.inputs[in_idx].previous_output
			if op not_in cs.coins.cache {
				append(&outpoints, op)
			}
		}
	}

	if len(outpoints) == 0 {
		return
	}

	items := prefetch_utxos_parallel(cs, &cs.verify_pool, outpoints[:], block_alloc)
	if items != nil {
		merged := coins_cache_prefetch_merge(&cs.coins, items)
		if merged > 0 {
			log.debugf("Prefetched %d/%d UTXOs (%d cache misses)", merged, total_inputs, len(outpoints))
		}
	}
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

	// If the block index extends beyond the meta tip, the UTXO set on disk
	// may reflect ANY partially-flushed state in (meta_tip, index_tip]: a
	// flush writes data chunks before the tip marker, so a failed or
	// interrupted flush leaves data ahead of the tip. Naively reconnecting
	// blocks over such a state dies on already-spent inputs (mainnet wedge
	// at 729,325, 2026-07-06). Undo-based rollback is state-independent:
	// force every key in the range to its pre-block value from the rev
	// files, which converges to the exact set @meta_tip no matter which
	// subset of writes landed (Bitcoin Core's ReplayBlocks approach).
	// Blocks in this range are above the last flush point, so pruning has
	// never touched their block/undo data.
	if best_valid.height > meta_height {
		Boot_Stage = "Recovering from unclean shutdown (rolling back blocks)"
		log.infof("Crash recovery: index tip %d > meta tip %d, rolling back %d blocks via undo data",
			best_valid.height, meta_height, best_valid.height - meta_height)

		// Records written before format v3 lack undo locations — rebuild
		// them from the rev files before rolling back.
		needs_rebuild := false
		for entry := best_valid; entry != nil && entry.height > meta_height; entry = entry.prev {
			if .Has_Undo in entry.status && entry.undo_size == 0 {
				needs_rebuild = true
				break
			}
		}
		if needs_rebuild && !_rebuild_undo_locations(cs, meta_height, best_valid) {
			// REFUSE to run: proceeding once advanced the meta tip over an
			// unreconciled UTXO set (bookmark said 734,886, data didn't),
			// converting a repairable state into a lying one.
			log.errorf("Crash recovery: could not rebuild undo locations — refusing to start with inconsistent UTXO state")
			cs.recovery_failed = true
			return
		}

		Boot_Rollback_Total = best_valid.height - meta_height
		Boot_Rollback_Done = 0
		for entry := best_valid; entry != nil && entry.height > meta_height; entry = entry.prev {
			Boot_Rollback_Done += 1
			if Boot_Rollback_Done % 5000 == 0 {
				log.infof("Crash recovery: rolled back %d / %d blocks (at height %d)",
					Boot_Rollback_Done, Boot_Rollback_Total, entry.height)
			}
			if rerr := _rollback_block_for_recovery(cs, entry); rerr != .None {
				// A half-applied rollback + continuing to run is how a
				// recoverable state becomes a lying one — refuse instead.
				log.errorf("Crash recovery: rollback failed at height %d (%v) — refusing to start",
					entry.height, rerr)
				cs.recovery_failed = true
				return
			}
		}

		for _, entry in cs.block_index.entries {
			if .Valid_Chain in entry.status && entry.height > meta_height {
				entry.status -= {.Valid_Chain}
				// PERSIST the strip: in-memory-only stripping left the DB
				// records claiming Valid_Chain up to the crash tip, so every
				// restart re-triggered the same full rollback (79k blocks,
				// ~25 min, each boot) until sync passed the old tip.
				rec := block_index_to_record(entry)
				storage.index_db_put(&cs.index_db, rec)
			}
		}
		Boot_Rollback_Total = 0
		Boot_Rollback_Done = 0
	}
}

// Rebuild in-memory undo locations for (meta_height, tip] by scanning the
// rev files. Undo records carry no block hash, but they are appended in
// connect order — which equals height order on a node that has never
// reorged mid-range — so the stream tail aligns with the index tip. Every
// assignment is content-verified against its block (spent-coin count and
// first spent outpoint must match the block's non-coinbase inputs) before
// anything is rolled back; any mismatch aborts untouched. Rebuilt locations
// are persisted so the next startup doesn't rescan.
_rebuild_undo_locations :: proc(cs: ^Chain_State, meta_height: int, tip: ^Block_Index_Entry) -> bool {
	Undo_Pos :: struct {
		file_num: u32,
		offset:   u32,
		size:     u32,
	}
	// Heap, NOT temp: _verify_undo_matches_block free_all()s the temp
	// allocator per block (blocks+undo would otherwise pile up ~2.5MB ×
	// thousands of blocks).
	positions := make([dynamic]Undo_Pos, 0, 16384)
	defer delete(positions)

	// Forward-parse every remaining rev file in ascending order:
	// records are [size:4 LE][payload].
	for fn in 0 ..= cs.undo_files.current_file {
		fsize := storage.flat_file_size(&cs.undo_files, fn)
		if fsize <= 0 {
			continue // pruned or absent
		}
		off: u32 = 0
		for i64(off) + 4 <= fsize {
			hdr, herr := storage.flat_file_read(&cs.undo_files, storage.File_Pos{file_num = fn, offset = off}, 4, context.temp_allocator)
			if herr != .None {
				break
			}
			rec_size := u32(hdr[0]) | u32(hdr[1]) << 8 | u32(hdr[2]) << 16 | u32(hdr[3]) << 24
			if rec_size == 0 || i64(off) + 4 + i64(rec_size) > fsize {
				break // truncated tail (interrupted final write)
			}
			append(&positions, Undo_Pos{file_num = fn, offset = off + 4, size = rec_size})
			off += 4 + rec_size
			if len(positions) % 4096 == 0 {
				free_all(context.temp_allocator) // header reads
			}
		}
	}

	// Find the alignment: the stream tail SHOULD be the tip, but an
	// interrupted final undo write truncates the tail — search which height
	// the last parseable record belongs to (content-verified, plus 8
	// consecutive confirmations walking down).
	if len(positions) == 0 {
		log.errorf("Undo rebuild: no parseable undo records")
		return false
	}
	anchor: ^Block_Index_Entry
	last := positions[len(positions) - 1]
	for j in 0 ..< 64 {
		cand := tip
		for _ in 0 ..< j {
			if cand == nil {
				break
			}
			cand = cand.prev
		}
		if cand == nil || cand.height <= meta_height {
			break
		}
		cand.undo_file_num = last.file_num
		cand.undo_offset = last.offset
		cand.undo_size = last.size
		if !_verify_undo_matches_block(cs, cand) {
			continue
		}
		// Confirm with the next 8 records down.
		confirmed := true
		e := cand.prev
		k := len(positions) - 2
		for c in 0 ..< 8 {
			_ = c
			if e == nil || e.height <= meta_height || k < 0 {
				break
			}
			e.undo_file_num = positions[k].file_num
			e.undo_offset = positions[k].offset
			e.undo_size = positions[k].size
			if !_verify_undo_matches_block(cs, e) {
				confirmed = false
				break
			}
			e = e.prev
			k -= 1
		}
		if confirmed {
			anchor = cand
			if j > 0 {
				log.warnf("Undo rebuild: rev stream tail truncated — last %d block(s) below tip %d have no undo data", j, tip.height)
			}
			break
		}
	}
	if anchor == nil {
		log.errorf("Undo rebuild: no alignment found near tip — aborting")
		return false
	}

	// Blocks above the anchor lost their undo records: strip Has_Undo so
	// the rollback uses the block-data-only path for them.
	for e := tip; e != nil && e != anchor; e = e.prev {
		e.status -= {.Has_Undo}
		e.undo_file_num = 0
		e.undo_offset = 0
		e.undo_size = 0
	}

	// Assign + verify the full range downward from the anchor.
	idx := len(positions) - 1
	for entry := anchor; entry != nil && entry.height > meta_height; entry = entry.prev {
		if idx < 0 {
			log.errorf("Undo rebuild: rev stream exhausted at height %d", entry.height)
			return false
		}
		pos := positions[idx]
		idx -= 1
		entry.undo_file_num = pos.file_num
		entry.undo_offset = pos.offset
		entry.undo_size = pos.size

		if !_verify_undo_matches_block(cs, entry) {
			log.errorf("Undo rebuild: content mismatch at height %d (rev file %d off %d) — aborting",
				entry.height, pos.file_num, pos.offset)
			return false
		}
	}

	// Persist the verified locations (format v3) so restarts skip the scan.
	for entry := tip; entry != nil && entry.height > meta_height; entry = entry.prev {
		rec := block_index_to_record(entry)
		storage.index_db_put(&cs.index_db, rec)
	}

	log.infof("Undo rebuild: verified and persisted undo locations down to height %d", meta_height + 1)
	return true
}

// Content check: the undo record's spent coins must correspond 1:1 (count
// and first outpoint) with the block's non-coinbase inputs.
_verify_undo_matches_block :: proc(cs: ^Chain_State, entry: ^Block_Index_Entry) -> bool {
	if .Has_Data not_in entry.status {
		return false
	}
	loc := storage.Block_Location{
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	raw, rerr := storage.block_db_read_raw(&cs.block_db, loc, context.temp_allocator)
	if rerr != .None {
		return false
	}
	r := wire.reader_init(raw)
	block, derr := wire.deserialize_block(&r, context.temp_allocator)
	if derr != nil {
		return false
	}

	undo, uerr := read_block_undo(&cs.undo_files, entry, context.temp_allocator)
	if uerr != .None {
		return false
	}

	input_count := 0
	first_prevout: wire.Outpoint
	have_first := false
	for tx_idx in 1 ..< len(block.txs) { // skip coinbase
		for in_idx in 0 ..< len(block.txs[tx_idx].inputs) {
			if !have_first {
				first_prevout = block.txs[tx_idx].inputs[in_idx].previous_output
				have_first = true
			}
			input_count += 1
		}
	}

	if len(undo.spent_coins) != input_count {
		return false
	}
	if input_count > 0 && undo.spent_coins[0].outpoint != first_prevout {
		return false
	}
	free_all(context.temp_allocator)
	return true
}

// Force-undo one block into the coins cache, tolerant of partially-applied
// on-disk state: created outputs are deleted whether or not they exist;
// spent inputs are restored unconditionally from the undo record. Purely
// mechanical — no validation, no active_chain interaction (recovery runs
// before the active chain is rebuilt).
_rollback_block_for_recovery :: proc(cs: ^Chain_State, entry: ^Block_Index_Entry) -> Chain_Error {
	if .Has_Data not_in entry.status {
		log.errorf("recovery rollback %d: no block data (status=%v)", entry.height, entry.status)
		return .Storage_Error
	}
	// Undo-less (truncated rev tail): delete this block's created outputs
	// from block data alone. Its spent pre-range coins can't be restored
	// here — if any of their deletes landed in the partial flush, the
	// validating replay fails LOUDLY on that exact input (never silent).
	undo_less := .Has_Undo not_in entry.status
	if undo_less {
		log.warnf("recovery rollback %d: no undo data — deleting created outputs only", entry.height)
	}

	loc := storage.Block_Location{
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	raw, rerr := storage.block_db_read_raw(&cs.block_db, loc, context.temp_allocator)
	if rerr != .None {
		log.errorf("recovery rollback %d: block read failed (%v) file=%d off=%d size=%d",
			entry.height, rerr, entry.file_num, entry.data_offset, entry.data_size)
		return .Storage_Error
	}
	r := wire.reader_init(raw)
	block, derr := wire.deserialize_block(&r, context.temp_allocator)
	if derr != nil {
		log.errorf("recovery rollback %d: block deserialize failed (%v)", entry.height, derr)
		return .Storage_Error
	}

	undo: Block_Undo
	if !undo_less {
		u, uerr := read_block_undo(&cs.undo_files, entry, context.temp_allocator)
		if uerr != .None {
			log.errorf("recovery rollback %d: undo read failed (%v) undo_file=%d undo_off=%d undo_size=%d",
				entry.height, uerr, entry.undo_file_num, entry.undo_offset, entry.undo_size)
			return uerr
		}
		undo = u
	}

	for tx_idx := len(block.txs) - 1; tx_idx >= 0; tx_idx -= 1 {
		tx := block.txs[tx_idx]
		txid := wire.tx_id(&tx)
		for out_idx := len(tx.outputs) - 1; out_idx >= 0; out_idx -= 1 {
			op := wire.Outpoint{hash = txid, index = u32(out_idx)}
			coins_cache_spend(&cs.coins, op) // missing already = fine
		}
	}
	for i in 0 ..< len(undo.spent_coins) {
		uc := undo.spent_coins[i]
		coins_cache_restore(&cs.coins, uc.outpoint, uc.coin)
	}

	free_all(context.temp_allocator)
	return .None
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

// Estimated total transactions in the chain right now, extrapolated from the
// params anchor (Bitcoin Core's chainTxData approach). Returns 0 when the
// network has no anchor (regtest).
estimated_total_chain_tx :: proc(params: ^consensus.Chain_Params, now: i64) -> f64 {
	if params.assumed_chain_tx <= 0 { return 0 }
	extra := f64(max(now - params.assumed_chain_tx_time, 0)) * params.assumed_tx_rate
	return f64(params.assumed_chain_tx) + extra
}

// Verification progress in [0,1], measured in transactions verified vs the
// estimated chain total — block counts misestimate work by ~40x across eras.
verification_progress :: proc(cs: ^Chain_State, now: i64) -> f64 {
	total := estimated_total_chain_tx(cs.params, now)
	if total <= 0 { return 1 }
	tip_hash, tip_height := chain_tip(cs)
	if tip_height < 0 { return 0 }
	entry, found := cs.block_index.entries[tip_hash]
	if !found { return 0 }
	p := f64(entry.chain_tx) / total
	return clamp(p, 0, 1)
}

// Cumulative txs at the current tip (0 if unavailable).
chain_tx_at_tip :: proc(cs: ^Chain_State) -> i64 {
	tip_hash, tip_height := chain_tip(cs)
	if tip_height < 0 { return 0 }
	if entry, found := cs.block_index.entries[tip_hash]; found { return entry.chain_tx }
	return 0
}

// Total bytes of block/undo flat files plus the chainstate DB on disk.
// Walks file sizes (a few thousand stat calls) — call sparingly.
disk_usage :: proc(cs: ^Chain_State) -> i64 {
	total: i64 = 0
	for fn in u32(0) ..= cs.block_db.files.current_file {
		total += storage.flat_file_size(&cs.block_db.files, fn)
	}
	for fn in u32(0) ..= cs.undo_files.current_file {
		total += storage.flat_file_size(&cs.undo_files, fn)
	}
	total += storage.ldb_dir_size(&cs.store)
	return total
}
