package psbt

import "core:slice"

import "../wire"

// input_utxo returns the TxOut being spent by input i, sourced from the
// input's WITNESS_UTXO record, or from NON_WITNESS_UTXO indexed by the
// unsigned tx's prevout. Returns ok=false when neither is present.
input_utxo :: proc(p: ^PSBT, i: int, allocator := context.allocator) -> (txout: wire.Tx_Out, ok: bool) {
	if i < 0 || i >= len(p.inputs) {
		return {}, false
	}
	if wu, has := map_find(p.inputs[i], IN_WITNESS_UTXO); has {
		r := wire.reader_init(wu.value)
		to, err := wire.deserialize_tx_out(&r, allocator)
		if err != nil {
			return {}, false
		}
		return to, true
	}
	if nwu, has := map_find(p.inputs[i], IN_NON_WITNESS_UTXO); has {
		r := wire.reader_init(nwu.value)
		prev, err := wire.deserialize_tx(&r, allocator)
		if err != nil {
			return {}, false
		}
		vout := int(p.tx.inputs[i].previous_output.index)
		if vout < 0 || vout >= len(prev.outputs) {
			return {}, false
		}
		return prev.outputs[vout], true
	}
	return {}, false
}

// is_finalized reports whether input i already carries final script data.
is_finalized :: proc(p: ^PSBT, i: int) -> bool {
	if _, has := map_find(p.inputs[i], IN_FINAL_SCRIPTSIG); has {
		return true
	}
	if _, has := map_find(p.inputs[i], IN_FINAL_SCRIPTWITNESS); has {
		return true
	}
	return false
}

// --- combine (BIP174 Combiner) ---

// combine merges PSBTs that share the same unsigned transaction, taking the
// union of every map. Returns ok=false if the unsigned txs differ.
combine :: proc(psbts: []PSBT, allocator := context.allocator) -> (out: PSBT, ok: bool) {
	if len(psbts) == 0 {
		return {}, false
	}
	base, has0 := map_find(psbts[0].global, GLOBAL_UNSIGNED_TX)
	if !has0 {
		return {}, false
	}
	for i in 1 ..< len(psbts) {
		t, h := map_find(psbts[i].global, GLOBAL_UNSIGNED_TX)
		if !h || !slice.equal(t.value, base.value) {
			return {}, false
		}
	}

	out = _clone_psbt(&psbts[0], allocator)
	for i in 1 ..< len(psbts) {
		src := &psbts[i]
		_merge_map(&out.global, src.global)
		for j in 0 ..< len(out.inputs) {
			_merge_map(&out.inputs[j], src.inputs[j])
		}
		for j in 0 ..< len(out.outputs) {
			_merge_map(&out.outputs[j], src.outputs[j])
		}
	}
	return out, true
}

// --- join (BIP174-adjacent: distinct txs into one) ---

// join concatenates the inputs and outputs of multiple PSBTs (which may have
// different unsigned txs) into one PSBT. version/locktime are taken from the
// first PSBT; all must agree. Returns ok=false on mismatch or duplicate prevouts.
join :: proc(psbts: []PSBT, allocator := context.allocator) -> (out: PSBT, ok: bool) {
	if len(psbts) == 0 {
		return {}, false
	}
	version := psbts[0].tx.version
	locktime := psbts[0].tx.locktime

	inputs := make([dynamic]wire.Tx_In, 0, allocator)
	outputs := make([dynamic]wire.Tx_Out, 0, allocator)
	seen := make(map[wire.Outpoint]bool, allocator)
	for i in 0 ..< len(psbts) {
		if psbts[i].tx.version != version || psbts[i].tx.locktime != locktime {
			return {}, false
		}
		for txin in psbts[i].tx.inputs {
			if seen[txin.previous_output] {
				return {}, false // duplicate input across PSBTs
			}
			seen[txin.previous_output] = true
			clean := txin
			clean.script_sig = nil
			append(&inputs, clean)
		}
		for txout in psbts[i].tx.outputs {
			append(&outputs, txout)
		}
	}

	newtx := wire.Tx {
		version  = version,
		inputs   = inputs[:],
		outputs  = outputs[:],
		locktime = locktime,
	}
	out = new_from_tx(&newtx, allocator)

	// Overwrite the empty per-input/per-output maps with the concatenated
	// source maps, in the same order the tx was assembled.
	in_idx, out_idx := 0, 0
	for i in 0 ..< len(psbts) {
		for m in psbts[i].inputs {
			out.inputs[in_idx] = _clone_map(m, allocator)
			in_idx += 1
		}
		for m in psbts[i].outputs {
			out.outputs[out_idx] = _clone_map(m, allocator)
			out_idx += 1
		}
		// Carry over non-tx globals (e.g. xpubs).
		for kp in psbts[i].global {
			kt, _ := keytype(kp)
			if kt == GLOBAL_UNSIGNED_TX {
				continue
			}
			_append_if_absent(&out.global, kp)
		}
	}
	return out, true
}

// --- helpers ---

_clone_map :: proc(m: Map, allocator := context.allocator) -> Map {
	out := make(Map, 0, len(m), allocator)
	for kp in m {
		append(&out, kp)
	}
	return out
}

_clone_psbt :: proc(p: ^PSBT, allocator := context.allocator) -> PSBT {
	out: PSBT
	out.tx = p.tx
	out.global = _clone_map(p.global, allocator)
	out.inputs = make([]Map, len(p.inputs), allocator)
	for i in 0 ..< len(p.inputs) {
		out.inputs[i] = _clone_map(p.inputs[i], allocator)
	}
	out.outputs = make([]Map, len(p.outputs), allocator)
	for i in 0 ..< len(p.outputs) {
		out.outputs[i] = _clone_map(p.outputs[i], allocator)
	}
	return out
}

// _merge_map appends every pair from src whose key is not already in dst.
_merge_map :: proc(dst: ^Map, src: Map) {
	for kp in src {
		_append_if_absent(dst, kp)
	}
}

_append_if_absent :: proc(dst: ^Map, kp: Key_Pair) {
	for existing in dst^ {
		if slice.equal(existing.key, kp.key) {
			return
		}
	}
	append(dst, kp)
}
