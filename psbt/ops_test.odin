package psbt

import "core:slice"
import "core:testing"

import "../wire"

_mk_tx :: proc(prev_byte: u8, allocator := context.allocator) -> wire.Tx {
	prev: wire.Hash256
	prev[0] = prev_byte
	inputs := make([]wire.Tx_In, 1, allocator)
	inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{hash = prev, index = 0},
		sequence        = 0xFFFFFFFF,
	}
	spk := make([]byte, 1, allocator)
	spk[0] = 0x6a
	outputs := make([]wire.Tx_Out, 1, allocator)
	outputs[0] = wire.Tx_Out{value = 90000, script_pubkey = spk}
	return wire.Tx{version = 2, inputs = inputs, outputs = outputs, locktime = 0}
}

_add_pair :: proc(m: ^Map, key: []byte, value: []byte) {
	append(m, Key_Pair{key = key, value = value})
}

_witness_utxo_val :: proc(value: i64, spk: []byte, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	wire.write_i64le(&w, value)
	wire.write_var_bytes(&w, spk)
	return wire.writer_bytes(&w)
}

_partial_sig_key :: proc(pubkey: []byte, allocator := context.allocator) -> []byte {
	key := make([]byte, 1 + len(pubkey), allocator)
	key[0] = IN_PARTIAL_SIG
	copy(key[1:], pubkey)
	return key
}

@(test)
test_finalize_p2wpkh :: proc(t: ^testing.T) {
	tx := _mk_tx(0x11, context.temp_allocator)
	p := new_from_tx(&tx, context.temp_allocator)

	// P2WPKH scriptPubKey: OP_0 <20-byte hash>.
	spk := make([]byte, 22, context.temp_allocator)
	spk[0] = 0x00
	spk[1] = 0x14
	wu := _witness_utxo_val(90000, spk, context.temp_allocator)
	_add_pair(&p.inputs[0], []byte{IN_WITNESS_UTXO}, wu)

	pubkey := make([]byte, 33, context.temp_allocator)
	pubkey[0] = 0x02
	pubkey[1] = 0xAB
	sig := []byte{0x30, 0x44, 0xDE, 0xAD, 0x01} // dummy DER+sighash; finalize doesn't verify
	_add_pair(&p.inputs[0], _partial_sig_key(pubkey, context.temp_allocator), sig)

	complete := finalize(&p, context.temp_allocator)
	testing.expect(t, complete, "single P2WPKH input should finalize")

	fw, ok := map_find(p.inputs[0], IN_FINAL_SCRIPTWITNESS)
	testing.expect(t, ok, "must have final scriptWitness")
	// Expect witness stack [sig, pubkey].
	want := _ser_witness_stack({sig, pubkey}, context.temp_allocator)
	testing.expect(t, slice.equal(fw.value, want), "witness stack must be [sig, pubkey]")

	// Partial sig must be stripped after finalization.
	_, still_partial := map_find(p.inputs[0], IN_PARTIAL_SIG)
	testing.expect(t, !still_partial, "partial sig should be stripped")
}

@(test)
test_combine_merges_sigs :: proc(t: ^testing.T) {
	tx := _mk_tx(0x22, context.temp_allocator)
	pa := new_from_tx(&tx, context.temp_allocator)
	pb := new_from_tx(&tx, context.temp_allocator)

	pk1 := make([]byte, 33, context.temp_allocator); pk1[0] = 0x02; pk1[1] = 0x01
	pk2 := make([]byte, 33, context.temp_allocator); pk2[0] = 0x02; pk2[1] = 0x02
	_add_pair(&pa.inputs[0], _partial_sig_key(pk1, context.temp_allocator), []byte{0xAA})
	_add_pair(&pb.inputs[0], _partial_sig_key(pk2, context.temp_allocator), []byte{0xBB})

	merged, ok := combine({pa, pb}, context.temp_allocator)
	testing.expect(t, ok, "combine should succeed for same unsigned tx")

	count := 0
	for kp in merged.inputs[0] {
		kt, _ := keytype(kp)
		if kt == IN_PARTIAL_SIG {
			count += 1
		}
	}
	testing.expect_value(t, count, 2)
}

@(test)
test_combine_rejects_different_tx :: proc(t: ^testing.T) {
	ta := _mk_tx(0x33, context.temp_allocator)
	tb := _mk_tx(0x44, context.temp_allocator)
	pa := new_from_tx(&ta, context.temp_allocator)
	pb := new_from_tx(&tb, context.temp_allocator)
	_, ok := combine({pa, pb}, context.temp_allocator)
	testing.expect(t, !ok, "combine must reject differing unsigned txs")
}

@(test)
test_join_concatenates :: proc(t: ^testing.T) {
	ta := _mk_tx(0x55, context.temp_allocator)
	tb := _mk_tx(0x66, context.temp_allocator)
	pa := new_from_tx(&ta, context.temp_allocator)
	pb := new_from_tx(&tb, context.temp_allocator)

	joined, ok := join({pa, pb}, context.temp_allocator)
	testing.expect(t, ok, "join should succeed")
	testing.expect_value(t, len(joined.tx.inputs), 2)
	testing.expect_value(t, len(joined.tx.outputs), 2)
	testing.expect_value(t, len(joined.inputs), 2)
	testing.expect_value(t, len(joined.outputs), 2)
}
