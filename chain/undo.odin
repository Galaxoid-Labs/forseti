package chain

import "../storage"
import "../wire"

// Write undo data for a block to rev*.dat flat files.
// Updates entry's undo location fields.
write_block_undo :: proc(undo_files: ^storage.Flat_File_Manager, entry: ^Block_Index_Entry, undo: Block_Undo) -> Chain_Error {
	w := wire.writer_init(context.temp_allocator)

	// Coin count
	wire.write_compact_size(&w, u64(len(undo.spent_coins)))

	// Each coin: txid(32) + vout(4 LE) + height(4 LE) + is_coinbase(1) + amount(8 LE) + script_len(CompactSize) + script
	for i in 0 ..< len(undo.spent_coins) {
		uc := undo.spent_coins[i]
		wire.write_hash(&w, uc.outpoint.hash)
		wire.write_u32le(&w, uc.outpoint.index)
		wire.write_u32le(&w, uc.coin.height)
		wire.write_byte(&w, uc.coin.is_coinbase ? 1 : 0)
		wire.write_i64le(&w, uc.coin.amount)
		wire.write_var_bytes(&w, uc.coin.script)
	}

	payload := wire.writer_bytes(&w)

	// Write with size prefix: [size:4 LE][payload]
	header_w := wire.writer_init(context.temp_allocator)
	wire.write_u32le(&header_w, u32(len(payload)))
	header_bytes := wire.writer_bytes(&header_w)

	// Write header
	pos, herr := storage.flat_file_write(undo_files, header_bytes)
	if herr != .None {
		return .Storage_Error
	}

	// Write payload
	_, perr := storage.flat_file_write(undo_files, payload)
	if perr != .None {
		return .Storage_Error
	}

	// Update entry's undo location
	entry.undo_file_num = pos.file_num
	entry.undo_offset = pos.offset + 4 // skip size prefix
	entry.undo_size = u32(len(payload))
	entry.status += {.Has_Undo}

	return .None
}

// Read undo data for a block from rev*.dat flat files.
read_block_undo :: proc(undo_files: ^storage.Flat_File_Manager, entry: ^Block_Index_Entry, allocator := context.allocator) -> (Block_Undo, Chain_Error) {
	if .Has_Undo not_in entry.status {
		return {}, .Undo_Data_Missing
	}

	pos := storage.File_Pos {
		file_num = entry.undo_file_num,
		offset   = entry.undo_offset,
	}

	data, rerr := storage.flat_file_read(undo_files, pos, entry.undo_size, context.temp_allocator)
	if rerr != .None {
		return {}, .Storage_Error
	}

	r := wire.reader_init(data)

	coin_count_u64, cs_err := wire.read_compact_size(&r)
	if cs_err != nil {
		return {}, .Undo_Data_Corrupt
	}
	coin_count := int(coin_count_u64)

	spent_coins := make([]Undo_Coin, coin_count, allocator)

	for i in 0 ..< coin_count {
		txid, hash_err := wire.read_hash(&r)
		if hash_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		vout, vout_err := wire.read_u32le(&r)
		if vout_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		height, h_err := wire.read_u32le(&r)
		if h_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		is_cb_byte, cb_err := wire.read_byte(&r)
		if cb_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		amount, amt_err := wire.read_i64le(&r)
		if amt_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		script_data, script_err := wire.read_var_bytes(&r, allocator)
		if script_err != nil {
			return {}, .Undo_Data_Corrupt
		}

		spent_coins[i] = Undo_Coin {
			outpoint = wire.Outpoint{hash = txid, index = vout},
			coin     = storage.UTXO_Coin {
				height      = height,
				is_coinbase = is_cb_byte != 0,
				amount      = amount,
				script      = script_data,
			},
		}
	}

	return Block_Undo{spent_coins = spent_coins}, .None
}
