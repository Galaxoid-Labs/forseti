package script

import "../crypto"
import "../wire"
import "core:crypto/legacy/sha1"

// --- Script errors ---

Script_Error :: enum {
	None,
	// Parse/structure errors
	Script_Too_Large,
	Push_Size,
	Op_Count,
	Stack_Size,
	Invalid_Stack_Operation,
	Disabled_Opcode,
	Unbalanced_Conditional,
	Negative_Locktime,
	Unsatisfied_Locktime,
	// Evaluation errors
	Script_Num_Overflow,
	Minimal_Data,
	Minimal_If,
	Op_Return,
	Verify,
	Equal_Verify,
	Num_Equal_Verify,
	Check_Sig_Verify,
	Check_Multisig_Verify,
	// Signature errors
	Sig_Hash_Type,
	Sig_DER,
	Sig_High_S,
	Sig_Null_Fail,
	Sig_Null_Dummy,
	Pub_Key_Type,
	// Script policy
	Sig_Push_Only,
	Clean_Stack,
	// Witness errors
	Witness_Program_Empty,
	Witness_Program_Mismatch,
	Witness_Program_Wrong_Length,
	Witness_Malleated,
	Witness_Malleated_P2SH,
	Witness_Unexpected,
	Witness_Pub_Key_Compressed,
	Discourage_Upgradable_Witness,
	// Taproot errors
	Taproot_Wrong_Control_Size,
	Taproot_Invalid_Control_Block,
	Taproot_Wrong_Sig_Size,
	Taproot_Sig_Hash_Type,
	Taproot_Checkmultisig_Disabled,
	Taproot_Op_Success,
	Taproot_Empty_Pubkey,
	Taproot_Sigops_Budget,
	Eval_False,
}

// --- Constants ---

MAX_SCRIPT_SIZE     :: 10_000
MAX_OPS_PER_SCRIPT  :: 201
MAX_PUBKEYS_PER_MULTISIG :: 20
MAX_SCRIPT_ELEMENT_SIZE  :: 520

// Sighash types
SIGHASH_ALL          :: u32(1)
SIGHASH_NONE         :: u32(2)
SIGHASH_SINGLE       :: u32(3)
SIGHASH_ANYONECANPAY :: u32(0x80)
SIGHASH_DEFAULT      :: u32(0x00) // Taproot: equivalent to SIGHASH_ALL

// Taproot constants
TAPROOT_LEAF_TAPSCRIPT :: u8(0xc0)
TAPROOT_LEAF_MASK      :: u8(0xfe)
TAPROOT_ANNEX_TAG      :: u8(0x50)
TAPROOT_CONTROL_BASE_SIZE :: 33 // 1 byte leaf_version + 32 bytes internal key
TAPROOT_CONTROL_NODE_SIZE :: 32 // merkle proof node size
TAPROOT_CONTROL_MAX_NODE_COUNT :: 128

// Script execution mode
Exec_Mode :: enum {
	Legacy,
	Witness_V0,
	Tapscript,
}

// Locktime/sequence constants
SEQUENCE_LOCKTIME_DISABLE_FLAG :: u32(1 << 31)
SEQUENCE_LOCKTIME_TYPE_FLAG    :: u32(1 << 22)
SEQUENCE_LOCKTIME_MASK         :: u32(0x0000ffff)
LOCKTIME_THRESHOLD             :: u32(500_000_000)

// Type aliases
Hash256 :: crypto.Hash256

// --- Sighash cache for BIP143 intermediate hashes ---

// Caches hashPrevouts, hashSequence, and hashOutputs so they are computed
// once per transaction instead of once per input. Without this, transactions
// with many inputs (e.g. 996) exhaust the temp allocator arena.
Sighash_Cache :: struct {
	// BIP143 (segwit v0) — double SHA256
	hash_prevouts:   Hash256,
	hash_sequence:   Hash256,
	hash_outputs:    Hash256,
	has_prevouts:    bool,
	has_sequence:    bool,
	has_outputs:     bool,
	// BIP341 (Taproot) — single SHA256
	tap_prevouts:      Hash256,
	tap_amounts:       Hash256,
	tap_script_pubkeys: Hash256,
	tap_sequences:     Hash256,
	tap_outputs:       Hash256,
	has_tap_prevouts:      bool,
	has_tap_amounts:       bool,
	has_tap_script_pubkeys: bool,
	has_tap_sequences:     bool,
	has_tap_outputs:       bool,
}

// Eagerly populate all sighash cache fields (BIP143 + BIP341).
// Called once per tx before dispatching parallel script verification.
// Workers read the fully-populated cache without synchronization.
sighash_cache_precompute :: proc(cache: ^Sighash_Cache, tx: ^wire.Tx, spent_outputs: []wire.Tx_Out) {
	// BIP143 (double SHA256)
	{
		pw := wire.writer_init(context.temp_allocator)
		for i in 0 ..< len(tx.inputs) {
			wire.serialize_outpoint(&pw, &tx.inputs[i].previous_output)
		}
		cache.hash_prevouts = crypto.sha256d(wire.writer_bytes(&pw))
		cache.has_prevouts = true
	}
	{
		sw := wire.writer_init(context.temp_allocator)
		for i in 0 ..< len(tx.inputs) {
			wire.write_u32le(&sw, tx.inputs[i].sequence)
		}
		cache.hash_sequence = crypto.sha256d(wire.writer_bytes(&sw))
		cache.has_sequence = true
	}
	{
		ow := wire.writer_init(context.temp_allocator)
		for i in 0 ..< len(tx.outputs) {
			wire.serialize_tx_out(&ow, &tx.outputs[i])
		}
		cache.hash_outputs = crypto.sha256d(wire.writer_bytes(&ow))
		cache.has_outputs = true
	}

	// BIP341 (single SHA256) — use existing Taproot helpers
	cache.tap_prevouts = _sha256_prevouts(tx)
	cache.has_tap_prevouts = true

	cache.tap_amounts = _sha256_amounts(spent_outputs)
	cache.has_tap_amounts = true

	cache.tap_script_pubkeys = _sha256_script_pubkeys(spent_outputs)
	cache.has_tap_script_pubkeys = true

	cache.tap_sequences = _sha256_sequences(tx)
	cache.has_tap_sequences = true

	cache.tap_outputs = _sha256_outputs(tx)
	cache.has_tap_outputs = true
}

// --- Script Verifier ---

Script_Verifier :: struct {
	tx:             ^wire.Tx,
	input_idx:      int,
	amount:         i64,           // value of the output being spent (for SegWit sighash)
	flags:          Verify_Flags,
	spent_outputs:  []wire.Tx_Out, // all spent outputs (for Taproot sighash)
	sighash_cache:  ^Sighash_Cache, // optional, shared across inputs of same tx
}

// Top-level script verification: 4-phase evaluation.
verify_script :: proc(
	verifier: ^Script_Verifier,
	script_sig: []byte,
	script_pubkey: []byte,
	witness: [][]byte,
) -> Script_Error {
	flags := verifier.flags

	// Check push-only for scriptSig if required
	if .Sig_Push_Only in flags {
		if !is_push_only(script_sig) {
			return .Sig_Push_Only
		}
	}

	// Phase 1: Execute scriptSig
	stack := stack_init(context.temp_allocator)
	err := execute_script(verifier, script_sig, &stack)
	if err != nil { return err }

	// Copy stack for P2SH evaluation
	stack_copy: Script_Stack
	has_p2sh := .P2SH in flags && classify_script(script_pubkey) == .P2SH
	if has_p2sh {
		stack_copy = stack_init(context.temp_allocator)
		for item in stack.items {
			stack_push(&stack_copy, item)
		}
	}

	// Phase 2: Execute scriptPubKey
	err = execute_script(verifier, script_pubkey, &stack)
	if err != nil { return err }

	if stack_size(&stack) == 0 { return .Eval_False }
	top := stack_top(&stack) or_return
	if !stack_to_bool(top) { return .Eval_False }

	// Phase 4: SegWit evaluation (before P2SH so P2SH-wrapped witness works)
	wit_version, wit_program, is_wit := is_witness_program(script_pubkey)
	if .Witness in flags && is_wit {
		// Direct witness program
		if len(script_sig) != 0 { return .Witness_Malleated }
		err = verify_witness_program(verifier, witness, wit_version, wit_program)
		if err != nil { return err }
		// Clean stack after witness: set stack to single true
		clear(&stack.items)
		stack_push(&stack, bool_to_stack(true, context.temp_allocator))
	}

	// Phase 3: P2SH evaluation
	if has_p2sh {
		// scriptSig must be push-only for P2SH
		if !is_push_only(script_sig) { return .Sig_Push_Only }

		// The serialized script is the top of the copied stack
		if stack_size(&stack_copy) == 0 { return .Eval_False }
		serialized_script := stack_pop(&stack_copy) or_return

		// Execute the deserialized script with the remaining stack
		err = execute_script(verifier, serialized_script, &stack_copy)
		if err != nil { return err }

		if stack_size(&stack_copy) == 0 { return .Eval_False }
		p2sh_top := stack_top(&stack_copy) or_return
		if !stack_to_bool(p2sh_top) { return .Eval_False }

		// Check for P2SH-wrapped witness program
		if .Witness in flags {
			wit_ver, wit_prog, is_p2sh_wit := is_witness_program(serialized_script)
			if is_p2sh_wit {
				// scriptSig must be exactly a single push of the witness program
				if !_is_single_push(script_sig, serialized_script) {
					return .Witness_Malleated_P2SH
				}
				err = verify_witness_program(verifier, witness, wit_ver, wit_prog, is_p2sh = true)
				if err != nil { return err }
				// Clean stack after witness
				clear(&stack_copy.items)
				stack_push(&stack_copy, bool_to_stack(true, context.temp_allocator))
			}
		}

		// Use the P2SH stack for clean stack check
		stack = stack_copy
	}

	// Witness: fail if witness data present but no witness program was matched
	if .Witness in flags && !is_wit && !has_p2sh {
		if witness != nil && len(witness) > 0 {
			return .Witness_Unexpected
		}
	}

	// Clean stack check
	if .Clean_Stack in flags {
		if stack_size(&stack) != 1 {
			return .Clean_Stack
		}
	}

	return nil
}

// Check if script_sig is exactly one push that produces the given data.
_is_single_push :: proc(script_sig: []byte, data: []byte) -> bool {
	if len(data) == 0 { return len(script_sig) == 1 && script_sig[0] == 0x00 }
	n := len(data)
	if n <= 0x4b {
		return len(script_sig) == n + 1 && int(script_sig[0]) == n && _bytes_equal(script_sig[1:], data)
	}
	if n <= 0xff {
		return len(script_sig) == n + 2 && script_sig[0] == u8(Opcode.OP_PUSHDATA1) && int(script_sig[1]) == n && _bytes_equal(script_sig[2:], data)
	}
	if n <= 0xffff {
		return len(script_sig) == n + 3 && script_sig[0] == u8(Opcode.OP_PUSHDATA2) && (int(script_sig[1]) | int(script_sig[2]) << 8) == n && _bytes_equal(script_sig[3:], data)
	}
	return false
}

// Verify a witness program (v0 P2WPKH/P2WSH, v1 Taproot).
verify_witness_program :: proc(
	verifier: ^Script_Verifier,
	witness: [][]byte,
	version: int,
	program: []byte,
	is_p2sh: bool = false,
) -> Script_Error {
	if version == 0 {
		if len(program) == 20 {
			// P2WPKH
			if witness == nil || len(witness) != 2 { return .Witness_Program_Mismatch }

			// Check compressed pubkey requirement
			if .Witness_Pub_Key_Compressed in verifier.flags {
				if !_is_compressed_pubkey(witness[1]) {
					return .Witness_Pub_Key_Compressed
				}
			}

			// Build P2PKH script from program: OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
			p2pkh_script := make([]byte, 25, context.temp_allocator)
			p2pkh_script[0] = u8(Opcode.OP_DUP)
			p2pkh_script[1] = u8(Opcode.OP_HASH160)
			p2pkh_script[2] = 0x14
			copy(p2pkh_script[3:23], program)
			p2pkh_script[23] = u8(Opcode.OP_EQUALVERIFY)
			p2pkh_script[24] = u8(Opcode.OP_CHECKSIG)

			stack := stack_init(context.temp_allocator)
			for item in witness {
				stack_push(&stack, item)
			}
			return execute_script(verifier, p2pkh_script, &stack, is_witness = true)
		} else if len(program) == 32 {
			// P2WSH
			if witness == nil || len(witness) == 0 { return .Witness_Program_Empty }

			// Last witness item is the script
			witness_script := witness[len(witness) - 1]
			if len(witness_script) > MAX_SCRIPT_SIZE { return .Script_Too_Large }

			// Verify hash
			script_hash := crypto.sha256_hash(witness_script)
			program_hash: Hash256
			copy(program_hash[:], program)
			if script_hash != program_hash { return .Witness_Program_Mismatch }

			stack := stack_init(context.temp_allocator)
			for i in 0 ..< len(witness) - 1 {
				if len(witness[i]) > MAX_SCRIPT_ELEMENT_SIZE { return .Push_Size }
				stack_push(&stack, witness[i])
			}
			return execute_script(verifier, witness_script, &stack, is_witness = true)
		} else {
			return .Witness_Program_Wrong_Length
		}
	} else if version == 1 && len(program) == 32 && !is_p2sh {
		// Taproot (BIP341) — native segwit v1 with exactly 32-byte program
		return verify_taproot(verifier, witness, program)
	} else {
		// Future witness versions/lengths — succeed unless discouraged
		if .Discourage_Upgradable_Witness in verifier.flags {
			return .Discourage_Upgradable_Witness
		}
		return nil
	}
}

// --- Main script execution loop ---

execute_script :: proc(
	verifier: ^Script_Verifier,
	script: []byte,
	stack: ^Script_Stack,
	alt_stack: ^Script_Stack = nil,
	is_witness: bool = false,
	exec_mode: Exec_Mode = .Legacy,
	tapleaf_hash: ^Hash256 = nil,
	codesep_pos: ^u32 = nil,
	sigops_budget: ^int = nil,
) -> Script_Error {
	// Tapscript has no 10k script size limit
	if exec_mode != .Tapscript && len(script) > MAX_SCRIPT_SIZE { return .Script_Too_Large }

	flags := verifier.flags
	require_minimal := .Minimal_Data in flags

	// Condition stack for IF/ELSE/ENDIF nesting
	cond_stack: [dynamic]bool
	defer delete(cond_stack)

	// Alt stack (create if not provided)
	_alt: Script_Stack
	alt := alt_stack
	if alt == nil {
		_alt = stack_init(context.temp_allocator)
		alt = &_alt
	}

	op_count := 0
	code_sep_pos := 0 // position of last OP_CODESEPARATOR (byte offset for legacy)
	opcode_idx := 0   // opcode index for BIP342 code_separator_pos

	pos := 0
	for pos < len(script) {
		cur_opcode_idx := opcode_idx
		opcode_idx += 1

		op := script[pos]
		pos += 1

		// Determine if we're currently executing (all conditions true)
		executing := true
		for c in cond_stack {
			if !c { executing = false; break }
		}

		// Data push: 0x01-0x4b (push N bytes directly)
		if op >= 0x01 && op <= 0x4b {
			n := int(op)
			if pos + n > len(script) { return .Script_Too_Large }
			if executing {
				stack_push(stack, script[pos:pos + n])
			}
			pos += n
			continue
		}

		// Handle remaining push opcodes
		#partial switch Opcode(op) {
		case .OP_0:
			if executing { stack_push(stack, nil) }
			continue
		case .OP_PUSHDATA1:
			if pos >= len(script) { return .Script_Too_Large }
			n := int(script[pos])
			pos += 1
			if pos + n > len(script) { return .Script_Too_Large }
			if require_minimal && n <= 0x4b {
				return .Minimal_Data
			}
			if executing { stack_push(stack, script[pos:pos + n]) }
			pos += n
			continue
		case .OP_PUSHDATA2:
			if pos + 1 >= len(script) { return .Script_Too_Large }
			n := int(script[pos]) | int(script[pos + 1]) << 8
			pos += 2
			if pos + n > len(script) { return .Script_Too_Large }
			if require_minimal && n <= 0xff {
				return .Minimal_Data
			}
			if executing { stack_push(stack, script[pos:pos + n]) }
			pos += n
			continue
		case .OP_PUSHDATA4:
			if pos + 3 >= len(script) { return .Script_Too_Large }
			n := int(script[pos]) | int(script[pos + 1]) << 8 | int(script[pos + 2]) << 16 | int(script[pos + 3]) << 24
			pos += 4
			if pos + n > len(script) { return .Script_Too_Large }
			if require_minimal && n <= 0xffff {
				return .Minimal_Data
			}
			if executing { stack_push(stack, script[pos:pos + n]) }
			pos += n
			continue
		case .OP_1NEGATE:
			if executing { stack_push(stack, script_num_encode(-1, context.temp_allocator)) }
			continue
		case .OP_1, .OP_2, .OP_3, .OP_4, .OP_5, .OP_6, .OP_7, .OP_8,
		     .OP_9, .OP_10, .OP_11, .OP_12, .OP_13, .OP_14, .OP_15, .OP_16:
			if executing {
				val := opcode_small_int(op)
				stack_push(stack, script_num_encode(i64(val), context.temp_allocator))
			}
			continue
		case:
			// Not a push opcode, fall through to main dispatch
		}

		// Disabled opcodes always fail (even in non-executing branches)
		if is_disabled_opcode(op) {
			return .Disabled_Opcode
		}

		// Count non-push opcodes (tapscript uses sigops budget instead)
		if is_count_opcode(op) {
			op_count += 1
			if exec_mode != .Tapscript && op_count > MAX_OPS_PER_SCRIPT {
				return .Op_Count
			}
		}

		// If not executing, only handle flow control
		if !executing {
			#partial switch Opcode(op) {
			case .OP_IF, .OP_NOTIF:
				append(&cond_stack, false)
			case .OP_ELSE:
				if len(cond_stack) == 0 { return .Unbalanced_Conditional }
				cond_stack[len(cond_stack) - 1] = !cond_stack[len(cond_stack) - 1]
			case .OP_ENDIF:
				if len(cond_stack) == 0 { return .Unbalanced_Conditional }
				pop(&cond_stack)
			case:
				// Skip non-flow-control opcodes in non-executing branch
			}
			continue
		}

		// === MAIN OPCODE DISPATCH (executing branch) ===
		#partial switch Opcode(op) {

		// --- Flow control ---
		case .OP_NOP:
			// do nothing

		case .OP_VER:
			return .Verify // OP_VER causes script to fail

		case .OP_IF, .OP_NOTIF:
			val := false
			top_data := stack_pop(stack) or_return
			if .Minimal_If in flags {
				if len(top_data) > 1 || (len(top_data) == 1 && top_data[0] != 1) {
					return .Minimal_If
				}
			}
			val = stack_to_bool(top_data)
			if Opcode(op) == .OP_NOTIF { val = !val }
			append(&cond_stack, val)

		case .OP_VERIF, .OP_VERNOTIF:
			return .Verify // Always fail

		case .OP_ELSE:
			if len(cond_stack) == 0 { return .Unbalanced_Conditional }
			cond_stack[len(cond_stack) - 1] = !cond_stack[len(cond_stack) - 1]

		case .OP_ENDIF:
			if len(cond_stack) == 0 { return .Unbalanced_Conditional }
			pop(&cond_stack)

		case .OP_VERIFY:
			top_data := stack_top(stack) or_return
			if !stack_to_bool(top_data) { return .Verify }
			stack_pop(stack)

		case .OP_RETURN:
			return .Op_Return

		// --- Alt stack ---
		case .OP_TOALTSTACK:
			val := stack_pop(stack) or_return
			stack_push_no_copy(alt, val)

		case .OP_FROMALTSTACK:
			val := stack_pop(alt) or_return
			stack_push_no_copy(stack, val)

		// --- Stack manipulation ---
		case .OP_2DROP:
			stack_pop(stack) or_return
			stack_pop(stack) or_return

		case .OP_2DUP:
			if stack_size(stack) < 2 { return .Invalid_Stack_Operation }
			stack_dup_n(stack, 2) or_return

		case .OP_3DUP:
			if stack_size(stack) < 3 { return .Invalid_Stack_Operation }
			stack_dup_n(stack, 3) or_return

		case .OP_2OVER:
			if stack_size(stack) < 4 { return .Invalid_Stack_Operation }
			v1 := stack_top(stack, -4) or_return
			v2 := stack_top(stack, -3) or_return
			stack_push(stack, v1)
			stack_push(stack, v2)

		case .OP_2ROT:
			if stack_size(stack) < 6 { return .Invalid_Stack_Operation }
			v1 := stack_top(stack, -6) or_return
			v2 := stack_top(stack, -5) or_return
			stack_remove(stack, -6) or_return
			stack_remove(stack, -5) or_return // was -6 is now -5
			stack_push(stack, v1)
			stack_push(stack, v2)

		case .OP_2SWAP:
			if stack_size(stack) < 4 { return .Invalid_Stack_Operation }
			stack_swap(stack, -4, -2) or_return
			stack_swap(stack, -3, -1) or_return

		case .OP_IFDUP:
			top_data := stack_top(stack) or_return
			if stack_to_bool(top_data) {
				stack_push(stack, top_data)
			}

		case .OP_DEPTH:
			stack_push(stack, script_num_encode(i64(stack_size(stack)), context.temp_allocator))

		case .OP_DROP:
			stack_pop(stack) or_return

		case .OP_DUP:
			top_data := stack_top(stack) or_return
			stack_push(stack, top_data)

		case .OP_NIP:
			if stack_size(stack) < 2 { return .Invalid_Stack_Operation }
			stack_remove(stack, -2) or_return

		case .OP_OVER:
			v := stack_top(stack, -2) or_return
			stack_push(stack, v)

		case .OP_PICK:
			n_data := stack_pop(stack) or_return
			n := script_num_decode(n_data, require_minimal = require_minimal) or_return
			if n < 0 { return .Invalid_Stack_Operation }
			v := stack_top(stack, -int(n) - 1) or_return
			stack_push(stack, v)

		case .OP_ROLL:
			n_data := stack_pop(stack) or_return
			n := script_num_decode(n_data, require_minimal = require_minimal) or_return
			if n < 0 { return .Invalid_Stack_Operation }
			v := stack_top(stack, -int(n) - 1) or_return
			clone := make([]byte, len(v), context.temp_allocator)
			copy(clone, v)
			stack_remove(stack, -int(n) - 1) or_return
			stack_push_no_copy(stack, clone)

		case .OP_ROT:
			if stack_size(stack) < 3 { return .Invalid_Stack_Operation }
			// Move third-from-top to top
			v := stack_top(stack, -3) or_return
			clone := make([]byte, len(v), context.temp_allocator)
			copy(clone, v)
			stack_remove(stack, -3) or_return
			stack_push_no_copy(stack, clone)

		case .OP_SWAP:
			if stack_size(stack) < 2 { return .Invalid_Stack_Operation }
			stack_swap(stack, -2, -1) or_return

		case .OP_TUCK:
			if stack_size(stack) < 2 { return .Invalid_Stack_Operation }
			top_data := stack_top(stack) or_return
			stack_insert(stack, -2, top_data) or_return

		// --- Splice ops (only OP_SIZE is enabled) ---
		case .OP_SIZE:
			top_data := stack_top(stack) or_return
			stack_push(stack, script_num_encode(i64(len(top_data)), context.temp_allocator))

		// --- Bitwise/equality ---
		case .OP_EQUAL, .OP_EQUALVERIFY:
			a := stack_pop(stack) or_return
			b := stack_pop(stack) or_return
			equal := _bytes_equal(a, b)
			stack_push(stack, bool_to_stack(equal, context.temp_allocator))
			if Opcode(op) == .OP_EQUALVERIFY {
				if !equal { return .Equal_Verify }
				stack_pop(stack)
			}

		case .OP_RESERVED, .OP_RESERVED1, .OP_RESERVED2:
			return .Verify // reserved opcodes fail

		// --- Arithmetic ---
		case .OP_1ADD:
			_unary_arith(stack, proc(a: i64) -> i64 { return a + 1 }, require_minimal) or_return
		case .OP_1SUB:
			_unary_arith(stack, proc(a: i64) -> i64 { return a - 1 }, require_minimal) or_return
		case .OP_NEGATE:
			_unary_arith(stack, proc(a: i64) -> i64 { return -a }, require_minimal) or_return
		case .OP_ABS:
			_unary_arith(stack, proc(a: i64) -> i64 { return a if a >= 0 else -a }, require_minimal) or_return
		case .OP_NOT:
			_unary_arith(stack, proc(a: i64) -> i64 { return 1 if a == 0 else 0 }, require_minimal) or_return
		case .OP_0NOTEQUAL:
			_unary_arith(stack, proc(a: i64) -> i64 { return 0 if a == 0 else 1 }, require_minimal) or_return

		case .OP_ADD:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return a + b }, require_minimal) or_return
		case .OP_SUB:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return a - b }, require_minimal) or_return
		case .OP_BOOLAND:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a != 0 && b != 0 else 0 }, require_minimal) or_return
		case .OP_BOOLOR:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a != 0 || b != 0 else 0 }, require_minimal) or_return
		case .OP_NUMEQUAL:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a == b else 0 }, require_minimal) or_return
		case .OP_NUMEQUALVERIFY:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a == b else 0 }, require_minimal) or_return
			top_data := stack_top(stack) or_return
			if !stack_to_bool(top_data) { return .Num_Equal_Verify }
			stack_pop(stack)
		case .OP_NUMNOTEQUAL:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a != b else 0 }, require_minimal) or_return
		case .OP_LESSTHAN:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a < b else 0 }, require_minimal) or_return
		case .OP_GREATERTHAN:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a > b else 0 }, require_minimal) or_return
		case .OP_LESSTHANOREQUAL:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a <= b else 0 }, require_minimal) or_return
		case .OP_GREATERTHANOREQUAL:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return 1 if a >= b else 0 }, require_minimal) or_return
		case .OP_MIN:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return a if a < b else b }, require_minimal) or_return
		case .OP_MAX:
			_binary_arith(stack, proc(a, b: i64) -> i64 { return a if a > b else b }, require_minimal) or_return

		case .OP_WITHIN:
			// a b c WITHIN -> (b <= a < c)
			c_data := stack_pop(stack) or_return
			b_data := stack_pop(stack) or_return
			a_data := stack_pop(stack) or_return
			a := script_num_decode(a_data, require_minimal = require_minimal) or_return
			b := script_num_decode(b_data, require_minimal = require_minimal) or_return
			c := script_num_decode(c_data, require_minimal = require_minimal) or_return
			result := b <= a && a < c
			stack_push(stack, bool_to_stack(result, context.temp_allocator))

		// --- Crypto hashes ---
		case .OP_RIPEMD160:
			data := stack_pop(stack) or_return
			hash := crypto.ripemd160(data)
			stack_push(stack, hash[:])

		case .OP_SHA1:
			data := stack_pop(stack) or_return
			sha1_ctx: sha1.Context
			sha1.init(&sha1_ctx)
			sha1.update(&sha1_ctx, data)
			sha1_hash: [20]byte
			sha1.final(&sha1_ctx, sha1_hash[:])
			stack_push(stack, sha1_hash[:])

		case .OP_SHA256:
			data := stack_pop(stack) or_return
			hash := crypto.sha256_hash(data)
			stack_push(stack, hash[:])

		case .OP_HASH160:
			data := stack_pop(stack) or_return
			hash := crypto.hash160(data)
			stack_push(stack, hash[:])

		case .OP_HASH256:
			data := stack_pop(stack) or_return
			hash := crypto.sha256d(data)
			stack_push(stack, hash[:])

		// --- Signature operations ---
		case .OP_CODESEPARATOR:
			code_sep_pos = pos // byte offset for legacy FindAndDelete
			if codesep_pos != nil {
				codesep_pos^ = u32(cur_opcode_idx) // BIP342: opcode index, not byte offset
			}

		case .OP_CHECKSIG, .OP_CHECKSIGVERIFY:
			pubkey_data := stack_pop(stack) or_return
			sig_data := stack_pop(stack) or_return

			success := false

			if exec_mode == .Tapscript {
				// Tapscript Schnorr CHECKSIG (BIP342)
				success = _tapscript_checksig(verifier, pubkey_data, sig_data, tapleaf_hash, codesep_pos, sigops_budget) or_return
			} else {
				// Legacy/SegWit v0 ECDSA CHECKSIG
				if len(sig_data) > 0 {
					hash_type := u32(sig_data[len(sig_data) - 1])
					sig_bytes := sig_data[:len(sig_data) - 1]

					if .DER_Sig in flags {
						if !is_valid_signature_encoding(sig_data) {
							return .Sig_DER
						}
					}
					if .Low_S in flags {
						if !_check_low_s(sig_bytes) {
							return .Sig_High_S
						}
					}
					if .Strict_Enc in flags {
						if !check_pubkey_encoding(pubkey_data, flags) {
							return .Pub_Key_Type
						}
					}

					sub_script := script[code_sep_pos:]
					// FindAndDelete: remove signature from subscript for legacy sighash
					if !is_witness {
						sub_script = _find_and_delete(sub_script, sig_data)
					}
					sighash: Hash256
					if is_witness {
						sighash = compute_sighash_witness_v0(verifier.tx, verifier.input_idx, sub_script, verifier.amount, hash_type, verifier.sighash_cache)
					} else {
						sighash = compute_sighash_legacy(verifier.tx, verifier.input_idx, sub_script, hash_type)
					}

					success = crypto.verify_ecdsa(pubkey_data, sig_bytes, sighash)
				} else {
					if .Strict_Enc in flags {
						if !check_pubkey_encoding(pubkey_data, flags) {
							return .Pub_Key_Type
						}
					}
				}

				if !success && .Null_Fail in flags && len(sig_data) > 0 {
					return .Sig_Null_Fail
				}
			}

			stack_push(stack, bool_to_stack(success, context.temp_allocator))

			if Opcode(op) == .OP_CHECKSIGVERIFY {
				if !success { return .Check_Sig_Verify }
				stack_pop(stack)
			}

		case .OP_CHECKSIGADD:
			if exec_mode != .Tapscript {
				return .Disabled_Opcode
			}
			// BIP342: pop pubkey, pop num, pop sig
			pubkey_data := stack_pop(stack) or_return
			n_data := stack_pop(stack) or_return
			sig_data := stack_pop(stack) or_return

			n := script_num_decode(n_data, max_len = 5, require_minimal = require_minimal) or_return

			success := _tapscript_checksig(verifier, pubkey_data, sig_data, tapleaf_hash, codesep_pos, sigops_budget) or_return
			if success {
				n += 1
			}
			stack_push(stack, script_num_encode(n, context.temp_allocator))

		case .OP_CHECKMULTISIG, .OP_CHECKMULTISIGVERIFY:
			// Disabled in tapscript
			if exec_mode == .Tapscript {
				return .Taproot_Checkmultisig_Disabled
			}
			// Read N (number of public keys)
			n_data := stack_pop(stack) or_return
			n_keys := script_num_decode(n_data, require_minimal = require_minimal) or_return
			if n_keys < 0 || n_keys > MAX_PUBKEYS_PER_MULTISIG {
				return .Op_Count
			}
			op_count += int(n_keys)
			if op_count > MAX_OPS_PER_SCRIPT { return .Op_Count }

			// Read public keys
			pubkeys := make([][]byte, int(n_keys), context.temp_allocator)
			for i in 0 ..< int(n_keys) {
				pubkeys[i] = stack_pop(stack) or_return
			}

			// Read M (number of required signatures)
			m_data := stack_pop(stack) or_return
			n_sigs := script_num_decode(m_data, require_minimal = require_minimal) or_return
			if n_sigs < 0 || n_sigs > n_keys {
				return .Op_Count
			}

			// Read signatures
			sigs := make([][]byte, int(n_sigs), context.temp_allocator)
			for i in 0 ..< int(n_sigs) {
				sigs[i] = stack_pop(stack) or_return
			}

			// Pop dummy element (Bitcoin bug — off-by-one in original impl)
			dummy := stack_pop(stack) or_return
			if .Null_Dummy in flags && len(dummy) > 0 {
				return .Sig_Null_Dummy
			}

			sub_script := script[code_sep_pos:]

			// FindAndDelete: remove all signatures from subscript for legacy sighash.
			// Bitcoin Core does this before the verification loop.
			if !is_witness {
				for si in 0 ..< int(n_sigs) {
					sub_script = _find_and_delete(sub_script, sigs[si])
				}
			}

			success := true
			key_idx := 0
			for sig_idx in 0 ..< int(n_sigs) {
				sig := sigs[sig_idx]
				if len(sig) == 0 {
					success = false
					break
				}

				hash_type := u32(sig[len(sig) - 1])
				sig_bytes := sig[:len(sig) - 1]

				if .DER_Sig in flags {
					if !is_valid_signature_encoding(sig) {
						return .Sig_DER
					}
				}
				if .Low_S in flags {
					if !_check_low_s(sig_bytes) {
						return .Sig_High_S
					}
				}

				found := false
				for key_idx < int(n_keys) {
					pubkey := pubkeys[key_idx]
					key_idx += 1

					if .Strict_Enc in flags {
						if !check_pubkey_encoding(pubkey, flags) {
							return .Pub_Key_Type
						}
					}

					sighash: Hash256
					if is_witness {
						sighash = compute_sighash_witness_v0(verifier.tx, verifier.input_idx, sub_script, verifier.amount, hash_type, verifier.sighash_cache)
					} else {
						sighash = compute_sighash_legacy(verifier.tx, verifier.input_idx, sub_script, hash_type)
					}

					if crypto.verify_ecdsa(pubkey, sig_bytes, sighash) {
						found = true
						break
					}
				}

				if !found {
					success = false
					break
				}
			}

			if !success && .Null_Fail in flags {
				for sig in sigs {
					if len(sig) > 0 { return .Sig_Null_Fail }
				}
			}

			stack_push(stack, bool_to_stack(success, context.temp_allocator))

			if Opcode(op) == .OP_CHECKMULTISIGVERIFY {
				if !success { return .Check_Multisig_Verify }
				stack_pop(stack)
			}

		// --- Timelocks ---
		case .OP_CHECKLOCKTIMEVERIFY:
			if .Check_Locktime not_in flags {
				// Treat as NOP
				if .Discourage_Upgradable_Nops in flags {
					return .Verify
				}
			} else {
				if stack_size(stack) == 0 { return .Invalid_Stack_Operation }
				locktime_data := stack_top(stack) or_return
				locktime_val := script_num_decode(locktime_data, max_len = 5, require_minimal = require_minimal) or_return
				if locktime_val < 0 { return .Negative_Locktime }
				locktime := u32(locktime_val)

				tx_locktime := verifier.tx.locktime
				// Both must be same type (block height or time)
				if (locktime < LOCKTIME_THRESHOLD) != (tx_locktime < LOCKTIME_THRESHOLD) {
					return .Unsatisfied_Locktime
				}
				if locktime > tx_locktime { return .Unsatisfied_Locktime }

				// Input sequence must not be final
				if verifier.tx.inputs[verifier.input_idx].sequence == 0xffffffff {
					return .Unsatisfied_Locktime
				}
			}

		case .OP_CHECKSEQUENCEVERIFY:
			if .Check_Sequence not_in flags {
				if .Discourage_Upgradable_Nops in flags {
					return .Verify
				}
			} else {
				if stack_size(stack) == 0 { return .Invalid_Stack_Operation }
				seq_data := stack_top(stack) or_return
				seq_val := script_num_decode(seq_data, max_len = 5, require_minimal = require_minimal) or_return
				if seq_val < 0 { return .Negative_Locktime }

				seq := u32(seq_val)
				// If disable flag is set, NOP behavior
				if seq & SEQUENCE_LOCKTIME_DISABLE_FLAG != 0 {
					// NOP
				} else {
					// Version 2+ required for CSV
					if verifier.tx.version < 2 { return .Unsatisfied_Locktime }

					tx_seq := verifier.tx.inputs[verifier.input_idx].sequence
					if tx_seq & SEQUENCE_LOCKTIME_DISABLE_FLAG != 0 {
						return .Unsatisfied_Locktime
					}

					// Both must be same type
					if (seq & SEQUENCE_LOCKTIME_TYPE_FLAG) != (tx_seq & SEQUENCE_LOCKTIME_TYPE_FLAG) {
						return .Unsatisfied_Locktime
					}

					if (seq & SEQUENCE_LOCKTIME_MASK) > (tx_seq & SEQUENCE_LOCKTIME_MASK) {
						return .Unsatisfied_Locktime
					}
				}
			}

		// --- NOPs ---
		case .OP_NOP1, .OP_NOP4, .OP_NOP5, .OP_NOP6, .OP_NOP7, .OP_NOP8, .OP_NOP9, .OP_NOP10:
			if .Discourage_Upgradable_Nops in flags {
				return .Verify
			}

		case:
			return .Disabled_Opcode // unknown opcode
		}

		// Check combined stack size
		if stack_size(stack) + stack_size(alt) > MAX_STACK_SIZE {
			return .Stack_Size
		}
	}

	if len(cond_stack) != 0 {
		return .Unbalanced_Conditional
	}

	return nil
}

// --- Tapscript CHECKSIG helper ---

_tapscript_checksig :: proc(
	verifier: ^Script_Verifier,
	pubkey_data: []byte,
	sig_data: []byte,
	tapleaf_hash: ^Hash256,
	codesep_pos: ^u32,
	sigops_budget: ^int,
) -> (success: bool, err: Script_Error) {
	if len(pubkey_data) == 0 {
		return false, .Taproot_Empty_Pubkey
	}

	if len(sig_data) == 0 {
		// Empty signature = fail (no error, just false)
		return false, nil
	}

	// Deduct sigops budget
	if sigops_budget != nil {
		sigops_budget^ -= 1
		if sigops_budget^ < 0 {
			return false, .Taproot_Sigops_Budget
		}
	}

	if len(pubkey_data) == 32 {
		// 32-byte key: Schnorr verification
		sig64: []byte
		hash_type := SIGHASH_DEFAULT

		if len(sig_data) == 64 {
			sig64 = sig_data
		} else if len(sig_data) == 65 {
			sig64 = sig_data[:64]
			hash_type = u32(sig_data[64])
			if hash_type == SIGHASH_DEFAULT {
				return false, .Taproot_Sig_Hash_Type
			}
		} else {
			return false, .Taproot_Wrong_Sig_Size
		}

		if !_is_valid_taproot_hash_type(hash_type) {
			return false, .Taproot_Sig_Hash_Type
		}

		csep := u32(0xffffffff)
		if codesep_pos != nil { csep = codesep_pos^ }

		sighash := compute_sighash_taproot(
			verifier, hash_type,
			tapleaf_hash = tapleaf_hash,
			codesep_pos = csep,
		)

		if !crypto.verify_schnorr(pubkey_data, sig64, sighash[:]) {
			return false, .Eval_False
		}
		return true, nil
	} else {
		// Unknown pubkey type in tapscript: succeed for future extensibility
		// (signature must be non-empty, which we already checked)
		return true, nil
	}
}

// --- Arithmetic helpers ---

_unary_arith :: proc(stack: ^Script_Stack, f: proc(i64) -> i64, require_minimal: bool) -> Script_Error {
	data := stack_pop(stack) or_return
	val := script_num_decode(data, require_minimal = require_minimal) or_return
	result := f(val)
	stack_push(stack, script_num_encode(result, context.temp_allocator))
	return nil
}

_binary_arith :: proc(stack: ^Script_Stack, f: proc(i64, i64) -> i64, require_minimal: bool) -> Script_Error {
	b_data := stack_pop(stack) or_return
	a_data := stack_pop(stack) or_return
	a := script_num_decode(a_data, require_minimal = require_minimal) or_return
	b := script_num_decode(b_data, require_minimal = require_minimal) or_return
	result := f(a, b)
	stack_push(stack, script_num_encode(result, context.temp_allocator))
	return nil
}

// --- Sighash computation (legacy) ---

// Computes the sighash for legacy (non-SegWit) script evaluation.
// Modifies a copy of the transaction based on hash_type, serializes it, and double-SHA256s.
compute_sighash_legacy :: proc(tx: ^wire.Tx, input_idx: int, sub_script: []byte, hash_type: u32) -> Hash256 {
	base_type := hash_type & 0x1f
	anyone_can_pay := (hash_type & u32(SIGHASH_ANYONECANPAY)) != 0

	// SIGHASH_SINGLE bug: if input_idx >= len(outputs), return specific hash
	if base_type == SIGHASH_SINGLE && input_idx >= len(tx.outputs) {
		result: Hash256
		result[0] = 1 // 0x0100...00
		return result
	}

	// Strip OP_CODESEPARATOR from subscript
	clean_script := _remove_codeseparator(sub_script)

	w := wire.writer_init(context.temp_allocator)

	// Version
	wire.write_i32le(&w, tx.version)

	// Inputs
	if anyone_can_pay {
		// Only sign the current input
		wire.write_compact_size(&w, 1)
		wire.serialize_outpoint(&w, &tx.inputs[input_idx].previous_output)
		wire.write_var_bytes(&w, clean_script)
		wire.write_u32le(&w, tx.inputs[input_idx].sequence)
	} else {
		wire.write_compact_size(&w, u64(len(tx.inputs)))
		for i in 0 ..< len(tx.inputs) {
			wire.serialize_outpoint(&w, &tx.inputs[i].previous_output)
			if i == input_idx {
				wire.write_var_bytes(&w, clean_script)
			} else {
				wire.write_var_bytes(&w, nil) // empty script for other inputs
			}
			if (base_type == SIGHASH_NONE || base_type == SIGHASH_SINGLE) && i != input_idx {
				wire.write_u32le(&w, 0) // zero sequence for other inputs
			} else {
				wire.write_u32le(&w, tx.inputs[i].sequence)
			}
		}
	}

	// Outputs
	switch base_type {
	case SIGHASH_NONE:
		wire.write_compact_size(&w, 0)
	case SIGHASH_SINGLE:
		wire.write_compact_size(&w, u64(input_idx + 1))
		for i in 0 ..< input_idx {
			// Empty outputs before the matching one
			wire.write_i64le(&w, -1) // value = -1 (0xffffffffffffffff)
			wire.write_var_bytes(&w, nil)
		}
		wire.serialize_tx_out(&w, &tx.outputs[input_idx])
	case:
		// SIGHASH_ALL
		wire.write_compact_size(&w, u64(len(tx.outputs)))
		for i in 0 ..< len(tx.outputs) {
			wire.serialize_tx_out(&w, &tx.outputs[i])
		}
	}

	// Locktime
	wire.write_u32le(&w, tx.locktime)

	// Hash type (4 bytes LE)
	wire.write_u32le(&w, hash_type)

	return crypto.sha256d(wire.writer_bytes(&w))
}

// --- Sighash computation (BIP143 witness v0) ---

compute_sighash_witness_v0 :: proc(tx: ^wire.Tx, input_idx: int, script_code: []byte, amount: i64, hash_type: u32, cache: ^Sighash_Cache = nil) -> Hash256 {
	base_type := hash_type & 0x1f
	anyone_can_pay := (hash_type & u32(SIGHASH_ANYONECANPAY)) != 0

	// Compute intermediate hashes (using cache if available)
	hash_prevouts: Hash256
	if !anyone_can_pay {
		if cache != nil && cache.has_prevouts {
			hash_prevouts = cache.hash_prevouts
		} else {
			pw := wire.writer_init(context.temp_allocator)
			for i in 0 ..< len(tx.inputs) {
				wire.serialize_outpoint(&pw, &tx.inputs[i].previous_output)
			}
			hash_prevouts = crypto.sha256d(wire.writer_bytes(&pw))
			if cache != nil {
				cache.hash_prevouts = hash_prevouts
				cache.has_prevouts = true
			}
		}
	}

	hash_sequence: Hash256
	if !anyone_can_pay && base_type != SIGHASH_SINGLE && base_type != SIGHASH_NONE {
		if cache != nil && cache.has_sequence {
			hash_sequence = cache.hash_sequence
		} else {
			sw := wire.writer_init(context.temp_allocator)
			for i in 0 ..< len(tx.inputs) {
				wire.write_u32le(&sw, tx.inputs[i].sequence)
			}
			hash_sequence = crypto.sha256d(wire.writer_bytes(&sw))
			if cache != nil {
				cache.hash_sequence = hash_sequence
				cache.has_sequence = true
			}
		}
	}

	hash_outputs: Hash256
	if base_type != SIGHASH_SINGLE && base_type != SIGHASH_NONE {
		if cache != nil && cache.has_outputs {
			hash_outputs = cache.hash_outputs
		} else {
			ow := wire.writer_init(context.temp_allocator)
			for i in 0 ..< len(tx.outputs) {
				wire.serialize_tx_out(&ow, &tx.outputs[i])
			}
			hash_outputs = crypto.sha256d(wire.writer_bytes(&ow))
			if cache != nil {
				cache.hash_outputs = hash_outputs
				cache.has_outputs = true
			}
		}
	} else if base_type == SIGHASH_SINGLE && input_idx < len(tx.outputs) {
		ow := wire.writer_init(context.temp_allocator)
		wire.serialize_tx_out(&ow, &tx.outputs[input_idx])
		hash_outputs = crypto.sha256d(wire.writer_bytes(&ow))
	}

	// Serialize the BIP143 preimage
	w := wire.writer_init(context.temp_allocator)
	wire.write_i32le(&w, tx.version)
	wire.write_hash(&w, hash_prevouts)
	wire.write_hash(&w, hash_sequence)
	wire.serialize_outpoint(&w, &tx.inputs[input_idx].previous_output)
	wire.write_var_bytes(&w, script_code)
	wire.write_i64le(&w, amount)
	wire.write_u32le(&w, tx.inputs[input_idx].sequence)
	wire.write_hash(&w, hash_outputs)
	wire.write_u32le(&w, tx.locktime)
	wire.write_u32le(&w, hash_type)

	return crypto.sha256d(wire.writer_bytes(&w))
}

// --- Signature encoding validators ---

// Strict DER signature check (BIP66).
// Signature format: 0x30 <total_len> 0x02 <r_len> <r> 0x02 <s_len> <s> [sighash_byte]
is_valid_signature_encoding :: proc(sig: []byte) -> bool {
	n := len(sig)
	if n < 9 || n > 73 { return false }
	if sig[0] != 0x30 { return false }
	if int(sig[1]) != n - 3 { return false } // total length check (minus 0x30, length byte, sighash byte)

	r_len := int(sig[3])
	if 5 + r_len >= n { return false }

	s_len := int(sig[5 + r_len])
	if r_len + s_len + 7 != n { return false }

	if sig[2] != 0x02 { return false }
	if r_len == 0 { return false }
	if sig[4] & 0x80 != 0 { return false } // R must be positive
	if r_len > 1 && sig[4] == 0x00 && sig[5] & 0x80 == 0 { return false } // no unnecessary padding

	if sig[4 + r_len] != 0x02 { return false }
	if s_len == 0 { return false }
	if sig[6 + r_len] & 0x80 != 0 { return false } // S must be positive
	if s_len > 1 && sig[6 + r_len] == 0x00 && sig[7 + r_len] & 0x80 == 0 { return false } // no unnecessary padding

	return true
}

// Check if a public key is properly encoded.
check_pubkey_encoding :: proc(pubkey: []byte, flags: Verify_Flags) -> bool {
	n := len(pubkey)
	if n == 0 { return false }

	if pubkey[0] == 0x04 {
		// Uncompressed: must be 65 bytes
		return n == 65
	} else if pubkey[0] == 0x02 || pubkey[0] == 0x03 {
		// Compressed: must be 33 bytes
		return n == 33
	}

	return false
}

_is_compressed_pubkey :: proc(pubkey: []byte) -> bool {
	if len(pubkey) != 33 { return false }
	return pubkey[0] == 0x02 || pubkey[0] == 0x03
}

// Check if the S value in the DER signature is low (BIP62).
_check_low_s :: proc(sig_der: []byte) -> bool {
	// Parse the S value from DER
	if len(sig_der) < 6 { return false }
	r_len := int(sig_der[3])
	if 5 + r_len >= len(sig_der) { return false }
	s_len := int(sig_der[5 + r_len])
	if 6 + r_len + s_len > len(sig_der) { return false }

	s := sig_der[6 + r_len : 6 + r_len + s_len]

	// secp256k1 order/2 (big-endian)
	half_order := [32]byte{
		0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
		0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
	}

	// Compare: S must be <= half_order
	// Pad S to 32 bytes for comparison
	if len(s) > 32 { return false }
	padded: [32]byte
	copy(padded[32 - len(s):], s)

	for i in 0 ..< 32 {
		if padded[i] < half_order[i] { return true }
		if padded[i] > half_order[i] { return false }
	}
	return true // equal
}

// --- Utility procs ---

_bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}

// Remove OP_CODESEPARATOR bytes from a script for legacy sighash.
_remove_codeseparator :: proc(script: []byte) -> []byte {
	// Check if there are any OP_CODESEPARATOR bytes
	has_cs := false
	for b in script {
		if b == u8(Opcode.OP_CODESEPARATOR) {
			has_cs = true
			break
		}
	}
	if !has_cs { return script }

	result := make([dynamic]byte, 0, len(script), context.temp_allocator)
	i := 0
	for i < len(script) {
		op := script[i]
		if op >= 0x01 && op <= 0x4b {
			// Direct push: copy opcode + N bytes
			n := int(op)
			end := i + 1 + n
			if end > len(script) { end = len(script) }
			append(&result, ..script[i:end])
			i = end
		} else if op == u8(Opcode.OP_PUSHDATA1) && i + 1 < len(script) {
			n := int(script[i + 1])
			end := i + 2 + n
			if end > len(script) { end = len(script) }
			append(&result, ..script[i:end])
			i = end
		} else if op == u8(Opcode.OP_PUSHDATA2) && i + 2 < len(script) {
			n := int(script[i + 1]) | int(script[i + 2]) << 8
			end := i + 3 + n
			if end > len(script) { end = len(script) }
			append(&result, ..script[i:end])
			i = end
		} else if op == u8(Opcode.OP_PUSHDATA4) && i + 4 < len(script) {
			n := int(script[i + 1]) | int(script[i + 2]) << 8 | int(script[i + 3]) << 16 | int(script[i + 4]) << 24
			end := i + 5 + n
			if end > len(script) { end = len(script) }
			append(&result, ..script[i:end])
			i = end
		} else if op == u8(Opcode.OP_CODESEPARATOR) {
			i += 1 // skip it
		} else {
			append(&result, op)
			i += 1
		}
	}
	return result[:]
}

// FindAndDelete: remove all occurrences of a serialized push of sig_data from the script.
// Used in legacy sighash computation (pre-segwit) to strip signatures from the subscript.
// Pattern is constructed as: <push_opcode(len)><sig_data> using minimal push encoding.
_find_and_delete :: proc(scr: []byte, sig_data: []byte) -> []byte {
	if len(sig_data) == 0 { return scr }

	// Build the serialized push pattern
	pattern := make([dynamic]byte, 0, len(sig_data) + 5, context.temp_allocator)
	if len(sig_data) < 0x4c {
		append(&pattern, u8(len(sig_data)))
	} else if len(sig_data) <= 0xff {
		append(&pattern, 0x4c) // OP_PUSHDATA1
		append(&pattern, u8(len(sig_data)))
	} else if len(sig_data) <= 0xffff {
		append(&pattern, 0x4d) // OP_PUSHDATA2
		append(&pattern, u8(len(sig_data) & 0xff))
		append(&pattern, u8((len(sig_data) >> 8) & 0xff))
	} else {
		append(&pattern, 0x4e) // OP_PUSHDATA4
		append(&pattern, u8(len(sig_data) & 0xff))
		append(&pattern, u8((len(sig_data) >> 8) & 0xff))
		append(&pattern, u8((len(sig_data) >> 16) & 0xff))
		append(&pattern, u8((len(sig_data) >> 24) & 0xff))
	}
	append(&pattern, ..sig_data)

	pat := pattern[:]
	pat_len := len(pat)

	// Quick check: does the pattern appear at all?
	found := false
	outer: for i in 0 ..= len(scr) - pat_len {
		for j in 0 ..< pat_len {
			if scr[i + j] != pat[j] { continue outer }
		}
		found = true
		break
	}
	if !found { return scr }

	// Walk script opcode by opcode, checking for pattern match at each opcode boundary
	result := make([dynamic]byte, 0, len(scr), context.temp_allocator)
	i := 0
	for i < len(scr) {
		// Check for pattern match at this opcode boundary
		if i + pat_len <= len(scr) {
			match := true
			for j in 0 ..< pat_len {
				if scr[i + j] != pat[j] { match = false; break }
			}
			if match {
				i += pat_len
				continue
			}
		}
		// Copy current opcode (with data if push)
		op := scr[i]
		if op >= 0x01 && op <= 0x4b {
			n := int(op)
			end := i + 1 + n
			if end > len(scr) { end = len(scr) }
			append(&result, ..scr[i:end])
			i = end
		} else if op == 0x4c && i + 1 < len(scr) {
			n := int(scr[i + 1])
			end := i + 2 + n
			if end > len(scr) { end = len(scr) }
			append(&result, ..scr[i:end])
			i = end
		} else if op == 0x4d && i + 2 < len(scr) {
			n := int(scr[i + 1]) | int(scr[i + 2]) << 8
			end := i + 3 + n
			if end > len(scr) { end = len(scr) }
			append(&result, ..scr[i:end])
			i = end
		} else if op == 0x4e && i + 4 < len(scr) {
			n := int(scr[i + 1]) | int(scr[i + 2]) << 8 | int(scr[i + 3]) << 16 | int(scr[i + 4]) << 24
			end := i + 5 + n
			if end > len(scr) { end = len(scr) }
			append(&result, ..scr[i:end])
			i = end
		} else {
			append(&result, op)
			i += 1
		}
	}
	return result[:]
}
