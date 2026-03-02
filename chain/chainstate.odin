package chain

import "core:log"
import "core:mem"
import "core:os"
import "../consensus"
import "../crypto"
import "../script"
import "../storage"
import "../wire"

Chain_State :: struct {
	block_index:  Block_Index,
	store:        storage.LDB_Store,
	index_db:     storage.Index_DB,
	block_db:     storage.Block_DB,
	utxo_db:      storage.UTXO_DB,
	coins:        Coins_Cache,
	active_chain: [dynamic]Hash256,
	undo_files:   storage.Flat_File_Manager,
	params:       ^consensus.Chain_Params,
	// Per-input verification arena: heap-allocated once, reset between inputs.
	verify_buf:   []byte,
	verify_arena: mem.Arena,
	verify_alloc: mem.Allocator,
}

// Initialize chain state. Caller allocates Chain_State and passes pointer.
chain_state_init :: proc(cs: ^Chain_State, data_dir: string, params: ^consensus.Chain_Params) -> Chain_Error {
	cs.params = params

	// Ensure data_dir exists
	os.make_directory(data_dir)

	// Open shared LevelDB store (chainstate + block index)
	store, store_err := storage.ldb_open(data_dir)
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

	// Initialize coins cache (pointer to cs.utxo_db stays valid)
	cs.coins = coins_cache_init(&cs.utxo_db)

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

	// Allocate persistent per-input verification arena (2 MB, reused across blocks)
	cs.verify_buf = make([]byte, 2 * 1024 * 1024)
	mem.arena_init(&cs.verify_arena, cs.verify_buf)
	cs.verify_alloc = mem.arena_allocator(&cs.verify_arena)

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
	tip_hash, tip_height := chain_tip(cs)
	coins_cache_flush(&cs.coins, tip_hash, tip_height)
	coins_cache_destroy(&cs.coins)
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
connect_block :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry) -> Chain_Error {
	height := entry.height

	// 1. Context-free validation
	block_val := block^
	cerr := consensus.check_block(&block_val, height, cs.params)
	if cerr != .None {
		return .Consensus_Error
	}

	// 2. Check duplicate txids within block
	{
		seen := make(map[Hash256]bool, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			tx := block.txs[i]
			txid := wire.tx_id(&tx)
			if txid in seen {
				return .Duplicate_Tx
			}
			seen[txid] = true
		}
	}

	// 3. BIP30: Check no unspent UTXOs with same txids. After BIP34 activation,
	// duplicate txids are impossible (coinbase includes height), so skip the check.
	if height < cs.params.bip34_height {
		for i in 0 ..< len(block.txs) {
			tx := block.txs[i]
			txid := wire.tx_id(&tx)
			for j in 0 ..< len(tx.outputs) {
				op := wire.Outpoint{hash = txid, index = u32(j)}
				if coins_cache_has(&cs.coins, op) {
					return .Bip30_Violation
				}
			}
		}
	}

	// 4. Process non-coinbase transactions: validate, spend inputs, add outputs.
	//    Each tx is processed atomically so later transactions in the same block
	//    can spend outputs created by earlier ones (intra-block spending).
	//    On failure, all changes from prior txs are rolled back so the UTXO cache
	//    remains consistent (critical for block retry after Bad_Script etc.).
	total_fees: i64 = 0
	script_flags := consensus.get_script_flags(height, cs.params)
	skip_scripts := cs.params.assumevalid_height > 0 && height <= cs.params.assumevalid_height

	undo_coins := make([dynamic]Undo_Coin, 0, 64, context.temp_allocator)
	applied_tx_indices := make([dynamic]int, 0, len(block.txs), context.temp_allocator)

	// Per-input verification arena: sighash computation allocates wire writers
	// on temp_allocator. For txs with hundreds of inputs, these accumulate and
	// exhaust the block arena. The Chain_State's persistent 2MB scratch arena
	// is reset between inputs to bound memory usage.
	if !skip_scripts {
		mem.arena_free_all(&cs.verify_arena)
	}

	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]

		if consensus.is_coinbase_tx(&tx) {
			continue
		}

		// 4a. Look up inputs
		spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
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

			spent_outputs[in_idx] = wire.Tx_Out {
				value         = coin.amount,
				script_pubkey = coin.script,
			}
			input_sum += coin.amount
		}

		// 4b. Script verification (skipped under assumevalid)
		if !skip_scripts {
			sighash_cache: script.Sighash_Cache
			saved_temp := context.temp_allocator

			for in_idx in 0 ..< len(tx.inputs) {
				mem.arena_free_all(&cs.verify_arena)
				context.temp_allocator = cs.verify_alloc

				verifier := script.Script_Verifier {
					tx            = &block.txs[tx_idx],
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
					context.temp_allocator = saved_temp
					txid := wire.tx_id(&block.txs[tx_idx])
					// Log txid in display order (reversed)
					txid_rev: Hash256
					for b in 0 ..< 32 { txid_rev[b] = txid[31 - b] }
					log.errorf(
						"Script FAIL height=%d tx_idx=%d in_idx=%d/%d err=%v txid=%02x%02x%02x%02x%02x%02x%02x%02x... scriptPubKey_len=%d num_inputs=%d",
						height, tx_idx, in_idx, len(tx.inputs), serr,
						txid_rev[0], txid_rev[1], txid_rev[2], txid_rev[3],
						txid_rev[4], txid_rev[5], txid_rev[6], txid_rev[7],
						len(spent_outputs[in_idx].script_pubkey), len(tx.inputs),
					)
					_rollback_applied_txs(cs, block, applied_tx_indices[:], undo_coins[:])
					return .Bad_Script
				}
			}

			context.temp_allocator = saved_temp
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
		txid := wire.tx_id(&tx)
		for out_idx in 0 ..< len(tx.outputs) {
			op := wire.Outpoint{hash = txid, index = u32(out_idx)}
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
		coinbase_txid := wire.tx_id(&coinbase)
		for out_idx in 0 ..< len(coinbase.outputs) {
			op := wire.Outpoint{hash = coinbase_txid, index = u32(out_idx)}
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

	// 8. Update entry status and append to active chain
	entry.status += {.Valid_Transactions, .Valid_Chain}

	// Persist updated index record
	rec := block_index_to_record(entry)
	storage.index_db_put(&cs.index_db, rec)

	append(&cs.active_chain, entry.hash)

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

	// 4. Update entry status and pop active chain
	entry.status -= {.Valid_Chain}

	pop(&cs.active_chain)

	return .None
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
	if header.prev_hash != HASH_ZERO {
		parent, parent_found := cs.block_index.entries[header.prev_hash]
		if !parent_found {
			return nil, .Invalid_Prev_Block
		}
		parent_height = parent.height
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
		if hdr.prev_hash != HASH_ZERO {
			parent, parent_found := cs.block_index.entries[hdr.prev_hash]
			if !parent_found {
				continue
			}
			parent_height = parent.height
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
	// Build index: prev_hash -> entry for blocks stored but not yet connected.
	// This gives O(1) lookup per block instead of scanning the full index.
	pending := make(map[Hash256]^Block_Index_Entry, 1024, context.temp_allocator)
	for _, entry in cs.block_index.entries {
		if .Has_Data in entry.status && .Valid_Chain not_in entry.status {
			pending[entry.prev_hash] = entry
		}
	}

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

	for connected < MAX_CONNECT_BATCH {
		tip_hash, _ := chain_tip(cs)
		next_entry, found := pending[tip_hash]
		if !found {
			return connected, .None
		}

		// Reset arena for this block — frees block data AND connect_block's
		// temp allocations (seen map, undo_coins, spent_outputs) from prev iteration.
		mem.arena_free_all(&block_arena)
		context.temp_allocator = block_alloc

		// Read block from disk.
		loc := storage.Block_Location{
			file_num    = next_entry.file_num,
			data_offset = next_entry.data_offset,
			data_size   = next_entry.data_size,
		}
		block, rerr := storage.block_db_read(&cs.block_db, loc, block_alloc)
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

		cerr := connect_block(cs, &block, next_entry)
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

		delete_key(&pending, tip_hash)
		connected += 1
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
