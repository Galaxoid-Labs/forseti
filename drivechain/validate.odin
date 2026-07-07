// BIP300 M5/M6 (deposit/withdrawal) and BIP301 BMM transaction handling.
//
// Track mode is DESCRIPTIVE: the chain is authoritative, so CTIPs follow
// whatever the connected block did and nothing is ever rejected. Enforce
// mode is PRESCRIPTIVE: rule violations make the block invalid. Where the
// BIP text and the CUSF enforcer (the living implementation the BIP defers
// to) disagree, we follow the enforcer; where a rule is ambiguous we lean
// lenient — wrongly rejecting a block forks us off even from other
// enforcers, wrongly accepting one merely under-enforces.
package drivechain

import "../wire"

// OP_DRIVECHAIN escrow script: OP_NOP5 <push1 n> OP_TRUE, exactly 4 bytes.
// Anything else using 0xb4 stays a NOP per BIP300.
parse_op_drivechain :: proc(spk: []byte) -> (sidechain: u8, ok: bool) {
	if len(spk) != 4 || spk[0] != 0xb4 || spk[1] != 0x01 || spk[3] != 0x51 {
		return 0, false
	}
	return spk[2], true
}

// BIP301 BMM request (in regular txs): 3-byte header, unlike the coinbase
// messages' 4-byte headers.
TAG_BMM_REQUEST :: [3]byte{0x00, 0xbf, 0x00}

BMM_Request :: struct {
	sidechain:       u8,
	h_star:          [32]byte,
	prev_main_block: [32]byte,
}

parse_bmm_request :: proc(payload: []byte) -> (m: BMM_Request, ok: bool) {
	if len(payload) != 3 + 1 + 32 + 32 ||
	   payload[0] != TAG_BMM_REQUEST[0] || payload[1] != TAG_BMM_REQUEST[1] ||
	   payload[2] != TAG_BMM_REQUEST[2] {
		return {}, false
	}
	m.sidechain = payload[3]
	copy(m.h_star[:], payload[4:36])
	copy(m.prev_main_block[:], payload[36:])
	return m, true
}

// Blinded withdrawal-bundle hash (m6id), per the CUSF enforcer: the M6 tx
// with (a) all inputs removed and (b) output 0 — the new CTIP — replaced by
// a zero-value OP_RETURN carrying the 8-byte BIG-endian L1 fee, where
// fee = old_treasury − new_treasury − sum(payout outputs). The txid of that
// modified tx is what M3 committed to (the bundle cannot know the CTIP
// outpoint or treasury total in advance — deposits change both).
compute_m6id :: proc(tx: ^wire.Tx, old_treasury: i64) -> (m6id: [32]byte, fee: i64, ok: bool) {
	if len(tx.outputs) == 0 {
		return {}, 0, false
	}
	t_new := tx.outputs[0].value
	p_total: i64 = 0
	for out in tx.outputs[1:] {
		p_total += out.value
	}
	fee = old_treasury - t_new - p_total
	if fee < 0 {
		return {}, 0, false
	}
	fee_script: [10]byte
	fee_script[0] = 0x6a // OP_RETURN
	fee_script[1] = 0x08 // push 8
	f := u64(fee)
	for i in 0 ..< 8 {
		fee_script[2 + i] = byte(f >> uint((7 - i) * 8))
	}
	outputs := make([]wire.Tx_Out, len(tx.outputs), context.temp_allocator)
	copy(outputs, tx.outputs)
	outputs[0] = wire.Tx_Out{value = 0, script_pubkey = fee_script[:]}
	blinded := wire.Tx {
		version  = tx.version,
		outputs  = outputs,
		locktime = tx.locktime,
	}
	return wire.tx_id(&blinded), fee, true
}

_has_ctip :: proc(s: ^Sidechain) -> bool {
	return s.ctip_txid != {}
}

// Process one non-coinbase tx against D1/D2. Mutates state (CTIP moves,
// approved bundle consumed). Returns a violation description in enforce
// mode, or "" if the tx is fine / not drivechain-related. Track mode
// always returns "".
process_tx :: proc(st: ^State, tx: ^wire.Tx, txid: [32]byte, enforce: bool) -> string {
	// Which active sidechain's CTIP does this tx spend?
	spent_slot := -1
	for in_idx in 0 ..< len(tx.inputs) {
		prev := tx.inputs[in_idx].previous_output
		for &s, n in st.slots {
			if !s.active || !_has_ctip(&s) { continue }
			if prev.hash == s.ctip_txid && prev.index == u32(s.ctip_vout) {
				if spent_slot >= 0 && spent_slot != n {
					if enforce { return "tx spends CTIPs of two sidechains" }
					return "" // track: can't model, leave both CTIPs (block says otherwise, but this is malformed traffic)
				}
				spent_slot = n
			}
		}
	}

	// OP_DRIVECHAIN outputs for ACTIVE sidechains.
	dc_out_count := 0
	dc_vout := -1
	dc_slot := -1
	for out_idx in 0 ..< len(tx.outputs) {
		n, ok := parse_op_drivechain(tx.outputs[out_idx].script_pubkey)
		if !ok || !st.slots[n].active { continue } // inactive slot = plain NOP script
		dc_out_count += 1
		if dc_out_count == 1 {
			dc_vout = out_idx
			dc_slot = int(n)
		}
	}

	if spent_slot < 0 {
		if dc_out_count == 0 {
			return "" // not drivechain-related
		}
		// Escrow output created without spending a CTIP: only valid as the
		// FIRST deposit to a sidechain that has no escrow yet.
		slot := &st.slots[dc_slot]
		if _has_ctip(slot) {
			if enforce { return "escrow output created without spending the sidechain's CTIP" }
			return "" // track: ignore the stray output; the real CTIP is still the tracked one
		}
		if dc_out_count > 1 {
			if enforce { return "deposit has more than one OP_DRIVECHAIN output" }
			// track: describe — first one becomes the CTIP
		}
		slot.ctip_txid = txid
		slot.ctip_vout = i32(dc_vout)
		slot.ctip_amount = tx.outputs[dc_vout].value
		return ""
	}

	// Tx spends the CTIP of spent_slot: must be M5 (deposit) or M6 (withdrawal).
	slot := &st.slots[spent_slot]
	t_old := slot.ctip_amount

	if dc_out_count == 0 {
		if enforce { return "CTIP spent without a replacement OP_DRIVECHAIN output" }
		// track: escrow destroyed on-chain; reflect it
		slot.ctip_txid = {}
		slot.ctip_vout = 0
		slot.ctip_amount = 0
		return ""
	}
	if dc_slot != spent_slot {
		if enforce { return "replacement escrow output is for a different sidechain" }
	}
	if dc_out_count > 1 {
		if enforce { return "more than one OP_DRIVECHAIN output in escrow spend" }
	}

	t_new := tx.outputs[dc_vout].value
	switch {
	case t_new > t_old:
		// M5 deposit. The enforcer additionally requires an OP_RETURN
		// deposit-address output immediately after the treasury output.
		if enforce {
			addr_ok := dc_vout + 1 < len(tx.outputs) &&
				len(tx.outputs[dc_vout + 1].script_pubkey) >= 1 &&
				tx.outputs[dc_vout + 1].script_pubkey[0] == 0x6a
			if !addr_ok { return "deposit missing OP_RETURN address output after the treasury output" }
		}
	case t_new < t_old:
		// M6 withdrawal.
		if enforce {
			if len(tx.inputs) != 1 { return "withdrawal must have exactly one input (the CTIP)" }
			if dc_vout != 0 { return "withdrawal's new CTIP must be output 0" }
		}
		m6id, _, m6_ok := compute_m6id(tx, t_old)
		bundle_idx := -1
		if m6_ok {
			for b, i in st.bundles {
				if int(b.sidechain) == spent_slot && b.approved && b.hash == m6id {
					bundle_idx = i
					break
				}
			}
		}
		if bundle_idx >= 0 {
			ordered_remove(&st.bundles, bundle_idx)
		} else if enforce {
			return "withdrawal does not match an approved bundle hash"
		}
	case:
		if enforce { return "escrow spend does not change the treasury amount" }
	}

	slot.ctip_txid = txid
	slot.ctip_vout = i32(dc_vout)
	slot.ctip_amount = t_new
	return ""
}

// Collect OP_RETURN payloads from a coinbase tx (candidates for M1-M4 /
// BMM Accept parsing).
collect_coinbase_payloads :: proc(coinbase: ^wire.Tx, allocator := context.temp_allocator) -> [][]byte {
	out := make([dynamic][]byte, 0, 4, allocator)
	for o in coinbase.outputs {
		if p := op_return_payload(o.script_pubkey); p != nil {
			append(&out, p)
		}
	}
	return out[:]
}

// BIP301 block rules (enforce mode): every BMM request must match a
// coinbase BMM accept for the same sidechain and h*, at most one request
// per sidechain per block, and prevMainBlock must be the actual previous
// block hash. Returns a violation description or "".
check_bmm :: proc(coinbase_payloads: [][]byte, txs: []wire.Tx, prev_hash: [32]byte) -> string {
	accepts := make(map[u8][32]byte, 4, context.temp_allocator)
	for p in coinbase_payloads {
		if a, ok := parse_bmm_accept(p); ok {
			accepts[a.sidechain] = a.h_star
		}
	}
	seen := make(map[u8]bool, 4, context.temp_allocator)
	for tx_idx in 1 ..< len(txs) {
		for o in txs[tx_idx].outputs {
			p := op_return_payload(o.script_pubkey)
			if p == nil { continue }
			req, ok := parse_bmm_request(p)
			if !ok { continue }
			if req.prev_main_block != prev_hash {
				return "BMM request prevMainBlock does not match the previous block hash"
			}
			if seen[req.sidechain] {
				return "more than one BMM request for the same sidechain"
			}
			seen[req.sidechain] = true
			h, has := accepts[req.sidechain]
			if !has || h != req.h_star {
				return "BMM request without matching coinbase BMM accept"
			}
		}
	}
	return ""
}

// Apply one full connected block: coinbase messages (M1-M4), BIP301 BMM
// rules, then M5/M6 escrow txs in block order. Mutates state as it goes —
// on a non-"" return (enforce mode only) the caller must restore the
// pre-block snapshot it took for the undo record.
apply_full_block :: proc(st: ^State, txs: []wire.Tx, txids: [][32]byte, prev_hash: [32]byte, height: int, enforce: bool) -> string {
	if len(txs) == 0 {
		return ""
	}
	payloads := collect_coinbase_payloads(&txs[0])

	if enforce {
		if v := check_bmm(payloads, txs, prev_hash); v != "" {
			return v
		}
	}

	apply_block(st, payloads, height)

	for tx_idx in 1 ..< len(txs) {
		if v := process_tx(st, &txs[tx_idx], txids[tx_idx], enforce); v != "" {
			return v
		}
	}
	return ""
}
