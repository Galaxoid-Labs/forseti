package script

import "core:strings"

// Script classification types.
Script_Type :: enum {
	Non_Standard,
	P2PKH,       // Pay-to-PubKey-Hash (OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG)
	P2SH,        // Pay-to-Script-Hash (OP_HASH160 <20> OP_EQUAL)
	P2WPKH,      // Pay-to-Witness-PubKey-Hash (OP_0 <20>)
	P2WSH,       // Pay-to-Witness-Script-Hash (OP_0 <32>)
	P2TR,        // Pay-to-Taproot (OP_1 <32>)
	P2PK,        // Pay-to-PubKey (<33|65> OP_CHECKSIG)
	Null_Data,   // OP_RETURN <data>
	Witness_Unknown, // Valid witness program with unknown version
}

// Classify a script by its byte pattern.
classify_script :: proc(s: []byte) -> Script_Type {
	n := len(s)

	// P2PKH: OP_DUP OP_HASH160 OP_PUSH20 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
	if n == 25 &&
	   s[0] == u8(Opcode.OP_DUP) &&
	   s[1] == u8(Opcode.OP_HASH160) &&
	   s[2] == 0x14 && // push 20 bytes
	   s[23] == u8(Opcode.OP_EQUALVERIFY) &&
	   s[24] == u8(Opcode.OP_CHECKSIG) {
		return .P2PKH
	}

	// P2SH: OP_HASH160 OP_PUSH20 <20 bytes> OP_EQUAL
	if n == 23 &&
	   s[0] == u8(Opcode.OP_HASH160) &&
	   s[1] == 0x14 && // push 20 bytes
	   s[22] == u8(Opcode.OP_EQUAL) {
		return .P2SH
	}

	// P2WPKH: OP_0 OP_PUSH20 <20 bytes>
	if n == 22 &&
	   s[0] == u8(Opcode.OP_0) &&
	   s[1] == 0x14 {
		return .P2WPKH
	}

	// P2WSH: OP_0 OP_PUSH32 <32 bytes>
	if n == 34 &&
	   s[0] == u8(Opcode.OP_0) &&
	   s[1] == 0x20 {
		return .P2WSH
	}

	// P2TR: OP_1 OP_PUSH32 <32 bytes>
	if n == 34 &&
	   s[0] == u8(Opcode.OP_1) &&
	   s[1] == 0x20 {
		return .P2TR
	}

	// P2PK: <33 or 65 byte pubkey> OP_CHECKSIG
	if n == 35 && s[0] == 0x21 && s[34] == u8(Opcode.OP_CHECKSIG) {
		return .P2PK
	}
	if n == 67 && s[0] == 0x41 && s[66] == u8(Opcode.OP_CHECKSIG) {
		return .P2PK
	}

	// Null data: OP_RETURN ...
	if n >= 1 && s[0] == u8(Opcode.OP_RETURN) {
		return .Null_Data
	}

	// Witness programs (unknown versions 2-16)
	ver, _, ok := is_witness_program(s)
	if ok && ver >= 2 {
		return .Witness_Unknown
	}

	return .Non_Standard
}

// Check if a script is a witness program: OP_n <2-40 bytes>.
// Returns the version (0-16), the program data, and whether it matched.
is_witness_program :: proc(s: []byte) -> (version: int, program: []byte, ok: bool) {
	n := len(s)
	if n < 4 || n > 42 { return 0, nil, false }

	// First byte must be OP_0 or OP_1..OP_16
	ver_byte := s[0]
	if ver_byte == u8(Opcode.OP_0) {
		version = 0
	} else if ver_byte >= u8(Opcode.OP_1) && ver_byte <= u8(Opcode.OP_16) {
		version = int(ver_byte) - int(Opcode.OP_1) + 1
	} else {
		return 0, nil, false
	}

	// Second byte is the push length (must be direct push 2-40)
	prog_len := int(s[1])
	if prog_len < 2 || prog_len > 40 { return 0, nil, false }
	if n != prog_len + 2 { return 0, nil, false }

	return version, s[2:], true
}

// Return Bitcoin Core-compatible type name string for a Script_Type.
script_type_name :: proc(t: Script_Type) -> string {
	switch t {
	case .P2PKH:           return "pubkeyhash"
	case .P2SH:            return "scripthash"
	case .P2WPKH:          return "witness_v0_keyhash"
	case .P2WSH:           return "witness_v0_scripthash"
	case .P2TR:            return "witness_v1_taproot"
	case .P2PK:            return "pubkey"
	case .Null_Data:       return "nulldata"
	case .Witness_Unknown: return "witness_unknown"
	case .Non_Standard:    return "nonstandard"
	}
	return "nonstandard"
}

// Disassemble script bytes into a human-readable ASM string.
script_to_asm :: proc(s: []byte, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s) * 3, allocator)
	i := 0
	first := true

	for i < len(s) {
		if !first {
			strings.write_byte(&b, ' ')
		}
		first = false

		op := s[i]
		i += 1

		if op == 0x00 {
			// OP_0
			strings.write_string(&b, opcode_name(op))
		} else if op >= 0x01 && op <= 0x4b {
			// Direct push of N bytes
			push_size := int(op)
			if i + push_size <= len(s) {
				_write_hex_bytes(&b, s[i:i + push_size])
				i += push_size
			} else {
				strings.write_string(&b, "[error]")
				break
			}
		} else if op == u8(Opcode.OP_PUSHDATA1) {
			if i >= len(s) { break }
			size := int(s[i])
			i += 1
			if i + size <= len(s) {
				_write_hex_bytes(&b, s[i:i + size])
				i += size
			} else {
				strings.write_string(&b, "[error]")
				break
			}
		} else if op == u8(Opcode.OP_PUSHDATA2) {
			if i + 1 >= len(s) { break }
			size := int(s[i]) | int(s[i + 1]) << 8
			i += 2
			if i + size <= len(s) {
				_write_hex_bytes(&b, s[i:i + size])
				i += size
			} else {
				strings.write_string(&b, "[error]")
				break
			}
		} else if op == u8(Opcode.OP_PUSHDATA4) {
			if i + 3 >= len(s) { break }
			size := int(s[i]) | int(s[i + 1]) << 8 | int(s[i + 2]) << 16 | int(s[i + 3]) << 24
			i += 4
			if i + size <= len(s) {
				_write_hex_bytes(&b, s[i:i + size])
				i += size
			} else {
				strings.write_string(&b, "[error]")
				break
			}
		} else {
			strings.write_string(&b, opcode_name(op))
		}
	}

	return strings.to_string(b)
}

// Write hex-encoded bytes to a string builder.
_write_hex_bytes :: proc(b: ^strings.Builder, data: []byte) {
	hex_chars := [16]byte{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}
	for byte_val in data {
		strings.write_byte(b, hex_chars[byte_val >> 4])
		strings.write_byte(b, hex_chars[byte_val & 0x0f])
	}
}

// Returns true if the script contains only push opcodes.
is_push_only :: proc(s: []byte) -> bool {
	i := 0
	for i < len(s) {
		op := s[i]
		i += 1

		if op == 0x00 {
			// OP_0 is a push opcode
			continue
		} else if op >= 0x01 && op <= 0x4b {
			// Direct push of N bytes
			i += int(op)
		} else if op == u8(Opcode.OP_PUSHDATA1) {
			if i >= len(s) { return false }
			size := int(s[i])
			i += 1 + size
		} else if op == u8(Opcode.OP_PUSHDATA2) {
			if i + 1 >= len(s) { return false }
			size := int(s[i]) | int(s[i + 1]) << 8
			i += 2 + size
		} else if op == u8(Opcode.OP_PUSHDATA4) {
			if i + 3 >= len(s) { return false }
			size := int(s[i]) | int(s[i + 1]) << 8 | int(s[i + 2]) << 16 | int(s[i + 3]) << 24
			i += 4 + size
		} else if op >= u8(Opcode.OP_1NEGATE) && op <= u8(Opcode.OP_16) {
			// OP_1NEGATE and OP_1..OP_16 are push opcodes
			continue
		} else {
			return false
		}

		if i > len(s) { return false }
	}
	return true
}
