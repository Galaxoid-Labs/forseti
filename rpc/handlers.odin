package rpc

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "../chain"
import "../consensus"
import crypto "../crypto"
import "../descriptor"
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
	obj["chain"] = json.Value(json.String(_bip70_chain_name(srv.params.name)))
	obj["blocks"] = json.Value(json.Integer(height))
	obj["headers"] = json.Value(json.Integer(header_height))
	obj["bestblockhash"] = json.Value(json.String(_hash_to_hex(tip_hash)))

	// Difficulty, time, and cumulative work from tip block
	tip_entry, tip_found := srv.chain.block_index.entries[tip_hash]
	if tip_found {
		obj["difficulty"] = json.Value(json.Float(consensus.get_difficulty(tip_entry.bits)))
		obj["time"] = json.Value(json.Integer(i64(tip_entry.timestamp)))
		obj["mediantime"] = json.Value(json.Integer(i64(_get_median_time(srv, tip_entry))))
		obj["chainwork"] = json.Value(json.String(_bytes_to_hex(tip_entry.chain_work[:])))
	} else {
		obj["difficulty"] = json.Value(json.Float(0.0))
		obj["time"] = json.Value(json.Integer(0))
		obj["mediantime"] = json.Value(json.Integer(0))
		zero_work: [32]byte
		obj["chainwork"] = json.Value(json.String(_bytes_to_hex(zero_work[:])))
	}
	obj["size_on_disk"] = json.Value(json.Integer(chain.disk_usage(srv.chain)))

	// Verification progress: blocks / headers (0.0 to 1.0)
	if header_height > 0 {
		obj["verificationprogress"] = json.Value(json.Float(chain.verification_progress(srv.chain, time.to_unix_seconds(time.now()))))
	} else {
		obj["verificationprogress"] = json.Value(json.Float(0.0))
	}

	// Initial block download: consider IBD if headers are significantly ahead of blocks
	obj["initialblockdownload"] = json.Value(json.Boolean(header_height - height > 24))
	obj["pruned"] = json.Value(json.Boolean(srv.chain.prune_target > 0))
	if srv.chain.prune_target > 0 {
		obj["pruneheight"] = json.Value(json.Integer(i64(srv.chain.prune_height)))
	}
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
	obj["chainwork"] = json.Value(json.String(_bytes_to_hex(entry.chain_work[:])))
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
	if found {
		tx := &entry.tx
		if !verbose {
			w := wire.writer_init(context.temp_allocator)
			wire.serialize_tx(&w, tx)
			raw := wire.writer_bytes(&w)
			return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
		}
		obj := _tx_to_json(tx, entry, srv.params)
		return _make_result(json.Value(obj), srv._current_id)
	}

	// Confirmed txs via the transaction index.
	if srv.chain.tx_index == nil {
		return _make_error(.Misc_Error, "No such mempool transaction. Use -txindex to enable blockchain transaction queries.", srv._current_id)
	}
	tx, block_hash, height, idx_found := chain.tx_index_lookup(srv.chain, txid)
	if !idx_found {
		return _make_error(.Misc_Error, "No such mempool or blockchain transaction", srv._current_id)
	}

	if !verbose {
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &tx)
		raw := wire.writer_bytes(&w)
		return _make_result(json.Value(json.String(_bytes_to_hex(raw))), srv._current_id)
	}

	obj := _tx_to_json(&tx, nil, srv.params)
	tip_height := chain.chain_height(srv.chain)
	obj["blockhash"] = json.Value(json.String(_hash_to_hex(block_hash)))
	obj["confirmations"] = json.Value(json.Integer(i64(tip_height - height + 1)))
	if blk_entry, e_found := srv.chain.block_index.entries[block_hash]; e_found {
		obj["time"] = json.Value(json.Integer(i64(blk_entry.timestamp)))
		obj["blocktime"] = json.Value(json.Integer(i64(blk_entry.timestamp)))
	}
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

	// Relay to peers with wtxid + fee rate for BIP133/339.
	if srv.cm != nil {
		entry, _ := mempool.mempool_get(srv.mp, txid)
		wtxid := entry.wtxid if entry != nil else txid
		fee_rate_kvb := mempool.fee_rate_per_kvb(entry.fee_rate) if entry != nil else i64(0)
		p2p.conn_manager_relay_tx(srv.cm, txid, wtxid, fee_rate_kvb)
	}

	return _make_result(json.Value(json.String(_hash_to_hex(txid))), srv._current_id)
}

// --- getmempoolinfo ---

_handle_getmempoolinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	count := mempool.mempool_count(srv.mp)

	// Sum of base fees of all mempool txs (BTC) — Core's total_fee.
	total_fee: i64 = 0
	for _, e in srv.mp.entries {
		total_fee += e.fee
	}

	obj := make(json.Object, 13, context.temp_allocator)
	obj["loaded"] = json.Value(json.Boolean(true))
	obj["size"] = json.Value(json.Integer(count))
	obj["bytes"] = json.Value(json.Integer(srv.mp.usage))
	obj["usage"] = json.Value(json.Integer(srv.mp.usage))
	obj["total_fee"] = json.Value(json.Float(_satoshi_to_btc(total_fee)))
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
	// getrawmempool ( verbose ) — verbose=true returns {txid: <mempoolentry>}.
	if _get_bool_param(params, 0, false) {
		obj := make(json.Object, mempool.mempool_count(srv.mp), context.temp_allocator)
		for txid, entry in srv.mp.entries {
			obj[_hash_to_hex(txid)] = json.Value(_format_mempool_entry(srv, entry))
		}
		return _make_result(json.Value(obj), srv._current_id)
	}

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

	// Fast path: rolling stats maintained by the coins cache (datadirs
	// synced since rolling stats shipped). Falls through to the legacy
	// full scan on older datadirs.
	if srv.chain.coins.stats_valid {
		obj := make(json.Object, 8, context.temp_allocator)
		obj["height"] = json.Value(json.Integer(height))
		obj["bestblock"] = json.Value(json.String(_hash_to_hex(tip_hash)))
		obj["txouts"] = json.Value(json.Integer(srv.chain.coins.stat_count))
		obj["total_amount"] = json.Value(json.Float(_satoshi_to_btc(srv.chain.coins.stat_amount)))
		obj["disk_size"] = json.Value(json.Integer(srv.chain.coins.stat_count * 100))
		obj["hash_serialized_2"] = json.Value(json.String(""))
		return _make_result(json.Value(obj), srv._current_id)
	}

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

// Full Bitcoin Core getmempoolentry shape. Strict clients (bitcoincore-rpc
// serde, hence electrs) require EVERY non-optional field: a thin response
// parses to nothing, entries silently vanish, and electrs's mempool sync
// never converges (get_balance hung forever).
_format_mempool_entry :: proc(srv: ^RPC_Server, entry: ^mempool.Mempool_Entry) -> json.Object {
	obj := make(json.Object, 16, context.temp_allocator)
	obj["vsize"] = json.Value(json.Integer(entry.vsize))
	obj["weight"] = json.Value(json.Integer(consensus.get_tx_weight(&entry.tx)))
	obj["time"] = json.Value(json.Integer(entry.time))
	obj["height"] = json.Value(json.Integer(srv.mp.tip_height))
	obj["wtxid"] = json.Value(json.String(_hash_to_hex(entry.wtxid)))
	obj["unbroadcast"] = json.Value(json.Boolean(false))

	// Ancestor/descendant aggregates (counts include the tx itself).
	anc := mempool.mempool_get_ancestors(srv.mp, entry.txid)
	defer delete(anc)
	desc := mempool.mempool_get_descendants(srv.mp, entry.txid)
	defer delete(desc)
	anc_size, anc_fees := entry.vsize, entry.fee
	for a in anc {
		if e, e_found := mempool.mempool_get(srv.mp, a); e_found {
			anc_size += e.vsize
			anc_fees += e.fee
		}
	}
	desc_size, desc_fees := entry.vsize, entry.fee
	for d in desc {
		if e, e_found := mempool.mempool_get(srv.mp, d); e_found {
			desc_size += e.vsize
			desc_fees += e.fee
		}
	}
	obj["ancestorcount"] = json.Value(json.Integer(len(anc) + 1))
	obj["ancestorsize"] = json.Value(json.Integer(anc_size))
	obj["descendantcount"] = json.Value(json.Integer(len(desc) + 1))
	obj["descendantsize"] = json.Value(json.Integer(desc_size))

	// Modified fee includes any prioritisetransaction delta for this tx.
	delta := srv.mp.fee_deltas[entry.txid]
	fees := make(json.Object, 4, context.temp_allocator)
	fees["base"] = json.Value(json.Float(_satoshi_to_btc(entry.fee)))
	fees["modified"] = json.Value(json.Float(_satoshi_to_btc(entry.fee + delta)))
	fees["ancestor"] = json.Value(json.Float(_satoshi_to_btc(anc_fees + delta)))
	fees["descendant"] = json.Value(json.Float(_satoshi_to_btc(desc_fees + delta)))
	obj["fees"] = json.Value(fees)

	// spentby: in-mempool children spending this tx's outputs.
	spentby := make(json.Array, 0, context.temp_allocator)
	seen := make(map[Hash256]bool, 8, context.temp_allocator)
	for out_idx in 0 ..< len(entry.tx.outputs) {
		op := wire.Outpoint{hash = entry.txid, index = u32(out_idx)}
		if child, spent := srv.mp.spent_outpoints[op]; spent && !seen[child] {
			seen[child] = true
			append(&spentby, json.Value(json.String(_hash_to_hex(child))))
		}
	}
	obj["spentby"] = json.Value(spentby)

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
	// getrawtransaction (verbose) includes the raw hex; decoderawtransaction does not.
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, tx)
	obj["hex"] = json.Value(json.String(_bytes_to_hex(wire.writer_bytes(&w))))
	if entry != nil {
		obj["vsize"] = json.Value(json.Integer(entry.vsize))
	}
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
	obj["chainwork"] = json.Value(json.String(_bytes_to_hex(entry.chain_work[:])))
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
		obj["inbound"] = json.Value(json.Boolean(peer.inbound))
		obj["connection_type"] = json.Value(json.String(p2p.connection_type_string(peer.conn_type)))
		obj["startingheight"] = json.Value(json.Integer(i64(peer.start_height)))
		obj["synced_headers"] = json.Value(json.Integer(srv.cm.sync_mgr.best_header_height))
		obj["synced_blocks"] = json.Value(json.Integer(chain.chain_height(srv.chain)))
		obj["transport_protocol_type"] = json.Value(json.String("v2" if (peer.v2 != nil && peer.v2.state == .Active) else "v1"))

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
	if services & 4 != 0 { count += 1 }       // NODE_BLOOM (BIP111)
	if services & 8 != 0 { count += 1 }       // NODE_WITNESS
	if services & 64 != 0 { count += 1 }      // NODE_COMPACT_FILTERS
	if services & 1024 != 0 { count += 1 }    // NODE_NETWORK_LIMITED
	if services & 2048 != 0 { count += 1 }    // NODE_P2P_V2

	names := make(json.Array, count, context.temp_allocator)
	idx := 0
	if services & 1 != 0 {
		names[idx] = json.Value(json.String("NETWORK"))
		idx += 1
	}
	if services & 4 != 0 {
		names[idx] = json.Value(json.String("BLOOM"))
		idx += 1
	}
	if services & 8 != 0 {
		names[idx] = json.Value(json.String("WITNESS"))
		idx += 1
	}
	if services & 64 != 0 {
		names[idx] = json.Value(json.String("COMPACT_FILTERS"))
		idx += 1
	}
	if services & 1024 != 0 {
		names[idx] = json.Value(json.String("NETWORK_LIMITED"))
		idx += 1
	}
	if services & 2048 != 0 {
		names[idx] = json.Value(json.String("P2P_V2"))
		idx += 1
	}
	return names
}

// --- getnetworkinfo ---

// Core-style numeric version (major*10000 + minor*100). Clients branch on
// this to pick RPC schemas — bitcoincore-rpc treats version < 190000 as
// Bitcoin 0.18 and demands the legacy softforks array + bip9_softforks map.
// Report the Core version whose RPC surface we mirror.
CORE_COMPAT_VERSION :: 280000

_handle_getnetworkinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, 12, context.temp_allocator)
	obj["version"] = json.Value(json.Integer(CORE_COMPAT_VERSION))
	obj["subversion"] = json.Value(json.String(wire.NODE_USER_AGENT))
	obj["protocolversion"] = json.Value(json.Integer(i64(wire.PROTOCOL_VERSION)))

	local_services := u64(p2p.LOCAL_SERVICES)
	if srv.cm != nil {
		local_services = srv.cm.local_services
	}
	obj["localservices"] = json.Value(json.String(fmt.tprintf("%016x", local_services)))
	obj["localservicesnames"] = json.Value(_services_to_names(local_services))

	conn_count := 0
	conn_in := 0
	conn_out := 0
	if srv.cm != nil {
		for _, peer in srv.cm.peers {
			conn_count += 1
			if peer.inbound {
				conn_in += 1
			} else {
				conn_out += 1
			}
		}
	}
	obj["connections"] = json.Value(json.Integer(conn_count))
	obj["connections_in"] = json.Value(json.Integer(conn_in))
	obj["connections_out"] = json.Value(json.Integer(conn_out))
	obj["networkactive"] = json.Value(json.Boolean(true))
	obj["localrelay"] = json.Value(json.Boolean(!srv.mp.config.blocks_only))
	obj["timeoffset"] = json.Value(json.Integer(0))
	obj["networks"] = json.Value(make(json.Array, 0, context.temp_allocator))
	obj["localaddresses"] = json.Value(make(json.Array, 0, context.temp_allocator))
	obj["relayfee"] = json.Value(json.Float(_satoshi_to_btc(srv.mp.config.min_relay_tx_fee)))
	obj["incrementalfee"] = json.Value(json.Float(_satoshi_to_btc(srv.mp.config.incremental_relay_fee)))
	obj["warnings"] = json.Value(json.String(""))

	return _make_result(json.Value(obj), srv._current_id)
}

// Map internal chain params name to the BIP70 network string Bitcoin Core
// reports (strict clients — bitcoincore-rpc serde — reject anything else).
_bip70_chain_name :: proc(name: string) -> string {
	switch name {
	case "mainnet":
		return "main"
	case "testnet3":
		return "test"
	}
	return name // signet, regtest, testnet4 match already
}

// --- estimatesmartfee ---
//
// Confirmation-tracking estimator (Core CBlockPolicyEstimator port). Until
// it has observed enough blocks/txs it falls back to the dynamic mempool
// floor — an honest lower bound, and clients like electrs always get a
// number (they hard-fail on errors here).
_handle_estimatesmartfee :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	conf_target, has_target := _get_int_param(params, 0)
	if !has_target || conf_target < 1 {
		conf_target = 6
	}
	conservative := false
	if mode, has_mode := _get_string_param(params, 1); has_mode {
		switch mode {
		case "conservative", "CONSERVATIVE":
			conservative = true
		case "economical", "ECONOMICAL", "unset", "UNSET":
			conservative = false
		case:
			return _make_error(.Invalid_Params, "Invalid estimate_mode parameter", srv._current_id)
		}
	}

	floor_sat := max(srv.mp.min_fee, srv.mp.config.min_relay_tx_fee)
	feerate_sat := floor_sat
	if est, found := mempool.estimator_smart_fee(&srv.mp.estimator, conf_target, conservative); found {
		feerate_sat = max(est, floor_sat)
	}

	obj := make(json.Object, 2, context.temp_allocator)
	obj["feerate"] = json.Value(json.Float(_satoshi_to_btc(feerate_sat)))
	obj["blocks"] = json.Value(json.Integer(i64(conf_target)))
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

// Master method list for `help` — REGENERATED FROM THE DISPATCH TABLE in
// server.odin (audit found 16 dispatched methods missing here). If you add
// a `case` to _dispatch, add it here, sorted.
RPC_METHODS := [?]string{
	"addnode",
	"analyzepsbt",
	"clearbanned",
	"combinepsbt",
	"combinerawtransaction",
	"converttopsbt",
	"createmultisig",
	"createpsbt",
	"createrawtransaction",
	"decodepsbt",
	"decoderawtransaction",
	"decodescript",
	"deriveaddresses",
	"disconnectnode",
	"estimatesmartfee",
	"finalizepsbt",
	"generateblock",
	"generatetoaddress",
	"generatetodescriptor",
	"getaddednodeinfo",
	"getaddrmaninfo",
	"getbestblockhash",
	"getblock",
	"getblockchaininfo",
	"getblockcount",
	"getblockfilter",
	"getblockfrompeer",
	"getblockhash",
	"getblockheader",
	"getblockstats",
	"getblocktemplate",
	"getchaintips",
	"getchaintxstats",
	"getconnectioncount",
	"getdeploymentinfo",
	"getdescriptoractivity",
	"getdescriptorinfo",
	"getdifficulty",
	"getindexinfo",
	"getmemoryinfo",
	"getmempoolancestors",
	"getmempooldescendants",
	"getmempoolentry",
	"getmempoolinfo",
	"getmininginfo",
	"getnettotals",
	"getnetworkhashps",
	"getnetworkinfo",
	"getnodeaddresses",
	"getnodestatus",
	"getpeerinfo",
	"getprioritisedtransactions",
	"getrawmempool",
	"getrawtransaction",
	"getrpcinfo",
	"getsidechaininfo",
	"gettxout",
	"gettxoutproof",
	"gettxoutsetinfo",
	"gettxspendingprevout",
	"help",
	"joinpsbts",
	"listbanned",
	"listsidechains",
	"listwithdrawalstatus",
	"logging",
	"ping",
	"preciousblock",
	"prioritisetransaction",
	"pruneblockchain",
	"savemempool",
	"scanblocks",
	"scantxoutset",
	"sendrawtransaction",
	"setban",
	"setnetworkactive",
	"signmessagewithprivkey",
	"signrawtransactionwithkey",
	"stop",
	"submitblock",
	"submitheader",
	"testmempoolaccept",
	"uptime",
	"utxoupdatepsbt",
	"validateaddress",
	"verifychain",
	"verifymessage",
	"verifytxoutproof",
	"waitforblock",
	"waitforblockheight",
	"waitfornewblock",
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
	case "getnodestatus":        return "getnodestatus\nReturns the dashboard status snapshot (chain, sync, peers, mempool, cache, profile)."
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
	case "decodepsbt":                  return "decodepsbt \"psbt\"\nReturn a JSON object representing the serialized, base64-encoded partially signed Bitcoin transaction."
	case "createpsbt":                  return "createpsbt [{\"txid\":\"hex\",\"vout\":n},...] [{\"address\":amount},...] ( locktime replaceable )\nCreates a transaction in the Partially Signed Transaction format. Returns base64 PSBT."
	case "converttopsbt":               return "converttopsbt \"hexstring\"\nConverts a network serialized transaction to a PSBT. ScriptSigs and witnesses are stripped."
	case "combinepsbt":                 return "combinepsbt [\"psbt\",...]\nCombine multiple partially signed transactions (same unsigned tx) into one. Returns base64 PSBT."
	case "joinpsbts":                   return "joinpsbts [\"psbt\",...]\nJoins multiple distinct PSBTs into one, unioning their inputs and outputs. Returns base64 PSBT."
	case "finalizepsbt":                return "finalizepsbt \"psbt\" ( extract )\nFinalize the inputs of a PSBT. If complete and extract=true, returns the network tx hex; otherwise returns the finalized PSBT."
	case "analyzepsbt":                 return "analyzepsbt \"psbt\"\nAnalyzes and provides information about the current status of a PSBT and its inputs (next role, missing UTXOs, fee)."
	case "utxoupdatepsbt":              return "utxoupdatepsbt \"psbt\"\nUpdates a PSBT with witness UTXOs retrieved from the node's UTXO set. Non-witness inputs require txindex."
	case "getprioritisedtransactions": return "getprioritisedtransactions\nReturns a map of all fee deltas set via prioritisetransaction, keyed by txid (with in_mempool and modified_fee)."
	case "getaddrmaninfo":              return "getaddrmaninfo\nReturns per-network address counts from the address manager. forseti has no new/tried split, so all are reported as new."
	case "gettxspendingprevout":        return "gettxspendingprevout [{\"txid\":\"hex\",\"vout\":n},...]\nScans the mempool to see if any transaction spends the given outputs; returns spendingtxid when found."
	case "getdeploymentinfo":           return "getdeploymentinfo ( \"blockhash\" )\nReturns soft-fork deployment status at the tip (or given block). forseti uses hardcoded activation heights, so all deployments are reported as buried."
	case "getblockfrompeer":            return "getblockfrompeer \"blockhash\" peer_id\nRequests a block from a connected peer by nodeid (header must already be known). Returns an empty object; the block arrives asynchronously."
	case "scanblocks":                  return "scanblocks \"action\" ( [scanobjects] start_height stop_height \"filtertype\" )\nUses BIP157 block filters (requires --blockfilterindex) to return blocks that may contain scriptPubKeys matching the given descriptors."
	case "getdescriptoractivity":       return "getdescriptoractivity ( [blockhashes] [scanobjects] include_mempool )\nReturns spend/receive activity for the given descriptors within the given blocks (uses undo data for spends) and optionally the mempool."
	case "waitfornewblock":             return "waitfornewblock ( timeout )\nWaits for a new block (any tip change) and returns {hash, height}. timeout in ms (0 = no timeout)."
	case "waitforblock":                return "waitforblock \"blockhash\" ( timeout )\nWaits until the chain tip is the given block hash, then returns {hash, height}. timeout in ms (0 = no timeout)."
	case "waitforblockheight":          return "waitforblockheight height ( timeout )\nWaits until the chain tip reaches the given height, then returns {hash, height}. timeout in ms (0 = no timeout)."
	case "verifytxoutproof":           return "verifytxoutproof \"proof\"\nVerifies that a proof points to a transaction in a block, returning the txids."
	case "getblockfilter":             return "getblockfilter \"blockhash\" ( \"filtertype\" )\nRetrieve a BIP 158 content filter for a particular block."
	case "listsidechains":             return "listsidechains\nList active BIP300 sidechains (D1) and pending sidechain proposals. Requires --drivechain=track or enforce."
	case "getsidechaininfo":           return "getsidechaininfo nsidechain\nReturns information about one active BIP300 sidechain, including its CTIP (treasury UTXO). Requires --drivechain=track or enforce."
	case "listwithdrawalstatus":       return "listwithdrawalstatus ( nsidechain )\nList BIP300 withdrawal bundles (D2) with their ACK scores and blocks remaining. Requires --drivechain=track or enforce."
	case "getblocktemplate":           return "getblocktemplate ( {\"rules\":[\"segwit\",...]} )\nReturns data needed to construct a block to work on. Requires the segwit rule; supports mode=proposal."
	case "submitblock":                return "submitblock \"hexdata\"\nAttempts to submit a new block to the network."
	case "submitheader":               return "submitheader \"hexdata\"\nDecode the given hexdata as a header and submit it as a candidate chain tip if valid."
	case "prioritisetransaction":      return "prioritisetransaction \"txid\" ( dummy ) fee_delta\nAccepts the transaction into mined blocks at a higher (or lower) priority."
	case "generateblock":              return "generateblock \"output\" ( [\"rawtx/txid\",...] )\nMine a block with a set of ordered transactions immediately to a specified address (regtest only)."
	case "getdescriptorinfo":          return "getdescriptorinfo \"descriptor\"\nAnalyses a descriptor: canonical form with checksum, isrange, issolvable."
	case "deriveaddresses":            return "deriveaddresses \"descriptor\" ( range )\nDerives one or more addresses corresponding to an output descriptor."
	case "generatetodescriptor":       return "generatetodescriptor num_blocks \"descriptor\" ( maxtries )\nMine to a specified descriptor and return the block hashes (regtest only)."
	case "scantxoutset":               return "scantxoutset \"action\" ( [scanobjects,...] )\nScans the unspent transaction output set for entries that match certain output descriptors."
	case "verifychain":                return "verifychain ( checklevel nblocks )\nVerifies blockchain database: block data reads/deserializes (0), context-free validity (1), undo data (2+)."
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

// getblockfilter — BIP 157/158
// Params: blockhash (string, required), filtertype (string, optional, default "basic")
// Returns: {"filter": "<hex>", "header": "<hex>"}
_handle_getblockfilter :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Check filter index is enabled.
	if srv.chain.filter_db == nil {
		return _make_error(.Misc_Error, "Index is not enabled for filtertype basic", srv._current_id)
	}

	hash_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing blockhash parameter", srv._current_id)
	}

	hash, hash_ok := _hex_to_hash(hash_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}

	// Optional filter type parameter (only "basic" supported).
	filter_type_str, has_type := _get_string_param(params, 1)
	if has_type && filter_type_str != "basic" {
		return _make_error(.Invalid_Params, fmt.tprintf("Unknown filtertype %s", filter_type_str), srv._current_id)
	}

	// Look up block in index.
	entry, found := srv.chain.block_index.entries[hash]
	if !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}

	// Must be in the active chain.
	tip_height := chain.chain_height(srv.chain)
	if entry.height < 0 || entry.height > tip_height {
		return _make_error(.Block_Not_Found, "Block is not in the main chain", srv._current_id)
	}
	if srv.chain.active_chain[entry.height] != hash {
		return _make_error(.Block_Not_Found, "Block is not in the main chain", srv._current_id)
	}

	// Retrieve filter and header from filter DB.
	filter_data, filter_found := storage.filter_db_get_filter(srv.chain.filter_db, hash, context.temp_allocator)
	if !filter_found {
		filter_data = nil
	}

	filter_header, header_found := storage.filter_db_get_header(srv.chain.filter_db, hash)
	if !header_found {
		filter_header = {}
	}

	obj := make(json.Object, 2, context.temp_allocator)
	obj["filter"] = json.Value(json.String(_bytes_to_hex(filter_data)))
	obj["header"] = json.Value(json.String(_bytes_to_hex(filter_header[:])))

	return _make_result(json.Value(obj), srv._current_id)
}

// --- BIP 137: signmessagewithprivkey ---

_handle_signmessagewithprivkey :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	arr, is_arr := params.(json.Array)
	if !is_arr || len(arr) < 2 {
		return _make_error(.Invalid_Params, "Expected [privkey, message]", srv._current_id)
	}

	wif_str, wif_ok := arr[0].(json.String)
	message, msg_ok := arr[1].(json.String)
	if !wif_ok || !msg_ok {
		return _make_error(.Invalid_Params, "Expected string arguments", srv._current_id)
	}

	seckey, compressed, decode_ok := crypto.wif_decode(wif_str)
	if !decode_ok {
		return _make_error(.Invalid_Params, "Invalid private key", srv._current_id)
	}

	msg_hash := crypto.message_hash(message)
	compact, recid, sign_ok := crypto.sign_recoverable(seckey[:], msg_hash)
	if !sign_ok {
		return _make_error(.Internal_Error, "Signing failed", srv._current_id)
	}

	// Build 65-byte signature: flag_byte + compact(64)
	// flag = 27 + recid + (4 if compressed)
	sig65: [65]u8
	sig65[0] = u8(27 + recid + (compressed ? 4 : 0))
	copy(sig65[1:], compact[:])

	sig_b64 := base64.encode(sig65[:], allocator = context.temp_allocator)
	return _make_result(json.Value(json.String(sig_b64)), srv._current_id)
}

// --- BIP 137: verifymessage ---

_handle_verifymessage :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	arr, is_arr := params.(json.Array)
	if !is_arr || len(arr) < 3 {
		return _make_error(.Invalid_Params, "Expected [address, signature, message]", srv._current_id)
	}

	address, addr_ok := arr[0].(json.String)
	sig_b64, sig_ok := arr[1].(json.String)
	message, msg_ok := arr[2].(json.String)
	if !addr_ok || !sig_ok || !msg_ok {
		return _make_error(.Invalid_Params, "Expected string arguments", srv._current_id)
	}

	// Decode base64 signature → 65 bytes
	sig_bytes, b64_err := base64.decode(sig_b64, allocator = context.temp_allocator)
	if b64_err != nil || len(sig_bytes) != 65 {
		return _make_error(.Invalid_Params, "Invalid signature encoding", srv._current_id)
	}

	flag := sig_bytes[0]
	if flag < 27 || flag > 34 {
		return _make_error(.Invalid_Params, "Invalid signature flag byte", srv._current_id)
	}

	recid := int((flag - 27) & 3)
	is_compressed := flag >= 31

	msg_hash := crypto.message_hash(message)
	compressed_pub, uncompressed_pub, recover_ok := crypto.recover_pubkey(sig_bytes[1:], recid, msg_hash)
	if !recover_ok {
		return _make_result(json.Value(json.Boolean(false)), srv._current_id)
	}

	// Compute address from recovered pubkey and compare
	p := srv.chain.params
	pub_bytes := is_compressed ? compressed_pub[:] : uncompressed_pub[:]
	pub_hash := crypto.hash160(pub_bytes)

	// Try matching as P2PKH (base58)
	p2pkh_addr := crypto.base58check_encode(p.p2pkh_prefix, pub_hash[:])
	if p2pkh_addr == address {
		return _make_result(json.Value(json.Boolean(true)), srv._current_id)
	}

	// Try matching as P2SH-P2WPKH (base58): only for compressed keys
	if is_compressed {
		// P2SH-P2WPKH redeem script: OP_0 <20> <pubkey_hash>
		redeem: [22]u8
		redeem[0] = 0x00 // OP_0
		redeem[1] = 0x14 // push 20
		copy(redeem[2:], pub_hash[:])
		script_hash := crypto.hash160(redeem[:])
		p2sh_addr := crypto.base58check_encode(p.p2sh_prefix, script_hash[:])
		if p2sh_addr == address {
			return _make_result(json.Value(json.Boolean(true)), srv._current_id)
		}

		// Try matching as bech32 P2WPKH
		bech32_addr := crypto.bech32_encode(p.bech32_hrp, 0, pub_hash[:])
		if bech32_addr == address {
			return _make_result(json.Value(json.Boolean(true)), srv._current_id)
		}
	}

	return _make_result(json.Value(json.Boolean(false)), srv._current_id)
}

// Dashboard status snapshot — everything the GUI renders, for remote
// dashboards. Mirrors p2p.Node_Status plus the node's static config.
_handle_getnodestatus :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.cm == nil {
		return _make_error(.Internal_Error, "P2P not running", srv._current_id)
	}
	st := p2p.conn_manager_get_status(srv.cm)

	obj := make(json.Object, 40, context.temp_allocator)
	obj["network"] = json.Value(json.String(srv.params.name))
	obj["data_dir"] = json.Value(json.String(srv.data_dir))
	obj["prune_mb"] = json.Value(json.Integer(i64(srv.chain.prune_target / 1_048_576)))
	obj["dbcache_mb"] = json.Value(json.Integer(i64(srv.chain.coins.budget / 1_048_576)))

	obj["chain_height"] = json.Value(json.Integer(i64(st.chain_height)))
	obj["best_header"] = json.Value(json.Integer(i64(st.best_header)))
	obj["sync_state"] = json.Value(json.Integer(i64(st.sync_state)))
	// Validation-halt banner data — without these the remote dashboard
	// (forseti-gui) can never show the red HALTED banner.
	obj["halt_height"] = json.Value(json.Integer(i64(st.halt_height)))
	obj["halt_reason"] = json.Value(json.String(string(st.halt_reason[:st.halt_reason_len])))
	obj["blocks_remaining"] = json.Value(json.Integer(i64(st.blocks_remaining)))
	obj["blocks_in_flight"] = json.Value(json.Integer(i64(st.blocks_in_flight)))
	obj["verification_pct"] = json.Value(json.Float(st.verification_pct))
	obj["eta_secs"] = json.Value(json.Integer(st.eta_secs))
	obj["blocks_per_sec"] = json.Value(json.Float(st.blocks_per_sec))
	obj["mempool_count"] = json.Value(json.Integer(i64(st.mempool_count)))
	obj["mempool_vbytes"] = json.Value(json.Integer(i64(st.mempool_vbytes)))
	obj["utxo_cache_count"] = json.Value(json.Integer(i64(st.utxo_cache_count)))
	obj["utxo_cache_bytes"] = json.Value(json.Integer(i64(st.utxo_cache_bytes)))
	obj["utxo_cache_budget"] = json.Value(json.Integer(i64(st.utxo_cache_budget)))
	obj["prof_blocks"] = json.Value(json.Integer(i64(st.prof_blocks)))
	obj["prof_ms_per_block"] = json.Value(json.Float(st.prof_ms_per_block))
	obj["prof_read_pct"] = json.Value(json.Float(st.prof_read_pct))
	obj["prof_prefetch_pct"] = json.Value(json.Float(st.prof_prefetch_pct))
	obj["prof_valid_pct"] = json.Value(json.Float(st.prof_valid_pct))
	obj["prof_utxo_pct"] = json.Value(json.Float(st.prof_utxo_pct))
	obj["prof_scripts_pct"] = json.Value(json.Float(st.prof_scripts_pct))
	obj["prof_undo_pct"] = json.Value(json.Float(st.prof_undo_pct))
	obj["uptime_secs"] = json.Value(json.Integer(st.uptime_secs))
	obj["disk_usage"] = json.Value(json.Integer(st.disk_usage))
	obj["total_bytes_sent"] = json.Value(json.Integer(st.total_bytes_sent))
	obj["total_bytes_recv"] = json.Value(json.Integer(st.total_bytes_recv))
	obj["flushing"] = json.Value(json.Boolean(st.flushing))
	obj["flush_total"] = json.Value(json.Integer(i64(st.flush_total)))
	obj["flush_progress"] = json.Value(json.Integer(i64(st.flush_progress)))

	peers := make(json.Array, 0, st.peer_count, context.temp_allocator)
	for i in 0 ..< st.peer_count {
		ps := &st.peers[i]
		po := make(json.Object, 12, context.temp_allocator)
		po["id"] = json.Value(json.Integer(i64(ps.id)))
		po["address"] = json.Value(json.String(string(ps.address[:ps.addr_len])))
		po["agent"] = json.Value(json.String(string(ps.user_agent[:ps.agent_len])))
		po["inbound"] = json.Value(json.Boolean(ps.inbound))
		po["start_height"] = json.Value(json.Integer(i64(ps.start_height)))
		po["bytes_sent"] = json.Value(json.Integer(ps.bytes_sent))
		po["bytes_recv"] = json.Value(json.Integer(ps.bytes_recv))
		po["blocks_delivered"] = json.Value(json.Integer(i64(ps.blocks_delivered)))
		po["blocks_in_flight"] = json.Value(json.Integer(i64(ps.blocks_in_flight)))
		po["throughput"] = json.Value(json.Float(ps.throughput))
		po["last_recv_secs"] = json.Value(json.Integer(ps.last_recv_secs))
		append(&peers, json.Value(po))
	}
	obj["peers"] = json.Value(peers)

	return _make_result(json.Value(obj), srv._current_id)
}

// --- createmultisig ---

_handle_createmultisig :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	nreq_i, nreq_ok := _get_int_param(params, 0)
	if !nreq_ok || nreq_i < 1 || nreq_i > 16 {
		return _make_error(.Invalid_Params, "nrequired must be 1-16", srv._current_id)
	}
	keys_val, keys_ok := _get_param(params, 1)
	keys_arr, is_arr := keys_val.(json.Array)
	if !keys_ok || !is_arr || len(keys_arr) < nreq_i || len(keys_arr) > 16 {
		return _make_error(.Invalid_Params, "keys must be an array of nrequired..16 public keys", srv._current_id)
	}
	addr_type := "legacy"
	if at, at_ok := _get_string_param(params, 2); at_ok {
		addr_type = at
	}

	// Build OP_n <pubkeys...> OP_m OP_CHECKMULTISIG. OP_1 = 0x51.
	redeem := make([dynamic]byte, 0, 8 + len(keys_arr) * 34, context.temp_allocator)
	append(&redeem, byte(0x50 + nreq_i))
	for kv in keys_arr {
		key_hex, is_str := kv.(json.String)
		if !is_str {
			return _make_error(.Invalid_Params, "key must be a hex string", srv._current_id)
		}
		key_bytes, hex_ok := _hex_decode(key_hex)
		if !hex_ok || (len(key_bytes) != 33 && len(key_bytes) != 65) {
			return _make_error(.Invalid_Params, "keys must be 33- or 65-byte hex public keys", srv._current_id)
		}
		append(&redeem, byte(len(key_bytes)))
		append(&redeem, ..key_bytes)
	}
	append(&redeem, byte(0x50 + len(keys_arr)))
	append(&redeem, byte(0xae)) // OP_CHECKMULTISIG
	if len(redeem) > 520 && addr_type == "legacy" {
		return _make_error(.Invalid_Params, "redeemScript exceeds 520-byte P2SH limit (use bech32)", srv._current_id)
	}

	address: string
	switch addr_type {
	case "legacy":
		h160 := crypto.hash160(redeem[:])
		address = crypto.base58check_encode(srv.params.p2sh_prefix, h160[:])
	case "bech32":
		wsh := crypto.sha256_hash(redeem[:])
		address = crypto.bech32_encode(srv.params.bech32_hrp, 0, wsh[:])
	case "p2sh-segwit":
		wsh := crypto.sha256_hash(redeem[:])
		wsh_script := make([dynamic]byte, 0, 34, context.temp_allocator)
		append(&wsh_script, 0x00, 0x20)
		append(&wsh_script, ..wsh[:])
		h160 := crypto.hash160(wsh_script[:])
		address = crypto.base58check_encode(srv.params.p2sh_prefix, h160[:])
	case:
		return _make_error(.Invalid_Params, "address_type must be legacy, p2sh-segwit, or bech32", srv._current_id)
	}

	obj := make(json.Object, 2, context.temp_allocator)
	obj["address"] = json.Value(json.String(address))
	obj["redeemScript"] = json.Value(json.String(_bytes_to_hex(redeem[:])))
	return _make_result(json.Value(obj), srv._current_id)
}

// --- getindexinfo ---

_handle_getindexinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, 1, context.temp_allocator)
	if srv.chain.filter_db != nil {
		_, tip_height := chain.chain_tip(srv.chain)
		fi := make(json.Object, 3, context.temp_allocator)
		fi["synced"] = json.Value(json.Boolean(true))
		fi["best_block_height"] = json.Value(json.Integer(tip_height))
		obj["basic block filter index"] = json.Value(fi)
	}
	if srv.chain.tx_index != nil {
		ti := make(json.Object, 2, context.temp_allocator)
		_, best_height, has_best := storage.tx_index_best(srv.chain.tx_index)
		_, tip_height := chain.chain_tip(srv.chain)
		ti["synced"] = json.Value(json.Boolean(has_best && best_height >= tip_height))
		ti["best_block_height"] = json.Value(json.Integer(i64(best_height)))
		obj["txindex"] = json.Value(ti)
	}
	return _make_result(json.Value(obj), srv._current_id)
}

// --- node-control RPCs (routed through the P2P control queue) ---

_require_cm :: proc(srv: ^RPC_Server) -> (^p2p.Conn_Manager, bool) {
	return srv.cm, srv.cm != nil
}

_handle_pruneblockchain :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.chain.prune_target <= 0 {
		return _make_error(.Internal_Error, "Cannot prune: node is not in prune mode (--prune)", srv._current_id)
	}
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	done: sync.Sema
	result: i64
	p2p.conn_manager_control(cm, p2p.Control_Request{action = .Prune_Now, done = &done, result = &result})
	if !sync.sema_wait_with_timeout(&done, 30 * time.Second) {
		return _make_error(.Internal_Error, "Prune timed out", srv._current_id)
	}
	return _make_result(json.Value(json.Integer(result)), srv._current_id)
}

_handle_preciousblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hash_hex, ok := _get_string_param(params, 0)
	hash, hash_ok := _hex_to_hash(hash_hex)
	if !ok || !hash_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}
	if _, found := srv.chain.block_index.entries[hash]; !found {
		return _make_error(.Block_Not_Found, "Block not found", srv._current_id)
	}
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	p2p.conn_manager_control(cm, p2p.Control_Request{action = .Precious_Block, hash = hash})
	return _make_result(json.Value(nil), srv._current_id)
}

_split_host_port :: proc(node: string, default_port: int) -> (host: string, port: int) {
	port = default_port
	host = node
	if colon := strings.last_index_byte(node, ':'); colon > 0 {
		if p, p_ok := strconv.parse_int(node[colon + 1:]); p_ok {
			host = node[:colon]
			port = p
		}
	}
	return
}

_handle_addnode :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	node, node_ok := _get_string_param(params, 0)
	command, cmd_ok := _get_string_param(params, 1)
	if !node_ok || !cmd_ok {
		return _make_error(.Invalid_Params, "Usage: addnode \"ip:port\" \"add|remove|onetry\"", srv._current_id)
	}
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	host, port := _split_host_port(node, cm.default_port)

	switch command {
	case "onetry", "add":
		if command == "add" {
			sync.mutex_lock(&cm.added_mutex)
			exists := false
			for a in cm.added_nodes {
				if a == node {
					exists = true
					break
				}
			}
			if !exists {
				append(&cm.added_nodes, strings.clone(node))
			}
			sync.mutex_unlock(&cm.added_mutex)
		}
		p2p.conn_manager_control(cm, p2p.Control_Request{action = .Connect_Once, address = strings.clone(host), port = port})
	case "remove":
		sync.mutex_lock(&cm.added_mutex)
		for a, i in cm.added_nodes {
			if a == node {
				delete(a)
				ordered_remove(&cm.added_nodes, i)
				break
			}
		}
		sync.mutex_unlock(&cm.added_mutex)
	case:
		return _make_error(.Invalid_Params, "command must be add, remove, or onetry", srv._current_id)
	}
	return _make_result(json.Value(nil), srv._current_id)
}

_handle_getaddednodeinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	sync.mutex_lock(&cm.added_mutex)
	arr := make(json.Array, len(cm.added_nodes), context.temp_allocator)
	for node, i in cm.added_nodes {
		host, _ := _split_host_port(node, cm.default_port)
		connected := false
		for _, peer in cm.peers { // same read-race tolerance as getpeerinfo
			if peer.address == host {
				connected = true
				break
			}
		}
		obj := make(json.Object, 3, context.temp_allocator)
		obj["addednode"] = json.Value(json.String(node))
		obj["connected"] = json.Value(json.Boolean(connected))
		arr[i] = json.Value(obj)
	}
	sync.mutex_unlock(&cm.added_mutex)
	return _make_result(json.Value(arr), srv._current_id)
}

_handle_disconnectnode :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	req := p2p.Control_Request{action = .Disconnect_Peer}
	if addr, addr_ok := _get_string_param(params, 0); addr_ok && addr != "" {
		host, _ := _split_host_port(addr, cm.default_port)
		req.address = strings.clone(host)
	} else if id, id_ok := _get_int_param(params, 1); id_ok {
		req.peer_id = p2p.Peer_Id(id)
	} else {
		return _make_error(.Invalid_Params, "Provide address or nodeid", srv._current_id)
	}
	p2p.conn_manager_control(cm, req)
	return _make_result(json.Value(nil), srv._current_id)
}

_handle_setban :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	subnet, subnet_ok := _get_string_param(params, 0)
	command, cmd_ok := _get_string_param(params, 1)
	if !subnet_ok || !cmd_ok {
		return _make_error(.Invalid_Params, "Usage: setban \"ip\" \"add|remove\" [bantime]", srv._current_id)
	}
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	// Address-level bans only; accept and strip a /32 suffix.
	addr := strings.trim_suffix(subnet, "/32")

	switch command {
	case "add":
		bantime := i64(0)
		if bt, bt_ok := _get_int_param(params, 2); bt_ok {
			bantime = i64(bt)
		}
		if bantime == 0 {
			bantime = 24 * 60 * 60 // Core default: 24h
		}
		until := time.to_unix_seconds(time.now()) + bantime
		p2p.conn_manager_set_ban(cm, addr, until)
		// Also disconnect if currently connected.
		p2p.conn_manager_control(cm, p2p.Control_Request{action = .Disconnect_Peer, address = strings.clone(addr)})
	case "remove":
		if !p2p.conn_manager_remove_ban(cm, addr) {
			return _make_error(.Invalid_Params, "Address not banned", srv._current_id)
		}
	case:
		return _make_error(.Invalid_Params, "command must be add or remove", srv._current_id)
	}
	return _make_result(json.Value(nil), srv._current_id)
}

_handle_listbanned :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	sync.mutex_lock(&cm.ban_mutex)
	arr := make(json.Array, 0, context.temp_allocator)
	now := time.to_unix_seconds(time.now())
	for addr, until in cm.banned {
		if until <= now {
			continue
		}
		obj := make(json.Object, 3, context.temp_allocator)
		obj["address"] = json.Value(json.String(addr))
		obj["banned_until"] = json.Value(json.Integer(until))
		obj["ban_created"] = json.Value(json.Integer(0))
		append(&arr, json.Value(obj))
	}
	sync.mutex_unlock(&cm.ban_mutex)
	return _make_result(json.Value(arr), srv._current_id)
}

_handle_clearbanned :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	p2p.conn_manager_clear_bans(cm)
	return _make_result(json.Value(nil), srv._current_id)
}

_handle_setnetworkactive :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	state_val, ok := _get_param(params, 0)
	state, is_bool := state_val.(json.Boolean)
	if !ok || !is_bool {
		return _make_error(.Invalid_Params, "Usage: setnetworkactive true|false", srv._current_id)
	}
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	p2p.conn_manager_control(cm, p2p.Control_Request{action = .Set_Network_Active, active = bool(state)})
	return _make_result(json.Value(json.Boolean(state)), srv._current_id)
}

_handle_getnodeaddresses :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	count := 1
	if c, c_ok := _get_int_param(params, 0); c_ok {
		count = c
	}
	if count == 0 {
		count = 2500 // Core: 0 = all (capped)
	}
	kas := p2p.addr_manager_get_random(&cm.addr_mgr, count, context.temp_allocator)
	arr := make(json.Array, 0, context.temp_allocator)
	for ka in kas {
		if ka.net != .IPv4 || len(ka.addr) != 4 {
			continue // v1: report IPv4 only
		}
		obj := make(json.Object, 5, context.temp_allocator)
		obj["time"] = json.Value(json.Integer(i64(ka.timestamp)))
		obj["services"] = json.Value(json.Integer(i64(ka.services)))
		obj["address"] = json.Value(json.String(fmt.tprintf("%d.%d.%d.%d", ka.addr[0], ka.addr[1], ka.addr[2], ka.addr[3])))
		obj["port"] = json.Value(json.Integer(int(ka.port)))
		obj["network"] = json.Value(json.String("ipv4"))
		append(&arr, json.Value(obj))
	}
	return _make_result(json.Value(arr), srv._current_id)
}

// --- generatetoaddress / generateblock (regtest) ---

// Serializes concurrent generate calls (threaded RPC server); when P2P is
// active, generation still runs here but the chain mutations race the P2P
// thread — restrict to regtest where that's the accepted testing tradeoff
// (Core regtest miners share the same caveat spirit; use --no-p2p for
// deterministic harnesses).
_generate_mutex: sync.Mutex

_handle_generatetoaddress :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.params.name != "regtest" {
		return _make_error(.Internal_Error, "generatetoaddress is regtest-only", srv._current_id)
	}
	nblocks, n_ok := _get_int_param(params, 0)
	addr, addr_ok := _get_string_param(params, 1)
	if !n_ok || nblocks < 1 || nblocks > 10_000 || !addr_ok {
		return _make_error(.Invalid_Params, "Usage: generatetoaddress nblocks \"address\" [maxtries]", srv._current_id)
	}
	max_tries := 1_000_000
	if mt, mt_ok := _get_int_param(params, 2); mt_ok {
		max_tries = mt
	}
	spk, spk_ok := _address_to_script_pubkey(addr, srv.params)
	if !spk_ok {
		return _make_error(.Invalid_Params, "Invalid address", srv._current_id)
	}
	return _generate_blocks(srv, nblocks, spk, max_tries)
}

// Shared mining loop for generatetoaddress/generatetodescriptor.
_generate_blocks :: proc(srv: ^RPC_Server, nblocks: int, spk: []byte, max_tries: int) -> RPC_Response {
	sync.mutex_lock(&_generate_mutex)
	defer sync.mutex_unlock(&_generate_mutex)

	hashes := make(json.Array, 0, context.temp_allocator)
	for _ in 0 ..< nblocks {
		// Feerate-ordered selection with in-mempool parents (same as GBT).
		selected, _, total_fees := _select_template_txs(srv)

		hash, merr := chain.mine_block(srv.chain, selected[:], total_fees, spk, max_tries)
		if merr != .None {
			return _make_error(.Internal_Error, fmt.tprintf("mining failed: %v", merr), srv._current_id)
		}
		if srv.mp != nil {
			// Remove mined txs the same way a network block would.
			for sel in selected {
				mempool.mempool_remove(srv.mp, sel.txid)
			}
		}
		append(&hashes, json.Value(json.String(_hash_to_hex(hash))))
	}
	return _make_result(json.Value(hashes), srv._current_id)
}

_handle_generatetodescriptor :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.params.name != "regtest" {
		return _make_error(.Internal_Error, "generatetodescriptor is regtest-only", srv._current_id)
	}
	nblocks, n_ok := _get_int_param(params, 0)
	desc_str, d_ok := _get_string_param(params, 1)
	if !n_ok || nblocks < 1 || nblocks > 10_000 || !d_ok {
		return _make_error(.Invalid_Params, "Usage: generatetodescriptor nblocks \"descriptor\" [maxtries]", srv._current_id)
	}
	max_tries := 1_000_000
	if mt, mt_ok := _get_int_param(params, 2); mt_ok {
		max_tries = mt
	}
	d, derr := descriptor.parse(desc_str, _desc_net(srv), context.temp_allocator)
	if derr != "" {
		return _make_error(.Invalid_Params, derr, srv._current_id)
	}
	if d.is_range {
		return _make_error(.Invalid_Params, "Ranged descriptor not accepted. Maybe pass through deriveaddresses first.", srv._current_id)
	}
	spk, spk_ok := descriptor.script_pubkey(&d, 0, context.temp_allocator)
	if !spk_ok {
		return _make_error(.Invalid_Params, "Cannot derive script from descriptor", srv._current_id)
	}
	return _generate_blocks(srv, nblocks, spk, max_tries)
}

// --- drivechain (BIP300/301) ---

_dc_check_enabled :: proc(srv: ^RPC_Server) -> (RPC_Response, bool) {
	if srv.chain.dc_mode == .Off {
		return _make_error(.Misc_Error, "Drivechain support is disabled (start with --drivechain=track or enforce)", srv._current_id), false
	}
	return {}, true
}

_dc_sidechain_to_json :: proc(srv: ^RPC_Server, n: int) -> json.Object {
	s := &srv.chain.dc_state.slots[n]
	obj := make(json.Object, 10, context.temp_allocator)
	obj["nsidechain"] = json.Value(json.Integer(i64(n)))
	obj["title"] = json.Value(json.String(s.title))
	obj["description"] = json.Value(json.String(s.description))
	obj["version"] = json.Value(json.Integer(i64(s.version)))
	obj["hashid1"] = json.Value(json.String(_hash_to_hex(s.hash_id_1)))
	obj["hashid2"] = json.Value(json.String(_bytes_to_hex(s.hash_id_2[:])))
	obj["activationheight"] = json.Value(json.Integer(i64(s.activated_h)))
	if s.ctip_txid != {} {
		ctip := make(json.Object, 3, context.temp_allocator)
		ctip["txid"] = json.Value(json.String(_hash_to_hex(s.ctip_txid)))
		ctip["vout"] = json.Value(json.Integer(i64(s.ctip_vout)))
		ctip["amount"] = json.Value(json.Float(_satoshi_to_btc(s.ctip_amount)))
		obj["ctip"] = json.Value(ctip)
	}
	return obj
}

// listsidechains: active sidechain slots (D1) plus pending M1 proposals.
_handle_listsidechains :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if resp, enabled := _dc_check_enabled(srv); !enabled {
		return resp
	}
	st := &srv.chain.dc_state

	active := make(json.Array, 0, context.temp_allocator)
	for n in 0 ..< len(st.slots) {
		if !st.slots[n].active { continue }
		append(&active, json.Value(_dc_sidechain_to_json(srv, n)))
	}

	proposals := make(json.Array, 0, context.temp_allocator)
	for &p in st.proposals {
		obj := make(json.Object, 7, context.temp_allocator)
		obj["nsidechain"] = json.Value(json.Integer(i64(p.sidechain)))
		obj["title"] = json.Value(json.String(p.title))
		obj["description"] = json.Value(json.String(p.description))
		obj["version"] = json.Value(json.Integer(i64(p.version)))
		obj["proposalhash"] = json.Value(json.String(_hash_to_hex(p.commitment)))
		obj["age"] = json.Value(json.Integer(i64(p.age)))
		obj["fails"] = json.Value(json.Integer(i64(p.fails)))
		obj["overwriting"] = json.Value(json.Boolean(p.overwriting))
		append(&proposals, json.Value(obj))
	}

	result := make(json.Object, 2, context.temp_allocator)
	result["sidechains"] = json.Value(active)
	result["proposals"] = json.Value(proposals)
	return _make_result(json.Value(result), srv._current_id)
}

// getsidechaininfo <nsidechain>: one active slot from D1.
_handle_getsidechaininfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if resp, enabled := _dc_check_enabled(srv); !enabled {
		return resp
	}
	n, ok := _get_int_param(params, 0)
	if !ok || n < 0 || n > 255 {
		return _make_error(.Invalid_Params, "Missing or invalid nsidechain parameter (0-255)", srv._current_id)
	}
	if !srv.chain.dc_state.slots[n].active {
		return _make_error(.Misc_Error, fmt.tprintf("Sidechain %d is not active", n), srv._current_id)
	}
	return _make_result(json.Value(_dc_sidechain_to_json(srv, n)), srv._current_id)
}

// listwithdrawalstatus ( nsidechain ): withdrawal bundles (D2), optionally
// filtered to one sidechain.
_handle_listwithdrawalstatus :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if resp, enabled := _dc_check_enabled(srv); !enabled {
		return resp
	}
	filter := -1
	if n, ok := _get_int_param(params, 0); ok {
		if n < 0 || n > 255 {
			return _make_error(.Invalid_Params, "Invalid nsidechain parameter (0-255)", srv._current_id)
		}
		filter = n
	}

	bundles := make(json.Array, 0, context.temp_allocator)
	for &b in srv.chain.dc_state.bundles {
		if filter >= 0 && int(b.sidechain) != filter { continue }
		obj := make(json.Object, 5, context.temp_allocator)
		obj["nsidechain"] = json.Value(json.Integer(i64(b.sidechain)))
		obj["hash"] = json.Value(json.String(_hash_to_hex(b.hash)))
		obj["nblocksleft"] = json.Value(json.Integer(i64(b.remaining)))
		obj["nworkscore"] = json.Value(json.Integer(i64(b.acks)))
		obj["approved"] = json.Value(json.Boolean(b.approved))
		append(&bundles, json.Value(obj))
	}
	return _make_result(json.Value(bundles), srv._current_id)
}

// --- mining interface (getblocktemplate / submitblock / submitheader /
//     prioritisetransaction / generateblock) ---

// Feerate-ordered greedy selection with in-mempool parent dependencies:
// a tx is eligible once every input is confirmed or spends an already-
// selected tx. Repeated passes over the feerate-sorted list until no
// progress (CPFP chains land parent-first in feerate order; true package
// selection is future work). Weight-capped at 4M minus a coinbase reserve.
_select_template_txs :: proc(srv: ^RPC_Server) -> (selected: [dynamic]chain.Mine_Tx, entries: [dynamic]^mempool.Mempool_Entry, total_fees: i64) {
	selected = make([dynamic]chain.Mine_Tx, 0, 256, context.temp_allocator)
	entries = make([dynamic]^mempool.Mempool_Entry, 0, 256, context.temp_allocator)
	if srv.mp == nil {
		return
	}

	sorted := make([dynamic]^mempool.Mempool_Entry, 0, len(srv.mp.entries), context.temp_allocator)
	for _, e in srv.mp.entries {
		append(&sorted, e)
	}
	// Sort by effective feerate (fee + prioritisation delta) descending.
	for i in 1 ..< len(sorted) {
		j := i
		for j > 0 {
			a, b := sorted[j], sorted[j - 1]
			fa := mempool.mempool_selection_fee(srv.mp, a)
			fb := mempool.mempool_selection_fee(srv.mp, b)
			if fa * i64(b.vsize) <= fb * i64(a.vsize) { break }
			sorted[j], sorted[j - 1] = sorted[j - 1], sorted[j]
			j -= 1
		}
	}

	MAX_TEMPLATE_WEIGHT :: 4_000_000 - 4000 // coinbase reserve
	weight := 0
	in_template := make(map[Hash256]bool, len(sorted), context.temp_allocator)

	for {
		progressed := false
		for e in sorted {
			if e.txid in in_template { continue }
			if weight + e.vsize * 4 > MAX_TEMPLATE_WEIGHT { continue }
			eligible := true
			for inp in e.tx.inputs {
				parent := inp.previous_output.hash
				if mempool.mempool_has(srv.mp, parent) && !(parent in in_template) {
					eligible = false
					break
				}
			}
			if !eligible { continue }
			in_template[e.txid] = true
			append(&selected, chain.Mine_Tx{tx = e.tx, txid = e.txid, wtxid = e.wtxid})
			append(&entries, e)
			total_fees += e.fee // real fees fund the coinbase, deltas only order
			weight += e.vsize * 4
			progressed = true
		}
		if !progressed { break }
	}
	return
}

_is_initial_block_download :: proc(srv: ^RPC_Server) -> bool {
	height := chain.chain_height(srv.chain)
	header_height := chain.chain_header_height(srv.chain)
	return header_height - height > 24
}

_handle_getblocktemplate :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// Template request object (optional): {"rules":["segwit",...], "mode":"template"}
	if obj, is_obj := params.(json.Array); is_obj && len(obj) > 0 {
		if req, req_ok := obj[0].(json.Object); req_ok {
			if mode, has_mode := req["mode"]; has_mode {
				if ms, _ := mode.(json.String); ms == "proposal" {
					return _gbt_proposal(srv, req)
				}
			}
			// Core requires clients to signal the segwit rule.
			has_segwit := false
			if rules, has_rules := req["rules"]; has_rules {
				if arr, arr_ok := rules.(json.Array); arr_ok {
					for r in arr {
						if rs, _ := r.(json.String); rs == "segwit" { has_segwit = true }
					}
				}
			}
			if !has_segwit {
				return _make_error(.Invalid_Params, "getblocktemplate must be called with the segwit rule set", srv._current_id)
			}
		}
	}

	if srv.params.name != "regtest" && _is_initial_block_download(srv) {
		return _make_error(.Internal_Error, "Bitcoin is downloading blocks...", srv._current_id)
	}

	tip_hash, tip_height := chain.chain_tip(srv.chain)
	tip_entry, tip_found := srv.chain.block_index.entries[tip_hash]
	if !tip_found {
		return _make_error(.Internal_Error, "Chain tip not found", srv._current_id)
	}
	height := tip_height + 1

	selected, entries, total_fees := _select_template_txs(srv)

	// Witness commitment for the template's tx set.
	wtxids := make([]crypto.Hash256, len(selected) + 1, context.temp_allocator)
	for s, i in selected {
		wtxids[i + 1] = s.wtxid
	}
	witness_root := crypto.merkle_root(wtxids)
	commit_preimage: [64]byte
	copy(commit_preimage[:32], witness_root[:])
	commitment := crypto.sha256d(commit_preimage[:]) // reserved value = 32 zero bytes
	commit_spk: [38]byte
	commit_spk[0] = 0x6a; commit_spk[1] = 0x24
	commit_spk[2] = 0xaa; commit_spk[3] = 0x21; commit_spk[4] = 0xa9; commit_spk[5] = 0xed
	copy(commit_spk[6:], commitment[:])

	// Transactions array with 1-based depends indices.
	index_of := make(map[Hash256]int, len(selected), context.temp_allocator)
	for s, i in selected {
		index_of[s.txid] = i + 1
	}
	txs_json := make(json.Array, 0, context.temp_allocator)
	for s, i in selected {
		e := entries[i]
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &e.tx)
		raw := wire.writer_bytes(&w)

		depends := make(json.Array, 0, context.temp_allocator)
		seen_dep := make(map[int]bool, 4, context.temp_allocator)
		for inp in e.tx.inputs {
			if idx, dep := index_of[inp.previous_output.hash]; dep && !seen_dep[idx] {
				seen_dep[idx] = true
				append(&depends, json.Value(json.Integer(i64(idx))))
			}
		}

		t := make(json.Object, 7, context.temp_allocator)
		t["data"] = json.Value(json.String(_bytes_to_hex(raw)))
		t["txid"] = json.Value(json.String(_hash_to_hex(s.txid)))
		t["hash"] = json.Value(json.String(_hash_to_hex(s.wtxid)))
		t["depends"] = json.Value(depends)
		t["fee"] = json.Value(json.Integer(e.fee))
		t["sigops"] = json.Value(json.Integer(0)) // not tracked per-tx (documented)
		t["weight"] = json.Value(json.Integer(i64(e.vsize * 4)))
		append(&txs_json, json.Value(t))
	}

	now := u32(time.to_unix_seconds(time.now()))
	mtp := chain.get_median_time_past(tip_entry)
	cur_time := max(now, mtp + 1)
	bits := chain.get_next_work_required(srv.chain, tip_entry, cur_time)
	target := consensus.bits_to_target(bits)

	rules := make(json.Array, 0, context.temp_allocator)
	for r in ([]string{"csv", "segwit", "taproot"}) {
		append(&rules, json.Value(json.String(r)))
	}
	mutable := make(json.Array, 0, context.temp_allocator)
	for m in ([]string{"time", "transactions", "prevblock"}) {
		append(&mutable, json.Value(json.String(m)))
	}

	obj := make(json.Object, 20, context.temp_allocator)
	obj["capabilities"] = json.Value(make(json.Array, 0, context.temp_allocator))
	obj["version"] = json.Value(json.Integer(0x20000000))
	obj["rules"] = json.Value(rules)
	obj["vbavailable"] = json.Value(make(json.Object, 0, context.temp_allocator))
	obj["vbrequired"] = json.Value(json.Integer(0))
	obj["previousblockhash"] = json.Value(json.String(_hash_to_hex(tip_hash)))
	obj["transactions"] = json.Value(txs_json)
	obj["coinbaseaux"] = json.Value(make(json.Object, 0, context.temp_allocator))
	obj["coinbasevalue"] = json.Value(json.Integer(consensus.get_block_subsidy(height, srv.params) + total_fees))
	obj["longpollid"] = json.Value(json.String(fmt.tprintf("%s%d", _hash_to_hex(tip_hash), len(selected))))
	obj["target"] = json.Value(json.String(_bytes_to_hex(target[:])))
	obj["mintime"] = json.Value(json.Integer(i64(mtp + 1)))
	obj["mutable"] = json.Value(mutable)
	obj["noncerange"] = json.Value(json.String("00000000ffffffff"))
	obj["sigoplimit"] = json.Value(json.Integer(80_000))
	obj["sizelimit"] = json.Value(json.Integer(4_000_000))
	obj["weightlimit"] = json.Value(json.Integer(4_000_000))
	obj["curtime"] = json.Value(json.Integer(i64(cur_time)))
	obj["bits"] = json.Value(json.String(fmt.tprintf("%08x", bits)))
	obj["height"] = json.Value(json.Integer(i64(height)))
	obj["default_witness_commitment"] = json.Value(json.String(_bytes_to_hex(commit_spk[:])))
	return _make_result(json.Value(obj), srv._current_id)
}

// getblocktemplate mode=proposal: context-free validation of a proposed
// block without connecting it. Returns null when acceptable.
_gbt_proposal :: proc(srv: ^RPC_Server, req: json.Object) -> RPC_Response {
	data, has_data := req["data"]
	ds, ds_ok := data.(json.String)
	if !has_data || !ds_ok {
		return _make_error(.Invalid_Params, "proposal mode requires data", srv._current_id)
	}
	raw, hex_ok := _hex_decode(string(ds))
	if !hex_ok {
		return _make_error(.Tx_Deser_Error, "Block decode failed", srv._current_id)
	}
	r := wire.reader_init(raw)
	block, derr := wire.deserialize_block(&r, context.temp_allocator)
	if derr != nil {
		return _make_error(.Tx_Deser_Error, "Block decode failed", srv._current_id)
	}
	tip_hash, tip_height := chain.chain_tip(srv.chain)
	if block.header.prev_hash != tip_hash {
		return _make_result(json.Value(json.String("inconclusive-not-best-prevblk")), srv._current_id)
	}
	if cerr := consensus.check_block(&block, tip_height + 1, srv.params, nil); cerr != .None {
		return _make_result(json.Value(json.String(fmt.tprintf("rejected: %v", cerr))), srv._current_id)
	}
	return _make_result(json.Value(json.Null(nil)), srv._current_id)
}

// Route a block/header to the P2P thread (chain single-writer) and wait.
// Falls back to a direct call when P2P is disabled (--no-p2p: the RPC
// thread is the only chain mutator).
_submit_via_control :: proc(srv: ^RPC_Server, block: ^wire.Block, action: p2p.Control_Action) -> i64 {
	if srv.cm == nil {
		#partial switch action {
		case .Submit_Block:
			hash := wire.block_header_hash(&block.header)
			if entry, known := srv.chain.block_index.entries[hash]; known && .Valid_Chain in entry.status {
				return p2p.SUBMIT_DUPLICATE
			}
			aerr := chain.accept_block(srv.chain, block)
			if aerr == .Block_Already_Known { return p2p.SUBMIT_DUPLICATE }
			if aerr != .None { return -i64(aerr) }
			if srv.mp != nil {
				mempool.mempool_remove_for_block(srv.mp, block)
				mempool.mempool_update_tip(srv.mp)
			}
			return p2p.SUBMIT_OK
		case .Submit_Header:
			hash := wire.block_header_hash(&block.header)
			if _, known := srv.chain.block_index.entries[hash]; known {
				return p2p.SUBMIT_DUPLICATE
			}
			if _, aerr := chain.accept_block_header(srv.chain, &block.header); aerr != .None {
				return -i64(aerr)
			}
			return p2p.SUBMIT_OK
		case .Disconnect_Peer, .Connect_Once, .Set_Network_Active, .Precious_Block, .Prune_Now:
			return -1
		}
		return -1
	}
	done: sync.Sema
	result: i64
	p2p.conn_manager_control(srv.cm, p2p.Control_Request{
		action = action,
		block  = block,
		done   = &done,
		result = &result,
	})
	sync.sema_wait(&done)
	return result
}

_submit_result_to_response :: proc(srv: ^RPC_Server, res: i64) -> RPC_Response {
	switch {
	case res == p2p.SUBMIT_OK:
		return _make_result(json.Value(json.Null(nil)), srv._current_id)
	case res == p2p.SUBMIT_DUPLICATE:
		return _make_result(json.Value(json.String("duplicate")), srv._current_id)
	case:
		cerr := chain.Chain_Error(-res)
		return _make_result(json.Value(json.String(fmt.tprintf("rejected: %v", cerr))), srv._current_id)
	}
}

_handle_submitblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hex_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing hexdata parameter", srv._current_id)
	}
	raw, hex_ok := _hex_decode(hex_str)
	if !hex_ok {
		return _make_error(.Tx_Deser_Error, "Block decode failed", srv._current_id)
	}
	r := wire.reader_init(raw)
	block, derr := wire.deserialize_block(&r, context.temp_allocator)
	if derr != nil || len(block.txs) == 0 {
		return _make_error(.Tx_Deser_Error, "Block decode failed", srv._current_id)
	}
	if !consensus.is_coinbase_tx(&block.txs[0]) {
		return _make_error(.Tx_Deser_Error, "Block does not start with a coinbase", srv._current_id)
	}
	res := _submit_via_control(srv, &block, .Submit_Block)
	return _submit_result_to_response(srv, res)
}

_handle_submitheader :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hex_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing hexdata parameter", srv._current_id)
	}
	raw, hex_ok := _hex_decode(hex_str)
	if !hex_ok || len(raw) != 80 {
		return _make_error(.Tx_Deser_Error, "Block header decode failed", srv._current_id)
	}
	r := wire.reader_init(raw)
	hdr, derr := wire.deserialize_block_header(&r)
	if derr != nil {
		return _make_error(.Tx_Deser_Error, "Block header decode failed", srv._current_id)
	}
	block := wire.Block{header = hdr}
	res := _submit_via_control(srv, &block, .Submit_Header)
	if res == p2p.SUBMIT_OK || res == p2p.SUBMIT_DUPLICATE {
		return _make_result(json.Value(json.Null(nil)), srv._current_id)
	}
	cerr := chain.Chain_Error(-res)
	if cerr == .Invalid_Prev_Block {
		return _make_error(.Invalid_Params, "Must submit previous header first", srv._current_id)
	}
	return _make_error(.Invalid_Params, fmt.tprintf("Header rejected: %v", cerr), srv._current_id)
}

_handle_prioritisetransaction :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	txid_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing txid parameter", srv._current_id)
	}
	txid, txid_ok := _hex_to_hash(txid_hex)
	if !txid_ok {
		return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
	}
	// Param 1 is the deprecated dummy (priority delta); param 2 is fee delta in sats.
	delta, delta_ok := _get_int_param(params, 2)
	if !delta_ok {
		return _make_error(.Invalid_Params, "Missing fee_delta parameter", srv._current_id)
	}
	if srv.mp == nil {
		return _make_error(.Internal_Error, "Mempool unavailable", srv._current_id)
	}
	mempool.mempool_prioritise(srv.mp, txid, i64(delta))
	return _make_result(json.Value(json.Boolean(true)), srv._current_id)
}

// generateblock (regtest): mine one block containing the given txs — raw
// hex or mempool txids — to an address.
_handle_generateblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.params.name != "regtest" {
		return _make_error(.Internal_Error, "generateblock is regtest-only", srv._current_id)
	}
	addr, addr_ok := _get_string_param(params, 0)
	if !addr_ok {
		return _make_error(.Invalid_Params, "Usage: generateblock \"output\" [\"rawtx/txid\",...]", srv._current_id)
	}
	spk, spk_ok := _address_to_script_pubkey(addr, srv.params)
	if !spk_ok {
		return _make_error(.Invalid_Params, "Invalid address (descriptors not supported)", srv._current_id)
	}

	selected := make([dynamic]chain.Mine_Tx, 0, 16, context.temp_allocator)
	total_fees: i64
	if arr_val, has_arr := _get_array_param(params, 1); has_arr {
		for item in arr_val {
			s, s_ok := item.(json.String)
			if !s_ok {
				return _make_error(.Invalid_Params, "transactions must be hex strings", srv._current_id)
			}
			if len(s) == 64 {
				// txid — must be in the mempool
				txid, h_ok := _hex_to_hash(string(s))
				if !h_ok {
					return _make_error(.Invalid_Params, "Invalid txid", srv._current_id)
				}
				e, found := mempool.mempool_get(srv.mp, txid)
				if !found {
					return _make_error(.Invalid_Params, fmt.tprintf("Transaction %s not in mempool", string(s)), srv._current_id)
				}
				append(&selected, chain.Mine_Tx{tx = e.tx, txid = e.txid, wtxid = e.wtxid})
				total_fees += e.fee
			} else {
				raw, h_ok := _hex_decode(string(s))
				if !h_ok {
					return _make_error(.Tx_Deser_Error, "TX decode failed", srv._current_id)
				}
				r := wire.reader_init(raw)
				tx, derr := wire.deserialize_tx(&r, context.temp_allocator)
				if derr != nil {
					return _make_error(.Tx_Deser_Error, "TX decode failed", srv._current_id)
				}
				append(&selected, chain.Mine_Tx{tx = tx, txid = wire.tx_id(&tx), wtxid = wire.tx_witness_id(&tx)})
				// Raw txs: fee unknown without prevout lookup; contributes 0
				// to the coinbase (undershooting is consensus-safe).
			}
		}
	}

	sync.mutex_lock(&_generate_mutex)
	defer sync.mutex_unlock(&_generate_mutex)

	hash, merr := chain.mine_block(srv.chain, selected[:], total_fees, spk, 1_000_000)
	if merr != .None {
		return _make_error(.Internal_Error, fmt.tprintf("mining failed: %v", merr), srv._current_id)
	}
	for sel in selected {
		mempool.mempool_remove(srv.mp, sel.txid)
	}
	obj := make(json.Object, 1, context.temp_allocator)
	obj["hash"] = json.Value(json.String(_hash_to_hex(hash)))
	return _make_result(json.Value(obj), srv._current_id)
}

// --- verifychain ---
//
// Levels (Core-shaped): 0 = block data reads + deserializes, 1 = context-
// free block validity (PoW, merkle, structure), 2+ = undo data reads and
// parses. Levels 3/4 (disconnect/reconnect simulation) are not implemented;
// requests for them run the level-2 checks.
_handle_verifychain :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	checklevel := 3
	if lvl, ok := _get_int_param(params, 0); ok {
		if lvl < 0 || lvl > 4 {
			return _make_error(.Invalid_Params, "checklevel must be 0-4", srv._current_id)
		}
		checklevel = lvl
	}
	nblocks := 6
	if n, ok := _get_int_param(params, 1); ok {
		nblocks = n
	}

	tip_height := chain.chain_height(srv.chain)
	if nblocks <= 0 || nblocks > tip_height {
		nblocks = tip_height
	}

	ok_result := true
	checked := 0
	for h := tip_height; h > tip_height - nblocks && h > 0; h -= 1 {
		hash := srv.chain.active_chain[h]
		entry, found := srv.chain.block_index.entries[hash]
		if !found {
			ok_result = false
			break
		}
		if .Has_Data not_in entry.status {
			// Pruned below this point — everything checkable was fine.
			log.infof("verifychain: block data pruned below height %d, checked %d block(s)", h, checked)
			break
		}

		loc := storage.Block_Location{
			file_num    = entry.file_num,
			data_offset = entry.data_offset,
			data_size   = entry.data_size,
		}
		raw, rerr := storage.block_db_read_raw(&srv.chain.block_db, loc, context.temp_allocator)
		if rerr != .None {
			ok_result = false
			break
		}
		r := wire.reader_init(raw)
		block, derr := wire.deserialize_block(&r, context.temp_allocator)
		if derr != nil {
			ok_result = false
			break
		}

		if checklevel >= 1 {
			if cerr := consensus.check_block(&block, entry.height, srv.params, nil); cerr != .None {
				log.warnf("verifychain: block %d fails check_block: %v", entry.height, cerr)
				ok_result = false
				break
			}
		}
		if checklevel >= 2 && .Has_Undo in entry.status {
			if _, uerr := chain.read_block_undo(&srv.chain.undo_files, entry, context.temp_allocator); uerr != .None {
				log.warnf("verifychain: block %d undo data unreadable: %v", entry.height, uerr)
				ok_result = false
				break
			}
		}
		checked += 1
		free_all(context.temp_allocator)
	}

	return _make_result(json.Value(json.Boolean(ok_result)), srv._current_id)
}

// --- descriptors: getdescriptorinfo / deriveaddresses / scantxoutset ---

_desc_net :: proc(srv: ^RPC_Server) -> descriptor.Net_Params {
	return descriptor.Net_Params{
		p2pkh_version = srv.params.p2pkh_prefix,
		p2sh_version  = srv.params.p2sh_prefix,
		hrp           = srv.params.bech32_hrp,
	}
}

_handle_getdescriptorinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	desc_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing descriptor parameter", srv._current_id)
	}
	d, derr := descriptor.parse(desc_str, _desc_net(srv), context.temp_allocator)
	if derr != "" {
		return _make_error(.Invalid_Params, derr, srv._current_id)
	}

	canonical := descriptor.to_string_with_checksum(&d)
	sum, _ := descriptor.checksum_create(d.body)
	obj := make(json.Object, 5, context.temp_allocator)
	obj["descriptor"] = json.Value(json.String(canonical))
	obj["checksum"] = json.Value(json.String(sum))
	obj["isrange"] = json.Value(json.Boolean(d.is_range))
	obj["issolvable"] = json.Value(json.Boolean(d.type != .Addr && d.type != .Raw))
	obj["hasprivatekeys"] = json.Value(json.Boolean(false))
	return _make_result(json.Value(obj), srv._current_id)
}

// Parse a range argument: n → [0,n], [begin,end] → as-is.
_parse_range :: proc(v: json.Value) -> (begin: int, end: int, ok: bool) {
	#partial switch r in v {
	case json.Integer:
		if r < 0 { return }
		return 0, int(r), true
	case json.Float:
		if r < 0 { return }
		return 0, int(r), true
	case json.Array:
		if len(r) != 2 { return }
		b, b_ok := r[0].(json.Integer)
		e, e_ok := r[1].(json.Integer)
		if !b_ok || !e_ok || b < 0 || e < b { return }
		return int(b), int(e), true
	}
	return
}

_handle_deriveaddresses :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	desc_str, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing descriptor parameter", srv._current_id)
	}
	net := _desc_net(srv)
	d, derr := descriptor.parse(desc_str, net, context.temp_allocator)
	if derr != "" {
		return _make_error(.Invalid_Params, derr, srv._current_id)
	}

	begin, end := 0, 0
	if range_val, has_range := _get_param(params, 1); has_range {
		if !d.is_range {
			return _make_error(.Invalid_Params, "Range should not be specified for an un-ranged descriptor", srv._current_id)
		}
		b, e, r_ok := _parse_range(range_val)
		if !r_ok || e - b + 1 > 10_000 {
			return _make_error(.Invalid_Params, "Invalid range", srv._current_id)
		}
		begin, end = b, e
	} else if d.is_range {
		return _make_error(.Invalid_Params, "Range must be specified for a ranged descriptor", srv._current_id)
	}

	out := make(json.Array, 0, context.temp_allocator)
	for i in begin ..= end {
		addr, a_ok := descriptor.address(&d, i, net)
		if !a_ok {
			return _make_error(.Invalid_Params, "Descriptor has no address form (raw scripts)", srv._current_id)
		}
		append(&out, json.Value(json.String(addr)))
	}
	return _make_result(json.Value(out), srv._current_id)
}

SCAN_DEFAULT_RANGE :: 1000

_handle_scantxoutset :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	action, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing action parameter", srv._current_id)
	}
	switch action {
	case "status", "abort":
		// Scans here are synchronous — there is never an in-progress scan.
		return _make_result(json.Value(json.Boolean(false)), srv._current_id)
	case "start":
	case:
		return _make_error(.Invalid_Params, "Invalid action", srv._current_id)
	}

	objs, objs_ok := _get_array_param(params, 1)
	if !objs_ok || len(objs) == 0 {
		return _make_error(.Invalid_Params, "scanobjects argument is required", srv._current_id)
	}

	// Expand every scan object into scriptPubKey → descriptor-string.
	net := _desc_net(srv)
	want := make(map[string]string, 64, context.temp_allocator)
	for so in objs {
		desc_str: string
		begin, end := 0, 0
		range_given := false
		#partial switch v in so {
		case json.String:
			desc_str = string(v)
		case json.Object:
			ds, ds_ok := v["desc"].(json.String)
			if !ds_ok {
				return _make_error(.Invalid_Params, "Scan object missing desc", srv._current_id)
			}
			desc_str = string(ds)
			if rv, has_rv := v["range"]; has_rv {
				b, e, r_ok := _parse_range(rv)
				if !r_ok {
					return _make_error(.Invalid_Params, "Invalid range", srv._current_id)
				}
				begin, end = b, e
				range_given = true
			}
		case:
			return _make_error(.Invalid_Params, "Invalid scan object", srv._current_id)
		}

		d, derr := descriptor.parse(desc_str, net, context.temp_allocator)
		if derr != "" {
			return _make_error(.Invalid_Params, fmt.tprintf("%s: %s", desc_str, derr), srv._current_id)
		}
		if d.is_range && !range_given {
			end = SCAN_DEFAULT_RANGE
		}
		if !d.is_range {
			begin, end = 0, 0
		}
		if end - begin + 1 > 100_000 {
			return _make_error(.Invalid_Params, "Range too large", srv._current_id)
		}
		for i in begin ..= end {
			spk, s_ok := descriptor.script_pubkey(&d, i, context.temp_allocator)
			if !s_ok {
				return _make_error(.Invalid_Params, "Cannot derive script", srv._current_id)
			}
			want[string(spk)] = desc_str
		}
	}

	tip_hash, tip_height := chain.chain_tip(srv.chain)
	unspents := make(json.Array, 0, context.temp_allocator)
	total: i64 = 0
	scanned := 0

	add_unspent := proc(unspents: ^json.Array, total: ^i64, op: wire.Outpoint, coin: storage.UTXO_Coin, desc: string) {
		u := make(json.Object, 6, context.temp_allocator)
		u["txid"] = json.Value(json.String(_hash_to_hex(op.hash)))
		u["vout"] = json.Value(json.Integer(i64(op.index)))
		u["scriptPubKey"] = json.Value(json.String(_bytes_to_hex(coin.script)))
		u["desc"] = json.Value(json.String(desc))
		u["amount"] = json.Value(json.Float(_satoshi_to_btc(coin.amount)))
		u["height"] = json.Value(json.Integer(i64(coin.height)))
		append(unspents, json.Value(u))
		total^ += coin.amount
	}

	// 1) Flushed UTXOs from LevelDB, skipping entries the cache has spent.
	{
		cc := &srv.chain.coins
		iter := storage.leveldb_create_iterator(cc.db.store.chainstate_db, cc.db.store.read_opts)
		defer storage.leveldb_iter_destroy(iter)
		storage.leveldb_iter_seek_to_first(iter)
		for storage.leveldb_iter_valid(iter) != 0 {
			defer storage.leveldb_iter_next(iter)
			klen: c.size_t
			kptr := storage.leveldb_iter_key(iter, &klen)
			if klen != 36 { continue }
			scanned += 1
			vlen: c.size_t
			vptr := storage.leveldb_iter_value(iter, &vlen)
			if vptr == nil { continue }
			val := ([^]byte)(vptr)[:vlen]
			coin, dec_ok := storage.utxo_db_decode_value(val, context.temp_allocator)
			if !dec_ok { continue }
			desc, hit := want[string(coin.script)]
			if !hit { continue }
			key := ([^]byte)(kptr)[:klen]
			op: wire.Outpoint
			copy(op.hash[:], key[:32])
			op.index = u32(key[32]) | u32(key[33]) << 8 | u32(key[34]) << 16 | u32(key[35]) << 24
			// Skip if the in-memory cache spent or replaced it.
			if _, in_cache := cc.cache[op]; in_cache {
				continue // live cache entries are handled in pass 2
			}
			if cc.frozen != nil {
				if _, in_frozen := cc.frozen[op]; in_frozen {
					continue
				}
			}
			add_unspent(&unspents, &total, op, coin, desc)
		}
	}
	// 2) In-memory cache entries (live coins only — sentinels are spends).
	{
		cc := &srv.chain.coins
		for op, entry in cc.cache {
			if entry.coin.amount == 0 && len(entry.coin.script) == 0 { continue } // spent sentinel
			if desc, hit := want[string(entry.coin.script)]; hit {
				add_unspent(&unspents, &total, op, entry.coin, desc)
			}
		}
		if cc.frozen != nil {
			for op, entry in cc.frozen {
				if entry.coin.amount == 0 && len(entry.coin.script) == 0 { continue }
				if _, shadowed := cc.cache[op]; shadowed { continue }
				if desc, hit := want[string(entry.coin.script)]; hit {
					add_unspent(&unspents, &total, op, entry.coin, desc)
				}
			}
		}
	}

	obj := make(json.Object, 7, context.temp_allocator)
	obj["success"] = json.Value(json.Boolean(true))
	obj["txouts"] = json.Value(json.Integer(i64(scanned)))
	obj["height"] = json.Value(json.Integer(i64(tip_height)))
	obj["bestblock"] = json.Value(json.String(_hash_to_hex(tip_hash)))
	obj["unspents"] = json.Value(unspents)
	obj["total_amount"] = json.Value(json.Float(_satoshi_to_btc(total)))
	return _make_result(json.Value(obj), srv._current_id)
}
