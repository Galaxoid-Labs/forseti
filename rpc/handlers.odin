package rpc

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "../chain"
import "../consensus"
import "../crypto"
import "../mempool"
import "../p2p"
import "../script"
import "../storage"
import "../wire"

// --- getblockchaininfo ---

_handle_getblockchaininfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, height := chain.chain_tip(srv.chain)
	header_height := chain.chain_header_height(srv.chain)

	obj := make(json.Object, 16, context.temp_allocator)
	obj["chain"] = json.Value(json.String(srv.params.name))
	obj["blocks"] = json.Value(json.Integer(height))
	obj["headers"] = json.Value(json.Integer(header_height))
	obj["bestblockhash"] = json.Value(json.String(_hash_to_hex(tip_hash)))

	// Difficulty and time from tip block
	tip_entry, tip_found := srv.chain.block_index.entries[tip_hash]
	if tip_found {
		obj["difficulty"] = json.Value(json.Float(consensus.get_difficulty(tip_entry.bits)))
		obj["time"] = json.Value(json.Integer(i64(tip_entry.timestamp)))
		obj["mediantime"] = json.Value(json.Integer(i64(_get_median_time(srv, tip_entry))))
	} else {
		obj["difficulty"] = json.Value(json.Float(0.0))
		obj["time"] = json.Value(json.Integer(0))
		obj["mediantime"] = json.Value(json.Integer(0))
	}

	// Verification progress: blocks / headers (0.0 to 1.0)
	if header_height > 0 {
		obj["verificationprogress"] = json.Value(json.Float(f64(height) / f64(header_height)))
	} else {
		obj["verificationprogress"] = json.Value(json.Float(0.0))
	}

	// Initial block download: consider IBD if headers are significantly ahead of blocks
	obj["initialblockdownload"] = json.Value(json.Boolean(header_height - height > 24))
	obj["pruned"] = json.Value(json.Boolean(false))
	obj["warnings"] = json.Value(json.String(""))

	// Softforks (Bitcoin Core format)
	softforks := make(json.Object, 6, context.temp_allocator)
	softforks["bip34"] = json.Value(_make_buried_softfork(srv.params.bip34_height, height))
	softforks["bip66"] = json.Value(_make_buried_softfork(srv.params.bip66_height, height))
	softforks["bip65"] = json.Value(_make_buried_softfork(srv.params.bip65_height, height))
	softforks["csv"] = json.Value(_make_buried_softfork(srv.params.csv_height, height))
	softforks["segwit"] = json.Value(_make_buried_softfork(srv.params.segwit_height, height))
	softforks["taproot"] = json.Value(_make_buried_softfork(srv.params.taproot_height, height))
	obj["softforks"] = json.Value(softforks)

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getblockcount ---

_handle_getblockcount :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	height := chain.chain_height(srv.chain)
	return _make_result(json.Value(json.Integer(height)), srv._current_id)
}

// --- getblockhash ---

_handle_getblockhash :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	height, ok := _get_int_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing height parameter", srv._current_id)
	}

	chain_height := chain.chain_height(srv.chain)
	if height < 0 || height > chain_height {
		return _make_error(.Block_Not_Found, fmt.tprintf("Block height %d out of range", height), srv._current_id)
	}

	hash := srv.chain.active_chain[height]
	return _make_result(json.Value(json.String(_hash_to_hex(hash))), srv._current_id)
}

// --- getbestblockhash ---

_handle_getbestblockhash :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, _ := chain.chain_tip(srv.chain)
	return _make_result(json.Value(json.String(_hash_to_hex(tip_hash))), srv._current_id)
}

// --- getblock ---

_handle_getblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hash_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing blockhash parameter", srv._current_id)
	}

	hash, hash_ok := _hex_to_hash(hash_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}

	// Look up block index entry
	entry, found := srv.chain.block_index.entries[hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}

	// Default verbosity = 1
	verbosity := 1
	v_val, v_ok := _get_int_param(params, 1)
	if v_ok {
		verbosity = v_val
	}

	if verbosity == 0 {
		// Raw hex serialized block
		if .Has_Data not_in entry.status {
			return _make_error(.Block_Not_Found, "Block data not available", srv._current_id)
		}
		loc := storage.Block_Location {
			file_num    = entry.file_num,
			data_offset = entry.data_offset,
			data_size   = entry.data_size,
		}
		raw, rerr := storage.block_db_read_raw(&srv.chain.block_db, loc, context.temp_allocator)
		if rerr != .None {
			return _make_error(.Internal_Error, "Failed to read block data", srv._current_id)
		}
		return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
	}

	// Verbose mode: return JSON object
	if .Has_Data not_in entry.status {
		return _make_error(.Block_Not_Found, "Block data not available", srv._current_id)
	}
	loc := storage.Block_Location {
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
	if berr != .None {
		return _make_error(.Internal_Error, "Failed to read block", srv._current_id)
	}

	tip_height := chain.chain_height(srv.chain)
	confirmations := tip_height - entry.height + 1

	obj := make(json.Object, 16, context.temp_allocator)
	obj["hash"] = json.Value(json.String(_hash_to_hex(entry.hash)))
	obj["confirmations"] = json.Value(json.Integer(confirmations))
	obj["height"] = json.Value(json.Integer(entry.height))
	obj["version"] = json.Value(json.Integer(i64(entry.version)))
	obj["versionHex"] = json.Value(json.String(fmt.tprintf("%08x", u32(entry.version))))
	obj["merkleroot"] = json.Value(json.String(_hash_to_hex(block.header.merkle_root)))
	obj["time"] = json.Value(json.Integer(i64(entry.timestamp)))
	obj["mediantime"] = json.Value(json.Integer(i64(_get_median_time(srv, entry))))
	obj["nonce"] = json.Value(json.Integer(i64(entry.nonce)))
	obj["bits"] = json.Value(json.String(fmt.tprintf("%08x", entry.bits)))
	obj["difficulty"] = json.Value(json.Float(consensus.get_difficulty(entry.bits)))
	obj["nTx"] = json.Value(json.Integer(len(block.txs)))

	// Previous block hash
	if entry.height > 0 {
		obj["previousblockhash"] = json.Value(json.String(_hash_to_hex(entry.prev_hash)))
	}

	// Next block hash (if not tip)
	if entry.height < tip_height {
		next_hash := srv.chain.active_chain[entry.height + 1]
		obj["nextblockhash"] = json.Value(json.String(_hash_to_hex(next_hash)))
	}

	// Transaction list
	tx_arr := make(json.Array, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		txid := wire.tx_id(&tx)
		tx_arr[i] = json.Value(json.String(_hash_to_hex(txid)))
	}
	obj["tx"] = json.Value(tx_arr)

	// Weight, size, and strippedsize
	weight := consensus.get_block_weight(&block)
	obj["weight"] = json.Value(json.Integer(weight))
	obj["size"] = json.Value(json.Integer(i64(entry.data_size)))
	obj["strippedsize"] = json.Value(json.Integer(_get_block_stripped_size(&block)))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getrawtransaction ---

_handle_getrawtransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}

	txid, hash_ok := _hex_to_hash(txid_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}

	verbose := _get_bool_param(params, 1, false)

	// Check mempool
	entry, found := mempool.mempool_get(srv.mp, txid)
	if !found {
		// No tx index — can't look up confirmed txs
		return _make_error(.Misc_Error, "No such mempool transaction. Use -txindex to enable blockchain transaction queries.", srv._current_id)
	}

	tx := &entry.tx

	if !verbose {
		// Raw hex
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, tx)
		raw := wire.writer_bytes(&w)
		return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
	}

	// Verbose: decode to JSON
	obj := _tx_to_json(tx, entry)
	return _make_result(json.Value(obj), srv._current_id)
}

// --- sendrawtransaction ---

_handle_sendrawtransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hex_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing hex string parameter", srv._current_id)
	}

	raw, decode_ok := _hex_decode(hex_str)
	if !decode_ok {
		return _make_error(.Tx_Deser_Error, "TX decode failed: invalid hex", srv._current_id)
	}

	reader := wire.reader_init(raw)
	tx, wire_err := wire.deserialize_tx(&reader, context.temp_allocator)
	if wire_err != nil {
		return _make_error(.Tx_Deser_Error, "TX decode failed: invalid transaction", srv._current_id)
	}

	mp_err := mempool.mempool_add(srv.mp, &tx)
	if mp_err != .None {
		msg: string
		code: RPC_Error_Code

		#partial switch mp_err {
		case .Tx_Already_Exists:
			msg = "Transaction already in mempool"
			code = .Verify_Error
		case .Double_Spend:
			msg = "Transaction conflicts with mempool"
			code = .Verify_Error
		case .Missing_Inputs:
			msg = "Missing inputs"
			code = .Verify_Error
		case .Coinbase_Not_Allowed:
			msg = "Coinbase transactions not allowed"
			code = .Verify_Error
		case .Non_Standard:
			msg = "Non-standard transaction"
			code = .Verify_Error
		case .Insufficient_Fee:
			msg = "Insufficient fee"
			code = .Mempool_Error
		case .Failed_Script:
			msg = "Script verification failed"
			code = .Verify_Error
		case .Mempool_Full:
			msg = "Mempool is full"
			code = .Mempool_Error
		case .RBF_Not_Signaling:
			msg = "RBF rejected: original transaction does not signal replaceability"
			code = .Verify_Error
		case .RBF_New_Unconfirmed:
			msg = "RBF rejected: replacement introduces new unconfirmed inputs"
			code = .Verify_Error
		case .RBF_Insufficient_Fee:
			msg = "RBF rejected: insufficient fee (must pay more than conflict set)"
			code = .Mempool_Error
		case .RBF_Fee_Too_Low:
			msg = "RBF rejected: additional fee does not cover replacement bandwidth"
			code = .Mempool_Error
		case .RBF_Too_Many_Evictions:
			msg = "RBF rejected: too many potential replacements (>100)"
			code = .Verify_Error
		case:
			msg = fmt.tprintf("Mempool rejection: %v", mp_err)
			code = .Verify_Error
		}
		return _make_error(code, msg, srv._current_id)
	}

	txid := wire.tx_id(&tx)

	// Relay to peers.
	if srv.cm != nil {
		p2p.conn_manager_relay_tx(srv.cm, txid)
	}

	return _make_result(json.Value(json.String(_hash_to_hex(txid))), srv._current_id)
}

// --- getmempoolinfo ---

_handle_getmempoolinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	count := mempool.mempool_count(srv.mp)

	// Sum vsizes
	total_vsize := 0
	for _, entry in srv.mp.entries {
		total_vsize += entry.vsize
	}

	obj := make(json.Object, 8, context.temp_allocator)
	obj["loaded"] = json.Value(json.Boolean(true))
	obj["size"] = json.Value(json.Integer(count))
	obj["bytes"] = json.Value(json.Integer(total_vsize))
	obj["usage"] = json.Value(json.Integer(total_vsize)) // approximate
	obj["maxmempool"] = json.Value(json.Integer(mempool.MAX_MEMPOOL_SIZE * 1_000_000))
	obj["mempoolminfee"] = json.Value(json.Float(_satoshi_to_btc(mempool.MIN_RELAY_TX_FEE)))
	obj["minrelaytxfee"] = json.Value(json.Float(_satoshi_to_btc(mempool.MIN_RELAY_TX_FEE)))
	obj["incrementalrelayfee"] = json.Value(json.Float(_satoshi_to_btc(mempool.MIN_RELAY_TX_FEE)))
	obj["unbroadcastcount"] = json.Value(json.Integer(0))
	obj["fullrbf"] = json.Value(json.Boolean(srv.mp.fullrbf))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getrawmempool ---

_handle_getrawmempool :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	count := mempool.mempool_count(srv.mp)
	arr := make(json.Array, count, context.temp_allocator)

	i := 0
	for txid, _ in srv.mp.entries {
		arr[i] = json.Value(json.String(_hash_to_hex(txid)))
		i += 1
	}

	return _make_result(json.Value(arr), srv._current_id)
}

// --- gettxout ---

_handle_gettxout :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}

	txid, hash_ok := _hex_to_hash(txid_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}

	vout, vout_ok := _get_int_param(params, 1)
	if !vout_ok {
		return _make_error(.Invalid_Params, "Missing vout parameter", srv._current_id)
	}

	include_mempool := _get_bool_param(params, 2, true)

	outpoint := wire.Outpoint{hash = txid, index = u32(vout)}

	// Check confirmed UTXOs
	coin, found := chain.coins_cache_get(&srv.chain.coins, outpoint)
	if found {
		tip_height := chain.chain_height(srv.chain)
		confirmations := tip_height - int(coin.height) + 1

		obj := make(json.Object, 8, context.temp_allocator)
		obj["bestblock"] = json.Value(json.String(_hash_to_hex(srv.chain.active_chain[tip_height])))
		obj["confirmations"] = json.Value(json.Integer(confirmations))
		obj["value"] = json.Value(json.Float(_satoshi_to_btc(coin.amount)))
		obj["coinbase"] = json.Value(json.Boolean(coin.is_coinbase))

		spk_obj := make(json.Object, 2, context.temp_allocator)
		spk_obj["hex"] = json.Value(json.String(_bytes_to_hex(coin.script)))
		obj["scriptPubKey"] = json.Value(spk_obj)

		return _make_result(json.Value(obj), srv._current_id)
	}

	// Check mempool if requested
	if include_mempool {
		mp_entry, mp_found := mempool.mempool_get(srv.mp, txid)
		if mp_found && vout < len(mp_entry.tx.outputs) {
			txout := mp_entry.tx.outputs[vout]

			tip_height := chain.chain_height(srv.chain)
			obj := make(json.Object, 8, context.temp_allocator)
			obj["bestblock"] = json.Value(json.String(_hash_to_hex(srv.chain.active_chain[tip_height])))
			obj["confirmations"] = json.Value(json.Integer(0)) // unconfirmed
			obj["value"] = json.Value(json.Float(_satoshi_to_btc(txout.value)))
			obj["coinbase"] = json.Value(json.Boolean(false))

			spk_obj := make(json.Object, 2, context.temp_allocator)
			spk_obj["hex"] = json.Value(json.String(_bytes_to_hex(txout.script_pubkey)))
			obj["scriptPubKey"] = json.Value(spk_obj)

			return _make_result(json.Value(obj), srv._current_id)
		}
	}

	// Not found — return null result (not an error, per Bitcoin Core behavior)
	return _make_result(json.Value(json.Null(nil)), srv._current_id)
}

// --- Helpers ---

_satoshi_to_btc :: proc(satoshi: i64) -> f64 {
	return f64(satoshi) / 100_000_000.0
}

// Build a buried softfork object matching Bitcoin Core's format.
_make_buried_softfork :: proc(activation_height: int, current_height: int) -> json.Object {
	obj := make(json.Object, 3, context.temp_allocator)
	obj["type"] = json.Value(json.String("buried"))
	obj["active"] = json.Value(json.Boolean(current_height >= activation_height))
	obj["height"] = json.Value(json.Integer(activation_height))
	return obj
}

// Block size excluding witness data.
_get_block_stripped_size :: proc(block: ^wire.Block) -> int {
	size := wire.BLOCK_HEADER_SIZE
	_, cs_size := wire.compact_size_encode(u64(len(block.txs)))
	size += cs_size
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx_no_witness(&w, &tx)
		size += wire.writer_len(&w)
	}
	return size
}

_tx_to_json :: proc(tx: ^wire.Tx, entry: ^mempool.Mempool_Entry) -> json.Object {
	obj := _decode_tx_to_json(tx)
	obj["vsize"] = json.Value(json.Integer(entry.vsize))
	return obj
}

// Decode a transaction into JSON (for decoderawtransaction and getrawtransaction).
_decode_tx_to_json :: proc(tx: ^wire.Tx) -> json.Object {
	obj := make(json.Object, 12, context.temp_allocator)

	txid := wire.tx_id(tx)
	wtxid := wire.tx_witness_id(tx)
	obj["txid"] = json.Value(json.String(_hash_to_hex(txid)))
	obj["hash"] = json.Value(json.String(_hash_to_hex(wtxid)))
	obj["version"] = json.Value(json.Integer(i64(tx.version)))
	obj["locktime"] = json.Value(json.Integer(i64(tx.locktime)))

	// Sizes
	w_full := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w_full, tx)
	full_size := wire.writer_len(&w_full)

	weight := consensus.get_tx_weight(tx)
	vsize := (weight + 3) / 4

	obj["size"] = json.Value(json.Integer(full_size))
	obj["vsize"] = json.Value(json.Integer(vsize))
	obj["weight"] = json.Value(json.Integer(weight))

	// Inputs
	vin := make(json.Array, len(tx.inputs), context.temp_allocator)
	for i in 0 ..< len(tx.inputs) {
		inp := make(json.Object, 6, context.temp_allocator)
		inp["txid"] = json.Value(json.String(_hash_to_hex(tx.inputs[i].previous_output.hash)))
		inp["vout"] = json.Value(json.Integer(i64(tx.inputs[i].previous_output.index)))
		inp["sequence"] = json.Value(json.Integer(i64(tx.inputs[i].sequence)))

		sig_obj := make(json.Object, 2, context.temp_allocator)
		sig_obj["asm"] = json.Value(json.String(script.script_to_asm(tx.inputs[i].script_sig)))
		sig_obj["hex"] = json.Value(json.String(_bytes_to_hex(tx.inputs[i].script_sig)))
		inp["scriptSig"] = json.Value(sig_obj)

		// Witness
		if len(tx.witness) > i && len(tx.witness[i]) > 0 {
			wit_arr := make(json.Array, len(tx.witness[i]), context.temp_allocator)
			for j in 0 ..< len(tx.witness[i]) {
				wit_arr[j] = json.Value(json.String(_bytes_to_hex(tx.witness[i][j])))
			}
			inp["txinwitness"] = json.Value(wit_arr)
		}

		vin[i] = json.Value(inp)
	}
	obj["vin"] = json.Value(vin)

	// Outputs
	vout := make(json.Array, len(tx.outputs), context.temp_allocator)
	for i in 0 ..< len(tx.outputs) {
		outp := make(json.Object, 4, context.temp_allocator)
		outp["value"] = json.Value(json.Float(_satoshi_to_btc(tx.outputs[i].value)))
		outp["n"] = json.Value(json.Integer(i))

		spk := make(json.Object, 3, context.temp_allocator)
		spk["asm"] = json.Value(json.String(script.script_to_asm(tx.outputs[i].script_pubkey)))
		spk["hex"] = json.Value(json.String(_bytes_to_hex(tx.outputs[i].script_pubkey)))
		stype := script.classify_script(tx.outputs[i].script_pubkey)
		spk["type"] = json.Value(json.String(script.script_type_name(stype)))
		outp["scriptPubKey"] = json.Value(spk)

		vout[i] = json.Value(outp)
	}
	obj["vout"] = json.Value(vout)

	return obj
}

// --- getblockheader ---

_handle_getblockheader :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hash_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing blockhash parameter", srv._current_id)
	}

	hash, hash_ok := _hex_to_hash(hash_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}

	entry, found := srv.chain.block_index.entries[hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}

	verbose := _get_bool_param(params, 1, true)

	if !verbose {
		// Return raw 80-byte header hex
		if .Has_Data not_in entry.status {
			return _make_error(.Block_Not_Found, "Block data not available", srv._current_id)
		}
		loc := storage.Block_Location {
			file_num    = entry.file_num,
			data_offset = entry.data_offset,
			data_size   = entry.data_size,
		}
		raw, rerr := storage.block_db_read_raw(&srv.chain.block_db, loc, context.temp_allocator)
		if rerr != .None {
			return _make_error(.Internal_Error, "Failed to read block data", srv._current_id)
		}
		// Header is the first 80 bytes
		header_size := 80
		if len(raw) < header_size {
			header_size = len(raw)
		}
		return _make_result(json.Value(json.String(_bytes_to_hex(raw[:header_size]))), srv._current_id)
	}

	// Verbose mode: need full block to get merkle_root (not stored in index)
	if .Has_Data not_in entry.status {
		return _make_error(.Block_Not_Found, "Block data not available", srv._current_id)
	}
	loc := storage.Block_Location {
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
	if berr != .None {
		return _make_error(.Internal_Error, "Failed to read block", srv._current_id)
	}

	tip_height := chain.chain_height(srv.chain)
	confirmations := tip_height - entry.height + 1

	obj := make(json.Object, 16, context.temp_allocator)
	obj["hash"] = json.Value(json.String(_hash_to_hex(entry.hash)))
	obj["confirmations"] = json.Value(json.Integer(confirmations))
	obj["height"] = json.Value(json.Integer(entry.height))
	obj["version"] = json.Value(json.Integer(i64(entry.version)))
	obj["versionHex"] = json.Value(json.String(fmt.tprintf("%08x", u32(entry.version))))
	obj["merkleroot"] = json.Value(json.String(_hash_to_hex(block.header.merkle_root)))
	obj["time"] = json.Value(json.Integer(i64(entry.timestamp)))
	obj["mediantime"] = json.Value(json.Integer(i64(_get_median_time(srv, entry))))
	obj["nonce"] = json.Value(json.Integer(i64(entry.nonce)))
	obj["bits"] = json.Value(json.String(fmt.tprintf("%08x", entry.bits)))
	obj["difficulty"] = json.Value(json.Float(consensus.get_difficulty(entry.bits)))
	obj["nTx"] = json.Value(json.Integer(len(block.txs)))

	if entry.height > 0 {
		obj["previousblockhash"] = json.Value(json.String(_hash_to_hex(entry.prev_hash)))
	}

	if entry.height < tip_height {
		next_hash := srv.chain.active_chain[entry.height + 1]
		obj["nextblockhash"] = json.Value(json.String(_hash_to_hex(next_hash)))
	}

	return _make_result(json.Value(obj), srv._current_id)
}

// Compute median time of past 11 blocks.
_get_median_time :: proc(srv: ^RPC_Server, entry: ^chain.Block_Index_Entry) -> u32 {
	timestamps: [11]u32
	count := 0
	current := entry
	for count < 11 && current != nil {
		timestamps[count] = current.timestamp
		count += 1
		current = current.prev
	}

	// Sort the timestamps (simple insertion sort for <= 11 elements)
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

// --- getdifficulty ---

_handle_getdifficulty :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, _ := chain.chain_tip(srv.chain)
	entry, found := srv.chain.block_index.entries[tip_hash]
	if !found {
		return _make_result(json.Value(json.Float(0.0)), srv._current_id)
	}
	diff := consensus.get_difficulty(entry.bits)
	return _make_result(json.Value(json.Float(diff)), srv._current_id)
}

// --- getconnectioncount ---

_handle_getconnectioncount :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	count := 0
	if srv.cm != nil {
		count = len(srv.cm.peers)
	}
	return _make_result(json.Value(json.Integer(count)), srv._current_id)
}

// --- getpeerinfo ---

_handle_getpeerinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.cm == nil {
		arr := make(json.Array, 0, context.temp_allocator)
		return _make_result(json.Value(arr), srv._current_id)
	}

	arr := make(json.Array, len(srv.cm.peers), context.temp_allocator)
	i := 0
	for id, peer in srv.cm.peers {
		obj := make(json.Object, 8, context.temp_allocator)
		obj["id"] = json.Value(json.Integer(i64(id)))
		obj["addr"] = json.Value(json.String(peer.address))
		obj["services"] = json.Value(json.Integer(i64(peer.services)))
		obj["version"] = json.Value(json.Integer(i64(peer.version)))
		obj["subver"] = json.Value(json.String(peer.user_agent))
		obj["startingheight"] = json.Value(json.Integer(i64(peer.start_height)))
		obj["inbound"] = json.Value(json.Boolean(false))

		// Compute ping time
		ping_time := 0.0
		if peer.last_pong > peer.last_ping && peer.last_ping > 0 {
			ping_time = f64(peer.last_pong - peer.last_ping)
		}
		obj["pingtime"] = json.Value(json.Float(ping_time))

		arr[i] = json.Value(obj)
		i += 1
	}

	return _make_result(json.Value(arr), srv._current_id)
}

// --- getnetworkinfo ---

_handle_getnetworkinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, 8, context.temp_allocator)
	obj["version"] = json.Value(json.Integer(1))
	obj["subversion"] = json.Value(json.String("/btcnode-odin:0.1.0/"))
	obj["protocolversion"] = json.Value(json.Integer(i64(wire.PROTOCOL_VERSION)))
	obj["localservices"] = json.Value(json.Integer(i64(p2p.LOCAL_SERVICES)))

	conn_count := 0
	if srv.cm != nil {
		conn_count = len(srv.cm.peers)
	}
	obj["connections"] = json.Value(json.Integer(conn_count))
	obj["connections_in"] = json.Value(json.Integer(0))
	obj["connections_out"] = json.Value(json.Integer(conn_count))
	obj["networkactive"] = json.Value(json.Boolean(true))
	obj["relayfee"] = json.Value(json.Float(0.00001000))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- stop ---

_handle_stop :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	rpc_server_stop(srv)
	if srv.cm != nil {
		p2p.conn_manager_shutdown(srv.cm)
	}
	return _make_result(json.Value(json.String("Bitcoin server stopping")), srv._current_id)
}

// --- uptime ---

_handle_uptime :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	now := time.to_unix_seconds(time.now())
	uptime := now - srv.start_time
	return _make_result(json.Value(json.Integer(uptime)), srv._current_id)
}

// --- decoderawtransaction ---

_handle_decoderawtransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hex_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing hex string parameter", srv._current_id)
	}

	raw, decode_ok := _hex_decode(hex_str)
	if !decode_ok {
		return _make_error(.Tx_Deser_Error, "TX decode failed: invalid hex", srv._current_id)
	}

	reader := wire.reader_init(raw)
	tx, wire_err := wire.deserialize_tx(&reader, context.temp_allocator)
	if wire_err != nil {
		return _make_error(.Tx_Deser_Error, "TX decode failed: invalid transaction", srv._current_id)
	}

	obj := _decode_tx_to_json(&tx)
	return _make_result(json.Value(obj), srv._current_id)
}

// --- decodescript ---

_handle_decodescript :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hex_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing hex string parameter", srv._current_id)
	}

	raw, decode_ok := _hex_decode(hex_str)
	if !decode_ok {
		return _make_error(.Invalid_Params, "Invalid hex string", srv._current_id)
	}

	obj := make(json.Object, 4, context.temp_allocator)
	obj["asm"] = json.Value(json.String(script.script_to_asm(raw)))

	stype := script.classify_script(raw)
	obj["type"] = json.Value(json.String(script.script_type_name(stype)))

	// P2SH hash of this script
	h160 := crypto.hash160(raw)
	obj["p2sh"] = json.Value(json.String(_bytes_to_hex(h160[:])))

	// Segwit sub-object if applicable
	ver, prog, is_wp := script.is_witness_program(raw)
	if is_wp {
		seg_obj := make(json.Object, 3, context.temp_allocator)
		seg_obj["asm"] = json.Value(json.String(script.script_to_asm(raw)))
		seg_obj["hex"] = json.Value(json.String(_bytes_to_hex(raw)))
		seg_type := script.classify_script(raw)
		seg_obj["type"] = json.Value(json.String(script.script_type_name(seg_type)))
		_ = ver
		_ = prog
		obj["segwit"] = json.Value(seg_obj)
	}

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getmempoolentry ---

_handle_getmempoolentry :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}

	txid, hash_ok := _hex_to_hash(txid_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}

	entry, found := mempool.mempool_get(srv.mp, txid)
	if !found {
		return _make_error(.Block_Not_Found, "Transaction not in mempool", srv._current_id)
	}

	obj := make(json.Object, 8, context.temp_allocator)
	obj["vsize"] = json.Value(json.Integer(entry.vsize))
	obj["weight"] = json.Value(json.Integer(consensus.get_tx_weight(&entry.tx)))
	obj["time"] = json.Value(json.Integer(entry.time))

	fees := make(json.Object, 1, context.temp_allocator)
	fees["base"] = json.Value(json.Float(_satoshi_to_btc(entry.fee)))
	obj["fees"] = json.Value(fees)

	// depends: parent txids that are also in mempool
	dep_count := 0
	for in_idx in 0 ..< len(entry.tx.inputs) {
		prev_txid := entry.tx.inputs[in_idx].previous_output.hash
		if mempool.mempool_has(srv.mp, prev_txid) {
			dep_count += 1
		}
	}
	depends := make(json.Array, dep_count, context.temp_allocator)
	dep_idx := 0
	for in_idx in 0 ..< len(entry.tx.inputs) {
		prev_txid := entry.tx.inputs[in_idx].previous_output.hash
		if mempool.mempool_has(srv.mp, prev_txid) {
			depends[dep_idx] = json.Value(json.String(_hash_to_hex(prev_txid)))
			dep_idx += 1
		}
	}
	obj["depends"] = json.Value(depends)

	// bip125-replaceable: true if tx signals RBF or fullrbf is enabled
	replaceable := srv.mp.fullrbf || mempool.tx_signals_rbf(&entry.tx)
	obj["bip125-replaceable"] = json.Value(json.Boolean(replaceable))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- testmempoolaccept ---

_handle_testmempoolaccept :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	arr_val, arr_ok := _get_param(params, 0)
	if !arr_ok {
		return _make_error(.Invalid_Params, "Missing rawtxs parameter", srv._current_id)
	}

	rawtxs, is_arr := arr_val.(json.Array)
	if !is_arr {
		return _make_error(.Invalid_Params, "rawtxs must be an array", srv._current_id)
	}

	results := make(json.Array, len(rawtxs), context.temp_allocator)
	for i in 0 ..< len(rawtxs) {
		hex_val, is_str := rawtxs[i].(json.String)

		result_obj := make(json.Object, 6, context.temp_allocator)

		if !is_str {
			result_obj["allowed"] = json.Value(json.Boolean(false))
			result_obj["reject-reason"] = json.Value(json.String("invalid-hex"))
			results[i] = json.Value(result_obj)
			continue
		}

		raw, decode_ok := _hex_decode(hex_val)
		if !decode_ok {
			result_obj["allowed"] = json.Value(json.Boolean(false))
			result_obj["reject-reason"] = json.Value(json.String("invalid-hex"))
			results[i] = json.Value(result_obj)
			continue
		}

		reader := wire.reader_init(raw)
		tx, wire_err := wire.deserialize_tx(&reader, context.temp_allocator)
		if wire_err != nil {
			result_obj["allowed"] = json.Value(json.Boolean(false))
			result_obj["reject-reason"] = json.Value(json.String("decode-failed"))
			results[i] = json.Value(result_obj)
			continue
		}

		txid := wire.tx_id(&tx)
		wtxid := wire.tx_witness_id(&tx)
		result_obj["txid"] = json.Value(json.String(_hash_to_hex(txid)))
		result_obj["wtxid"] = json.Value(json.String(_hash_to_hex(wtxid)))

		tx_fee, tx_vsize, val_err := mempool.mempool_validate(srv.mp, &tx)
		if val_err != .None {
			result_obj["allowed"] = json.Value(json.Boolean(false))
			result_obj["reject-reason"] = json.Value(json.String(_mempool_error_string(val_err)))
		} else {
			result_obj["allowed"] = json.Value(json.Boolean(true))
			result_obj["vsize"] = json.Value(json.Integer(tx_vsize))
			fees := make(json.Object, 1, context.temp_allocator)
			fees["base"] = json.Value(json.Float(_satoshi_to_btc(tx_fee)))
			result_obj["fees"] = json.Value(fees)
		}

		results[i] = json.Value(result_obj)
	}

	return _make_result(json.Value(results), srv._current_id)
}

// Map Mempool_Error to Bitcoin Core reject string.
_mempool_error_string :: proc(err: mempool.Mempool_Error) -> string {
	#partial switch err {
	case .Tx_Already_Exists:   return "txn-already-in-mempool"
	case .Double_Spend:        return "txn-mempool-conflict"
	case .Missing_Inputs:      return "missing-inputs"
	case .Coinbase_Not_Allowed: return "coinbase"
	case .Coinbase_Not_Mature: return "bad-txns-premature-spend-of-coinbase"
	case .Non_Standard:        return "non-standard"
	case .Insufficient_Fee:    return "min-fee-not-met"
	case .Too_Many_Sigops:     return "bad-txns-too-many-sigops"
	case .Failed_Script:       return "mandatory-script-verify-flag-failed"
	case .Mempool_Full:            return "mempool-full"
	case .RBF_Not_Signaling:       return "txn-mempool-conflict"
	case .RBF_New_Unconfirmed:     return "rbf-new-unconfirmed"
	case .RBF_Insufficient_Fee:    return "insufficient-fee"
	case .RBF_Fee_Too_Low:         return "insufficient-fee"
	case .RBF_Too_Many_Evictions:  return "too-many-potential-replacements"
	case:                          return "unknown"
	}
}

// --- getchaintips ---

_handle_getchaintips :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Build set of hashes that are referenced as prev_hash (i.e., have children)
	has_child := make(map[Hash256]bool, len(srv.chain.block_index.entries), context.temp_allocator)
	for _, entry in srv.chain.block_index.entries {
		if entry.prev_hash != HASH_ZERO {
			has_child[entry.prev_hash] = true
		}
	}

	// Find the active tip
	active_tip_hash, active_tip_height := chain.chain_tip(srv.chain)

	// Count tips first
	tip_count := 0
	for _, entry in srv.chain.block_index.entries {
		if !(entry.hash in has_child) {
			tip_count += 1
		}
	}

	tips := make(json.Array, tip_count, context.temp_allocator)
	tip_idx := 0

	for _, entry in srv.chain.block_index.entries {
		if entry.hash in has_child {
			continue // not a tip
		}

		obj := make(json.Object, 4, context.temp_allocator)
		obj["height"] = json.Value(json.Integer(entry.height))
		obj["hash"] = json.Value(json.String(_hash_to_hex(entry.hash)))

		if entry.hash == active_tip_hash {
			obj["branchlen"] = json.Value(json.Integer(0))
			obj["status"] = json.Value(json.String("active"))
		} else {
			// Walk back to find fork point with active chain
			branchlen := 0
			current := entry
			for current != nil && current.height > active_tip_height {
				current = current.prev
				branchlen += 1
			}
			// Walk until we find a block on the active chain
			for current != nil && current.height >= 0 {
				if current.height < len(srv.chain.active_chain) && srv.chain.active_chain[current.height] == current.hash {
					break
				}
				current = current.prev
				branchlen += 1
			}
			obj["branchlen"] = json.Value(json.Integer(branchlen))

			// Determine status from entry flags
			if .Has_Data in entry.status && .Valid_Chain in entry.status {
				obj["status"] = json.Value(json.String("valid-fork"))
			} else if .Has_Data in entry.status {
				obj["status"] = json.Value(json.String("valid-fork"))
			} else if .Valid_Header in entry.status {
				obj["status"] = json.Value(json.String("headers-only"))
			} else {
				obj["status"] = json.Value(json.String("unknown"))
			}
		}

		tips[tip_idx] = json.Value(obj)
		tip_idx += 1
	}

	return _make_result(json.Value(tips), srv._current_id)
}

// --- getblockstats ---

_handle_getblockstats :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// First param can be int (height) or string (hash)
	height := -1
	hash: Hash256

	int_val, int_ok := _get_int_param(params, 0)
	if int_ok {
		height = int_val
		chain_h := chain.chain_height(srv.chain)
		if height < 0 || height > chain_h {
			return _make_error(.Block_Not_Found, "Block height out of range", srv._current_id)
		}
		hash = srv.chain.active_chain[height]
	} else {
		hash_hex, str_ok := _get_string_param(params, 0)
		if !str_ok {
			return _make_error(.Invalid_Params, "Missing hash_or_height parameter", srv._current_id)
		}
		h, h_ok := _hex_to_hash(hash_hex)
		if !h_ok {
			return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
		}
		hash = h
	}

	entry, found := srv.chain.block_index.entries[hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}
	height = entry.height

	// Read the full block
	if .Has_Data not_in entry.status {
		return _make_error(.Block_Not_Found, "Block data not available", srv._current_id)
	}
	loc := storage.Block_Location {
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
	if berr != .None {
		return _make_error(.Internal_Error, "Failed to read block", srv._current_id)
	}

	// Compute stats
	total_size := 0
	total_weight := 0
	total_ins := 0
	total_outs := 0
	total_fee: i64 = 0
	txs := len(block.txs)

	for tx_idx in 0 ..< txs {
		tx := block.txs[tx_idx]
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &tx)
		total_size += wire.writer_len(&w)
		total_weight += consensus.get_tx_weight(&tx)

		if !consensus.is_coinbase_tx(&tx) {
			total_ins += len(tx.inputs)
		}
		total_outs += len(tx.outputs)
	}

	// totalfee = coinbase_output_sum - subsidy
	subsidy := consensus.get_block_subsidy(height, srv.params)
	coinbase_out: i64 = 0
	if txs > 0 {
		cb := block.txs[0]
		for o in 0 ..< len(cb.outputs) {
			coinbase_out += cb.outputs[o].value
		}
	}
	total_fee = coinbase_out - subsidy
	if total_fee < 0 {
		total_fee = 0
	}

	avg_fee: i64 = 0
	avg_txsize := 0
	// Exclude coinbase from averages
	non_cb_count := txs - 1
	if non_cb_count > 0 {
		avg_fee = total_fee / i64(non_cb_count)
		avg_txsize = total_size / txs // include coinbase in avg size (Bitcoin Core does)
	}

	obj := make(json.Object, 16, context.temp_allocator)
	obj["avgfee"] = json.Value(json.Integer(avg_fee))
	obj["avgtxsize"] = json.Value(json.Integer(avg_txsize))
	obj["height"] = json.Value(json.Integer(height))
	obj["ins"] = json.Value(json.Integer(total_ins))
	obj["outs"] = json.Value(json.Integer(total_outs))
	obj["subsidy"] = json.Value(json.Integer(subsidy))
	obj["time"] = json.Value(json.Integer(i64(entry.timestamp)))
	obj["totalfee"] = json.Value(json.Integer(total_fee))
	obj["txs"] = json.Value(json.Integer(txs))
	obj["total_size"] = json.Value(json.Integer(total_size))
	obj["total_weight"] = json.Value(json.Integer(total_weight))

	return _make_result(json.Value(obj), srv._current_id)
}
