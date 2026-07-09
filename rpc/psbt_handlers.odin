package rpc

import "core:encoding/json"
import "core:fmt"

import "../chain"
import "../psbt"
import "../wire"

// Non-wallet PSBT RPCs (BIP174), mirroring Bitcoin Core's rawtransactions
// category: decodepsbt, createpsbt, converttopsbt, combinepsbt, joinpsbts,
// finalizepsbt, analyzepsbt, utxoupdatepsbt. Signing/funding lives in the
// wallet, which this node does not have.

// _parse_psbt_b64 decodes a base64 PSBT parameter, or returns an error response.
_parse_psbt_b64 :: proc(srv: ^RPC_Server, params: json.Value, idx: int) -> (p: psbt.PSBT, ok: bool, resp: RPC_Response) {
	s, s_ok := _get_string_param(params, idx)
	if !s_ok {
		return {}, false, _make_error(.Invalid_Params, "Missing PSBT base64 parameter", srv._current_id)
	}
	pp, err := psbt.deserialize_base64(s, context.temp_allocator)
	if err != .None {
		return {}, false, _make_error(.Tx_Deser_Error, fmt.tprintf("PSBT decode failed: %v", err), srv._current_id)
	}
	return pp, true, {}
}

_script_obj :: proc(s: []byte) -> json.Object {
	o := make(json.Object, 2, context.temp_allocator)
	o["hex"] = json.Value(json.String(_bytes_to_hex(s)))
	return o
}

_u32_le :: proc(b: []byte) -> (u32, bool) {
	if len(b) < 4 {
		return 0, false
	}
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24, true
}

// --- decodepsbt ---

_handle_decodepsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	p, ok, resp := _parse_psbt_b64(srv, params, 0)
	if !ok {
		return resp
	}

	obj := make(json.Object, 6, context.temp_allocator)
	obj["tx"] = json.Value(_decode_tx_to_json(&p.tx, srv.params))

	if v, has := psbt.map_find(p.global, psbt.GLOBAL_VERSION); has {
		if ver, vok := _u32_le(v.value); vok {
			obj["psbt_version"] = json.Value(json.Integer(i64(ver)))
		}
	}

	total_in: i64 = 0
	have_all_utxo := true

	inputs := make(json.Array, 0, len(p.inputs), context.temp_allocator)
	for i in 0 ..< len(p.inputs) {
		io := make(json.Object, 8, context.temp_allocator)

		if wu, has := psbt.map_find(p.inputs[i], psbt.IN_WITNESS_UTXO); has {
			r := wire.reader_init(wu.value)
			if to, e := wire.deserialize_tx_out(&r, context.temp_allocator); e == nil {
				wo := make(json.Object, 2, context.temp_allocator)
				wo["amount"] = json.Value(json.Float(f64(to.value) / 1e8))
				wo["scriptPubKey"] = json.Value(_script_obj(to.script_pubkey))
				io["witness_utxo"] = json.Value(wo)
				total_in += to.value
			} else {
				have_all_utxo = false
			}
		} else if nwu, has := psbt.map_find(p.inputs[i], psbt.IN_NON_WITNESS_UTXO); has {
			r := wire.reader_init(nwu.value)
			if prev, e := wire.deserialize_tx(&r, context.temp_allocator); e == nil {
				io["non_witness_utxo"] = json.Value(_decode_tx_to_json(&prev, srv.params))
				vout := int(p.tx.inputs[i].previous_output.index)
				if vout < len(prev.outputs) {
					total_in += prev.outputs[vout].value
				}
			} else {
				have_all_utxo = false
			}
		} else {
			have_all_utxo = false
		}

		psigs := make(json.Object, 2, context.temp_allocator)
		nsig := 0
		for kp in p.inputs[i] {
			kt, keydata := psbt.keytype(kp)
			if kt == psbt.IN_PARTIAL_SIG {
				psigs[_bytes_to_hex(keydata)] = json.Value(json.String(_bytes_to_hex(kp.value)))
				nsig += 1
			}
		}
		if nsig > 0 {
			io["partial_signatures"] = json.Value(psigs)
		}
		if sh, has := psbt.map_find(p.inputs[i], psbt.IN_SIGHASH_TYPE); has {
			if st, sok := _u32_le(sh.value); sok {
				io["sighash"] = json.Value(json.Integer(i64(st)))
			}
		}
		if rs, has := psbt.map_find(p.inputs[i], psbt.IN_REDEEM_SCRIPT); has {
			io["redeem_script"] = json.Value(_script_obj(rs.value))
		}
		if ws, has := psbt.map_find(p.inputs[i], psbt.IN_WITNESS_SCRIPT); has {
			io["witness_script"] = json.Value(_script_obj(ws.value))
		}
		if fs, has := psbt.map_find(p.inputs[i], psbt.IN_FINAL_SCRIPTSIG); has {
			io["final_scriptSig"] = json.Value(_script_obj(fs.value))
		}
		if fw, has := psbt.map_find(p.inputs[i], psbt.IN_FINAL_SCRIPTWITNESS); has {
			io["final_scriptwitness"] = json.Value(json.String(_bytes_to_hex(fw.value)))
		}
		append(&inputs, json.Value(io))
	}
	obj["inputs"] = json.Value(inputs)

	outputs := make(json.Array, 0, len(p.outputs), context.temp_allocator)
	for i in 0 ..< len(p.outputs) {
		oo := make(json.Object, 4, context.temp_allocator)
		if rs, has := psbt.map_find(p.outputs[i], psbt.OUT_REDEEM_SCRIPT); has {
			oo["redeem_script"] = json.Value(_script_obj(rs.value))
		}
		if ws, has := psbt.map_find(p.outputs[i], psbt.OUT_WITNESS_SCRIPT); has {
			oo["witness_script"] = json.Value(_script_obj(ws.value))
		}
		append(&outputs, json.Value(oo))
	}
	obj["outputs"] = json.Value(outputs)

	if have_all_utxo {
		total_out: i64 = 0
		for to in p.tx.outputs {
			total_out += to.value
		}
		if fee := total_in - total_out; fee >= 0 {
			obj["fee"] = json.Value(json.Float(f64(fee) / 1e8))
		}
	}

	return _make_result(json.Value(obj), srv._current_id)
}

// --- createpsbt ---

_handle_createpsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	tx, resp, ok := _build_tx_from_params(srv, params)
	if !ok {
		return resp
	}
	p := psbt.new_from_tx(&tx, context.temp_allocator)
	return _make_result(json.Value(json.String(psbt.serialize_base64(&p, context.temp_allocator))), srv._current_id)
}

// --- converttopsbt ---

_handle_converttopsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
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
	// new_from_tx strips scriptSigs/witness (BIP174 unsigned tx must be bare).
	p := psbt.new_from_tx(&tx, context.temp_allocator)
	return _make_result(json.Value(json.String(psbt.serialize_base64(&p, context.temp_allocator))), srv._current_id)
}

// --- combinepsbt ---

_handle_combinepsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	list, ok, resp := _decode_psbt_array(srv, params)
	if !ok {
		return resp
	}
	merged, m_ok := psbt.combine(list[:], context.temp_allocator)
	if !m_ok {
		return _make_error(.Invalid_Params, "Combined PSBTs must have the same unsigned transaction", srv._current_id)
	}
	return _make_result(json.Value(json.String(psbt.serialize_base64(&merged, context.temp_allocator))), srv._current_id)
}

// --- joinpsbts ---

_handle_joinpsbts :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	list, ok, resp := _decode_psbt_array(srv, params)
	if !ok {
		return resp
	}
	if len(list) < 2 {
		return _make_error(.Invalid_Params, "joinpsbts requires at least two PSBTs", srv._current_id)
	}
	joined, j_ok := psbt.join(list[:], context.temp_allocator)
	if !j_ok {
		return _make_error(.Invalid_Params, "PSBTs must have matching version/locktime and no shared inputs", srv._current_id)
	}
	return _make_result(json.Value(json.String(psbt.serialize_base64(&joined, context.temp_allocator))), srv._current_id)
}

// --- finalizepsbt ---

_handle_finalizepsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	p, ok, resp := _parse_psbt_b64(srv, params, 0)
	if !ok {
		return resp
	}
	extract := _get_bool_param(params, 1, true)

	complete := psbt.finalize(&p, context.temp_allocator)

	obj := make(json.Object, 2, context.temp_allocator)
	if complete && extract {
		tx, _ := psbt.extract(&p, context.temp_allocator)
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &tx)
		obj["hex"] = json.Value(json.String(_bytes_to_hex(wire.writer_bytes(&w))))
	} else {
		obj["psbt"] = json.Value(json.String(psbt.serialize_base64(&p, context.temp_allocator)))
	}
	obj["complete"] = json.Value(json.Boolean(complete))
	return _make_result(json.Value(obj), srv._current_id)
}

// --- analyzepsbt ---

_handle_analyzepsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	p, ok, resp := _parse_psbt_b64(srv, params, 0)
	if !ok {
		return resp
	}

	obj := make(json.Object, 4, context.temp_allocator)
	inputs := make(json.Array, 0, len(p.inputs), context.temp_allocator)

	all_final := true
	need_utxo := false
	total_in: i64 = 0
	have_all_utxo := true

	for i in 0 ..< len(p.inputs) {
		io := make(json.Object, 4, context.temp_allocator)
		_, has_utxo := psbt.input_utxo(&p, i, context.temp_allocator)
		is_final := psbt.is_finalized(&p, i)
		io["has_utxo"] = json.Value(json.Boolean(has_utxo))
		io["is_final"] = json.Value(json.Boolean(is_final))

		next := "signer"
		if is_final {
			next = "extractor"
		} else if !has_utxo {
			next = "updater"
			need_utxo = true
		}
		io["next"] = json.Value(json.String(next))
		append(&inputs, json.Value(io))

		if !is_final {
			all_final = false
		}
		if to, hu := psbt.input_utxo(&p, i, context.temp_allocator); hu {
			total_in += to.value
		} else {
			have_all_utxo = false
		}
	}
	obj["inputs"] = json.Value(inputs)

	overall := "signer"
	switch {
	case all_final:
		overall = "extractor"
	case need_utxo:
		overall = "updater"
	}
	obj["next"] = json.Value(json.String(overall))

	if have_all_utxo {
		total_out: i64 = 0
		for to in p.tx.outputs {
			total_out += to.value
		}
		if fee := total_in - total_out; fee >= 0 {
			obj["fee"] = json.Value(json.Float(f64(fee) / 1e8))
		}
	}
	return _make_result(json.Value(obj), srv._current_id)
}

// --- utxoupdatepsbt ---

// _is_witness_program reports whether spk is a vN witness program (v0..v16).
_is_witness_program :: proc(spk: []byte) -> bool {
	if len(spk) < 4 || len(spk) > 42 {
		return false
	}
	ver := spk[0]
	if ver != 0x00 && (ver < 0x51 || ver > 0x60) {
		return false
	}
	return int(spk[1]) == len(spk) - 2
}

_handle_utxoupdatepsbt :: proc(srv: ^RPC_Server, params: json.Value) -> RPC_Response {
	p, ok, resp := _parse_psbt_b64(srv, params, 0)
	if !ok {
		return resp
	}

	// For each input lacking a UTXO record, look up the prevout in the node's
	// UTXO set. Witness outputs get a WITNESS_UTXO record. Non-witness inputs
	// need the full previous transaction (txindex) and are left for a wallet /
	// an updater that has it.
	for i in 0 ..< len(p.inputs) {
		if _, has := psbt.map_find(p.inputs[i], psbt.IN_WITNESS_UTXO); has {
			continue
		}
		if _, has := psbt.map_find(p.inputs[i], psbt.IN_NON_WITNESS_UTXO); has {
			continue
		}
		outpoint := p.tx.inputs[i].previous_output
		coin, found := chain.coins_cache_get(&srv.chain.coins, outpoint)
		if !found || !_is_witness_program(coin.script) {
			continue
		}
		// Serialize the TxOut being spent as the WITNESS_UTXO value.
		w := wire.writer_init(context.temp_allocator)
		to := wire.Tx_Out{value = coin.amount, script_pubkey = coin.script}
		wire.serialize_tx_out(&w, &to)
		key := make([]byte, 1, context.temp_allocator)
		key[0] = psbt.IN_WITNESS_UTXO
		append(&p.inputs[i], psbt.Key_Pair{key = key, value = wire.writer_bytes(&w)})
	}

	return _make_result(json.Value(json.String(psbt.serialize_base64(&p, context.temp_allocator))), srv._current_id)
}

// --- shared helpers ---

// _decode_psbt_array decodes params[0] as an array of base64 PSBT strings.
_decode_psbt_array :: proc(srv: ^RPC_Server, params: json.Value) -> (list: [dynamic]psbt.PSBT, ok: bool, resp: RPC_Response) {
	arr, arr_ok := _get_array_param(params, 0)
	if !arr_ok || len(arr) < 1 {
		return nil, false, _make_error(.Invalid_Params, "Expected a non-empty array of PSBTs", srv._current_id)
	}
	list = make([dynamic]psbt.PSBT, 0, len(arr), context.temp_allocator)
	for i in 0 ..< len(arr) {
		s, s_ok := arr[i].(json.String)
		if !s_ok {
			return nil, false, _make_error(.Invalid_Params, fmt.tprintf("PSBT %d: must be a base64 string", i), srv._current_id)
		}
		pp, err := psbt.deserialize_base64(string(s), context.temp_allocator)
		if err != .None {
			return nil, false, _make_error(.Tx_Deser_Error, fmt.tprintf("PSBT %d decode failed: %v", i, err), srv._current_id)
		}
		append(&list, pp)
	}
	return list, true, {}
}

// _build_tx_from_params builds an unsigned wire.Tx from createrawtransaction-
// style params ([inputs, outputs, locktime?, replaceable?]).
_build_tx_from_params :: proc(srv: ^RPC_Server, params: json.Value) -> (tx: wire.Tx, resp: RPC_Response, ok: bool) {
	inputs_val, inputs_ok := _get_param(params, 0)
	if !inputs_ok {
		return {}, _make_error(.Invalid_Params, "Missing inputs parameter", srv._current_id), false
	}
	inputs_arr, is_in := inputs_val.(json.Array)
	if !is_in {
		return {}, _make_error(.Invalid_Params, "inputs must be an array", srv._current_id), false
	}
	outputs_val, outputs_ok := _get_param(params, 1)
	if !outputs_ok {
		return {}, _make_error(.Invalid_Params, "Missing outputs parameter", srv._current_id), false
	}
	outputs_arr, is_out := outputs_val.(json.Array)
	if !is_out {
		return {}, _make_error(.Invalid_Params, "outputs must be an array", srv._current_id), false
	}

	locktime: u32 = 0
	if lt, lt_ok := _get_int_param(params, 2); lt_ok {
		locktime = u32(lt)
	}
	replaceable := _get_bool_param(params, 3, false)
	default_sequence: u32 = replaceable ? 0xFFFFFFFD : 0xFFFFFFFE

	tx_inputs := make([]wire.Tx_In, len(inputs_arr), context.temp_allocator)
	for i in 0 ..< len(inputs_arr) {
		in_obj, in_ok := inputs_arr[i].(json.Object)
		if !in_ok {
			return {}, _make_error(.Invalid_Params, fmt.tprintf("input %d: must be an object", i), srv._current_id), false
		}
		txid_str, txid_ok := in_obj["txid"].(json.String)
		if !txid_ok {
			return {}, _make_error(.Invalid_Params, fmt.tprintf("input %d: missing txid", i), srv._current_id), false
		}
		txid_hash, hash_ok := _hex_to_hash(string(txid_str))
		if !hash_ok {
			return {}, _make_error(.Invalid_Params, fmt.tprintf("input %d: invalid txid", i), srv._current_id), false
		}
		vout: u32 = 0
		if v, f := in_obj["vout"]; f {
			#partial switch vv in v {
			case json.Integer: vout = u32(vv)
			case json.Float:   vout = u32(vv)
			}
		}
		seq := default_sequence
		if v, f := in_obj["sequence"]; f {
			#partial switch vv in v {
			case json.Integer: seq = u32(vv)
			case json.Float:   seq = u32(vv)
			}
		}
		tx_inputs[i] = wire.Tx_In {
			previous_output = wire.Outpoint{hash = txid_hash, index = vout},
			sequence        = seq,
		}
	}

	tx_outputs := make([dynamic]wire.Tx_Out, 0, len(outputs_arr), context.temp_allocator)
	for i in 0 ..< len(outputs_arr) {
		out_obj, out_ok := outputs_arr[i].(json.Object)
		if !out_ok {
			return {}, _make_error(.Invalid_Params, fmt.tprintf("output %d: must be an object", i), srv._current_id), false
		}
		for key, val in out_obj {
			if key == "data" {
				data_hex, d_ok := val.(json.String)
				if !d_ok {
					return {}, _make_error(.Invalid_Params, "data must be a string", srv._current_id), false
				}
				data_bytes, dec_ok := _hex_decode(string(data_hex))
				if !dec_ok {
					return {}, _make_error(.Invalid_Params, "invalid data hex", srv._current_id), false
				}
				spk := make([]byte, 2 + len(data_bytes), context.temp_allocator)
				spk[0] = 0x6a // OP_RETURN
				spk[1] = u8(len(data_bytes))
				copy(spk[2:], data_bytes)
				append(&tx_outputs, wire.Tx_Out{value = 0, script_pubkey = spk})
			} else {
				amount_f64: f64 = 0
				#partial switch vv in val {
				case json.Float:   amount_f64 = vv
				case json.Integer: amount_f64 = f64(vv)
				case:
					return {}, _make_error(.Invalid_Params, fmt.tprintf("output %d: amount must be numeric", i), srv._current_id), false
				}
				spk, spk_ok := _address_to_script_pubkey(key, srv.params)
				if !spk_ok {
					return {}, _make_error(.Invalid_Params, fmt.tprintf("Invalid address: %s", key), srv._current_id), false
				}
				append(&tx_outputs, wire.Tx_Out{value = i64(amount_f64 * 1e8 + 0.5), script_pubkey = spk})
			}
		}
	}

	tx = wire.Tx {
		version  = 2,
		inputs   = tx_inputs,
		outputs  = tx_outputs[:],
		locktime = locktime,
	}
	return tx, {}, true
}
