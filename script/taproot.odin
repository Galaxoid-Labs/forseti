package script

import "../crypto"
import "../wire"
import "core:crypto/sha2"

// --- Taproot verification (BIP341/342) ---

// Entry point from verify_witness_program when version == 1.
verify_taproot :: proc(
	verifier: ^Script_Verifier,
	witness: [][]byte,
	program: []byte,
) -> Script_Error {
	if len(program) != 32 { return .Witness_Program_Wrong_Length }
	if witness == nil || len(witness) == 0 { return .Witness_Program_Mismatch }

	// Detect annex: last witness item starts with 0x50 and there are 2+ items
	annex: []byte = nil
	witness_items := witness
	if len(witness) >= 2 && len(witness[len(witness) - 1]) > 0 && witness[len(witness) - 1][0] == TAPROOT_ANNEX_TAG {
		annex = witness[len(witness) - 1]
		witness_items = witness[:len(witness) - 1]
	}

	if len(witness_items) == 1 {
		// Key path spending
		return verify_taproot_key_path(verifier, witness_items[0], program, annex)
	} else {
		// Script path spending (2+ items: stack... script control_block)
		return verify_taproot_script_path(verifier, witness_items, program, annex)
	}
}

// Key path spending: verify Schnorr signature against the output key.
verify_taproot_key_path :: proc(
	verifier: ^Script_Verifier,
	sig_data: []byte,
	output_key: []byte,
	annex: []byte,
) -> Script_Error {
	if len(sig_data) != 64 && len(sig_data) != 65 {
		return .Taproot_Wrong_Sig_Size
	}

	// Parse hash type
	hash_type := SIGHASH_DEFAULT
	sig64 := sig_data[:64]
	if len(sig_data) == 65 {
		hash_type = u32(sig_data[64])
		if hash_type == SIGHASH_DEFAULT {
			return .Taproot_Sig_Hash_Type // explicit 0x00 forbidden with 65-byte sig
		}
	}

	if !_is_valid_taproot_hash_type(hash_type) {
		return .Taproot_Sig_Hash_Type
	}

	// Compute sighash
	sighash := compute_sighash_taproot(verifier, hash_type, annex = annex)

	// Verify Schnorr signature
	if !crypto.verify_schnorr(output_key, sig64, sighash[:]) {
		return .Eval_False
	}
	return nil
}

// Script path spending: verify merkle proof and execute tapscript.
verify_taproot_script_path :: proc(
	verifier: ^Script_Verifier,
	witness_items: [][]byte,
	output_key: []byte,
	annex: []byte,
) -> Script_Error {
	// Last two items are script and control block
	if len(witness_items) < 2 { return .Witness_Program_Mismatch }
	control_block := witness_items[len(witness_items) - 1]
	tap_script := witness_items[len(witness_items) - 2]

	// Validate control block size
	if len(control_block) < TAPROOT_CONTROL_BASE_SIZE { return .Taproot_Wrong_Control_Size }
	path_len := len(control_block) - TAPROOT_CONTROL_BASE_SIZE
	if path_len % TAPROOT_CONTROL_NODE_SIZE != 0 { return .Taproot_Wrong_Control_Size }
	node_count := path_len / TAPROOT_CONTROL_NODE_SIZE
	if node_count > TAPROOT_CONTROL_MAX_NODE_COUNT { return .Taproot_Wrong_Control_Size }

	// Parse control block
	leaf_version := control_block[0] & TAPROOT_LEAF_MASK
	output_parity := int(control_block[0] & 0x01)
	internal_key := control_block[1:33]

	// Compute tapleaf hash
	tapleaf := compute_tapleaf_hash(leaf_version, tap_script)

	// Walk merkle path
	current := tapleaf
	for i in 0 ..< node_count {
		node_start := TAPROOT_CONTROL_BASE_SIZE + i * TAPROOT_CONTROL_NODE_SIZE
		node := control_block[node_start:node_start + TAPROOT_CONTROL_NODE_SIZE]
		current = compute_tapbranch_hash(current, node)
	}

	// Compute tweak: tagged_hash("TapTweak", internal_key || merkle_root)
	tweak := crypto.tagged_hash("TapTweak", internal_key, current[:])

	// Verify the tweak produces the output key
	if !crypto.verify_taproot_tweak(internal_key, tweak[:], output_key, output_parity) {
		return .Taproot_Invalid_Control_Block
	}

	// Execute based on leaf version
	if leaf_version == TAPROOT_LEAF_TAPSCRIPT {
		return execute_tapscript(verifier, witness_items[:len(witness_items) - 2], tap_script, &tapleaf, annex)
	}

	// Unknown leaf versions: succeed (unless discouraged)
	if .Discourage_Upgradable_Witness in verifier.flags {
		return .Discourage_Upgradable_Witness
	}
	return nil
}

// Execute a tapscript (BIP342).
execute_tapscript :: proc(
	verifier: ^Script_Verifier,
	witness_stack: [][]byte,
	tap_script: []byte,
	tapleaf_hash: ^Hash256,
	annex: []byte,
) -> Script_Error {
	// Pre-scan for OP_SUCCESS opcodes
	if _has_op_success(tap_script) {
		return nil // OP_SUCCESS causes immediate success
	}

	// Build stack from witness items
	stack := stack_init(context.temp_allocator)
	for item in witness_stack {
		if len(item) > MAX_SCRIPT_ELEMENT_SIZE { return .Push_Size }
		stack_push(&stack, item)
	}

	// Compute sigops budget: total witness size / 50
	witness_size := 0
	for item in witness_stack {
		witness_size += len(item)
	}
	witness_size += len(tap_script)
	if annex != nil { witness_size += len(annex) }
	sigops_budget := max(witness_size / 50, 1)

	// Execute with tapscript mode
	codesep_pos := u32(0xffffffff) // no OP_CODESEPARATOR seen yet
	err := execute_script(
		verifier, tap_script, &stack,
		is_witness = true,
		exec_mode = .Tapscript,
		tapleaf_hash = tapleaf_hash,
		codesep_pos = &codesep_pos,
		sigops_budget = &sigops_budget,
	)
	if err != nil { return err }

	// Clean stack: exactly 1 true element
	if stack_size(&stack) != 1 { return .Clean_Stack }
	top := stack_top(&stack) or_return
	if !stack_to_bool(top) { return .Eval_False }

	return nil
}

// Pre-scan script for OP_SUCCESS opcodes (BIP342).
_has_op_success :: proc(script: []byte) -> bool {
	pos := 0
	for pos < len(script) {
		op := script[pos]
		pos += 1

		if op >= 0x01 && op <= 0x4b {
			pos += int(op)
		} else if op == u8(Opcode.OP_PUSHDATA1) {
			if pos >= len(script) { return false }
			n := int(script[pos])
			pos += 1 + n
		} else if op == u8(Opcode.OP_PUSHDATA2) {
			if pos + 1 >= len(script) { return false }
			n := int(script[pos]) | int(script[pos + 1]) << 8
			pos += 2 + n
		} else if op == u8(Opcode.OP_PUSHDATA4) {
			if pos + 3 >= len(script) { return false }
			n := int(script[pos]) | int(script[pos + 1]) << 8 | int(script[pos + 2]) << 16 | int(script[pos + 3]) << 24
			pos += 4 + n
		} else if is_op_success(op) {
			return true
		}
	}
	return false
}

// Compute the tapleaf hash: tagged_hash("TapLeaf", leaf_version || compact_size(len) || script)
compute_tapleaf_hash :: proc(leaf_version: u8, script: []byte) -> Hash256 {
	// Build: leaf_version(1) || compact_size(len(script)) || script
	w := wire.writer_init(context.temp_allocator)
	wire.write_byte(&w, leaf_version)
	wire.write_compact_size(&w, u64(len(script)))
	wire.write_bytes(&w, script)
	return crypto.tagged_hash("TapLeaf", wire.writer_bytes(&w))
}

// Compute the tapbranch hash: tagged_hash("TapBranch", sorted(a, b))
compute_tapbranch_hash :: proc(a: Hash256, b_slice: []byte) -> Hash256 {
	a := a
	b: Hash256
	copy(b[:], b_slice)

	// Sort lexicographically
	a_first := true
	for i in 0 ..< 32 {
		if a[i] < b[i] { a_first = true; break }
		if a[i] > b[i] { a_first = false; break }
	}

	if a_first {
		return crypto.tagged_hash("TapBranch", a[:], b[:])
	} else {
		return crypto.tagged_hash("TapBranch", b[:], a[:])
	}
}

// --- BIP341 Taproot Sighash ---

compute_sighash_taproot :: proc(
	verifier: ^Script_Verifier,
	hash_type: u32,
	annex: []byte = nil,
	// Script path params (nil for key path)
	tapleaf_hash: ^Hash256 = nil,
	key_version: u8 = 0,
	codesep_pos: u32 = 0xffffffff,
) -> Hash256 {
	tx := verifier.tx
	input_idx := verifier.input_idx

	base_type := hash_type & 0x1f
	anyone_can_pay := (hash_type & u32(SIGHASH_ANYONECANPAY)) != 0

	// Use SIGHASH_ALL behavior when hash_type == 0x00
	effective_base := base_type
	if hash_type == SIGHASH_DEFAULT { effective_base = SIGHASH_ALL }

	// Build preimage
	w := wire.writer_init(context.temp_allocator)

	// Epoch (0x00)
	wire.write_byte(&w, 0x00)

	// hash_type
	wire.write_byte(&w, u8(hash_type))

	// nVersion
	wire.write_i32le(&w, tx.version)

	// nLockTime
	wire.write_u32le(&w, tx.locktime)

	// If not ANYONECANPAY: hash_prevouts, hash_amounts, hash_script_pubkeys, hash_sequences
	cache := verifier.sighash_cache
	if !anyone_can_pay {
		hp: Hash256
		if cache != nil && cache.has_tap_prevouts {
			hp = cache.tap_prevouts
		} else {
			hp = _sha256_prevouts(tx)
			if cache != nil { cache.tap_prevouts = hp; cache.has_tap_prevouts = true }
		}
		wire.write_hash(&w, hp)

		ha: Hash256
		if cache != nil && cache.has_tap_amounts {
			ha = cache.tap_amounts
		} else {
			ha = _sha256_amounts(verifier.spent_outputs)
			if cache != nil { cache.tap_amounts = ha; cache.has_tap_amounts = true }
		}
		wire.write_hash(&w, ha)

		hsp: Hash256
		if cache != nil && cache.has_tap_script_pubkeys {
			hsp = cache.tap_script_pubkeys
		} else {
			hsp = _sha256_script_pubkeys(verifier.spent_outputs)
			if cache != nil { cache.tap_script_pubkeys = hsp; cache.has_tap_script_pubkeys = true }
		}
		wire.write_hash(&w, hsp)

		hs: Hash256
		if cache != nil && cache.has_tap_sequences {
			hs = cache.tap_sequences
		} else {
			hs = _sha256_sequences(tx)
			if cache != nil { cache.tap_sequences = hs; cache.has_tap_sequences = true }
		}
		wire.write_hash(&w, hs)
	}

	// If not NONE and not SINGLE: hash_outputs
	if effective_base != SIGHASH_NONE && effective_base != SIGHASH_SINGLE {
		ho: Hash256
		if cache != nil && cache.has_tap_outputs {
			ho = cache.tap_outputs
		} else {
			ho = _sha256_outputs(tx)
			if cache != nil { cache.tap_outputs = ho; cache.has_tap_outputs = true }
		}
		wire.write_hash(&w, ho)
	}

	// spend_type
	spend_type: u8 = 0
	if annex != nil { spend_type |= 1 }
	if tapleaf_hash != nil { spend_type |= 2 }
	wire.write_byte(&w, spend_type)

	// Input data
	if anyone_can_pay {
		// outpoint
		wire.serialize_outpoint(&w, &tx.inputs[input_idx].previous_output)
		// amount
		wire.write_i64le(&w, verifier.amount)
		// scriptPubKey of the spent output
		if verifier.spent_outputs != nil && input_idx < len(verifier.spent_outputs) {
			wire.write_var_bytes(&w, verifier.spent_outputs[input_idx].script_pubkey)
		} else {
			wire.write_var_bytes(&w, nil)
		}
		// sequence
		wire.write_u32le(&w, tx.inputs[input_idx].sequence)
	} else {
		// input_index
		wire.write_u32le(&w, u32(input_idx))
	}

	// If annex: SHA256(compact_size(len(annex)) || annex)
	if annex != nil {
		aw := wire.writer_init(context.temp_allocator)
		wire.write_var_bytes(&aw, annex)
		annex_hash := crypto.sha256_hash(wire.writer_bytes(&aw))
		wire.write_hash(&w, annex_hash)
	}

	// If SIGHASH_SINGLE: SHA256(output[input_idx])
	if effective_base == SIGHASH_SINGLE {
		if input_idx < len(tx.outputs) {
			ow := wire.writer_init(context.temp_allocator)
			wire.serialize_tx_out(&ow, &tx.outputs[input_idx])
			single_hash := crypto.sha256_hash(wire.writer_bytes(&ow))
			wire.write_hash(&w, single_hash)
		}
	}

	// Script path data
	if tapleaf_hash != nil {
		tlh := tapleaf_hash^
		wire.write_hash(&w, tlh)
		wire.write_byte(&w, key_version)
		wire.write_u32le(&w, codesep_pos)
	}

	return crypto.tagged_hash("TapSighash", wire.writer_bytes(&w))
}

// --- Intermediate hash helpers (single SHA256, NOT double) ---

_sha256_prevouts :: proc(tx: ^wire.Tx) -> Hash256 {
	w := wire.writer_init(context.temp_allocator)
	for i in 0 ..< len(tx.inputs) {
		wire.serialize_outpoint(&w, &tx.inputs[i].previous_output)
	}
	return crypto.sha256_hash(wire.writer_bytes(&w))
}

_sha256_amounts :: proc(spent_outputs: []wire.Tx_Out) -> Hash256 {
	w := wire.writer_init(context.temp_allocator)
	if spent_outputs != nil {
		for i in 0 ..< len(spent_outputs) {
			wire.write_i64le(&w, spent_outputs[i].value)
		}
	}
	return crypto.sha256_hash(wire.writer_bytes(&w))
}

_sha256_script_pubkeys :: proc(spent_outputs: []wire.Tx_Out) -> Hash256 {
	w := wire.writer_init(context.temp_allocator)
	if spent_outputs != nil {
		for i in 0 ..< len(spent_outputs) {
			wire.write_var_bytes(&w, spent_outputs[i].script_pubkey)
		}
	}
	return crypto.sha256_hash(wire.writer_bytes(&w))
}

_sha256_sequences :: proc(tx: ^wire.Tx) -> Hash256 {
	w := wire.writer_init(context.temp_allocator)
	for i in 0 ..< len(tx.inputs) {
		wire.write_u32le(&w, tx.inputs[i].sequence)
	}
	return crypto.sha256_hash(wire.writer_bytes(&w))
}

_sha256_outputs :: proc(tx: ^wire.Tx) -> Hash256 {
	w := wire.writer_init(context.temp_allocator)
	for i in 0 ..< len(tx.outputs) {
		wire.serialize_tx_out(&w, &tx.outputs[i])
	}
	return crypto.sha256_hash(wire.writer_bytes(&w))
}

// --- Taproot sighash type validation ---

_is_valid_taproot_hash_type :: proc(hash_type: u32) -> bool {
	switch hash_type {
	case SIGHASH_DEFAULT, SIGHASH_ALL, SIGHASH_NONE, SIGHASH_SINGLE,
	     SIGHASH_ALL | SIGHASH_ANYONECANPAY,
	     SIGHASH_NONE | SIGHASH_ANYONECANPAY,
	     SIGHASH_SINGLE | SIGHASH_ANYONECANPAY:
		return true
	case:
		return false
	}
}
