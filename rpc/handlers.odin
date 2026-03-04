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

// --- address to scriptPubKey ---

// Convert a Bitcoin address string to its scriptPubKey bytes.
_address_to_script_pubkey :: proc(addr: string, params: ^consensus.Chain_Params) -> ([]byte, bool) {
	// Try bech32 first
	hrp, ver, prog, prog_len, bech_ok := crypto.bech32_decode(addr)
	if bech_ok && hrp == params.bech32_hrp {
		spk := make([]byte, 2 + prog_len, context.temp_allocator)
		if ver == 0 {
			spk[0] = 0x00 // OP_0
		} else {
			spk[0] = u8(0x50 + ver) // OP_1..OP_16
		}
		spk[1] = u8(prog_len)
		copy(spk[2:], prog[:prog_len])
		return spk, true
	}

	// Try base58check
	version, payload, b58_ok := crypto.base58check_decode(addr)
	if b58_ok {
		if version == params.p2pkh_prefix {
			// P2PKH: OP_DUP OP_HASH160 <20> <hash> OP_EQUALVERIFY OP_CHECKSIG
			spk := make([]byte, 25, context.temp_allocator)
			spk[0] = 0x76  // OP_DUP
			spk[1] = 0xa9  // OP_HASH160
			spk[2] = 0x14  // push 20
			copy(spk[3:23], payload[:])
			spk[23] = 0x88 // OP_EQUALVERIFY
			spk[24] = 0xac // OP_CHECKSIG
			return spk, true
		} else if version == params.p2sh_prefix {
			// P2SH: OP_HASH160 <20> <hash> OP_EQUAL
			spk := make([]byte, 23, context.temp_allocator)
			spk[0] = 0xa9  // OP_HASH160
			spk[1] = 0x14  // push 20
			copy(spk[2:22], payload[:])
			spk[22] = 0x87 // OP_EQUAL
			return spk, true
		}
	}

	return nil, false
}

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
		if verbosity >= 2 {
			tx_arr[i] = json.Value(_decode_tx_to_json(&tx, srv.params))
		} else {
			txid := wire.tx_id(&tx)
			tx_arr[i] = json.Value(json.String(_hash_to_hex(txid)))
		}
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
	obj := _tx_to_json(tx, entry, srv.params)
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

	obj := make(json.Object, 12, context.temp_allocator)
	obj["loaded"] = json.Value(json.Boolean(true))
	obj["size"] = json.Value(json.Integer(count))
	obj["bytes"] = json.Value(json.Integer(srv.mp.usage))
	obj["usage"] = json.Value(json.Integer(srv.mp.usage))
	obj["maxmempool"] = json.Value(json.Integer(srv.mp.config.max_mempool_mb * 1_000_000))
	obj["mempoolminfee"] = json.Value(json.Float(_satoshi_to_btc(srv.mp.min_fee)))
	obj["minrelaytxfee"] = json.Value(json.Float(_satoshi_to_btc(srv.mp.config.min_relay_tx_fee)))
	obj["incrementalrelayfee"] = json.Value(json.Float(_satoshi_to_btc(srv.mp.config.incremental_relay_fee)))
	obj["unbroadcastcount"] = json.Value(json.Integer(0))
	obj["fullrbf"] = json.Value(json.Boolean(srv.mp.config.fullrbf))

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

		spk_obj := make(json.Object, 4, context.temp_allocator)
		spk_obj["asm"] = json.Value(json.String(script.script_to_asm(coin.script)))
		spk_obj["hex"] = json.Value(json.String(_bytes_to_hex(coin.script)))
		coin_stype := script.classify_script(coin.script)
		spk_obj["type"] = json.Value(json.String(script.script_type_name(coin_stype)))
		coin_addr, coin_addr_ok := _script_to_address(coin.script, srv.params)
		if coin_addr_ok {
			spk_obj["address"] = json.Value(json.String(coin_addr))
		}
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

			spk_obj := make(json.Object, 4, context.temp_allocator)
			spk_obj["asm"] = json.Value(json.String(script.script_to_asm(txout.script_pubkey)))
			spk_obj["hex"] = json.Value(json.String(_bytes_to_hex(txout.script_pubkey)))
			mp_stype := script.classify_script(txout.script_pubkey)
			spk_obj["type"] = json.Value(json.String(script.script_type_name(mp_stype)))
			mp_addr, mp_addr_ok := _script_to_address(txout.script_pubkey, srv.params)
			if mp_addr_ok {
				spk_obj["address"] = json.Value(json.String(mp_addr))
			}
			obj["scriptPubKey"] = json.Value(spk_obj)

			return _make_result(json.Value(obj), srv._current_id)
		}
	}

	// Not found — return null result (not an error, per Bitcoin Core behavior)
	return _make_result(json.Value(json.Null(nil)), srv._current_id)
}

// --- gettxoutsetinfo ---

_handle_gettxoutsetinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, height := chain.chain_tip(srv.chain)

	// Scan UTXO database for flushed stats
	db_count, db_amount := storage.utxo_db_scan_stats(srv.chain.coins.db)

	// Also count cache entries not yet flushed to LevelDB
	cache_count: u32 = 0
	cache_amount: i64 = 0
	for _, ce in srv.chain.coins.cache {
		// Skip spent sentinels (Dirty + zeroed coin + not Fresh)
		is_sentinel := ce.coin.amount == 0 && ce.coin.height == 0 &&
		               !ce.coin.is_coinbase && len(ce.coin.script) == 0 &&
		               .Dirty in ce.flags && .Fresh not_in ce.flags
		if is_sentinel { continue }

		if .Fresh in ce.flags {
			// Fresh = only in cache, not yet in DB
			cache_count += 1
			cache_amount += ce.coin.amount
		}
	}

	total_count := i64(db_count) + i64(cache_count)
	total_amount := db_amount + cache_amount

	// Estimate disk size
	disk_size := i64(db_count) * 100

	obj := make(json.Object, 8, context.temp_allocator)
	obj["height"] = json.Value(json.Integer(height))
	obj["bestblock"] = json.Value(json.String(_hash_to_hex(tip_hash)))
	obj["txouts"] = json.Value(json.Integer(total_count))
	obj["total_amount"] = json.Value(json.Float(_satoshi_to_btc(total_amount)))
	obj["disk_size"] = json.Value(json.Integer(disk_size))
	obj["hash_serialized_2"] = json.Value(json.String(""))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getmempoolancestors ---

_handle_getmempoolancestors :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}

	txid, hash_ok := _hex_to_hash(txid_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}

	if !mempool.mempool_has(srv.mp, txid) {
		return _make_error(.Block_Not_Found, "Transaction not in mempool", srv._current_id)
	}

	ancestors := mempool.mempool_get_ancestors(srv.mp, txid)
	verbose := _get_bool_param(params, 1, false)

	if verbose {
		obj := make(json.Object, len(ancestors), context.temp_allocator)
		for anc_txid in ancestors {
			entry, found := mempool.mempool_get(srv.mp, anc_txid)
			if found {
				obj[_hash_to_hex(anc_txid)] = json.Value(_format_mempool_entry(srv, entry))
			}
		}
		return _make_result(json.Value(obj), srv._current_id)
	} else {
		arr := make(json.Array, len(ancestors), context.temp_allocator)
		for i in 0 ..< len(ancestors) {
			arr[i] = json.Value(json.String(_hash_to_hex(ancestors[i])))
		}
		return _make_result(json.Value(arr), srv._current_id)
	}
}

// --- getmempooldescendants ---

_handle_getmempooldescendants :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}

	txid, hash_ok := _hex_to_hash(txid_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}

	if !mempool.mempool_has(srv.mp, txid) {
		return _make_error(.Block_Not_Found, "Transaction not in mempool", srv._current_id)
	}

	descendants := mempool.mempool_get_descendants(srv.mp, txid)
	verbose := _get_bool_param(params, 1, false)

	if verbose {
		obj := make(json.Object, len(descendants), context.temp_allocator)
		for desc_txid in descendants {
			entry, found := mempool.mempool_get(srv.mp, desc_txid)
			if found {
				obj[_hash_to_hex(desc_txid)] = json.Value(_format_mempool_entry(srv, entry))
			}
		}
		return _make_result(json.Value(obj), srv._current_id)
	} else {
		arr := make(json.Array, len(descendants), context.temp_allocator)
		for i in 0 ..< len(descendants) {
			arr[i] = json.Value(json.String(_hash_to_hex(descendants[i])))
		}
		return _make_result(json.Value(arr), srv._current_id)
	}
}

// --- gettxoutproof ---

_handle_gettxoutproof :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txids_val, txids_ok := _get_param(params, 0)
	if !txids_ok {
		return _make_error(.Invalid_Params, "Missing txids parameter", srv._current_id)
	}

	txids_arr, is_arr := txids_val.(json.Array)
	if !is_arr || len(txids_arr) == 0 {
		return _make_error(.Invalid_Params, "txids must be a non-empty array", srv._current_id)
	}

	// Parse txids
	target_txids := make([]Hash256, len(txids_arr), context.temp_allocator)
	for i in 0 ..< len(txids_arr) {
		hex_str, h_ok := txids_arr[i].(json.String)
		if !h_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("txid %d: must be a string", i), srv._current_id)
		}
		h, hh_ok := _hex_to_hash(hex_str)
		if !hh_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("txid %d: invalid hash", i), srv._current_id)
		}
		target_txids[i] = h
	}

	// Optional blockhash
	block_hash: Hash256
	have_blockhash := false
	bh_hex, bh_ok := _get_string_param(params, 1)
	if bh_ok {
		h, hh_ok := _hex_to_hash(bh_hex)
		if !hh_ok {
			return _make_error(.Invalid_Params, "Invalid blockhash", srv._current_id)
		}
		block_hash = h
		have_blockhash = true
	}

	if !have_blockhash {
		// Look up from UTXO set to find block height, then get hash
		outpoint := wire.Outpoint{hash = target_txids[0], index = 0}
		coin, found := chain.coins_cache_get(&srv.chain.coins, outpoint)
		if !found {
			return _make_error(.Misc_Error, "Transaction not yet in block or UTXO spent", srv._current_id)
		}
		h := int(coin.height)
		if h < 0 || h >= len(srv.chain.active_chain) {
			return _make_error(.Internal_Error, "Block height out of range", srv._current_id)
		}
		block_hash = srv.chain.active_chain[h]
		have_blockhash = true
	}

	// Load block
	entry, found := srv.chain.block_index.entries[block_hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}
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

	// Compute all txids
	all_txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		all_txids[i] = wire.tx_id(&block.txs[i])
	}

	// Build match set
	match_set := make(map[Hash256]bool, len(target_txids), context.temp_allocator)
	for txid in target_txids {
		match_set[txid] = true
	}

	// Verify all target txids are in the block
	for txid in target_txids {
		found_in_block := false
		for btxid in all_txids {
			if btxid == txid {
				found_in_block = true
				break
			}
		}
		if !found_in_block {
			return _make_error(.Misc_Error, "Not all transactions found in specified block", srv._current_id)
		}
	}

	// Build partial merkle tree
	hashes, flags, flags_len := crypto.merkle_build_partial_tree(all_txids, match_set)

	// Serialize proof: header(80) + total_txs(4 LE) + varint(num_hashes) + hashes + varint(num_flag_bytes) + flags
	w := wire.writer_init(context.temp_allocator)

	// Block header (80 bytes)
	wire.serialize_block_header(&w, &block.header)

	// total_txs (4 LE)
	wire.write_u32le(&w, u32(len(block.txs)))

	// varint(num_hashes) + hashes
	wire.write_compact_size(&w, u64(len(hashes)))
	for h in hashes {
		h := h
		wire.write_bytes(&w, h[:])
	}

	// varint(num_flag_bytes) + flags
	wire.write_compact_size(&w, u64(flags_len))
	wire.write_bytes(&w, flags[:flags_len])

	raw := wire.writer_bytes(&w)
	return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
}

// --- verifytxoutproof ---

_handle_verifytxoutproof :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	proof_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing proof parameter", srv._current_id)
	}

	raw, decode_ok := _hex_decode(proof_hex)
	if !decode_ok {
		return _make_error(.Invalid_Params, "Invalid hex string", srv._current_id)
	}

	if len(raw) < 84 { // 80 header + 4 total_txs minimum
		return _make_error(.Invalid_Params, "Proof too short", srv._current_id)
	}

	// Deserialize block header (80 bytes)
	reader := wire.reader_init(raw)
	header, hdr_err := wire.deserialize_block_header(&reader)
	if hdr_err != nil {
		return _make_error(.Invalid_Params, "Failed to deserialize block header", srv._current_id)
	}

	// total_txs (4 LE)
	total_txs_val, tt_err := wire.read_u32le(&reader)
	if tt_err != nil {
		return _make_error(.Invalid_Params, "Failed to read total_txs", srv._current_id)
	}
	total_txs := int(total_txs_val)

	// varint(num_hashes) + hashes
	num_hashes_val, nh_err := wire.read_compact_size(&reader)
	if nh_err != nil {
		return _make_error(.Invalid_Params, "Failed to read num_hashes", srv._current_id)
	}
	num_hashes := int(num_hashes_val)
	proof_hashes := make([]Hash256, num_hashes, context.temp_allocator)
	for i in 0 ..< num_hashes {
		h, hb_err := wire.read_hash(&reader)
		if hb_err != nil {
			return _make_error(.Invalid_Params, "Failed to read hash", srv._current_id)
		}
		proof_hashes[i] = h
	}

	// varint(num_flag_bytes) + flags
	num_flags_val, nf_err := wire.read_compact_size(&reader)
	if nf_err != nil {
		return _make_error(.Invalid_Params, "Failed to read num_flag_bytes", srv._current_id)
	}
	flag_bytes, fb_err := wire.read_bytes(&reader, int(num_flags_val), context.temp_allocator)
	if fb_err != nil {
		return _make_error(.Invalid_Params, "Failed to read flags", srv._current_id)
	}

	// Verify
	root, matched, verify_ok := crypto.merkle_verify_partial_tree(proof_hashes, flag_bytes, total_txs)
	if !verify_ok {
		arr := make(json.Array, 0, context.temp_allocator)
		return _make_result(json.Value(arr), srv._current_id)
	}

	// Check root matches header
	if root != header.merkle_root {
		arr := make(json.Array, 0, context.temp_allocator)
		return _make_result(json.Value(arr), srv._current_id)
	}

	// Verify the block exists in our index
	block_hash := wire.block_header_hash(&header)
	entry, bfound := srv.chain.block_index.entries[block_hash]
	if !bfound || .Valid_Header not_in entry.status {
		arr := make(json.Array, 0, context.temp_allocator)
		return _make_result(json.Value(arr), srv._current_id)
	}

	// Return matched txids
	arr := make(json.Array, len(matched), context.temp_allocator)
	for i in 0 ..< len(matched) {
		arr[i] = json.Value(json.String(_hash_to_hex(matched[i])))
	}
	return _make_result(json.Value(arr), srv._current_id)
}

// --- Format mempool entry (shared helper) ---

_format_mempool_entry :: proc(srv: ^RPC_Server, entry: ^mempool.Mempool_Entry) -> json.Object {
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

	replaceable := srv.mp.config.fullrbf || mempool.tx_signals_rbf(&entry.tx)
	obj["bip125-replaceable"] = json.Value(json.Boolean(replaceable))

	return obj
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

_tx_to_json :: proc(tx: ^wire.Tx, entry: ^mempool.Mempool_Entry, params: ^consensus.Chain_Params) -> json.Object {
	obj := _decode_tx_to_json(tx, params)
	obj["vsize"] = json.Value(json.Integer(entry.vsize))
	return obj
}

// Decode a transaction into JSON (for decoderawtransaction and getrawtransaction).
_decode_tx_to_json :: proc(tx: ^wire.Tx, params: ^consensus.Chain_Params) -> json.Object {
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

		spk := make(json.Object, 4, context.temp_allocator)
		spk["asm"] = json.Value(json.String(script.script_to_asm(tx.outputs[i].script_pubkey)))
		spk["hex"] = json.Value(json.String(_bytes_to_hex(tx.outputs[i].script_pubkey)))
		stype := script.classify_script(tx.outputs[i].script_pubkey)
		spk["type"] = json.Value(json.String(script.script_type_name(stype)))
		addr, addr_ok := _script_to_address(tx.outputs[i].script_pubkey, params)
		if addr_ok {
			spk["address"] = json.Value(json.String(addr))
		}
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
	return chain.get_median_time_past(entry)
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
		obj := make(json.Object, 20, context.temp_allocator)
		obj["id"] = json.Value(json.Integer(i64(id)))
		obj["addr"] = json.Value(json.String(peer.address))
		obj["services"] = json.Value(json.String(fmt.tprintf("%016x", peer.services)))
		obj["servicesnames"] = json.Value(_services_to_names(peer.services))
		obj["lastsend"] = json.Value(json.Integer(peer.last_send))
		obj["lastrecv"] = json.Value(json.Integer(peer.last_recv))
		obj["bytessent"] = json.Value(json.Integer(peer.bytes_sent))
		obj["bytesrecv"] = json.Value(json.Integer(peer.bytes_recv))
		obj["conntime"] = json.Value(json.Integer(peer.connected_at))
		obj["version"] = json.Value(json.Integer(i64(peer.version)))
		obj["subver"] = json.Value(json.String(peer.user_agent))
		obj["inbound"] = json.Value(json.Boolean(false))
		obj["startingheight"] = json.Value(json.Integer(i64(peer.start_height)))
		obj["synced_headers"] = json.Value(json.Integer(srv.cm.sync_mgr.best_header_height))
		obj["synced_blocks"] = json.Value(json.Integer(chain.chain_height(srv.chain)))
		obj["connection_type"] = json.Value(json.String("outbound-full-relay"))

		// Peer sync state
		ps, ps_found := srv.cm.sync_mgr.peer_sync[id]
		if ps_found {
			obj["last_block"] = json.Value(json.Integer(ps.last_block_received))
			obj["inflight"] = json.Value(json.Integer(ps.blocks_in_flight))
		} else {
			obj["last_block"] = json.Value(json.Integer(0))
			obj["inflight"] = json.Value(json.Integer(0))
		}

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

// Decode service bits to human-readable names.
_services_to_names :: proc(services: u64) -> json.Array {
	count := 0
	if services & 1 != 0 { count += 1 }       // NODE_NETWORK
	if services & 8 != 0 { count += 1 }       // NODE_WITNESS
	if services & 1024 != 0 { count += 1 }    // NODE_NETWORK_LIMITED

	names := make(json.Array, count, context.temp_allocator)
	idx := 0
	if services & 1 != 0 {
		names[idx] = json.Value(json.String("NETWORK"))
		idx += 1
	}
	if services & 8 != 0 {
		names[idx] = json.Value(json.String("WITNESS"))
		idx += 1
	}
	if services & 1024 != 0 {
		names[idx] = json.Value(json.String("NETWORK_LIMITED"))
		idx += 1
	}
	return names
}

// --- getnetworkinfo ---

_handle_getnetworkinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, 8, context.temp_allocator)
	obj["version"] = json.Value(json.Integer(1))
	obj["subversion"] = json.Value(json.String(wire.NODE_USER_AGENT))
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

	obj := _decode_tx_to_json(&tx, srv.params)
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

	obj := make(json.Object, 5, context.temp_allocator)
	obj["asm"] = json.Value(json.String(script.script_to_asm(raw)))

	stype := script.classify_script(raw)
	obj["type"] = json.Value(json.String(script.script_type_name(stype)))

	ds_addr, ds_addr_ok := _script_to_address(raw, srv.params)
	if ds_addr_ok {
		obj["address"] = json.Value(json.String(ds_addr))
	}

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

	obj := _format_mempool_entry(srv, entry)
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

_handle_getchaintxstats :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	chain_h := chain.chain_height(srv.chain)
	if chain_h < 0 {
		return _make_error(.Internal_Error, "Chain not initialized", srv._current_id)
	}

	// Default window: min(chain_height, 30 days of blocks at 10-min intervals)
	default_window := chain_h
	if default_window > 30 * 24 * 6 {
		default_window = 30 * 24 * 6
	}

	// Parse optional nblocks (param 0)
	nblocks := default_window
	nblocks_val, nblocks_ok := _get_int_param(params, 0)
	if nblocks_ok {
		nblocks = nblocks_val
	}

	// Parse optional blockhash (param 1) — defaults to chain tip
	end_hash: Hash256
	hash_hex, hash_ok := _get_string_param(params, 1)
	if hash_ok {
		h, h_ok := _hex_to_hash(hash_hex)
		if !h_ok {
			return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
		}
		end_hash = h
	} else {
		end_hash = srv.chain.active_chain[chain_h]
	}

	end_entry, found := srv.chain.block_index.entries[end_hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}

	if nblocks < 0 || nblocks > end_entry.height {
		return _make_error(.Invalid_Params, "Invalid nblocks", srv._current_id)
	}

	// Walk backward from end_entry for nblocks to find start_entry
	start_entry := chain.block_index_get_ancestor(end_entry, end_entry.height - nblocks)
	if start_entry == nil {
		return _make_error(.Internal_Error, "Failed to find ancestor block", srv._current_id)
	}

	// Compute window_tx_count by walking from start+1 to end
	window_tx_count: i64 = 0
	if end_entry.chain_tx > 0 && start_entry.chain_tx > 0 {
		// Fast path: use precomputed cumulative counts
		window_tx_count = end_entry.chain_tx - start_entry.chain_tx
	} else {
		// Slow path: walk the window and sum num_tx, reading from disk if needed
		current := end_entry
		for current != nil && current.height > start_entry.height {
			if current.num_tx > 0 {
				window_tx_count += i64(current.num_tx)
			} else if .Has_Data in current.status {
				// Read block from disk to count txs
				loc := storage.Block_Location {
					file_num    = current.file_num,
					data_offset = current.data_offset,
					data_size   = current.data_size,
				}
				block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
				if berr == .None {
					window_tx_count += i64(len(block.txs))
				}
			}
			current = current.prev
		}
	}

	// Compute window interval
	window_interval := i64(end_entry.timestamp) - i64(start_entry.timestamp)

	obj := make(json.Object, 8, context.temp_allocator)
	obj["time"] = json.Value(json.Integer(i64(end_entry.timestamp)))
	obj["window_final_block_hash"] = json.Value(json.String(_hash_to_hex(end_entry.hash)))
	obj["window_final_block_height"] = json.Value(json.Integer(end_entry.height))
	obj["window_block_count"] = json.Value(json.Integer(nblocks))

	if nblocks > 0 {
		obj["window_tx_count"] = json.Value(json.Integer(window_tx_count))
		obj["window_interval"] = json.Value(json.Integer(window_interval))
		if window_interval > 0 {
			txrate := f64(window_tx_count) / f64(window_interval)
			obj["txrate"] = json.Value(json.Float(txrate))
		}
	}

	// Include txcount (cumulative) only if chain_tx is populated
	if end_entry.chain_tx > 0 {
		obj["txcount"] = json.Value(json.Integer(end_entry.chain_tx))
	}

	return _make_result(json.Value(obj), srv._current_id)
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

// Convert a scriptPubKey to an address string using chain params.
_script_to_address :: proc(spk: []byte, params: ^consensus.Chain_Params) -> (string, bool) {
	stype := script.classify_script(spk)

	switch stype {
	case .P2PKH:
		return crypto.base58check_encode(params.p2pkh_prefix, spk[3:23]), true
	case .P2SH:
		return crypto.base58check_encode(params.p2sh_prefix, spk[2:22]), true
	case .P2WPKH, .P2WSH, .P2TR, .Witness_Unknown:
		ver, prog, ok := script.is_witness_program(spk)
		if !ok { return "", false }
		return crypto.bech32_encode(params.bech32_hrp, ver, prog), true
	case .P2PK, .Null_Data, .Non_Standard:
		return "", false
	}

	return "", false
}

// --- help ---

RPC_METHODS := [?]string{
	"combinerawtransaction",
	"createrawtransaction",
	"decoderawtransaction",
	"decodescript",
	"getbestblockhash",
	"getblock",
	"getblockchaininfo",
	"getblockcount",
	"getblockhash",
	"getblockheader",
	"getblockstats",
	"getchaintips",
	"getchaintxstats",
	"getconnectioncount",
	"getdifficulty",
	"getmempoolancestors",
	"getmempooldescendants",
	"getmempoolentry",
	"getmempoolinfo",
	"getmemoryinfo",
	"getmininginfo",
	"getnettotals",
	"getnetworkhashps",
	"getnetworkinfo",
	"getpeerinfo",
	"getrawmempool",
	"getrawtransaction",
	"getrpcinfo",
	"gettxout",
	"gettxoutproof",
	"gettxoutsetinfo",
	"help",
	"logging",
	"ping",
	"savemempool",
	"sendrawtransaction",
	"signrawtransactionwithkey",
	"stop",
	"testmempoolaccept",
	"uptime",
	"validateaddress",
	"verifytxoutproof",
}

_handle_help :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	method_name, has_method := _get_string_param(params, 0)

	if !has_method || len(method_name) == 0 {
		// Return sorted list of all method names
		b := strings.builder_make(0, 512, context.temp_allocator)
		for i in 0 ..< len(RPC_METHODS) {
			if i > 0 { strings.write_byte(&b, '\n') }
			strings.write_string(&b, RPC_METHODS[i])
		}
		return _make_result(json.Value(json.String(strings.to_string(b))), srv._current_id)
	}

	// Check if method exists
	found := false
	for m in RPC_METHODS {
		if m == method_name {
			found = true
			break
		}
	}
	if !found {
		return _make_error(.Method_Not_Found, fmt.tprintf("help: unknown method '%s'", method_name), srv._current_id)
	}

	usage := _get_method_help(method_name)
	return _make_result(json.Value(json.String(usage)), srv._current_id)
}

_get_method_help :: proc(method: string) -> string {
	switch method {
	case "getblockchaininfo":    return "getblockchaininfo\nReturns an object containing various state info regarding blockchain processing."
	case "getblockcount":        return "getblockcount\nReturns the height of the most-work fully-validated chain."
	case "getblockhash":         return "getblockhash height\nReturns hash of block in best-block-chain at height provided."
	case "getbestblockhash":     return "getbestblockhash\nReturns the hash of the best (tip) block in the most-work fully-validated chain."
	case "getblock":             return "getblock \"blockhash\" ( verbosity )\nReturns block data. verbosity 0=hex, 1=json, 2=json with decoded txs."
	case "getrawtransaction":    return "getrawtransaction \"txid\" ( verbose )\nReturn the raw transaction data."
	case "sendrawtransaction":   return "sendrawtransaction \"hexstring\"\nSubmit a raw transaction to the mempool."
	case "getmempoolinfo":       return "getmempoolinfo\nReturns details on the active state of the TX memory pool."
	case "getrawmempool":        return "getrawmempool\nReturns all transaction ids in memory pool."
	case "gettxout":             return "gettxout \"txid\" n ( include_mempool )\nReturns details about an unspent transaction output."
	case "getblockheader":       return "getblockheader \"blockhash\" ( verbose )\nReturns information about a block header."
	case "getdifficulty":        return "getdifficulty\nReturns the proof-of-work difficulty as a multiple of the minimum difficulty."
	case "getconnectioncount":   return "getconnectioncount\nReturns the number of connections to other nodes."
	case "getpeerinfo":          return "getpeerinfo\nReturns data about each connected network peer."
	case "getnetworkinfo":       return "getnetworkinfo\nReturns an object containing various state info regarding P2P networking."
	case "stop":                 return "stop\nRequest a graceful shutdown of the node."
	case "uptime":               return "uptime\nReturns the total uptime of the server in seconds."
	case "decoderawtransaction": return "decoderawtransaction \"hexstring\"\nReturn a JSON object representing the serialized, hex-encoded transaction."
	case "decodescript":         return "decodescript \"hexstring\"\nDecode a hex-encoded script."
	case "getmempoolancestors":  return "getmempoolancestors \"txid\" ( verbose )\nReturns all in-mempool ancestors of a transaction."
	case "getmempooldescendants": return "getmempooldescendants \"txid\" ( verbose )\nReturns all in-mempool descendants of a transaction."
	case "getmempoolentry":      return "getmempoolentry \"txid\"\nReturns mempool data for given transaction."
	case "testmempoolaccept":    return "testmempoolaccept [\"rawtx\",...]\nReturns result of mempool acceptance tests."
	case "getchaintips":         return "getchaintips\nReturn information about all known tips in the block tree."
	case "getchaintxstats":      return "getchaintxstats ( nblocks \"blockhash\" )\nCompute statistics about the total number and rate of transactions in the chain."
	case "getblockstats":        return "getblockstats hash_or_height\nCompute per block statistics for a given window."
	case "gettxoutproof":        return "gettxoutproof [\"txid\",...] ( \"blockhash\" )\nReturns a hex-encoded proof that one or more txids were included in a block."
	case "gettxoutsetinfo":      return "gettxoutsetinfo\nReturns statistics about the unspent transaction output set."
	case "help":                 return "help ( \"method\" )\nList all commands, or get help for a specified command."
	case "getmininginfo":        return "getmininginfo\nReturns a json object containing mining-related information."
	case "getnetworkhashps":     return "getnetworkhashps ( nblocks height )\nReturns the estimated network hashes per second."
	case "getnettotals":         return "getnettotals\nReturns information about network traffic."
	case "validateaddress":      return "validateaddress \"address\"\nReturn information about the given bitcoin address."
	case "savemempool":          return "savemempool\nDumps the mempool to disk."
	case "ping":                        return "ping\nRequests that a ping be sent to all other nodes."
	case "getmemoryinfo":               return "getmemoryinfo ( \"mode\" )\nReturns an object containing information about memory usage."
	case "getrpcinfo":                  return "getrpcinfo\nReturns details about the RPC server."
	case "logging":                     return "logging\nGets the logging configuration categories."
	case "createrawtransaction":        return "createrawtransaction [{\"txid\":\"hex\",\"vout\":n},...] [{\"address\":amount},...] ( locktime replaceable )\nCreate a transaction spending the given inputs and creating new outputs."
	case "combinerawtransaction":       return "combinerawtransaction [\"hex\",...]\nCombine multiple partially signed transactions into one transaction."
	case "signrawtransactionwithkey":   return "signrawtransactionwithkey \"hex\" [\"privatekey\",...] ( [{\"txid\":\"hex\",\"vout\":n,\"scriptPubKey\":\"hex\",\"amount\":n},...] \"sighashtype\" )\nSign inputs for raw transaction with provided private keys."
	case "verifytxoutproof":           return "verifytxoutproof \"proof\"\nVerifies that a proof points to a transaction in a block, returning the txids."
	}
	return fmt.tprintf("%s\nNo detailed help available.", method)
}

// --- getblock verbosity=2 ---
// (Handled in existing _handle_getblock by extending the verbosity check)

// --- getmininginfo ---

_handle_getmininginfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, height := chain.chain_tip(srv.chain)

	obj := make(json.Object, 8, context.temp_allocator)
	obj["blocks"] = json.Value(json.Integer(height))

	entry, found := srv.chain.block_index.entries[tip_hash]
	if found {
		obj["difficulty"] = json.Value(json.Float(consensus.get_difficulty(entry.bits)))
	} else {
		obj["difficulty"] = json.Value(json.Float(0.0))
	}

	obj["networkhashps"] = json.Value(json.Float(_estimate_hashps(srv, 120, -1)))
	obj["pooledtx"] = json.Value(json.Integer(mempool.mempool_count(srv.mp)))
	obj["chain"] = json.Value(json.String(srv.params.name))
	obj["warnings"] = json.Value(json.String(""))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getnetworkhashps ---

_handle_getnetworkhashps :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	nblocks := 120
	height := -1

	nb, nb_ok := _get_int_param(params, 0)
	if nb_ok { nblocks = nb }

	h, h_ok := _get_int_param(params, 1)
	if h_ok { height = h }

	hashps := _estimate_hashps(srv, nblocks, height)
	return _make_result(json.Value(json.Float(hashps)), srv._current_id)
}

// Estimate network hash rate over nblocks ending at height.
_estimate_hashps :: proc(srv: ^RPC_Server, nblocks: int, height: int) -> f64 {
	tip_height := chain.chain_height(srv.chain)
	target_height := height < 0 ? tip_height : min(height, tip_height)

	if target_height < 1 || nblocks < 1 {
		return 0.0
	}

	// Walk back nblocks from target_height
	lookback := min(nblocks, target_height)
	start_height := target_height - lookback

	// Get timestamps
	end_hash := srv.chain.active_chain[target_height]
	start_hash := srv.chain.active_chain[start_height]

	end_entry, end_found := srv.chain.block_index.entries[end_hash]
	start_entry, start_found := srv.chain.block_index.entries[start_hash]
	if !end_found || !start_found {
		return 0.0
	}

	time_span := i64(end_entry.timestamp) - i64(start_entry.timestamp)
	if time_span <= 0 {
		return 0.0
	}

	// hashps = difficulty * 2^32 / avg_block_time
	// avg_block_time = time_span / lookback
	// So: hashps = difficulty * 2^32 * lookback / time_span
	diff := consensus.get_difficulty(end_entry.bits)
	return diff * 4294967296.0 * f64(lookback) / f64(time_span)
}

// --- getnettotals ---

_handle_getnettotals :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	total_recv: i64 = 0
	total_sent: i64 = 0

	if srv.cm != nil {
		for _, peer in srv.cm.peers {
			total_recv += peer.bytes_recv
			total_sent += peer.bytes_sent
		}
	}

	obj := make(json.Object, 4, context.temp_allocator)
	obj["totalbytesrecv"] = json.Value(json.Integer(total_recv))
	obj["totalbytessent"] = json.Value(json.Integer(total_sent))
	obj["timemillis"] = json.Value(json.Integer(time.to_unix_seconds(time.now()) * 1000))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- validateaddress ---

_handle_validateaddress :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	addr_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing address parameter", srv._current_id)
	}

	obj := make(json.Object, 8, context.temp_allocator)
	obj["address"] = json.Value(json.String(addr_str))

	// Try bech32 first
	hrp, ver, prog, prog_len, bech_ok := crypto.bech32_decode(addr_str)
	if bech_ok {
		// Verify HRP matches network
		if hrp != srv.params.bech32_hrp {
			obj["isvalid"] = json.Value(json.Boolean(false))
			return _make_result(json.Value(obj), srv._current_id)
		}

		obj["isvalid"] = json.Value(json.Boolean(true))
		obj["iswitness"] = json.Value(json.Boolean(true))
		obj["witness_version"] = json.Value(json.Integer(ver))
		obj["witness_program"] = json.Value(json.String(_bytes_to_hex(prog[:prog_len])))

		// Build scriptPubKey: OP_n <push prog_len> <program>
		spk := make([]byte, 2 + prog_len, context.temp_allocator)
		if ver == 0 {
			spk[0] = 0x00 // OP_0
		} else {
			spk[0] = u8(0x50 + ver) // OP_1..OP_16
		}
		spk[1] = u8(prog_len)
		copy(spk[2:], prog[:prog_len])
		obj["scriptPubKey"] = json.Value(json.String(_bytes_to_hex(spk)))

		obj["isscript"] = json.Value(json.Boolean(ver == 0 && prog_len == 32)) // P2WSH

		return _make_result(json.Value(obj), srv._current_id)
	}

	// Try base58check
	version, payload, b58_ok := crypto.base58check_decode(addr_str)
	if b58_ok {
		// Check version matches network
		is_p2pkh := version == srv.params.p2pkh_prefix
		is_p2sh := version == srv.params.p2sh_prefix
		if !is_p2pkh && !is_p2sh {
			obj["isvalid"] = json.Value(json.Boolean(false))
			return _make_result(json.Value(obj), srv._current_id)
		}

		obj["isvalid"] = json.Value(json.Boolean(true))
		obj["iswitness"] = json.Value(json.Boolean(false))
		obj["isscript"] = json.Value(json.Boolean(is_p2sh))

		if is_p2pkh {
			// OP_DUP OP_HASH160 <20> <hash> OP_EQUALVERIFY OP_CHECKSIG
			spk := make([]byte, 25, context.temp_allocator)
			spk[0] = 0x76  // OP_DUP
			spk[1] = 0xa9  // OP_HASH160
			spk[2] = 0x14  // push 20
			copy(spk[3:23], payload[:])
			spk[23] = 0x88 // OP_EQUALVERIFY
			spk[24] = 0xac // OP_CHECKSIG
			obj["scriptPubKey"] = json.Value(json.String(_bytes_to_hex(spk)))
		} else {
			// OP_HASH160 <20> <hash> OP_EQUAL
			spk := make([]byte, 23, context.temp_allocator)
			spk[0] = 0xa9  // OP_HASH160
			spk[1] = 0x14  // push 20
			copy(spk[2:22], payload[:])
			spk[22] = 0x87 // OP_EQUAL
			obj["scriptPubKey"] = json.Value(json.String(_bytes_to_hex(spk)))
		}

		return _make_result(json.Value(obj), srv._current_id)
	}

	// Invalid address
	obj["isvalid"] = json.Value(json.Boolean(false))
	return _make_result(json.Value(obj), srv._current_id)
}

// --- savemempool ---

_handle_savemempool :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	ok := mempool.mempool_save(srv.mp, srv.data_dir)
	if !ok {
		return _make_error(.Misc_Error, "Failed to save mempool to disk", srv._current_id)
	}
	return _make_result(json.Value(json.Null(nil)), srv._current_id)
}

// --- ping ---

_handle_ping :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.cm != nil {
		for _, peer in srv.cm.peers {
			p2p.peer_send_ping(peer)
		}
	}
	return _make_result(json.Value(json.Null(nil)), srv._current_id)
}

// --- getmemoryinfo ---

_handle_getmemoryinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Optional mode param (default "stats", only "stats" supported)
	mode, has_mode := _get_string_param(params, 0)
	if has_mode && mode != "stats" {
		return _make_error(.Invalid_Params, "Only \"stats\" mode is supported", srv._current_id)
	}

	used := i64(srv.chain.coins.mem_usage)
	total := i64(srv.chain.coins.budget)
	free_mem := total - used
	if free_mem < 0 { free_mem = 0 }
	chunks_used := i64(len(srv.chain.coins.cache))

	locked := make(json.Object, 8, context.temp_allocator)
	locked["used"] = json.Value(json.Integer(used))
	locked["free"] = json.Value(json.Integer(free_mem))
	locked["total"] = json.Value(json.Integer(total))
	locked["chunks_used"] = json.Value(json.Integer(chunks_used))
	locked["chunks_free"] = json.Value(json.Integer(0))

	obj := make(json.Object, 2, context.temp_allocator)
	obj["locked"] = json.Value(locked)

	return _make_result(json.Value(obj), srv._current_id)
}

// --- getrpcinfo ---

_handle_getrpcinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cmd := make(json.Object, 4, context.temp_allocator)
	cmd["method"] = json.Value(json.String("getrpcinfo"))
	cmd["duration"] = json.Value(json.Integer(0))

	cmds := make(json.Array, 1, context.temp_allocator)
	cmds[0] = json.Value(cmd)

	obj := make(json.Object, 2, context.temp_allocator)
	obj["active_commands"] = json.Value(cmds)

	return _make_result(json.Value(obj), srv._current_id)
}

// --- logging ---

_handle_logging :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, 8, context.temp_allocator)
	obj["net"] = json.Value(json.Boolean(true))
	obj["mempool"] = json.Value(json.Boolean(true))
	obj["validation"] = json.Value(json.Boolean(true))
	obj["rpc"] = json.Value(json.Boolean(true))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- createrawtransaction ---

_handle_createrawtransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Params: [inputs_array, outputs_array, locktime?, replaceable?]
	inputs_val, inputs_ok := _get_param(params, 0)
	if !inputs_ok {
		return _make_error(.Invalid_Params, "Missing inputs parameter", srv._current_id)
	}
	inputs_arr, is_inputs_arr := inputs_val.(json.Array)
	if !is_inputs_arr {
		return _make_error(.Invalid_Params, "inputs must be an array", srv._current_id)
	}

	outputs_val, outputs_ok := _get_param(params, 1)
	if !outputs_ok {
		return _make_error(.Invalid_Params, "Missing outputs parameter", srv._current_id)
	}
	outputs_arr, is_outputs_arr := outputs_val.(json.Array)
	if !is_outputs_arr {
		return _make_error(.Invalid_Params, "outputs must be an array", srv._current_id)
	}

	// Optional locktime
	locktime: u32 = 0
	lt, lt_ok := _get_int_param(params, 2)
	if lt_ok { locktime = u32(lt) }

	// Optional replaceable
	replaceable := _get_bool_param(params, 3, false)
	default_sequence: u32 = replaceable ? 0xFFFFFFFD : 0xFFFFFFFE

	// Build inputs
	tx_inputs := make([]wire.Tx_In, len(inputs_arr), context.temp_allocator)
	for i in 0 ..< len(inputs_arr) {
		in_obj, in_ok := inputs_arr[i].(json.Object)
		if !in_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("input %d: must be an object", i), srv._current_id)
		}

		txid_str, txid_ok := in_obj["txid"].(json.String)
		if !txid_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("input %d: missing txid", i), srv._current_id)
		}
		txid_hash, hash_ok := _hex_to_hash(txid_str)
		if !hash_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("input %d: invalid txid", i), srv._current_id)
		}

		vout: u32 = 0
		vout_val, vout_found := in_obj["vout"]
		if vout_found {
			#partial switch v in vout_val {
			case json.Integer: vout = u32(v)
			case json.Float:   vout = u32(v)
			}
		}

		seq := default_sequence
		seq_val, seq_found := in_obj["sequence"]
		if seq_found {
			#partial switch v in seq_val {
			case json.Integer: seq = u32(v)
			case json.Float:   seq = u32(v)
			}
		}

		tx_inputs[i] = wire.Tx_In {
			previous_output = wire.Outpoint{hash = txid_hash, index = vout},
			script_sig      = make([]byte, 0, context.temp_allocator),
			sequence        = seq,
		}
	}

	// Build outputs
	tx_outputs := make([dynamic]wire.Tx_Out, 0, len(outputs_arr), context.temp_allocator)
	for i in 0 ..< len(outputs_arr) {
		out_obj, out_ok := outputs_arr[i].(json.Object)
		if !out_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("output %d: must be an object", i), srv._current_id)
		}

		for key, val in out_obj {
			if key == "data" {
				// OP_RETURN output
				data_hex, d_ok := val.(json.String)
				if !d_ok {
					return _make_error(.Invalid_Params, "data must be a string", srv._current_id)
				}
				data_bytes, dec_ok := _hex_decode(data_hex)
				if !dec_ok {
					return _make_error(.Invalid_Params, "invalid data hex", srv._current_id)
				}
				// Build OP_RETURN script: OP_RETURN <push data>
				script_len := 1 + 1 + len(data_bytes) // OP_RETURN + push_len + data
				spk := make([]byte, script_len, context.temp_allocator)
				spk[0] = 0x6a // OP_RETURN
				spk[1] = u8(len(data_bytes))
				copy(spk[2:], data_bytes)
				append(&tx_outputs, wire.Tx_Out{value = 0, script_pubkey = spk})
			} else {
				// Address output
				amount_f64: f64 = 0
				#partial switch v in val {
				case json.Float:   amount_f64 = v
				case json.Integer: amount_f64 = f64(v)
				case:
					return _make_error(.Invalid_Params, fmt.tprintf("output %d: amount must be numeric", i), srv._current_id)
				}
				amount_sat := i64(amount_f64 * 1e8 + 0.5)

				spk, spk_ok := _address_to_script_pubkey(key, srv.params)
				if !spk_ok {
					return _make_error(.Invalid_Params, fmt.tprintf("Invalid address: %s", key), srv._current_id)
				}
				append(&tx_outputs, wire.Tx_Out{value = amount_sat, script_pubkey = spk})
			}
		}
	}

	tx := wire.Tx {
		version  = 2,
		inputs   = tx_inputs,
		outputs  = tx_outputs[:],
		locktime = locktime,
	}

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &tx)
	raw := wire.writer_bytes(&w)

	return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
}

// --- combinerawtransaction ---

_handle_combinerawtransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Params: [["hex1", "hex2", ...]]
	hex_arr_val, arr_ok := _get_param(params, 0)
	if !arr_ok {
		return _make_error(.Invalid_Params, "Missing hex array parameter", srv._current_id)
	}
	hex_arr, is_arr := hex_arr_val.(json.Array)
	if !is_arr || len(hex_arr) < 1 {
		return _make_error(.Invalid_Params, "Must provide at least one transaction", srv._current_id)
	}

	// Deserialize all transactions
	txs := make([dynamic]wire.Tx, 0, len(hex_arr), context.temp_allocator)
	for i in 0 ..< len(hex_arr) {
		hex_str, h_ok := hex_arr[i].(json.String)
		if !h_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("tx %d: must be hex string", i), srv._current_id)
		}
		raw, dec_ok := _hex_decode(hex_str)
		if !dec_ok {
			return _make_error(.Tx_Deser_Error, fmt.tprintf("tx %d: invalid hex", i), srv._current_id)
		}
		r := wire.reader_init(raw)
		tx, err := wire.deserialize_tx(&r, context.temp_allocator)
		if err != nil {
			return _make_error(.Tx_Deser_Error, fmt.tprintf("tx %d: deserialization failed", i), srv._current_id)
		}
		append(&txs, tx)
	}

	// Verify all have same structure
	base := &txs[0]
	for i in 1 ..< len(txs) {
		tx := &txs[i]
		if len(tx.inputs) != len(base.inputs) || len(tx.outputs) != len(base.outputs) {
			return _make_error(.Invalid_Params, "Transactions do not have the same structure", srv._current_id)
		}
		// Verify same prevouts
		for j in 0 ..< len(tx.inputs) {
			if tx.inputs[j].previous_output.hash != base.inputs[j].previous_output.hash ||
			   tx.inputs[j].previous_output.index != base.inputs[j].previous_output.index {
				return _make_error(.Invalid_Params, "Transactions do not spend the same inputs", srv._current_id)
			}
		}
	}

	// Merge: for each input, pick the best scriptSig/witness
	merged := txs[0]
	has_any_witness := false

	for i in 0 ..< len(merged.inputs) {
		for j in 1 ..< len(txs) {
			tx := &txs[j]
			// Prefer longer scriptSig
			if len(tx.inputs[i].script_sig) > len(merged.inputs[i].script_sig) {
				merged.inputs[i].script_sig = tx.inputs[i].script_sig
			}
			// Prefer non-empty witness
			if tx.witness != nil && i < len(tx.witness) && len(tx.witness[i]) > 0 {
				if merged.witness == nil || i >= len(merged.witness) || len(merged.witness[i]) == 0 {
					// Need to ensure merged.witness is big enough
					if merged.witness == nil {
						merged.witness = make([][][]byte, len(merged.inputs), context.temp_allocator)
					}
					merged.witness[i] = tx.witness[i]
				}
			}
		}
		if merged.witness != nil && i < len(merged.witness) && len(merged.witness[i]) > 0 {
			has_any_witness = true
		}
	}

	if !has_any_witness {
		merged.witness = nil
	}

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &merged)
	raw := wire.writer_bytes(&w)

	return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
}

// --- signrawtransactionwithkey ---

_handle_signrawtransactionwithkey :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Params: [hex_tx, [privkey_wif, ...], [prevtxs?], sighash_type?]
	hex_str, hex_ok := _get_string_param(params, 0)
	if !hex_ok {
		return _make_error(.Invalid_Params, "Missing transaction hex", srv._current_id)
	}

	raw, dec_ok := _hex_decode(hex_str)
	if !dec_ok {
		return _make_error(.Tx_Deser_Error, "Invalid transaction hex", srv._current_id)
	}
	r := wire.reader_init(raw)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		return _make_error(.Tx_Deser_Error, "Failed to deserialize transaction", srv._current_id)
	}

	// Parse private keys
	keys_val, keys_ok := _get_param(params, 1)
	if !keys_ok {
		return _make_error(.Invalid_Params, "Missing private keys array", srv._current_id)
	}
	keys_arr, is_keys_arr := keys_val.(json.Array)
	if !is_keys_arr {
		return _make_error(.Invalid_Params, "Private keys must be an array", srv._current_id)
	}

	// Decode all WIF keys and derive pubkeys
	Key_Info :: struct {
		seckey:     [32]u8,
		pubkey:     [33]u8,
		compressed: bool,
	}
	key_infos := make([dynamic]Key_Info, 0, len(keys_arr), context.temp_allocator)
	for i in 0 ..< len(keys_arr) {
		wif_str, w_ok := keys_arr[i].(json.String)
		if !w_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("key %d: must be string", i), srv._current_id)
		}
		seckey, compressed, wif_ok := crypto.wif_decode(wif_str)
		if !wif_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("key %d: invalid WIF", i), srv._current_id)
		}
		pubkey, pub_ok := crypto.pubkey_from_seckey(seckey[:])
		if !pub_ok {
			return _make_error(.Invalid_Params, fmt.tprintf("key %d: failed to derive pubkey", i), srv._current_id)
		}
		append(&key_infos, Key_Info{seckey = seckey, pubkey = pubkey, compressed = compressed})
	}

	// Parse prevtxs
	Prevtx_Info :: struct {
		txid:           Hash256,
		vout:           u32,
		script_pubkey:  []byte,
		amount:         i64,
		redeem_script:  []byte,
	}
	prevtxs := make([dynamic]Prevtx_Info, 0, 8, context.temp_allocator)
	prevtxs_val, prevtxs_ok := _get_param(params, 2)
	if prevtxs_ok {
		prevtxs_arr, is_pt_arr := prevtxs_val.(json.Array)
		if is_pt_arr {
			for i in 0 ..< len(prevtxs_arr) {
				pt_obj, pt_ok := prevtxs_arr[i].(json.Object)
				if !pt_ok { continue }

				ptxid_str, ptxid_ok := pt_obj["txid"].(json.String)
				if !ptxid_ok { continue }
				ptxid, ptxid_hash_ok := _hex_to_hash(ptxid_str)
				if !ptxid_hash_ok { continue }

				pvout: u32 = 0
				pvout_val, pvout_found := pt_obj["vout"]
				if pvout_found {
					#partial switch v in pvout_val {
					case json.Integer: pvout = u32(v)
					case json.Float:   pvout = u32(v)
					}
				}

				spk_hex, spk_ok := pt_obj["scriptPubKey"].(json.String)
				if !spk_ok { continue }
				spk_bytes, spk_dec_ok := _hex_decode(spk_hex)
				if !spk_dec_ok { continue }

				amt: i64 = 0
				amt_val, amt_found := pt_obj["amount"]
				if amt_found {
					#partial switch v in amt_val {
					case json.Float:   amt = i64(v * 1e8 + 0.5)
					case json.Integer: amt = i64(v)
					}
				}

				rs: []byte = nil
				rs_hex, rs_ok := pt_obj["redeemScript"].(json.String)
				if rs_ok {
					rs, _ = _hex_decode(rs_hex)
				}

				append(&prevtxs, Prevtx_Info{
					txid = ptxid, vout = pvout,
					script_pubkey = spk_bytes, amount = amt,
					redeem_script = rs,
				})
			}
		}
	}

	// Sign each input
	errors := make(json.Array, 0, len(tx.inputs), context.temp_allocator)
	complete := true

	// Ensure witness array exists
	if tx.witness == nil {
		tx.witness = make([][][]byte, len(tx.inputs), context.temp_allocator)
	}

	for i in 0 ..< len(tx.inputs) {
		inp := &tx.inputs[i]

		// Find matching prevtx info
		pt_found := false
		pt_info: Prevtx_Info
		for pt in prevtxs[:] {
			if pt.txid == inp.previous_output.hash && pt.vout == inp.previous_output.index {
				pt_info = pt
				pt_found = true
				break
			}
		}
		if !pt_found {
			complete = false
			continue
		}

		// Determine script type and sign
		spk := pt_info.script_pubkey
		signed := false

		if len(spk) == 25 && spk[0] == 0x76 && spk[1] == 0xa9 && spk[2] == 0x14 && spk[23] == 0x88 && spk[24] == 0xac {
			// P2PKH: OP_DUP OP_HASH160 <20 hash> OP_EQUALVERIFY OP_CHECKSIG
			pkh := spk[3:23]
			for &ki in key_infos {
				pub_hash := crypto.hash160(ki.pubkey[:])
				if _bytes_equal(pub_hash[:], pkh) {
					// Compute legacy sighash
					sighash := script.compute_sighash_legacy(&tx, i, spk, 0x01) // SIGHASH_ALL
					sig_der, sig_len, sig_ok := crypto.sign_ecdsa(ki.seckey[:], sighash)
					if sig_ok {
						// Build scriptSig: <sig + hashtype> <pubkey>
						ss := make([]byte, 1 + sig_len + 1 + 1 + 33, context.temp_allocator)
						ss[0] = u8(sig_len + 1) // push (sig + hashtype byte)
						copy(ss[1:], sig_der[:sig_len])
						ss[1 + sig_len] = 0x01 // SIGHASH_ALL
						ss[2 + sig_len] = 0x21 // push 33 (compressed pubkey)
						copy(ss[3 + sig_len:], ki.pubkey[:])
						inp.script_sig = ss
						signed = true
					}
					break
				}
			}
		} else if len(spk) == 22 && spk[0] == 0x00 && spk[1] == 0x14 {
			// P2WPKH: OP_0 <20-byte hash>
			pkh := spk[2:22]
			for &ki in key_infos {
				pub_hash := crypto.hash160(ki.pubkey[:])
				if _bytes_equal(pub_hash[:], pkh) {
					// Build script code for P2WPKH: OP_DUP OP_HASH160 <20> <hash> OP_EQUALVERIFY OP_CHECKSIG
					script_code := make([]byte, 25, context.temp_allocator)
					script_code[0] = 0x76
					script_code[1] = 0xa9
					script_code[2] = 0x14
					copy(script_code[3:23], pkh)
					script_code[23] = 0x88
					script_code[24] = 0xac

					sighash := script.compute_sighash_witness_v0(&tx, i, script_code, pt_info.amount, 0x01)
					sig_der, sig_len, sig_ok := crypto.sign_ecdsa(ki.seckey[:], sighash)
					if sig_ok {
						// Build witness: [sig+hashtype, pubkey]
						wit := make([][]byte, 2, context.temp_allocator)
						sig_with_ht := make([]byte, sig_len + 1, context.temp_allocator)
						copy(sig_with_ht, sig_der[:sig_len])
						sig_with_ht[sig_len] = 0x01
						wit[0] = sig_with_ht
						pk_copy := make([]byte, 33, context.temp_allocator)
						copy(pk_copy, ki.pubkey[:])
						wit[1] = pk_copy
						tx.witness[i] = wit
						signed = true
					}
					break
				}
			}
		} else if len(spk) == 23 && spk[0] == 0xa9 && spk[1] == 0x14 && spk[22] == 0x87 {
			// P2SH — check if it's P2SH-P2WPKH using redeemScript
			if pt_info.redeem_script != nil && len(pt_info.redeem_script) == 22 &&
			   pt_info.redeem_script[0] == 0x00 && pt_info.redeem_script[1] == 0x14 {
				// P2SH-P2WPKH
				pkh := pt_info.redeem_script[2:22]
				for &ki in key_infos {
					pub_hash := crypto.hash160(ki.pubkey[:])
					if _bytes_equal(pub_hash[:], pkh) {
						script_code := make([]byte, 25, context.temp_allocator)
						script_code[0] = 0x76
						script_code[1] = 0xa9
						script_code[2] = 0x14
						copy(script_code[3:23], pkh)
						script_code[23] = 0x88
						script_code[24] = 0xac

						sighash := script.compute_sighash_witness_v0(&tx, i, script_code, pt_info.amount, 0x01)
						sig_der, sig_len, sig_ok := crypto.sign_ecdsa(ki.seckey[:], sighash)
						if sig_ok {
							// scriptSig: push redeemScript
							rs_len := len(pt_info.redeem_script)
							ss := make([]byte, 1 + rs_len, context.temp_allocator)
							ss[0] = u8(rs_len)
							copy(ss[1:], pt_info.redeem_script)
							inp.script_sig = ss

							// witness: [sig+hashtype, pubkey]
							wit := make([][]byte, 2, context.temp_allocator)
							sig_with_ht := make([]byte, sig_len + 1, context.temp_allocator)
							copy(sig_with_ht, sig_der[:sig_len])
							sig_with_ht[sig_len] = 0x01
							wit[0] = sig_with_ht
							pk_copy := make([]byte, 33, context.temp_allocator)
							copy(pk_copy, ki.pubkey[:])
							wit[1] = pk_copy
							tx.witness[i] = wit
							signed = true
						}
						break
					}
				}
			}
		}

		if !signed {
			complete = false
			err_obj := make(json.Object, 4, context.temp_allocator)
			err_obj["txid"] = json.Value(json.String(_hash_to_hex(inp.previous_output.hash)))
			err_obj["vout"] = json.Value(json.Integer(i64(inp.previous_output.index)))
			err_obj["error"] = json.Value(json.String("Unable to sign input"))
			append(&errors, json.Value(err_obj))
		}
	}

	// Serialize signed tx
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &tx)
	signed_raw := wire.writer_bytes(&w)

	obj := make(json.Object, 4, context.temp_allocator)
	obj["hex"] = json.Value(json.String(_bytes_to_hex(signed_raw)))
	obj["complete"] = json.Value(json.Boolean(complete))
	obj["errors"] = json.Value(errors)

	return _make_result(json.Value(obj), srv._current_id)
}

// Helper: compare two byte slices for equality.
_bytes_equal :: proc(a: []byte, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}
