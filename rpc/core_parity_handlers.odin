package rpc

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:time"

import "../chain"
import crypto "../crypto"
import "../descriptor"
import "../p2p"
import "../storage"
import "../wire"

// Additional Bitcoin Core v30 non-wallet RPCs.

// _expand_scan_objects turns a scanobjects array (descriptors or {desc,range})
// into the set of scriptPubKeys they cover — shared by scanblocks and
// getdescriptoractivity. Mirrors scantxoutset's expansion.
_expand_scan_objects :: proc(srv: ^RPC_Server, objs: json.Array) -> (scripts: [dynamic][]byte, resp: RPC_Response, ok: bool) {
	net := _desc_net(srv)
	scripts = make([dynamic][]byte, 0, 64, context.temp_allocator)
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
				return nil, _make_error(.Invalid_Params, "Scan object missing desc", srv._current_id), false
			}
			desc_str = string(ds)
			if rv, has_rv := v["range"]; has_rv {
				b, e, r_ok := _parse_range(rv)
				if !r_ok {
					return nil, _make_error(.Invalid_Params, "Invalid range", srv._current_id), false
				}
				begin, end = b, e
				range_given = true
			}
		case:
			return nil, _make_error(.Invalid_Params, "Invalid scan object", srv._current_id), false
		}

		d, derr := descriptor.parse(desc_str, net, context.temp_allocator)
		if derr != "" {
			return nil, _make_error(.Invalid_Params, fmt.tprintf("%s: %s", desc_str, derr), srv._current_id), false
		}
		if d.is_range && !range_given {
			end = SCAN_DEFAULT_RANGE
		}
		if !d.is_range {
			begin, end = 0, 0
		}
		if end - begin + 1 > 100_000 {
			return nil, _make_error(.Invalid_Params, "Range too large", srv._current_id), false
		}
		for i in begin ..= end {
			spk, s_ok := descriptor.script_pubkey(&d, i, context.temp_allocator)
			if s_ok {
				append(&scripts, spk)
			}
		}
	}
	return scripts, {}, true
}

// --- getdescriptoractivity ---

_handle_getdescriptoractivity :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	// params: [ [blockhashes], [scanobjects], include_mempool ]
	objs, objs_ok := _get_array_param(params, 1)
	if !objs_ok || len(objs) == 0 {
		return _make_error(.Invalid_Params, "scanobjects argument is required", srv._current_id)
	}
	scripts, resp, sc_ok := _expand_scan_objects(srv, objs)
	if !sc_ok {
		return resp
	}
	want := make(map[string]bool, len(scripts) * 2, context.temp_allocator)
	for s in scripts {
		want[string(s)] = true
	}
	include_mempool := _get_bool_param(params, 2, false)

	activity := make(json.Array, 0, context.temp_allocator)

	_receive :: proc(activity: ^json.Array, amount: i64, txid: string, vout: int, blockhash: string, height: int, in_mempool: bool) {
		e := make(json.Object, 6, context.temp_allocator)
		e["type"] = json.Value(json.String("receive"))
		e["amount"] = json.Value(json.Float(f64(amount) / 1e8))
		e["txid"] = json.Value(json.String(txid))
		e["vout"] = json.Value(json.Integer(i64(vout)))
		if in_mempool {
			e["mempool"] = json.Value(json.Boolean(true))
		} else {
			e["blockhash"] = json.Value(json.String(blockhash))
			e["height"] = json.Value(json.Integer(i64(height)))
		}
		append(activity, json.Value(e))
	}
	_spend :: proc(activity: ^json.Array, amount: i64, prev_txid: string, prev_vout: u32, blockhash: string, height: int, in_mempool: bool) {
		e := make(json.Object, 6, context.temp_allocator)
		e["type"] = json.Value(json.String("spend"))
		e["amount"] = json.Value(json.Float(f64(amount) / 1e8))
		e["prevout_txid"] = json.Value(json.String(prev_txid))
		e["prevout_vout"] = json.Value(json.Integer(i64(prev_vout)))
		if in_mempool {
			e["mempool"] = json.Value(json.Boolean(true))
		} else {
			e["blockhash"] = json.Value(json.String(blockhash))
			e["height"] = json.Value(json.Integer(i64(height)))
		}
		append(activity, json.Value(e))
	}

	// Confirmed activity in the requested blocks.
	if bhs, ok := _get_array_param(params, 0); ok {
		for i in 0 ..< len(bhs) {
			bh_str, s_ok := bhs[i].(json.String)
			if !s_ok {
				return _make_error(.Invalid_Params, "blockhash must be a string", srv._current_id)
			}
			hash, h_ok := _hex_to_hash(string(bh_str))
			if !h_ok {
				return _make_error(.Invalid_Params, "invalid block hash", srv._current_id)
			}
			entry, found := srv.chain.block_index.entries[hash]
			if !found || .Has_Data not_in entry.status {
				return _make_error(.Block_Not_Found, "Block not found or data unavailable", srv._current_id)
			}
			loc := storage.Block_Location{file_num = entry.file_num, data_offset = entry.data_offset, data_size = entry.data_size}
			block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
			if berr != .None {
				continue
			}
			hh := string(bh_str)
			// receives: outputs paying a target script
			for &tx in block.txs {
				txid := _hash_to_hex(wire.tx_id(&tx))
				for vout in 0 ..< len(tx.outputs) {
					if want[string(tx.outputs[vout].script_pubkey)] {
						_receive(&activity, tx.outputs[vout].value, txid, vout, hh, entry.height, false)
					}
				}
			}
			// spends: undo records carry the spent outpoint + its coin
			if .Has_Undo in entry.status {
				if undo, uerr := chain.read_block_undo(&srv.chain.undo_files, entry, context.temp_allocator); uerr == .None {
					for uc in undo.spent_coins {
						if want[string(uc.coin.script)] {
							_spend(&activity, uc.coin.amount, _hash_to_hex(uc.outpoint.hash), uc.outpoint.index, hh, entry.height, false)
						}
					}
				}
			}
		}
	}

	// Unconfirmed activity in the mempool.
	if include_mempool {
		for _, ent in srv.mp.entries {
			txid := _hash_to_hex(ent.txid)
			for vout in 0 ..< len(ent.tx.outputs) {
				if want[string(ent.tx.outputs[vout].script_pubkey)] {
					_receive(&activity, ent.tx.outputs[vout].value, txid, vout, "", 0, true)
				}
			}
			// spends: resolve each input's prevout script from the UTXO set
			for &in_ in ent.tx.inputs {
				if coin, found := chain.coins_cache_get(&srv.chain.coins, in_.previous_output); found {
					if want[string(coin.script)] {
						_spend(&activity, coin.amount, _hash_to_hex(in_.previous_output.hash), in_.previous_output.index, "", 0, true)
					}
				}
			}
		}
	}

	obj := make(json.Object, 1, context.temp_allocator)
	obj["activity"] = json.Value(activity)
	return _make_result(json.Value(obj), srv._current_id)
}

// --- scanblocks ---

_handle_scanblocks :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	if srv.chain.filter_db == nil {
		return _make_error(.Misc_Error, "Index is not enabled for filtertype basic (start with --blockfilterindex)", srv._current_id)
	}
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
	scripts, resp, sc_ok := _expand_scan_objects(srv, objs)
	if !sc_ok {
		return resp
	}

	tip_height := chain.chain_height(srv.chain)
	start_height := 0
	stop_height := tip_height
	if s, s_ok := _get_int_param(params, 2); s_ok {
		start_height = s
	}
	if s, s_ok := _get_int_param(params, 3); s_ok {
		stop_height = s
	}
	if ft, ft_ok := _get_string_param(params, 4); ft_ok && ft != "basic" {
		return _make_error(.Invalid_Params, fmt.tprintf("Unknown filtertype %s", ft), srv._current_id)
	}
	if start_height < 0 {
		start_height = 0
	}
	if stop_height > tip_height {
		stop_height = tip_height
	}

	relevant := make(json.Array, 0, context.temp_allocator)
	for h in start_height ..= stop_height {
		if h < 0 || h >= len(srv.chain.active_chain) {
			continue
		}
		block_hash := srv.chain.active_chain[h]
		filter_data, found := storage.filter_db_get_filter(srv.chain.filter_db, block_hash, context.temp_allocator)
		if !found {
			continue
		}
		if crypto.gcs_match_any(block_hash, filter_data, scripts[:]) {
			append(&relevant, json.Value(json.String(_hash_to_hex(block_hash))))
		}
	}

	obj := make(json.Object, 3, context.temp_allocator)
	obj["from_height"] = json.Value(json.Integer(i64(start_height)))
	obj["to_height"] = json.Value(json.Integer(i64(stop_height)))
	obj["relevant_blocks"] = json.Value(relevant)
	return _make_result(json.Value(obj), srv._current_id)
}

// --- waitfornewblock / waitforblock / waitforblockheight ---

_WAIT_POLL :: 50 * time.Millisecond

// _wait_current returns the current tip as {hash, height}.
_wait_current :: proc(srv: ^RPC_Server) -> RPC_Response {
	h, ht := chain.chain_tip(srv.chain)
	obj := make(json.Object, 2, context.temp_allocator)
	obj["hash"] = json.Value(json.String(_hash_to_hex(h)))
	obj["height"] = json.Value(json.Integer(i64(ht)))
	return _make_result(json.Value(obj), srv._current_id)
}

// _timed_out reports whether timeout_ms (0 = no timeout) has elapsed since tick.
_timed_out :: proc(tick: time.Tick, timeout_ms: int) -> bool {
	return timeout_ms > 0 && time.duration_milliseconds(time.tick_since(tick)) >= f64(timeout_ms)
}

_handle_waitfornewblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	timeout_ms := 0
	if t, ok := _get_int_param(params, 0); ok {
		timeout_ms = t
	}
	start_hash, _ := chain.chain_tip(srv.chain)
	tick := time.tick_now()
	for {
		h, _ := chain.chain_tip(srv.chain)
		if h != start_hash {
			break
		}
		if _timed_out(tick, timeout_ms) {
			break
		}
		time.sleep(_WAIT_POLL)
	}
	return _wait_current(srv)
}

_handle_waitforblock :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	target_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing blockhash parameter", srv._current_id)
	}
	target, h_ok := _hex_to_hash(target_hex)
	if !h_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}
	timeout_ms := 0
	if t, t_ok := _get_int_param(params, 1); t_ok {
		timeout_ms = t
	}
	tick := time.tick_now()
	for {
		h, _ := chain.chain_tip(srv.chain)
		if h == target {
			break
		}
		if _timed_out(tick, timeout_ms) {
			break
		}
		time.sleep(_WAIT_POLL)
	}
	return _wait_current(srv)
}

_handle_waitforblockheight :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	target, ok := _get_int_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing height parameter", srv._current_id)
	}
	timeout_ms := 0
	if t, t_ok := _get_int_param(params, 1); t_ok {
		timeout_ms = t
	}
	tick := time.tick_now()
	for {
		_, ht := chain.chain_tip(srv.chain)
		if ht >= target {
			break
		}
		if _timed_out(tick, timeout_ms) {
			break
		}
		time.sleep(_WAIT_POLL)
	}
	return _wait_current(srv)
}

// --- getblockfrompeer ---

_handle_getblockfrompeer :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	hash_hex, ok := _get_string_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing blockhash parameter", srv._current_id)
	}
	hash, hash_ok := _hex_to_hash(hash_hex)
	if !hash_ok {
		return _make_error(.Invalid_Params, "Invalid block hash", srv._current_id)
	}
	peer_id, pid_ok := _get_int_param(params, 1)
	if !pid_ok {
		return _make_error(.Invalid_Params, "Missing peer_id parameter", srv._current_id)
	}

	// The block header must already be known (Core requires the header first).
	entry, found := srv.chain.block_index.entries[hash]
	if !found {
		return _make_error(.Misc_Error, "Block header missing, try adding it first (getheaders/sendheaders)", srv._current_id)
	}
	if .Has_Data in entry.status {
		return _make_error(.Misc_Error, "Block already downloaded", srv._current_id)
	}

	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}
	p2p.conn_manager_control(cm, p2p.Control_Request{action = .Get_Block_From_Peer, hash = hash, peer_id = p2p.Peer_Id(peer_id)})
	// Core returns an empty object; the block arrives asynchronously.
	return _make_result(json.Value(make(json.Object, 0, context.temp_allocator)), srv._current_id)
}

// --- getprioritisedtransactions ---

_handle_getprioritisedtransactions :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	obj := make(json.Object, len(srv.mp.fee_deltas) + 1, context.temp_allocator)
	for txid, delta in srv.mp.fee_deltas {
		e := make(json.Object, 3, context.temp_allocator)
		e["fee_delta"] = json.Value(json.Integer(delta))
		entry, in_mp := srv.mp.entries[txid]
		e["in_mempool"] = json.Value(json.Boolean(in_mp))
		if in_mp {
			e["modified_fee"] = json.Value(json.Integer(entry.fee + delta))
		}
		obj[_hash_to_hex(txid)] = json.Value(e)
	}
	return _make_result(json.Value(obj), srv._current_id)
}

// --- getaddrmaninfo ---

_net_name :: proc(net: wire.Addr_V2_Net) -> string {
	switch net {
	case .IPv4:  return "ipv4"
	case .IPv6:  return "ipv6"
	case .TorV3: return "onion"
	case .I2P:   return "i2p"
	case .CJDNS: return "cjdns"
	}
	return "unknown"
}

_handle_getaddrmaninfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	cm, has_cm := _require_cm(srv)
	if !has_cm {
		return _make_error(.Internal_Error, "P2P disabled", srv._current_id)
	}

	// forseti's address manager is a single flat table (no new/tried bucket
	// split), so every known address is reported as "new"; "tried" is always 0.
	nets := [?]string{"ipv4", "ipv6", "onion", "i2p", "cjdns"}
	counts := make(map[string]int, len(nets), context.temp_allocator)
	total := 0

	sync.mutex_lock(&cm.addr_mgr.mutex)
	for ka in cm.addr_mgr.addresses {
		counts[_net_name(ka.net)] += 1
		total += 1
	}
	sync.mutex_unlock(&cm.addr_mgr.mutex)

	make_net := proc(n: int) -> json.Object {
		o := make(json.Object, 3, context.temp_allocator)
		o["new"] = json.Value(json.Integer(i64(n)))
		o["tried"] = json.Value(json.Integer(0))
		o["total"] = json.Value(json.Integer(i64(n)))
		return o
	}

	obj := make(json.Object, len(nets) + 1, context.temp_allocator)
	for name in nets {
		obj[name] = json.Value(make_net(counts[name]))
	}
	obj["all_networks"] = json.Value(make_net(total))
	return _make_result(json.Value(obj), srv._current_id)
}

// --- gettxspendingprevout ---

_handle_gettxspendingprevout :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	arr_val, ok := _get_param(params, 0)
	if !ok {
		return _make_error(.Invalid_Params, "Missing outputs array", srv._current_id)
	}
	arr, is_arr := arr_val.(json.Array)
	if !is_arr {
		return _make_error(.Invalid_Params, "outputs must be an array", srv._current_id)
	}

	result := make(json.Array, 0, len(arr), context.temp_allocator)
	for i in 0 ..< len(arr) {
		o, o_ok := arr[i].(json.Object)
		if !o_ok {
			return _make_error(.Invalid_Params, "each output must be an object", srv._current_id)
		}
		txid_str, t_ok := o["txid"].(json.String)
		if !t_ok {
			return _make_error(.Invalid_Params, "output missing txid", srv._current_id)
		}
		txid, h_ok := _hex_to_hash(string(txid_str))
		if !h_ok {
			return _make_error(.Invalid_Params, "invalid txid", srv._current_id)
		}
		vout: u32 = 0
		#partial switch v in o["vout"] {
		case json.Integer: vout = u32(v)
		case json.Float:   vout = u32(v)
		case:
			return _make_error(.Invalid_Params, "output missing vout", srv._current_id)
		}

		entry := make(json.Object, 3, context.temp_allocator)
		entry["txid"] = json.Value(json.String(string(txid_str)))
		entry["vout"] = json.Value(json.Integer(i64(vout)))
		if spender, found := srv.mp.spent_outpoints[wire.Outpoint{hash = txid, index = vout}]; found {
			entry["spendingtxid"] = json.Value(json.String(_hash_to_hex(spender)))
		}
		append(&result, json.Value(entry))
	}
	return _make_result(json.Value(result), srv._current_id)
}

// --- getdeploymentinfo ---

_handle_getdeploymentinfo :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tip_hash, tip_height := chain.chain_tip(srv.chain)

	// Optional blockhash param — Core allows querying at a specific block; we
	// report at the given height if it's an ancestor of the tip, else the tip.
	height := tip_height
	hash := tip_hash
	if bh, bh_ok := _get_string_param(params, 0); bh_ok {
		if h, ok := _hex_to_hash(bh); ok {
			if idx, found := srv.chain.block_index.entries[h]; found {
				hash = h
				height = idx.height
			}
		}
	}

	p := srv.params
	deployments := make(json.Object, 8, context.temp_allocator)

	// forseti activates soft forks at hardcoded heights (no BIP9 versionbits
	// tracking), so every deployment is reported as "buried" with its height.
	add := proc(deps: ^json.Object, name: string, act_height, tip: int) {
		d := make(json.Object, 3, context.temp_allocator)
		d["type"] = json.Value(json.String("buried"))
		d["active"] = json.Value(json.Boolean(tip >= act_height && act_height >= 0))
		d["height"] = json.Value(json.Integer(i64(act_height)))
		deps[name] = json.Value(d)
	}
	add(&deployments, "bip34", p.bip34_height, height)
	add(&deployments, "bip66", p.bip66_height, height)
	add(&deployments, "bip65", p.bip65_height, height)
	add(&deployments, "csv", p.csv_height, height)
	add(&deployments, "segwit", p.segwit_height, height)
	add(&deployments, "taproot", p.taproot_height, height)

	obj := make(json.Object, 3, context.temp_allocator)
	obj["hash"] = json.Value(json.String(_hash_to_hex(hash)))
	obj["height"] = json.Value(json.Integer(i64(height)))
	obj["deployments"] = json.Value(deployments)
	return _make_result(json.Value(obj), srv._current_id)
}
