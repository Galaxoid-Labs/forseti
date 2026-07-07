// Regtest block generation (generatetoaddress). Builds a valid block from
// the mempool + a coinbase paying the given script, grinds the (trivial on
// regtest) PoW, and submits through the normal accept_block pipeline so it
// gets exactly the same validation as a network block.
package chain

import "core:time"
import "../consensus"
import crypto "../crypto"
import "../storage"
import "../wire"

COINBASE_WITNESS_RESERVED :: [32]byte{}

// One selected mempool transaction (chain cannot import mempool — cycle —
// so the caller does selection and hands over the pieces).
Mine_Tx :: struct {
	tx:    wire.Tx,
	txid:  Hash256,
	wtxid: Hash256,
}

// Mine one block on top of the current tip. Returns the new block hash.
mine_block :: proc(cs: ^Chain_State, selected: []Mine_Tx, total_fees: i64, coinbase_spk: []byte, max_tries: int) -> (block_hash: Hash256, err: Chain_Error) {
	// Fresh regtest datadir: genesis exists in the index but is only
	// connected lazily. Mining block 1 needs it active — bootstrap it.
	if len(cs.active_chain) == 0 && cs.block_index.genesis != nil {
		g := cs.block_index.genesis
		if .Valid_Chain not_in g.status {
			g.status += {.Valid_Chain}
			append(&cs.active_chain, g.hash)
			rec := block_index_to_record(g)
			storage.index_db_put(&cs.index_db, rec)
		}
	}

	tip_hash, tip_height := chain_tip(cs)
	tip_entry, tip_found := cs.block_index.entries[tip_hash]
	if !tip_found {
		return {}, .Invalid_Prev_Block
	}
	height := tip_height + 1

	// Coinbase: BIP34 height push + marker, single payout + witness commitment.
	height_push := make([dynamic]byte, 0, 8, context.temp_allocator)
	{
		// Minimal CScriptNum push of the height.
		h := height
		num := make([dynamic]byte, 0, 5, context.temp_allocator)
		for h > 0 {
			append(&num, byte(h & 0xff))
			h >>= 8
		}
		if len(num) > 0 && num[len(num) - 1] & 0x80 != 0 {
			append(&num, 0)
		}
		append(&height_push, byte(len(num)))
		append(&height_push, ..num[:])
		append(&height_push, "/btcnode/")
	}

	subsidy := consensus.get_block_subsidy(height, cs.params)

	// wtxids for the witness commitment (coinbase counts as all-zero).
	wtxids := make([]Hash256, len(selected) + 1, context.temp_allocator)
	for e, i in selected {
		wtxids[i + 1] = e.wtxid
	}
	witness_root := crypto.merkle_root(wtxids)
	commit_preimage: [64]byte
	copy(commit_preimage[:32], witness_root[:])
	reserved := COINBASE_WITNESS_RESERVED
	copy(commit_preimage[32:], reserved[:])
	commitment := crypto.sha256d(commit_preimage[:])

	commit_spk := make([]byte, 38, context.temp_allocator)
	commit_spk[0] = 0x6a // OP_RETURN
	commit_spk[1] = 0x24 // push 36
	commit_spk[2] = 0xaa
	commit_spk[3] = 0x21
	commit_spk[4] = 0xa9
	commit_spk[5] = 0xed
	copy(commit_spk[6:], commitment[:])

	coinbase := wire.Tx{
		version = 2,
		inputs = []wire.Tx_In{{
			previous_output = wire.Outpoint{index = 0xffffffff},
			script_sig      = height_push[:],
			sequence        = 0xffffffff,
		}},
		outputs = []wire.Tx_Out{
			{value = subsidy + total_fees, script_pubkey = coinbase_spk},
			{value = 0, script_pubkey = commit_spk},
		},
		witness = [][][]byte{{reserved[:]}},
	}

	txs := make([]wire.Tx, len(selected) + 1, context.temp_allocator)
	txs[0] = coinbase
	for e, i in selected {
		txs[i + 1] = e.tx
	}

	// Merkle root over txids.
	txids := make([]Hash256, len(txs), context.temp_allocator)
	txids[0] = wire.tx_id(&txs[0])
	for e, i in selected {
		txids[i + 1] = e.txid
	}
	merkle := crypto.merkle_root(txids)

	now := u32(time.to_unix_seconds(time.now()))
	mtp := get_median_time_past(tip_entry)
	timestamp := max(now, mtp + 1)

	block := wire.Block{
		header = wire.Block_Header{
			version     = 0x20000000,
			prev_hash   = tip_hash,
			merkle_root = merkle,
			timestamp   = timestamp,
			bits        = get_next_work_required(cs, tip_entry, timestamp),
			nonce       = 0,
		},
		txs = txs,
	}

	// Grind.
	found := false
	for _ in 0 ..< max_tries {
		h := wire.block_header_hash(&block.header)
		if consensus.check_proof_of_work(h, block.header.bits, cs.params) {
			block_hash = h
			found = true
			break
		}
		block.header.nonce += 1
	}
	if !found {
		return {}, .Bad_Script // exhausted maxtries (regtest PoW should hit in a few nonces)
	}

	// Full normal validation + connect.
	aerr := accept_block(cs, &block)
	if aerr != .None {
		return {}, aerr
	}
	return block_hash, .None
}
