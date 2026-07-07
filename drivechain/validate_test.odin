package drivechain

import "core:testing"
import "../wire"

_dc_script :: proc(n: u8, allocator := context.temp_allocator) -> []byte {
	s := make([]byte, 4, allocator)
	s[0] = 0xb4; s[1] = 0x01; s[2] = n; s[3] = 0x51
	return s
}

_op_return_script :: proc(payload: []byte, allocator := context.temp_allocator) -> []byte {
	s := make([]byte, 2 + len(payload), allocator)
	s[0] = 0x6a
	s[1] = byte(len(payload))
	copy(s[2:], payload)
	return s
}

_p2pkh_script :: proc(allocator := context.temp_allocator) -> []byte {
	s := make([]byte, 25, allocator)
	s[0] = 0x76; s[1] = 0xa9; s[2] = 0x14
	s[23] = 0x88; s[24] = 0xac
	return s
}

@(test)
test_op_drivechain_parse :: proc(t: ^testing.T) {
	n, ok := parse_op_drivechain([]byte{0xb4, 0x01, 7, 0x51})
	testing.expect(t, ok, "canonical form parses")
	testing.expect_value(t, n, u8(7))

	_, bad1 := parse_op_drivechain([]byte{0xb4, 0x01, 7, 0x51, 0x51}) // extra byte
	testing.expect(t, !bad1, "5-byte script rejected")
	_, bad2 := parse_op_drivechain([]byte{0xb4, 0x02, 7, 0x51}) // wrong push
	testing.expect(t, !bad2, "push2 rejected")
	_, bad3 := parse_op_drivechain([]byte{0xb4, 0x01, 7, 0x52}) // OP_2 not OP_TRUE
	testing.expect(t, !bad3, "non-OP_TRUE rejected")
}

@(test)
test_bmm_request_parse :: proc(t: ^testing.T) {
	payload := make([]byte, 68, context.temp_allocator)
	payload[0] = 0x00; payload[1] = 0xbf; payload[2] = 0x00
	payload[3] = 5
	for i in 4 ..< 36 { payload[i] = 0xaa }
	for i in 36 ..< 68 { payload[i] = 0xbb }

	req, ok := parse_bmm_request(payload)
	testing.expect(t, ok, "bmm request parses")
	testing.expect_value(t, req.sidechain, u8(5))
	testing.expect_value(t, req.h_star[0], byte(0xaa))
	testing.expect_value(t, req.prev_main_block[31], byte(0xbb))

	_, bad := parse_bmm_request(payload[:67])
	testing.expect(t, !bad, "short request rejected")
}

@(test)
test_compute_m6id :: proc(t: ^testing.T) {
	ctip_txid: [32]byte
	ctip_txid[0] = 0x11

	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In{previous_output = {hash = ctip_txid, index = 0}, sequence = 0xffffffff}
	outputs := make([]wire.Tx_Out, 2, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = 40, script_pubkey = _dc_script(0)}
	outputs[1] = wire.Tx_Out{value = 55, script_pubkey = _p2pkh_script()}
	tx := wire.Tx{version = 2, inputs = inputs, outputs = outputs}

	m6id, fee, ok := compute_m6id(&tx, 100)
	testing.expect(t, ok, "m6id computes")
	testing.expect_value(t, fee, i64(5)) // 100 - 40 - 55

	// Reference: blinded tx built by hand — no inputs, output 0 replaced by
	// zero-value OP_RETURN <fee as 8-byte BE>.
	fee_script := []byte{0x6a, 0x08, 0, 0, 0, 0, 0, 0, 0, 5}
	b_outputs := make([]wire.Tx_Out, 2, context.temp_allocator)
	b_outputs[0] = wire.Tx_Out{value = 0, script_pubkey = fee_script}
	b_outputs[1] = outputs[1]
	blinded := wire.Tx{version = 2, outputs = b_outputs}
	testing.expect_value(t, m6id, wire.tx_id(&blinded))

	// Overspend (outputs exceed treasury) → invalid.
	_, _, over := compute_m6id(&tx, 90)
	testing.expect(t, !over, "negative fee rejected")
}

_make_tx :: proc(prev: wire.Outpoint, outs: []wire.Tx_Out, n_inputs := 1) -> wire.Tx {
	inputs := make([]wire.Tx_In, n_inputs, context.temp_allocator)
	inputs[0] = wire.Tx_In{previous_output = prev, sequence = 0xffffffff}
	for i in 1 ..< n_inputs {
		extra: [32]byte
		extra[0] = byte(0x80 + i)
		inputs[i] = wire.Tx_In{previous_output = {hash = extra, index = 0}, sequence = 0xffffffff}
	}
	return wire.Tx{version = 2, inputs = inputs, outputs = outs}
}

@(test)
test_process_tx_deposits :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)
	st.slots[0].active = true

	// Initial escrow creation: OP_DRIVECHAIN output without spending a CTIP.
	txid1: [32]byte
	txid1[0] = 1
	outs1 := make([]wire.Tx_Out, 1, context.temp_allocator)
	outs1[0] = wire.Tx_Out{value = 100, script_pubkey = _dc_script(0)}
	tx1 := _make_tx(wire.Outpoint{}, outs1)
	v := process_tx(&st, &tx1, txid1, true)
	testing.expect_value(t, v, "")
	testing.expect_value(t, st.slots[0].ctip_txid, txid1)
	testing.expect_value(t, st.slots[0].ctip_amount, i64(100))

	// M5 deposit: spend CTIP, larger replacement + OP_RETURN address output.
	txid2: [32]byte
	txid2[0] = 2
	outs2 := make([]wire.Tx_Out, 2, context.temp_allocator)
	outs2[0] = wire.Tx_Out{value = 150, script_pubkey = _dc_script(0)}
	outs2[1] = wire.Tx_Out{value = 0, script_pubkey = _op_return_script([]byte{0xde, 0xad})}
	tx2 := _make_tx(wire.Outpoint{hash = txid1, index = 0}, outs2)
	v = process_tx(&st, &tx2, txid2, true)
	testing.expect_value(t, v, "")
	testing.expect_value(t, st.slots[0].ctip_txid, txid2)
	testing.expect_value(t, st.slots[0].ctip_amount, i64(150))

	// Deposit without the address OP_RETURN → enforce rejects, track describes.
	txid3: [32]byte
	txid3[0] = 3
	outs3 := make([]wire.Tx_Out, 1, context.temp_allocator)
	outs3[0] = wire.Tx_Out{value = 200, script_pubkey = _dc_script(0)}
	tx3 := _make_tx(wire.Outpoint{hash = txid2, index = 0}, outs3)
	v = process_tx(&st, &tx3, txid3, true)
	testing.expect(t, v != "", "deposit without address output rejected in enforce mode")
	testing.expect_value(t, st.slots[0].ctip_txid, txid2) // unchanged on violation

	v = process_tx(&st, &tx3, txid3, false)
	testing.expect_value(t, v, "")
	testing.expect_value(t, st.slots[0].ctip_amount, i64(200)) // track follows the chain

	// Creating a second escrow output while a CTIP exists (not spent) → violation.
	txid4: [32]byte
	txid4[0] = 4
	tx4 := _make_tx(wire.Outpoint{hash = txid1, index = 5}, outs1) // random prevout
	v = process_tx(&st, &tx4, txid4, true)
	testing.expect(t, v != "", "duplicate escrow creation rejected")

	// Equal-amount escrow spend → violation.
	txid5: [32]byte
	txid5[0] = 5
	outs5 := make([]wire.Tx_Out, 2, context.temp_allocator)
	outs5[0] = wire.Tx_Out{value = 200, script_pubkey = _dc_script(0)}
	outs5[1] = wire.Tx_Out{value = 0, script_pubkey = _op_return_script([]byte{0x01})}
	tx5 := _make_tx(wire.Outpoint{hash = txid3, index = 0}, outs5)
	v = process_tx(&st, &tx5, txid5, true)
	testing.expect(t, v != "", "zero-diff escrow spend rejected")
}

@(test)
test_process_tx_withdrawal :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)
	st.slots[0].active = true
	ctip_txid: [32]byte
	ctip_txid[0] = 0xcc
	st.slots[0].ctip_txid = ctip_txid
	st.slots[0].ctip_vout = 0
	st.slots[0].ctip_amount = 100

	outs := make([]wire.Tx_Out, 2, context.temp_allocator)
	outs[0] = wire.Tx_Out{value = 40, script_pubkey = _dc_script(0)}
	outs[1] = wire.Tx_Out{value = 55, script_pubkey = _p2pkh_script()}
	tx := _make_tx(wire.Outpoint{hash = ctip_txid, index = 0}, outs)
	m6id, _, m6_ok := compute_m6id(&tx, 100)
	testing.expect(t, m6_ok, "m6id computes")

	// No approved bundle yet → enforce rejects.
	wtxid: [32]byte
	wtxid[0] = 0xdd
	v := process_tx(&st, &tx, wtxid, true)
	testing.expect(t, v != "", "withdrawal without approved bundle rejected")
	testing.expect_value(t, st.slots[0].ctip_amount, i64(100))

	// Approve the bundle, retry → accepted, bundle consumed, CTIP moves.
	append(&st.bundles, Bundle{sidechain = 0, hash = m6id, acks = BUNDLE_SUCCESS_ACKS, remaining = 100, approved = true})
	v = process_tx(&st, &tx, wtxid, true)
	testing.expect_value(t, v, "")
	testing.expect_value(t, len(st.bundles), 0)
	testing.expect_value(t, st.slots[0].ctip_txid, wtxid)
	testing.expect_value(t, st.slots[0].ctip_amount, i64(40))

	// Two-input withdrawal → violation.
	st.slots[0].ctip_txid = ctip_txid
	st.slots[0].ctip_amount = 100
	tx2 := _make_tx(wire.Outpoint{hash = ctip_txid, index = 0}, outs, n_inputs = 2)
	append(&st.bundles, Bundle{sidechain = 0, hash = m6id, acks = BUNDLE_SUCCESS_ACKS, remaining = 100, approved = true})
	v = process_tx(&st, &tx2, wtxid, true)
	testing.expect(t, v != "", "multi-input withdrawal rejected")

	// CTIP spend with no replacement output → violation in enforce,
	// escrow cleared in track.
	outs3 := make([]wire.Tx_Out, 1, context.temp_allocator)
	outs3[0] = wire.Tx_Out{value = 90, script_pubkey = _p2pkh_script()}
	tx3 := _make_tx(wire.Outpoint{hash = ctip_txid, index = 0}, outs3)
	v = process_tx(&st, &tx3, wtxid, true)
	testing.expect(t, v != "", "escrow destruction rejected in enforce mode")
	v = process_tx(&st, &tx3, wtxid, false)
	testing.expect_value(t, v, "")
	testing.expect(t, st.slots[0].ctip_txid == {}, "track mode clears destroyed escrow")
}

@(test)
test_check_bmm :: proc(t: ^testing.T) {
	prev: [32]byte
	prev[0] = 0x99
	h_star: [32]byte
	h_star[0] = 0x42

	accept := make([]byte, 37, context.temp_allocator)
	accept[0] = 0xd1; accept[1] = 0x61; accept[2] = 0x73; accept[3] = 0x68
	accept[4] = 3
	copy(accept[5:], h_star[:])

	req_payload := make([]byte, 68, context.temp_allocator)
	req_payload[0] = 0x00; req_payload[1] = 0xbf; req_payload[2] = 0x00
	req_payload[3] = 3
	copy(req_payload[4:36], h_star[:])
	copy(req_payload[36:], prev[:])

	req_outs := make([]wire.Tx_Out, 1, context.temp_allocator)
	req_outs[0] = wire.Tx_Out{value = 0, script_pubkey = _op_return_script(req_payload)}
	req_tx := _make_tx(wire.Outpoint{}, req_outs)

	cb := wire.Tx{} // coinbase stand-in; payloads passed separately
	txs := []wire.Tx{cb, req_tx}

	// Matching accept → OK.
	v := check_bmm([][]byte{accept}, txs, prev)
	testing.expect_value(t, v, "")

	// No accept → violation.
	v = check_bmm(nil, txs, prev)
	testing.expect(t, v != "", "request without accept rejected")

	// Wrong prev hash → violation.
	other: [32]byte
	v = check_bmm([][]byte{accept}, txs, other)
	testing.expect(t, v != "", "wrong prevMainBlock rejected")

	// Duplicate request for the same sidechain → violation.
	txs_dup := []wire.Tx{cb, req_tx, req_tx}
	v = check_bmm([][]byte{accept}, txs_dup, prev)
	testing.expect(t, v != "", "duplicate request rejected")
}
