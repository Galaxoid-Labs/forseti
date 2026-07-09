package rpc

import "core:encoding/json"
import "core:sync"

import "../chain"
import "../p2p"
import "../wire"

// Additional Bitcoin Core v30 non-wallet RPCs.

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
