package chain

import "core:fmt"
import "core:os"
import "../consensus"
import "../crypto"
import "../script"
import "../storage"
import "../wire"

Chain_State :: struct {
	block_index:  Block_Index,
	index_db:     storage.Index_DB,
	block_db:     storage.Block_DB,
	utxo_db:      storage.UTXO_DB,
	coins:        Coins_Cache,
	active_chain: [dynamic]Hash256,
	undo_files:   storage.Flat_File_Manager,
	params:       ^consensus.Chain_Params,
}

// Initialize chain state. Caller allocates Chain_State and passes pointer.
chain_state_init :: proc(cs: ^Chain_State, data_dir: string, params: ^consensus.Chain_Params) -> Chain_Error {
	cs.params = params

	// Ensure data_dir exists
	os.make_directory(data_dir)

	// Open index DB
	idx_db, idx_err := storage.index_db_open(data_dir)
	if idx_err != .None {
		return .Storage_Error
	}
	cs.index_db = idx_db

	// Open block DB
	blk_db, blk_err := storage.block_db_open(data_dir, params.network_magic)
	if blk_err != .None {
		storage.index_db_close(&cs.index_db)
		return .Storage_Error
	}
	cs.block_db = blk_db

	// Open UTXO DB
	utxo_db, utxo_err := storage.utxo_db_open(data_dir)
	if utxo_err != .None {
		storage.index_db_close(&cs.index_db)
		storage.block_db_close(&cs.block_db)
		return .Storage_Error
	}
	cs.utxo_db = utxo_db

	// Initialize coins cache (pointer to cs.utxo_db stays valid)
	cs.coins = coins_cache_init(&cs.utxo_db)

	// Open undo flat files
	undo_files, undo_err := storage.flat_file_open(data_dir, "rev")
	if undo_err != .None {
		storage.index_db_close(&cs.index_db)
		storage.block_db_close(&cs.block_db)
		storage.utxo_db_close(&cs.utxo_db)
		return .Storage_Error
	}
	cs.undo_files = undo_files

	// Build in-memory block index
	cs.block_index = block_index_init()
	block_index_load(&cs.block_index, &cs.index_db)

	// Rebuild active chain from genesis to tip
	cs.active_chain = make([dynamic]Hash256, 0, 1024)
	_rebuild_active_chain(cs)

	return .None
}

// Destroy chain state, flushing everything to disk.
chain_state_destroy :: proc(cs: ^Chain_State) {
	coins_cache_flush(&cs.coins)
	coins_cache_destroy(&cs.coins)
	storage.utxo_db_close(&cs.utxo_db)
	storage.block_db_close(&cs.block_db)
	storage.index_db_close(&cs.index_db)
	storage.flat_file_close(&cs.undo_files)
	block_index_destroy(&cs.block_index)
	delete(cs.active_chain)
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

	// 3. BIP30: Check no unspent UTXOs with same txids (after BIP34 activation)
	if height >= cs.params.bip34_height {
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

	// 4. Validate non-coinbase transactions
	total_fees: i64 = 0
	script_flags := consensus.get_script_flags(height, cs.params)

	undo_coins := make([dynamic]Undo_Coin, 0, 64, context.temp_allocator)

	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]

		if consensus.is_coinbase_tx(&tx) {
			continue
		}

		// Build spent_outputs slice for this tx (needed for Taproot sighash)
		spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
		input_sum: i64 = 0

		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output
			coin, found := coins_cache_get(&cs.coins, prev_out)
			if !found {
				return .Inputs_Unavailable
			}

			// Check coinbase maturity
			if coin.is_coinbase {
				if height - int(coin.height) < consensus.COINBASE_MATURITY {
					return .Coinbase_Not_Mature
				}
			}

			spent_outputs[in_idx] = wire.Tx_Out {
				value         = coin.amount,
				script_pubkey = coin.script,
			}
			input_sum += coin.amount
		}

		// Run script verification for each input
		for in_idx in 0 ..< len(tx.inputs) {
			verifier := script.Script_Verifier {
				tx            = &block.txs[tx_idx],
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
				return .Bad_Script
			}
		}

		// Calculate fees
		output_sum: i64 = 0
		for out_idx in 0 ..< len(tx.outputs) {
			output_sum += tx.outputs[out_idx].value
		}
		total_fees += input_sum - output_sum
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

	// 6. Spend all inputs and collect undo coins
	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]
		if consensus.is_coinbase_tx(&tx) {
			continue
		}
		for in_idx in 0 ..< len(tx.inputs) {
			prev_out := tx.inputs[in_idx].previous_output
			spent_coin, ok := coins_cache_spend(&cs.coins, prev_out)
			if !ok {
				return .Invalid_State
			}
			append(&undo_coins, Undo_Coin{outpoint = prev_out, coin = spent_coin})
		}
	}

	// 7. Add all outputs
	for tx_idx in 0 ..< len(block.txs) {
		tx := block.txs[tx_idx]
		txid := wire.tx_id(&tx)
		is_cb := consensus.is_coinbase_tx(&tx)
		for out_idx in 0 ..< len(tx.outputs) {
			op := wire.Outpoint{hash = txid, index = u32(out_idx)}
			coin := storage.UTXO_Coin {
				height      = u32(height),
				is_coinbase = is_cb,
				amount      = tx.outputs[out_idx].value,
				script      = tx.outputs[out_idx].script_pubkey,
			}
			coins_cache_add(&cs.coins, op, coin)
		}
	}

	// 8. Write undo data
	undo := Block_Undo{spent_coins = undo_coins[:]}
	uerr := write_block_undo(&cs.undo_files, entry, undo)
	if uerr != .None {
		return uerr
	}

	// 9. Update entry status and append to active chain
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
