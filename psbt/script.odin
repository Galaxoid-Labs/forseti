package psbt

import "core:slice"

import "../wire"

// Standard scriptPubKey shape detectors (byte patterns; no full parse).

_is_p2pkh :: proc(s: []byte) -> bool {
	return len(s) == 25 && s[0] == 0x76 && s[1] == 0xa9 && s[2] == 0x14 && s[23] == 0x88 && s[24] == 0xac
}

_is_p2sh :: proc(s: []byte) -> bool {
	return len(s) == 23 && s[0] == 0xa9 && s[1] == 0x14 && s[22] == 0x87
}

_is_p2wpkh :: proc(s: []byte) -> bool {
	return len(s) == 22 && s[0] == 0x00 && s[1] == 0x14
}

_is_p2wsh :: proc(s: []byte) -> bool {
	return len(s) == 34 && s[0] == 0x00 && s[1] == 0x20
}

_is_p2tr :: proc(s: []byte) -> bool {
	return len(s) == 34 && s[0] == 0x51 && s[1] == 0x20
}

_is_multisig :: proc(s: []byte) -> bool {
	_, _, ok := _parse_multisig(s, context.temp_allocator)
	return ok
}

// _parse_multisig decodes a bare m-of-n CHECKMULTISIG script:
// OP_m <pubkey>...<pubkey> OP_n OP_CHECKMULTISIG. Returns m and the pubkeys
// in script order (slices into s).
_parse_multisig :: proc(s: []byte, allocator := context.allocator) -> (m: int, pubkeys: [][]byte, ok: bool) {
	if len(s) < 3 || s[len(s) - 1] != 0xae {
		return 0, nil, false
	}
	if s[0] < 0x51 || s[0] > 0x60 {
		return 0, nil, false
	}
	m = int(s[0] - 0x50)
	if s[len(s) - 2] < 0x51 || s[len(s) - 2] > 0x60 {
		return 0, nil, false
	}
	n := int(s[len(s) - 2] - 0x50)

	pk := make([dynamic][]byte, 0, n, allocator)
	pos := 1
	end := len(s) - 2
	for pos < end {
		l := int(s[pos])
		pos += 1
		if l != 33 && l != 65 { // compressed / uncompressed pubkey pushes only
			return 0, nil, false
		}
		if pos + l > end {
			return 0, nil, false
		}
		append(&pk, s[pos:pos + l])
		pos += l
	}
	if len(pk) != n || m < 1 || m > n {
		return 0, nil, false
	}
	return m, pk[:], true
}

// --- serialization helpers ---

_bytes_eq :: proc(a, b: []byte) -> bool {
	return slice.equal(a, b)
}

// _push appends a canonical minimal data push for data to w.
_push :: proc(w: ^wire.Wire_Writer, data: []byte) {
	n := len(data)
	switch {
	case n < 0x4c:
		wire.write_byte(w, u8(n))
	case n <= 0xff:
		wire.write_byte(w, 0x4c) // OP_PUSHDATA1
		wire.write_byte(w, u8(n))
	case n <= 0xffff:
		wire.write_byte(w, 0x4d) // OP_PUSHDATA2
		wire.write_u16le(w, u16(n))
	case:
		wire.write_byte(w, 0x4e) // OP_PUSHDATA4
		wire.write_u32le(w, u32(n))
	}
	wire.write_bytes(w, data)
}

// _ser_scriptsig builds a scriptSig that is just a sequence of data pushes.
_ser_scriptsig :: proc(items: [][]byte, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	for it in items {
		_push(&w, it)
	}
	return wire.writer_bytes(&w)
}

// _ser_scriptsig_with_leading_zero builds a multisig scriptSig:
// OP_0 <push item>... (the OP_0 satisfies CHECKMULTISIG's dummy-pop bug).
_ser_scriptsig_with_leading_zero :: proc(items: [][]byte, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	wire.write_byte(&w, 0x00) // OP_0
	for it in items {
		_push(&w, it)
	}
	return wire.writer_bytes(&w)
}

// _ser_witness_stack serializes a witness stack (count + var_bytes items) as
// stored in an IN_FINAL_SCRIPTWITNESS value.
_ser_witness_stack :: proc(items: [][]byte, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	wire.write_compact_size(&w, u64(len(items)))
	for it in items {
		wire.write_var_bytes(&w, it)
	}
	return wire.writer_bytes(&w)
}

// _set_pair inserts (or replaces) a single-byte-keytype record in a map.
_set_pair :: proc(m: ^Map, kt: u8, value: []byte, allocator := context.allocator) {
	key := make([]byte, 1, allocator)
	key[0] = kt
	for i in 0 ..< len(m^) {
		if slice.equal(m[i].key, key) {
			m[i].value = value
			return
		}
	}
	append(m, Key_Pair{key = key, value = value})
}

// _strip_to_final drops every input field except the UTXO records and the
// final scriptSig/scriptWitness, per the BIP174 Finalizer role.
_strip_to_final :: proc(m: ^Map, allocator := context.allocator) {
	kept := make(Map, 0, len(m^), allocator)
	for kp in m^ {
		kt, _ := keytype(kp)
		switch kt {
		case IN_NON_WITNESS_UTXO, IN_WITNESS_UTXO, IN_FINAL_SCRIPTSIG, IN_FINAL_SCRIPTWITNESS:
			append(&kept, kp)
		}
	}
	m^ = kept
}
