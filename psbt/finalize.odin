package psbt

import "../wire"

// finalize assembles final scriptSig / scriptWitness for every input it can,
// from the partial signatures and scripts already present. It does NOT verify
// signatures (that is the signer's job) — it only assembles, exactly like
// Bitcoin Core's FinalizePSBT. Supported: P2PKH, P2WPKH, P2SH-P2WPKH, bare/
// P2SH/P2WSH/P2SH-P2WSH multisig, and P2TR key-path. Inputs of any other type
// (e.g. arbitrary tapscript) are left untouched. Returns complete=true when
// every input ended up finalized.
finalize :: proc(p: ^PSBT, allocator := context.allocator) -> (complete: bool) {
	complete = true
	for i in 0 ..< len(p.inputs) {
		if is_finalized(p, i) {
			continue
		}
		if !_finalize_input(p, i, allocator) {
			complete = false
		} else {
			// Finalized inputs shed all non-final input data (BIP174).
			_strip_to_final(&p.inputs[i], allocator)
		}
	}
	return complete
}

// extract assembles the final network transaction from a finalized PSBT,
// pulling each input's scriptSig / witness from its FINAL_SCRIPTSIG /
// FINAL_SCRIPTWITNESS records. complete is true only if every input is
// finalized (the caller should not broadcast an incomplete tx).
extract :: proc(p: ^PSBT, allocator := context.allocator) -> (tx: wire.Tx, complete: bool) {
	tx = p.tx
	tx.inputs = make([]wire.Tx_In, len(p.tx.inputs), allocator)
	witness := make([][][]byte, len(p.tx.inputs), allocator)
	has_wit := false
	complete = true

	for i in 0 ..< len(p.tx.inputs) {
		tx.inputs[i] = p.tx.inputs[i]
		tx.inputs[i].script_sig = nil
		if ss, h := map_find(p.inputs[i], IN_FINAL_SCRIPTSIG); h {
			tx.inputs[i].script_sig = ss.value
		}
		if fw, h := map_find(p.inputs[i], IN_FINAL_SCRIPTWITNESS); h {
			witness[i] = _parse_witness_stack(fw.value, allocator)
			has_wit = true
		}
		if !is_finalized(p, i) {
			complete = false
		}
	}
	if has_wit {
		tx.witness = witness
	} else {
		tx.witness = nil
	}
	return tx, complete
}

// _parse_witness_stack decodes a FINAL_SCRIPTWITNESS value (count + var_bytes
// items) into a witness stack.
_parse_witness_stack :: proc(value: []byte, allocator := context.allocator) -> [][]byte {
	r := wire.reader_init(value)
	count, err := wire.read_compact_size(&r)
	if err != nil {
		return nil
	}
	items := make([][]byte, int(count), allocator)
	for j in 0 ..< int(count) {
		item, e := wire.read_var_bytes(&r, allocator)
		if e != nil {
			return items
		}
		items[j] = item
	}
	return items
}

_finalize_input :: proc(p: ^PSBT, i: int, allocator := context.allocator) -> bool {
	utxo, has_utxo := input_utxo(p, i, allocator)
	// P2TR key-path: signalled by a TAP_KEY_SIG, no scriptPubKey inspection needed.
	if tks, has := map_find(p.inputs[i], IN_TAP_KEY_SIG); has {
		wit := _ser_witness_stack({tks.value}, allocator)
		_set_pair(&p.inputs[i], IN_FINAL_SCRIPTWITNESS, wit, allocator)
		return true
	}
	if !has_utxo {
		return false
	}
	spk := utxo.script_pubkey

	sigs := _collect_partial_sigs(p.inputs[i], allocator)

	switch {
	case _is_p2pkh(spk):
		sig, pk, ok := _single_sig(sigs)
		if !ok {
			return false
		}
		ss := _ser_scriptsig({sig, pk}, allocator)
		_set_pair(&p.inputs[i], IN_FINAL_SCRIPTSIG, ss, allocator)
		return true

	case _is_p2wpkh(spk):
		sig, pk, ok := _single_sig(sigs)
		if !ok {
			return false
		}
		wit := _ser_witness_stack({sig, pk}, allocator)
		_set_pair(&p.inputs[i], IN_FINAL_SCRIPTWITNESS, wit, allocator)
		return true

	case _is_p2sh(spk):
		rs, has_rs := map_find(p.inputs[i], IN_REDEEM_SCRIPT)
		if !has_rs {
			return false
		}
		redeem := rs.value
		switch {
		case _is_p2wpkh(redeem): // P2SH-P2WPKH
			sig, pk, ok := _single_sig(sigs)
			if !ok {
				return false
			}
			ss := _ser_scriptsig({redeem}, allocator) // push the redeemScript
			wit := _ser_witness_stack({sig, pk}, allocator)
			_set_pair(&p.inputs[i], IN_FINAL_SCRIPTSIG, ss, allocator)
			_set_pair(&p.inputs[i], IN_FINAL_SCRIPTWITNESS, wit, allocator)
			return true
		case _is_p2wsh(redeem): // P2SH-P2WSH multisig
			ws, has_ws := map_find(p.inputs[i], IN_WITNESS_SCRIPT)
			if !has_ws {
				return false
			}
			stack, ok := _multisig_witness(ws.value, sigs, allocator)
			if !ok {
				return false
			}
			ss := _ser_scriptsig({redeem}, allocator)
			wit := _ser_witness_stack(stack, allocator)
			_set_pair(&p.inputs[i], IN_FINAL_SCRIPTSIG, ss, allocator)
			_set_pair(&p.inputs[i], IN_FINAL_SCRIPTWITNESS, wit, allocator)
			return true
		case _is_multisig(redeem): // P2SH multisig (legacy)
			ordered, _, ok := _order_sigs(redeem, sigs, allocator)
			if !ok {
				return false
			}
			items := make([dynamic][]byte, 0, len(ordered) + 1, allocator)
			for s in ordered {
				append(&items, s)
			}
			append(&items, redeem) // push the redeemScript last
			ss := _ser_scriptsig_with_leading_zero(items[:], allocator)
			_set_pair(&p.inputs[i], IN_FINAL_SCRIPTSIG, ss, allocator)
			return true
		}
		return false

	case _is_p2wsh(spk): // P2WSH multisig
		ws, has_ws := map_find(p.inputs[i], IN_WITNESS_SCRIPT)
		if !has_ws {
			return false
		}
		stack, ok := _multisig_witness(ws.value, sigs, allocator)
		if !ok {
			return false
		}
		wit := _ser_witness_stack(stack, allocator)
		_set_pair(&p.inputs[i], IN_FINAL_SCRIPTWITNESS, wit, allocator)
		return true

	case _is_multisig(spk): // bare multisig
		ordered, _, ok := _order_sigs(spk, sigs, allocator)
		if !ok {
			return false
		}
		ss := _ser_scriptsig_with_leading_zero(ordered, allocator)
		_set_pair(&p.inputs[i], IN_FINAL_SCRIPTSIG, ss, allocator)
		return true
	}
	return false
}

// --- signature collection ---

Sig_Entry :: struct {
	pubkey: []byte, // key data after the 0x02 keytype
	sig:    []byte,
}

_collect_partial_sigs :: proc(m: Map, allocator := context.allocator) -> [dynamic]Sig_Entry {
	out := make([dynamic]Sig_Entry, 0, allocator)
	for kp in m {
		kt, keydata := keytype(kp)
		if kt == IN_PARTIAL_SIG {
			append(&out, Sig_Entry{pubkey = keydata, sig = kp.value})
		}
	}
	return out
}

_single_sig :: proc(sigs: [dynamic]Sig_Entry) -> (sig: []byte, pubkey: []byte, ok: bool) {
	if len(sigs) != 1 {
		return nil, nil, false
	}
	return sigs[0].sig, sigs[0].pubkey, true
}

// _multisig_witness builds the witness stack for an m-of-n multisig:
// [OP_0 dummy, sig_1, ..., sig_m, witnessScript], sigs ordered by pubkey
// order in the script.
_multisig_witness :: proc(script: []byte, sigs: [dynamic]Sig_Entry, allocator := context.allocator) -> ([][]byte, bool) {
	ordered, m, ok := _order_sigs(script, sigs, allocator)
	if !ok {
		return nil, false
	}
	stack := make([dynamic][]byte, 0, m + 2, allocator)
	append(&stack, []byte{}) // CHECKMULTISIG off-by-one dummy
	for s in ordered {
		append(&stack, s)
	}
	append(&stack, script)
	return stack[:], true
}

// _order_sigs returns exactly m signatures ordered by their pubkey's position
// in the multisig script. Fails if fewer than m of the script's pubkeys are signed.
_order_sigs :: proc(script: []byte, sigs: [dynamic]Sig_Entry, allocator := context.allocator) -> ([][]byte, int, bool) {
	m, pubkeys, ok := _parse_multisig(script, allocator)
	if !ok {
		return nil, 0, false
	}
	ordered := make([dynamic][]byte, 0, m, allocator)
	for pk in pubkeys {
		for s in sigs {
			if _bytes_eq(s.pubkey, pk) {
				append(&ordered, s.sig)
				break
			}
		}
		if len(ordered) == m {
			break
		}
	}
	if len(ordered) < m {
		return nil, 0, false
	}
	return ordered[:], m, true
}
