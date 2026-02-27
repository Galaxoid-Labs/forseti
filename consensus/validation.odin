package consensus

import "../crypto"
import "../script"
import "../wire"

WITNESS_SCALE_FACTOR :: 4
MAX_BLOCK_SIGOPS_COST :: 80_000

COINBASE_WITNESS_COMMITMENT_HEADER :: [4]byte{0xaa, 0x21, 0xa9, 0xed}

Consensus_Error :: enum {
	None,
	Bad_Pow,
	Bad_Pow_Bits,
	No_Transactions,
	Bad_Coinbase_Not_First,
	Coinbase_In_Non_First,
	Bad_Merkle_Root,
	Block_Too_Large,
	Block_Sigops_Too_Many,
	Bad_Tx_Empty_Inputs,
	Bad_Tx_Empty_Outputs,
	Bad_Tx_Negative_Value,
	Bad_Tx_Too_Large_Value,
	Bad_Witness_Commitment,
	Bad_Witness_Nonce,
	// Phase 4 contextual errors (defined now, used later)
	Duplicate_Tx,
	Bad_Coinbase_Value,
	Inputs_Unavailable,
	Bad_Script,
}

// Verify block header proof-of-work.
check_block_header :: proc(header: ^wire.Block_Header, params: ^Chain_Params) -> Consensus_Error {
	hash := wire.block_header_hash(header)
	if !check_proof_of_work(hash, header.bits, params) {
		return .Bad_Pow
	}
	return .None
}

// Full context-free block validation.
check_block :: proc(block: ^wire.Block, height: int, params: ^Chain_Params) -> Consensus_Error {
	// 1. Check header PoW
	header := block.header
	err := check_block_header(&header, params)
	if err != .None {
		return err
	}

	// 2. Must have at least one transaction
	if len(block.txs) == 0 {
		return .No_Transactions
	}

	// 3. First transaction must be coinbase
	first_tx := block.txs[0]
	if !is_coinbase_tx(&first_tx) {
		return .Bad_Coinbase_Not_First
	}

	// 4. No other transaction may be coinbase
	for i in 1 ..< len(block.txs) {
		tx := block.txs[i]
		if is_coinbase_tx(&tx) {
			return .Coinbase_In_Non_First
		}
	}

	// 5. Per-tx sanity checks
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		tx_err := check_tx_sanity(&tx)
		if tx_err != .None {
			return tx_err
		}
	}

	// 6. Verify merkle root
	tx_ids := make([]crypto.Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		tx_ids[i] = wire.tx_id(&tx)
	}
	computed_root := crypto.merkle_root(tx_ids)
	if computed_root != block.header.merkle_root {
		return .Bad_Merkle_Root
	}

	// 7. Check block weight
	if get_block_weight(block) > wire.MAX_BLOCK_WEIGHT {
		return .Block_Too_Large
	}

	// 8. Check sigops
	if count_block_sigops(block) * WITNESS_SCALE_FACTOR > MAX_BLOCK_SIGOPS_COST {
		return .Block_Sigops_Too_Many
	}

	// 9. Check witness commitment (if segwit active)
	if height >= params.segwit_height {
		has_witness := false
		for i in 0 ..< len(block.txs) {
			tx := block.txs[i]
			if wire.tx_has_witness(&tx) {
				has_witness = true
				break
			}
		}
		if has_witness {
			witness_err := check_witness_commitment(block)
			if witness_err != .None {
				return witness_err
			}
		}
	}

	return .None
}

// Basic transaction sanity checks (context-free).
check_tx_sanity :: proc(tx: ^wire.Tx) -> Consensus_Error {
	if len(tx.inputs) == 0 {
		return .Bad_Tx_Empty_Inputs
	}
	if len(tx.outputs) == 0 {
		return .Bad_Tx_Empty_Outputs
	}

	total_out: i64 = 0
	for i in 0 ..< len(tx.outputs) {
		if tx.outputs[i].value < 0 {
			return .Bad_Tx_Negative_Value
		}
		if tx.outputs[i].value > MAX_MONEY {
			return .Bad_Tx_Too_Large_Value
		}
		total_out += tx.outputs[i].value
		if total_out > MAX_MONEY {
			return .Bad_Tx_Too_Large_Value
		}
	}

	return .None
}

// Check if a transaction is a coinbase transaction.
is_coinbase_tx :: proc(tx: ^wire.Tx) -> bool {
	if len(tx.inputs) != 1 {
		return false
	}
	if tx.inputs[0].previous_output.hash != wire.HASH_ZERO {
		return false
	}
	if tx.inputs[0].previous_output.index != 0xffffffff {
		return false
	}
	return true
}

// Calculate block weight: base_size * 3 + total_size.
get_block_weight :: proc(block: ^wire.Block) -> int {
	// Serialize header (always 80 bytes)
	base_size := wire.BLOCK_HEADER_SIZE
	total_size := wire.BLOCK_HEADER_SIZE

	// CompactSize for tx count
	cs_len := wire.compact_size_length(u64(len(block.txs)))
	base_size += cs_len
	total_size += cs_len

	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		w_base := wire.writer_init(context.temp_allocator)
		wire.serialize_tx_no_witness(&w_base, &tx)
		tx_base := wire.writer_len(&w_base)

		w_total := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w_total, &tx)
		tx_total := wire.writer_len(&w_total)

		base_size += tx_base
		total_size += tx_total
	}

	return base_size * 3 + total_size
}

// Calculate transaction weight.
get_tx_weight :: proc(tx: ^wire.Tx) -> int {
	w_base := wire.writer_init(context.temp_allocator)
	wire.serialize_tx_no_witness(&w_base, tx)
	base_size := wire.writer_len(&w_base)

	w_total := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w_total, tx)
	total_size := wire.writer_len(&w_total)

	return base_size * 3 + total_size
}

// Calculate transaction virtual size.
get_tx_vsize :: proc(tx: ^wire.Tx) -> int {
	weight := get_tx_weight(tx)
	return (weight + 3) / 4
}

// Count legacy sigops in a script (no P2SH expansion).
count_legacy_sigops :: proc(s: []byte) -> int {
	count := 0
	i := 0
	for i < len(s) {
		op := s[i]
		i += 1

		// Skip push data
		if op <= 0x4b { // direct push (1-75 bytes)
			i += int(op)
			continue
		}
		if op == 0x4c { // OP_PUSHDATA1
			if i >= len(s) do break
			size := int(s[i])
			i += 1 + size
			continue
		}
		if op == 0x4d { // OP_PUSHDATA2
			if i + 1 >= len(s) do break
			size := int(s[i]) | (int(s[i + 1]) << 8)
			i += 2 + size
			continue
		}
		if op == 0x4e { // OP_PUSHDATA4
			if i + 3 >= len(s) do break
			size := int(s[i]) | (int(s[i + 1]) << 8) | (int(s[i + 2]) << 16) | (int(s[i + 3]) << 24)
			i += 4 + size
			continue
		}

		// Count sigops
		switch op {
		case 0xac, 0xad: // OP_CHECKSIG, OP_CHECKSIGVERIFY
			count += 1
		case 0xae, 0xaf: // OP_CHECKMULTISIG, OP_CHECKMULTISIGVERIFY
			count += 20 // MAX_PUBKEYS_PER_MULTISIG
		}
	}
	return count
}

// Count total legacy sigops in a block (inputs + outputs).
count_block_sigops :: proc(block: ^wire.Block) -> int {
	count := 0
	for i in 0 ..< len(block.txs) {
		tx := block.txs[i]
		for j in 0 ..< len(tx.inputs) {
			count += count_legacy_sigops(tx.inputs[j].script_sig)
		}
		for j in 0 ..< len(tx.outputs) {
			count += count_legacy_sigops(tx.outputs[j].script_pubkey)
		}
	}
	return count
}

// Get script verification flags based on BIP activation heights.
get_script_flags :: proc(height: int, params: ^Chain_Params) -> script.Verify_Flags {
	flags := script.Verify_Flags{}

	// P2SH active from height >= 1 (always for practical purposes)
	if height >= 1 {
		flags += {.P2SH}
	}

	// BIP66 — strict DER + strict encoding
	if height >= params.bip66_height {
		flags += {.DER_Sig, .Strict_Enc}
	}

	// BIP65 — CHECKLOCKTIMEVERIFY
	if height >= params.bip65_height {
		flags += {.Check_Locktime}
	}

	// CSV — CHECKSEQUENCEVERIFY
	if height >= params.csv_height {
		flags += {.Check_Sequence}
	}

	// SegWit
	if height >= params.segwit_height {
		flags += {.Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}
	}

	return flags
}

// BIP141: Check witness commitment in coinbase.
check_witness_commitment :: proc(block: ^wire.Block) -> Consensus_Error {
	if len(block.txs) == 0 {
		return .Bad_Witness_Commitment
	}

	coinbase := block.txs[0]

	// Find the last output with OP_RETURN + witness commitment header
	commitment_idx := -1
	for i := len(coinbase.outputs) - 1; i >= 0; i -= 1 {
		spk := coinbase.outputs[i].script_pubkey
		if len(spk) >= 38 && spk[0] == 0x6a && spk[1] == 0x24 { // OP_RETURN OP_PUSH36
			if spk[2] == COINBASE_WITNESS_COMMITMENT_HEADER[0] &&
			   spk[3] == COINBASE_WITNESS_COMMITMENT_HEADER[1] &&
			   spk[4] == COINBASE_WITNESS_COMMITMENT_HEADER[2] &&
			   spk[5] == COINBASE_WITNESS_COMMITMENT_HEADER[3] {
				commitment_idx = i
				break
			}
		}
	}

	if commitment_idx < 0 {
		return .Bad_Witness_Commitment
	}

	// Coinbase must have witness with exactly 1 item of 32 bytes (the nonce)
	if !wire.tx_has_witness(&coinbase) {
		return .Bad_Witness_Nonce
	}
	if len(coinbase.witness) == 0 || len(coinbase.witness[0]) != 1 || len(coinbase.witness[0][0]) != 32 {
		return .Bad_Witness_Nonce
	}
	nonce := coinbase.witness[0][0]

	// Compute witness merkle root
	// coinbase wtxid is all zeros, other txs use their wtxid
	wtxids := make([]crypto.Hash256, len(block.txs), context.temp_allocator)
	wtxids[0] = crypto.HASH_ZERO // coinbase
	for i in 1 ..< len(block.txs) {
		tx := block.txs[i]
		wtxids[i] = wire.tx_witness_id(&tx)
	}
	witness_root := crypto.merkle_root(wtxids)

	// commitment = SHA256d(witness_root || nonce)
	commitment_data: [64]byte
	for i in 0 ..< 32 {
		commitment_data[i] = witness_root[i]
	}
	for i in 0 ..< 32 {
		commitment_data[i + 32] = nonce[i]
	}
	computed_commitment := crypto.sha256d(commitment_data[:])

	// Compare against the stored commitment
	stored_commitment: [32]byte
	spk := coinbase.outputs[commitment_idx].script_pubkey
	for i in 0 ..< 32 {
		stored_commitment[i] = spk[6 + i]
	}

	if computed_commitment != stored_commitment {
		return .Bad_Witness_Commitment
	}

	return .None
}
