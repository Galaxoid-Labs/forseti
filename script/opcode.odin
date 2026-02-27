package script

import "core:fmt"

// Bitcoin script opcodes.
// Data push opcodes 0x01-0x4b push exactly N bytes and are handled
// by the interpreter directly, not as individual enum values.
Opcode :: enum u8 {
	OP_0                   = 0x00,
	// 0x01-0x4b: direct push of N bytes (not enumerated)
	OP_PUSHDATA1           = 0x4c,
	OP_PUSHDATA2           = 0x4d,
	OP_PUSHDATA4           = 0x4e,
	OP_1NEGATE             = 0x4f,
	OP_RESERVED            = 0x50,
	OP_1                   = 0x51,
	OP_2                   = 0x52,
	OP_3                   = 0x53,
	OP_4                   = 0x54,
	OP_5                   = 0x55,
	OP_6                   = 0x56,
	OP_7                   = 0x57,
	OP_8                   = 0x58,
	OP_9                   = 0x59,
	OP_10                  = 0x5a,
	OP_11                  = 0x5b,
	OP_12                  = 0x5c,
	OP_13                  = 0x5d,
	OP_14                  = 0x5e,
	OP_15                  = 0x5f,
	OP_16                  = 0x60,
	OP_NOP                 = 0x61,
	OP_VER                 = 0x62,
	OP_IF                  = 0x63,
	OP_NOTIF               = 0x64,
	OP_VERIF               = 0x65,
	OP_VERNOTIF            = 0x66,
	OP_ELSE                = 0x67,
	OP_ENDIF               = 0x68,
	OP_VERIFY              = 0x69,
	OP_RETURN              = 0x6a,
	OP_TOALTSTACK          = 0x6b,
	OP_FROMALTSTACK        = 0x6c,
	OP_2DROP               = 0x6d,
	OP_2DUP                = 0x6e,
	OP_3DUP                = 0x6f,
	OP_2OVER               = 0x70,
	OP_2ROT                = 0x71,
	OP_2SWAP               = 0x72,
	OP_IFDUP               = 0x73,
	OP_DEPTH               = 0x74,
	OP_DROP                = 0x75,
	OP_DUP                 = 0x76,
	OP_NIP                 = 0x77,
	OP_OVER                = 0x78,
	OP_PICK                = 0x79,
	OP_ROLL                = 0x7a,
	OP_ROT                 = 0x7b,
	OP_SWAP                = 0x7c,
	OP_TUCK                = 0x7d,
	OP_CAT                 = 0x7e, // disabled
	OP_SUBSTR              = 0x7f, // disabled
	OP_LEFT                = 0x80, // disabled
	OP_RIGHT               = 0x81, // disabled
	OP_SIZE                = 0x82,
	OP_INVERT              = 0x83, // disabled
	OP_AND                 = 0x84, // disabled
	OP_OR                  = 0x85, // disabled
	OP_XOR                 = 0x86, // disabled
	OP_EQUAL               = 0x87,
	OP_EQUALVERIFY         = 0x88,
	OP_RESERVED1           = 0x89,
	OP_RESERVED2           = 0x8a,
	OP_1ADD                = 0x8b,
	OP_1SUB                = 0x8c,
	OP_2MUL                = 0x8d, // disabled
	OP_2DIV                = 0x8e, // disabled
	OP_NEGATE              = 0x8f,
	OP_ABS                 = 0x90,
	OP_NOT                 = 0x91,
	OP_0NOTEQUAL           = 0x92,
	OP_ADD                 = 0x93,
	OP_SUB                 = 0x94,
	OP_MUL                 = 0x95, // disabled
	OP_DIV                 = 0x96, // disabled
	OP_MOD                 = 0x97, // disabled
	OP_LSHIFT              = 0x98, // disabled
	OP_RSHIFT              = 0x99, // disabled
	OP_BOOLAND             = 0x9a,
	OP_BOOLOR              = 0x9b,
	OP_NUMEQUAL            = 0x9c,
	OP_NUMEQUALVERIFY      = 0x9d,
	OP_NUMNOTEQUAL         = 0x9e,
	OP_LESSTHAN            = 0x9f,
	OP_GREATERTHAN         = 0xa0,
	OP_LESSTHANOREQUAL     = 0xa1,
	OP_GREATERTHANOREQUAL  = 0xa2,
	OP_MIN                 = 0xa3,
	OP_MAX                 = 0xa4,
	OP_WITHIN              = 0xa5,
	OP_RIPEMD160           = 0xa6,
	OP_SHA1                = 0xa7, // deferred
	OP_SHA256              = 0xa8,
	OP_HASH160             = 0xa9,
	OP_HASH256             = 0xaa,
	OP_CODESEPARATOR       = 0xab,
	OP_CHECKSIG            = 0xac,
	OP_CHECKSIGVERIFY      = 0xad,
	OP_CHECKMULTISIG       = 0xae,
	OP_CHECKMULTISIGVERIFY = 0xaf,
	OP_NOP1                = 0xb0,
	OP_CHECKLOCKTIMEVERIFY = 0xb1, // BIP65
	OP_CHECKSEQUENCEVERIFY = 0xb2, // BIP112
	OP_NOP4                = 0xb3,
	OP_NOP5                = 0xb4,
	OP_NOP6                = 0xb5,
	OP_NOP7                = 0xb6,
	OP_NOP8                = 0xb7,
	OP_NOP9                = 0xb8,
	OP_NOP10               = 0xb9,
	OP_CHECKSIGADD         = 0xba, // BIP342: Tapscript only
	OP_INVALIDOPCODE       = 0xff,
}

// Returns true if the opcode is a data-push opcode (OP_0 through OP_PUSHDATA4).
is_push_opcode :: proc(op: u8) -> bool {
	return op <= u8(Opcode.OP_PUSHDATA4)
}

// Returns true if the opcode is disabled and must cause script failure.
is_disabled_opcode :: proc(op: u8) -> bool {
	#partial switch Opcode(op) {
	case .OP_CAT, .OP_SUBSTR, .OP_LEFT, .OP_RIGHT,
	     .OP_INVERT, .OP_AND, .OP_OR, .OP_XOR,
	     .OP_2MUL, .OP_2DIV,
	     .OP_MUL, .OP_DIV, .OP_MOD, .OP_LSHIFT, .OP_RSHIFT:
		return true
	case:
		return false
	}
}

// Returns true if this opcode counts toward the 201-opcode limit.
is_count_opcode :: proc(op: u8) -> bool {
	return op > u8(Opcode.OP_16)
}

// Returns true if the opcode is an OP_SUCCESS in tapscript (BIP342).
// These opcodes cause immediate script success when encountered during tapscript pre-scan.
is_op_success :: proc(op: u8) -> bool {
	switch op {
	case 0x50, 0x62, 0x7e, 0x7f, 0x80, 0x81, 0x83, 0x84, 0x85, 0x86,
	     0x89, 0x8a, 0x8d, 0x8e, 0x95, 0x96, 0x97, 0x98, 0x99,
	     0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc1, 0xc2, 0xc3,
	     0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc,
	     0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5,
	     0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde,
	     0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
	     0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xf0,
	     0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9,
	     0xfa, 0xfb, 0xfc, 0xfd, 0xfe:
		return true
	case:
		return false
	}
}

// Return Bitcoin Core-compatible string name for an opcode byte.
opcode_name :: proc(op: u8) -> string {
	// Data push opcodes (1-75 bytes)
	if op >= 0x01 && op <= 0x4b {
		return fmt.tprintf("OP_PUSHBYTES_%d", int(op))
	}

	#partial switch Opcode(op) {
	case .OP_0:                   return "0"
	case .OP_PUSHDATA1:           return "OP_PUSHDATA1"
	case .OP_PUSHDATA2:           return "OP_PUSHDATA2"
	case .OP_PUSHDATA4:           return "OP_PUSHDATA4"
	case .OP_1NEGATE:             return "OP_1NEGATE"
	case .OP_RESERVED:            return "OP_RESERVED"
	case .OP_1:                   return "1"
	case .OP_2:                   return "2"
	case .OP_3:                   return "3"
	case .OP_4:                   return "4"
	case .OP_5:                   return "5"
	case .OP_6:                   return "6"
	case .OP_7:                   return "7"
	case .OP_8:                   return "8"
	case .OP_9:                   return "9"
	case .OP_10:                  return "10"
	case .OP_11:                  return "11"
	case .OP_12:                  return "12"
	case .OP_13:                  return "13"
	case .OP_14:                  return "14"
	case .OP_15:                  return "15"
	case .OP_16:                  return "16"
	case .OP_NOP:                 return "OP_NOP"
	case .OP_VER:                 return "OP_VER"
	case .OP_IF:                  return "OP_IF"
	case .OP_NOTIF:               return "OP_NOTIF"
	case .OP_VERIF:               return "OP_VERIF"
	case .OP_VERNOTIF:            return "OP_VERNOTIF"
	case .OP_ELSE:                return "OP_ELSE"
	case .OP_ENDIF:               return "OP_ENDIF"
	case .OP_VERIFY:              return "OP_VERIFY"
	case .OP_RETURN:              return "OP_RETURN"
	case .OP_TOALTSTACK:          return "OP_TOALTSTACK"
	case .OP_FROMALTSTACK:        return "OP_FROMALTSTACK"
	case .OP_2DROP:               return "OP_2DROP"
	case .OP_2DUP:                return "OP_2DUP"
	case .OP_3DUP:                return "OP_3DUP"
	case .OP_2OVER:               return "OP_2OVER"
	case .OP_2ROT:                return "OP_2ROT"
	case .OP_2SWAP:               return "OP_2SWAP"
	case .OP_IFDUP:               return "OP_IFDUP"
	case .OP_DEPTH:               return "OP_DEPTH"
	case .OP_DROP:                return "OP_DROP"
	case .OP_DUP:                 return "OP_DUP"
	case .OP_NIP:                 return "OP_NIP"
	case .OP_OVER:                return "OP_OVER"
	case .OP_PICK:                return "OP_PICK"
	case .OP_ROLL:                return "OP_ROLL"
	case .OP_ROT:                 return "OP_ROT"
	case .OP_SWAP:                return "OP_SWAP"
	case .OP_TUCK:                return "OP_TUCK"
	case .OP_CAT:                 return "OP_CAT"
	case .OP_SUBSTR:              return "OP_SUBSTR"
	case .OP_LEFT:                return "OP_LEFT"
	case .OP_RIGHT:               return "OP_RIGHT"
	case .OP_SIZE:                return "OP_SIZE"
	case .OP_INVERT:              return "OP_INVERT"
	case .OP_AND:                 return "OP_AND"
	case .OP_OR:                  return "OP_OR"
	case .OP_XOR:                 return "OP_XOR"
	case .OP_EQUAL:               return "OP_EQUAL"
	case .OP_EQUALVERIFY:         return "OP_EQUALVERIFY"
	case .OP_RESERVED1:           return "OP_RESERVED1"
	case .OP_RESERVED2:           return "OP_RESERVED2"
	case .OP_1ADD:                return "OP_1ADD"
	case .OP_1SUB:                return "OP_1SUB"
	case .OP_2MUL:                return "OP_2MUL"
	case .OP_2DIV:                return "OP_2DIV"
	case .OP_NEGATE:              return "OP_NEGATE"
	case .OP_ABS:                 return "OP_ABS"
	case .OP_NOT:                 return "OP_NOT"
	case .OP_0NOTEQUAL:           return "OP_0NOTEQUAL"
	case .OP_ADD:                 return "OP_ADD"
	case .OP_SUB:                 return "OP_SUB"
	case .OP_MUL:                 return "OP_MUL"
	case .OP_DIV:                 return "OP_DIV"
	case .OP_MOD:                 return "OP_MOD"
	case .OP_LSHIFT:              return "OP_LSHIFT"
	case .OP_RSHIFT:              return "OP_RSHIFT"
	case .OP_BOOLAND:             return "OP_BOOLAND"
	case .OP_BOOLOR:              return "OP_BOOLOR"
	case .OP_NUMEQUAL:            return "OP_NUMEQUAL"
	case .OP_NUMEQUALVERIFY:      return "OP_NUMEQUALVERIFY"
	case .OP_NUMNOTEQUAL:         return "OP_NUMNOTEQUAL"
	case .OP_LESSTHAN:            return "OP_LESSTHAN"
	case .OP_GREATERTHAN:         return "OP_GREATERTHAN"
	case .OP_LESSTHANOREQUAL:     return "OP_LESSTHANOREQUAL"
	case .OP_GREATERTHANOREQUAL:  return "OP_GREATERTHANOREQUAL"
	case .OP_MIN:                 return "OP_MIN"
	case .OP_MAX:                 return "OP_MAX"
	case .OP_WITHIN:              return "OP_WITHIN"
	case .OP_RIPEMD160:           return "OP_RIPEMD160"
	case .OP_SHA1:                return "OP_SHA1"
	case .OP_SHA256:              return "OP_SHA256"
	case .OP_HASH160:             return "OP_HASH160"
	case .OP_HASH256:             return "OP_HASH256"
	case .OP_CODESEPARATOR:       return "OP_CODESEPARATOR"
	case .OP_CHECKSIG:            return "OP_CHECKSIG"
	case .OP_CHECKSIGVERIFY:      return "OP_CHECKSIGVERIFY"
	case .OP_CHECKMULTISIG:       return "OP_CHECKMULTISIG"
	case .OP_CHECKMULTISIGVERIFY: return "OP_CHECKMULTISIGVERIFY"
	case .OP_NOP1:                return "OP_NOP1"
	case .OP_CHECKLOCKTIMEVERIFY: return "OP_CHECKLOCKTIMEVERIFY"
	case .OP_CHECKSEQUENCEVERIFY: return "OP_CHECKSEQUENCEVERIFY"
	case .OP_NOP4:                return "OP_NOP4"
	case .OP_NOP5:                return "OP_NOP5"
	case .OP_NOP6:                return "OP_NOP6"
	case .OP_NOP7:                return "OP_NOP7"
	case .OP_NOP8:                return "OP_NOP8"
	case .OP_NOP9:                return "OP_NOP9"
	case .OP_NOP10:               return "OP_NOP10"
	case .OP_CHECKSIGADD:         return "OP_CHECKSIGADD"
	case .OP_INVALIDOPCODE:       return "OP_INVALIDOPCODE"
	case:
		return fmt.tprintf("OP_UNKNOWN_%02x", op)
	}
}

// For OP_1 through OP_16, returns the small integer value (1-16).
// For OP_0 returns 0. Returns -1 if not a small integer opcode.
opcode_small_int :: proc(op: u8) -> int {
	if op == u8(Opcode.OP_0) { return 0 }
	if op >= u8(Opcode.OP_1) && op <= u8(Opcode.OP_16) {
		return int(op) - int(Opcode.OP_1) + 1
	}
	return -1
}
