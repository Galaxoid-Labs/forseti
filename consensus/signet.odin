package consensus

import crypto "../crypto"
import "../script"
import "../wire"

// BIP325 signet header bytes that identify the signet commitment.
SIGNET_HEADER :: [4]byte{0xec, 0xc7, 0xda, 0xa2}

// Scan an OP_RETURN scriptPubKey for a signet commitment push.
// Returns the solution data (bytes after the signet header), the start position
// of the push opcode, and the end position (exclusive) of the push data.
// This allows the caller to strip just the signet section while keeping other pushes.
_parse_signet_commitment :: proc(spk: []byte) -> (solution: []byte, push_start: int, push_end: int, ok: bool) {
	if len(spk) < 2 || spk[0] != 0x6a { // OP_RETURN
		return nil, 0, 0, false
	}

	pos := 1
	for pos < len(spk) {
		op := spk[pos]
		data_start: int
		data_len: int

		if op >= 0x01 && op <= 0x4b {
			// Direct push (1-75 bytes)
			data_len = int(op)
			data_start = pos + 1
		} else if op == 0x4c {
			// OP_PUSHDATA1
			if pos + 1 >= len(spk) {
				break
			}
			data_len = int(spk[pos + 1])
			data_start = pos + 2
		} else if op == 0x4d {
			// OP_PUSHDATA2
			if pos + 2 >= len(spk) {
				break
			}
			data_len = int(spk[pos + 1]) | (int(spk[pos + 2]) << 8)
			data_start = pos + 3
		} else {
			break // Unknown opcode
		}

		if data_start + data_len > len(spk) {
			break
		}

		// Check if this push starts with the signet header
		if data_len >= 4 &&
		   spk[data_start] == SIGNET_HEADER[0] && spk[data_start + 1] == SIGNET_HEADER[1] &&
		   spk[data_start + 2] == SIGNET_HEADER[2] && spk[data_start + 3] == SIGNET_HEADER[3] {
			return spk[data_start + 4 : data_start + data_len], pos, data_start + data_len, true
		}

		// Advance past this push
		pos = data_start + data_len
	}

	return nil, 0, 0, false
}

// BIP325: Validate signet block signature.
check_signet_block :: proc(block: ^wire.Block, params: ^Chain_Params) -> Consensus_Error {
	if len(block.txs) == 0 {
		return .Bad_Signet_Signature
	}

	coinbase := block.txs[0]

	// 1. Find signet commitment: scan coinbase outputs in reverse
	commitment_idx := -1
	solution_data: []byte
	signet_push_start: int
	signet_push_end: int
	for i := len(coinbase.outputs) - 1; i >= 0; i -= 1 {
		sol, ps, pe, ok := _parse_signet_commitment(coinbase.outputs[i].script_pubkey)
		if ok {
			commitment_idx = i
			solution_data = sol
			signet_push_start = ps
			signet_push_end = pe
			break
		}
	}

	if commitment_idx < 0 {
		return .Bad_Signet_Signature
	}

	// 2. Parse solution: scriptSig then witness stack
	r := wire.reader_init(solution_data)

	// Read scriptSig (CompactSize-prefixed bytes)
	sol_script_sig, sig_err := wire.read_var_bytes(&r)
	if sig_err != .None {
		return .Bad_Signet_Signature
	}

	// Read witness stack
	sol_witness: [][]byte
	if wire.reader_remaining(&r) > 0 {
		witness_count_val, wc_err := wire.read_compact_size(&r)
		if wc_err != .None {
			return .Bad_Signet_Signature
		}
		witness_count := int(witness_count_val)
		sol_witness = make([][]byte, witness_count, context.temp_allocator)
		for i in 0 ..< witness_count {
			item, item_err := wire.read_var_bytes(&r, context.temp_allocator)
			if item_err != .None {
				return .Bad_Signet_Signature
			}
			sol_witness[i] = item
		}
	}

	// 3. Compute signet block_data: raw serialization of header fields
	//    (version || prev_hash || signet_merkle_root || timestamp)
	//    Excludes bits and nonce so miners can grind without re-signing.

	// Build stripped scriptPubKey: replace the signet commitment push with just the
	// 4-byte header (no solution data), keeping the rest of the output (e.g. witness
	// commitment) intact. This matches Bitcoin Core's FetchAndClearCommitmentSection.
	original_spk := coinbase.outputs[commitment_idx].script_pubkey
	signet_header_push := [5]byte{0x04, SIGNET_HEADER[0], SIGNET_HEADER[1], SIGNET_HEADER[2], SIGNET_HEADER[3]}
	stripped_len := signet_push_start + 5 + (len(original_spk) - signet_push_end)
	stripped_spk := make([]byte, stripped_len, context.temp_allocator)
	copy(stripped_spk, original_spk[:signet_push_start])
	copy(stripped_spk[signet_push_start:], signet_header_push[:])
	copy(stripped_spk[signet_push_start + 5:], original_spk[signet_push_end:])

	// Temporarily swap coinbase output scriptPubKey
	block.txs[0].outputs[commitment_idx].script_pubkey = stripped_spk

	// Recompute merkle root with modified coinbase
	tx_ids := make([]crypto.Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		tx_ids[i] = wire.tx_id(&tx)
	}
	signet_merkle := crypto.merkle_root(tx_ids)

	// Restore original
	block.txs[0].outputs[commitment_idx].script_pubkey = original_spk

	// 4. Build virtual transactions for script verification
	challenge := params.signet_challenge[:params.signet_challenge_len]

	// BIP325 block_data: version(4) || prev_hash(32) || signet_merkle(32) || timestamp(4) = 72 bytes
	// to_spend scriptSig = OP_0 PUSH72 <block_data>
	to_spend_script_sig: [74]byte
	to_spend_script_sig[0] = 0x00 // OP_0
	to_spend_script_sig[1] = 0x48 // PUSH72 (72 = 0x48)
	// version (4 bytes LE)
	to_spend_script_sig[2] = byte(u32(block.header.version))
	to_spend_script_sig[3] = byte(u32(block.header.version) >> 8)
	to_spend_script_sig[4] = byte(u32(block.header.version) >> 16)
	to_spend_script_sig[5] = byte(u32(block.header.version) >> 24)
	// prev_hash (32 bytes)
	for i in 0 ..< 32 {
		to_spend_script_sig[6 + i] = block.header.prev_hash[i]
	}
	// signet_merkle_root (32 bytes)
	for i in 0 ..< 32 {
		to_spend_script_sig[38 + i] = signet_merkle[i]
	}
	// timestamp (4 bytes LE)
	to_spend_script_sig[70] = byte(block.header.timestamp)
	to_spend_script_sig[71] = byte(block.header.timestamp >> 8)
	to_spend_script_sig[72] = byte(block.header.timestamp >> 16)
	to_spend_script_sig[73] = byte(block.header.timestamp >> 24)

	null_hash: wire.Hash256
	to_spend_input := [1]wire.Tx_In{
		{
			previous_output = wire.Outpoint{hash = null_hash, index = 0xffffffff},
			script_sig      = to_spend_script_sig[:],
			sequence        = 0,
		},
	}
	to_spend_output := [1]wire.Tx_Out{
		{
			value         = 0,
			script_pubkey = challenge,
		},
	}
	to_spend_tx := wire.Tx{
		version  = 0,
		inputs   = to_spend_input[:],
		outputs  = to_spend_output[:],
		locktime = 0,
	}

	// Compute txid of to_spend
	to_spend_txid := wire.tx_id(&to_spend_tx)

	// to_sign: spends to_spend output 0
	op_return_script := [1]byte{0x6a} // OP_RETURN
	to_sign_input := [1]wire.Tx_In{
		{
			previous_output = wire.Outpoint{hash = to_spend_txid, index = 0},
			script_sig      = sol_script_sig,
			sequence        = 0,
		},
	}
	to_sign_output := [1]wire.Tx_Out{
		{
			value         = 0,
			script_pubkey = op_return_script[:],
		},
	}

	// Build witness for to_sign (one input, so witness[0] = sol_witness)
	to_sign_witness: [1][][]byte
	to_sign_witness[0] = sol_witness

	to_sign_tx := wire.Tx{
		version  = 0,
		inputs   = to_sign_input[:],
		outputs  = to_sign_output[:],
		witness  = to_sign_witness[:],
		locktime = 0,
	}

	// 5. Verify the script
	// BIP325: P2SH + Witness + DER_SIG + Null_Dummy (matches Bitcoin Core)
	signet_flags := script.Verify_Flags{.P2SH, .Witness, .DER_Sig, .Null_Dummy}

	spent_output := [1]wire.Tx_Out{
		{
			value         = 0,
			script_pubkey = challenge,
		},
	}

	verifier := script.Script_Verifier{
		tx            = &to_sign_tx,
		input_idx     = 0,
		amount        = 0,
		flags         = signet_flags,
		spent_outputs = spent_output[:],
	}

	serr := script.verify_script(
		&verifier,
		sol_script_sig,
		challenge,
		sol_witness,
	)

	if serr != .None {
		return .Bad_Signet_Signature
	}

	return .None
}
