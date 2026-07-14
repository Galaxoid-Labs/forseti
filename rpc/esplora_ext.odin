package rpc

// Esplora REST — full-parity endpoints (Phase 2 coverage). Adds the Blockstream
// Esplora HTTP API surface beyond the BDK-critical subset in esplora.odin:
//   - /address/:addr[/txs[/chain/:last | /mempool]] , /address/:addr/utxo
//   - /address/:addr and /scripthash/:h summaries (chain_stats / mempool_stats)
//   - /block/:hash , /block/:hash/status , /block/:hash/txids ,
//     /block/:hash/txs[/:start] , /block/:hash/txid/:i , /block/:hash/raw
//   - /tx/:txid/outspends , /tx/:txid/outspend/:vout ,
//     /tx/:txid/merkle-proof , /tx/:txid/merkleblock-proof
//   - /mempool , /mempool/txids , /mempool/recent
//
// All read-only over the address index (RocksDB), block index, flat files and
// mempool — the same concurrency surface the existing esplora endpoints use
// (chain thread is the sole writer; readers are safe). Spent-ness is derived
// from the address index + mempool, NEVER the coins cache (which mutates on
// read and would race the chain thread).

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../chain"
import "../consensus"
import crypto "../crypto"
import "../mempool"
import "../script"
import "../storage"
import "../wire"

ESPLORA_RECENT :: 10 // /mempool/recent page size (Esplora default)

// Max scripthash history rows the stats summary will resolve. Each row costs a
// tx load from disk, so above this the summary would take many seconds and tie
// up a connection thread — refused (400, detected cheaply via an early-exit
// count before any history is materialized). Wallet addresses are far below it;
// only mega-reused addresses (exchanges / pools / the genesis address) hit it,
// which is also where blockstream's Esplora rate-limits its own address endpoints.
ESPLORA_STATS_MAX_ROWS :: 10_000
ESPLORA_STATS_SCRATCH_RESET :: 2048 // free the per-row tx-load arena every N rows

// --- address endpoints (thin wrappers over scripthash, address→spk→sha256) ---

_esplora_address_route :: proc(srv: ^Esplora_Server, segs: []string) -> (int, string, []byte) {
	spk, ok := _address_to_script_pubkey(segs[1], srv.params)
	if !ok { return 400, "text/plain", transmute([]byte)string("Invalid Bitcoin address") }
	sh := crypto.sha256_hash(spk)

	if len(segs) == 2 {
		return _esplora_summary_response(srv, sh, segs[1])
	}
	if segs[2] == "utxo" {
		return _esplora_scripthash_utxo(srv, sh)
	}
	if segs[2] == "txs" {
		mode := ""
		last_seen := ""
		if len(segs) >= 4 {
			mode = segs[3]
			if len(segs) >= 5 { last_seen = segs[4] }
		}
		return _esplora_scripthash_txs(srv, sh, mode, last_seen)
	}
	return _not_found()
}

// --- scripthash / address summary (chain_stats + mempool_stats) ---

// GET /scripthash/:h or /address/:a → { (scripthash|address), chain_stats, mempool_stats }.
// address_str != "" emits an "address" field (address route); else "scripthash".
_esplora_summary_response :: proc(srv: ^Esplora_Server, sh: Hash256, address_str: string) -> (int, string, []byte) {
	chain_stats, mempool_stats, ok := _esplora_scripthash_stats(srv, sh)
	if !ok {
		return 400, "text/plain", transmute([]byte)string("address history too large for a stats summary — use /txs and /utxo with pagination")
	}
	obj := make(json.Object, 3, context.temp_allocator)
	if address_str != "" {
		obj["address"] = _es(address_str)
	} else {
		obj["scripthash"] = _es(_scripthash_to_hex(sh))
	}
	obj["chain_stats"] = chain_stats
	obj["mempool_stats"] = mempool_stats
	return _json_ok(string(_json_bytes(json.Value(obj))))
}

_esplora_stats_obj :: proc(funded_count, spent_count: int, funded_sum, spent_sum: i64, tx_count: int) -> json.Value {
	o := make(json.Object, 5, context.temp_allocator)
	o["funded_txo_count"] = _ei(i64(funded_count))
	o["funded_txo_sum"] = _ei(funded_sum)
	o["spent_txo_count"] = _ei(i64(spent_count))
	o["spent_txo_sum"] = _ei(spent_sum)
	o["tx_count"] = _ei(i64(tx_count))
	return json.Value(o)
}

// Compute confirmed (chain) and unconfirmed (mempool) touch statistics for a
// scripthash. Confirmed values are resolved from the flat files (the H history
// rows carry no value), so cost scales with history length: refused (ok=false)
// above ESPLORA_STATS_MAX_ROWS, and the per-row tx loads run in a scratch arena
// freed every ESPLORA_STATS_SCRATCH_RESET rows so RAM stays bounded regardless
// of history size (a naive temp-allocator loop OOM-kills the node on a
// mega-history address).
_esplora_scripthash_stats :: proc(srv: ^Esplora_Server, sh: Hash256) -> (chain_stats: json.Value, mempool_stats: json.Value, ok: bool) {
	// Cheap early-exit cap check BEFORE materializing the history — a
	// mega-history scripthash otherwise blows out both scan time and memory.
	if _, exceeded := storage.addr_index_history_count_capped(srv.chain.addr_index, sh, ESPLORA_STATS_MAX_ROWS); exceeded {
		return nil, nil, false
	}
	hist := storage.addr_index_get_history(srv.chain.addr_index, sh, context.temp_allocator)

	// Pass 1 — counts + unique tx_count (no disk, on the request allocator).
	txset := make(map[Hash256]bool, len(hist), context.temp_allocator)
	funded_count, spent_count := 0, 0
	for e in hist {
		txset[e.txid] = true
		if e.io == 0 { funded_count += 1 } else { spent_count += 1 }
	}

	// Pass 2 — value sums. Each row loads a tx from disk; do it in a scratch
	// arena reset periodically so memory can't grow with history length.
	funded_sum, spent_sum: i64
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch, 16 * 1024 * 1024) == nil {
		defer virtual.arena_destroy(&scratch)
		saved := context.temp_allocator
		context.temp_allocator = virtual.arena_allocator(&scratch)
		for e, i in hist {
			if e.io == 0 { // funding: value = output[idx] of e.txid
				if tx, _, _, _, found := chain.addr_index_lookup_tx(srv.chain, e.txid); found && int(e.idx) < len(tx.outputs) {
					funded_sum += tx.outputs[e.idx].value
				}
			} else { // spending: value = the prevout consumed by input[idx] of e.txid
				if stx, _, _, _, found := chain.addr_index_lookup_tx(srv.chain, e.txid); found && int(e.idx) < len(stx.inputs) {
					po := stx.inputs[e.idx].previous_output
					if _, val, ok2 := _esplora_resolve_prevout(srv, po.hash, int(po.index)); ok2 {
						spent_sum += val
					}
				}
			}
			if (i + 1) % ESPLORA_STATS_SCRATCH_RESET == 0 { free_all(context.temp_allocator) }
		}
		context.temp_allocator = saved
	}
	chain_stats = _esplora_stats_obj(funded_count, spent_count, funded_sum, spent_sum, len(txset))

	// --- mempool stats ---
	mfc, msc := 0, 0
	mfs, mss: i64
	mtx := 0
	for txid in _esplora_mempool_matches(srv, sh) {
		if tx, _, ok := _esplora_resolve_tx(srv, txid); ok {
			mtx += 1
			for o in tx.outputs {
				if crypto.sha256_hash(o.script_pubkey) == sh { mfc += 1; mfs += o.value }
			}
			for in_ in tx.inputs {
				if spk, val, ok2 := _esplora_resolve_prevout(srv, in_.previous_output.hash, int(in_.previous_output.index)); ok2 {
					if crypto.sha256_hash(spk) == sh { msc += 1; mss += val }
				}
			}
		}
	}
	mempool_stats = _esplora_stats_obj(mfc, msc, mfs, mss, mtx)
	ok = true
	return
}

// --- block detail endpoints ---

_esplora_load_block :: proc(srv: ^Esplora_Server, hash_hex: string) -> (block: wire.Block, entry: ^chain.Block_Index_Entry, ok: bool) {
	hash, hok := _hex_to_hash(hash_hex)
	if !hok { return {}, nil, false }
	e, found := srv.chain.block_index.entries[hash]
	if !found || .Has_Data not_in e.status { return {}, nil, false }
	loc := storage.Block_Location{file_num = e.file_num, data_offset = e.data_offset, data_size = e.data_size}
	blk, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
	if berr != .None { return {}, nil, false }
	return blk, e, true
}

// GET /block/:hash — full block object.
_esplora_block_info :: proc(srv: ^Esplora_Server, hash_hex: string) -> (int, string, []byte) {
	hash, hok := _hex_to_hash(hash_hex)
	if !hok { return 400, "text/plain", transmute([]byte)string("invalid block hash") }
	entry, found := srv.chain.block_index.entries[hash]
	if !found { return 404, "text/plain", transmute([]byte)string("block not found") }
	return _json_ok(string(_json_bytes(_esplora_make_block_object(srv, hash, entry))))
}

// GET /block/:hash/status — { in_best_chain, height, next_best }.
_esplora_block_status :: proc(srv: ^Esplora_Server, hash_hex: string) -> (int, string, []byte) {
	hash, hok := _hex_to_hash(hash_hex)
	if !hok { return 400, "text/plain", transmute([]byte)string("invalid block hash") }
	entry, found := srv.chain.block_index.entries[hash]
	if !found { return 404, "text/plain", transmute([]byte)string("block not found") }
	h := entry.height
	in_best := h >= 0 && h < len(srv.chain.active_chain) && srv.chain.active_chain[h] == hash
	o := make(json.Object, 3, context.temp_allocator)
	o["in_best_chain"] = _eb(in_best)
	if in_best {
		o["height"] = _ei(i64(h))
		if h + 1 < len(srv.chain.active_chain) {
			o["next_best"] = _es(_hash_to_hex(srv.chain.active_chain[h + 1]))
		}
	}
	return _json_ok(string(_json_bytes(json.Value(o))))
}

// GET /block/:hash/txids — [ txid, ... ] in block order.
_esplora_block_txids :: proc(srv: ^Esplora_Server, hash_hex: string) -> (int, string, []byte) {
	block, _, ok := _esplora_load_block(srv, hash_hex)
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	arr := make(json.Array, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		arr[i] = _es(_hash_to_hex(wire.tx_id(&block.txs[i])))
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// GET /block/:hash/txs[/:start_index] — up to 25 full tx objects from start_index.
_esplora_block_txs :: proc(srv: ^Esplora_Server, segs: []string) -> (int, string, []byte) {
	block, entry, ok := _esplora_load_block(srv, segs[1])
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	start := 0
	if len(segs) >= 4 {
		if s, sok := strconv.parse_int(segs[3]); sok { start = s }
	}
	if start < 0 || start >= len(block.txs) { return _json_ok("[]") }
	bh, _ := _hex_to_hash(segs[1])
	arr := make(json.Array, 0, ESPLORA_PAGE, context.temp_allocator)
	for i := start; i < len(block.txs) && len(arr) < ESPLORA_PAGE; i += 1 {
		meta := _Esplora_Tx_Meta{
			confirmed = true, height = entry.height, block_hash = bh,
			block_time = entry.timestamp, position = i,
		}
		append(&arr, _esplora_tx_json(srv, &block.txs[i], wire.tx_id(&block.txs[i]), meta))
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// GET /block/:hash/txid/:index — single txid (text).
_esplora_block_txid :: proc(srv: ^Esplora_Server, hash_hex: string, index_str: string) -> (int, string, []byte) {
	block, _, ok := _esplora_load_block(srv, hash_hex)
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	idx, iok := strconv.parse_int(index_str)
	if !iok || idx < 0 || idx >= len(block.txs) {
		return 404, "text/plain", transmute([]byte)string("index out of range")
	}
	return _txt(_hash_to_hex(wire.tx_id(&block.txs[idx])))
}

// GET /block/:hash/raw — raw serialized block bytes.
_esplora_block_raw :: proc(srv: ^Esplora_Server, hash_hex: string) -> (int, string, []byte) {
	block, _, ok := _esplora_load_block(srv, hash_hex)
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_block(&w, &block)
	return 200, "application/octet-stream", wire.writer_bytes(&w)
}

// Full Esplora block object (shared by /block/:hash and /blocks summaries).
_esplora_make_block_object :: proc(srv: ^Esplora_Server, bh: Hash256, entry: ^chain.Block_Index_Entry) -> json.Value {
	height := entry.height
	merkle: Hash256
	tx_count := int(entry.num_tx)
	size := 0
	weight := 0
	if .Has_Data in entry.status {
		loc := storage.Block_Location{file_num = entry.file_num, data_offset = entry.data_offset, data_size = entry.data_size}
		if block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator); berr == .None {
			merkle = block.header.merkle_root
			tx_count = len(block.txs)
			size = int(entry.data_size)
			w := 0
			for i in 0 ..< len(block.txs) { w += consensus.get_tx_weight(&block.txs[i]) }
			// Block weight also counts the 80-byte header + tx-count varint as
			// base (non-witness) bytes, i.e. ×4 (Esplora / Core CBlock weight).
			weight = w + 4 * (80 + wire.compact_size_length(u64(len(block.txs))))
		}
	} else if height == 0 {
		merkle = srv.chain.params.genesis_header.merkle_root
		tx_count = 1
	}

	o := make(json.Object, 14, context.temp_allocator)
	o["id"] = _es(_hash_to_hex(bh))
	o["height"] = _ei(i64(height))
	o["version"] = _ei(i64(entry.version))
	o["timestamp"] = _ei(i64(entry.timestamp))
	o["tx_count"] = _ei(i64(tx_count))
	o["size"] = _ei(i64(size))
	o["weight"] = _ei(i64(weight))
	o["merkle_root"] = _es(_hash_to_hex(merkle))
	if height > 0 {
		o["previousblockhash"] = _es(_hash_to_hex(entry.prev_hash))
	}
	o["mediantime"] = _ei(i64(chain.get_median_time_past(entry)))
	o["nonce"] = _ei(i64(entry.nonce))
	o["bits"] = _ei(i64(entry.bits))
	o["difficulty"] = _ef(consensus.get_difficulty(entry.bits))
	return json.Value(o)
}

// --- tx outspend endpoints ---

// GET /tx/:txid/outspends — spend status per output.
_esplora_tx_outspends :: proc(srv: ^Esplora_Server, tx: ^wire.Tx, txid: Hash256) -> (int, string, []byte) {
	arr := make(json.Array, len(tx.outputs), context.temp_allocator)
	for i in 0 ..< len(tx.outputs) {
		arr[i] = _esplora_outspend_json(srv, txid, i, tx.outputs[i].script_pubkey)
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// GET /tx/:txid/outspend/:vout — spend status of one output.
_esplora_tx_outspend :: proc(srv: ^Esplora_Server, tx: ^wire.Tx, txid: Hash256, vout_str: string) -> (int, string, []byte) {
	vout, ok := strconv.parse_int(vout_str)
	if !ok || vout < 0 || vout >= len(tx.outputs) {
		return 404, "text/plain", transmute([]byte)string("vout out of range")
	}
	return _json_ok(string(_json_bytes(_esplora_outspend_json(srv, txid, vout, tx.outputs[vout].script_pubkey))))
}

_esplora_outspend_json :: proc(srv: ^Esplora_Server, txid: Hash256, vout: int, spk: []byte) -> json.Value {
	spent, spender, vin, meta := _esplora_find_spend(srv, wire.Outpoint{hash = txid, index = u32(vout)}, spk)
	o := make(json.Object, 4, context.temp_allocator)
	o["spent"] = _eb(spent)
	if spent {
		o["txid"] = _es(_hash_to_hex(spender))
		o["vin"] = _ei(i64(vin))
		o["status"] = _esplora_status_json(srv, meta)
	}
	return json.Value(o)
}

// Determine whether an outpoint is spent, and by whom. Order: mempool spend →
// unspent (U row present) → confirmed spend (scan the prevout scripthash's
// spending history) → unspent/unspendable fallback. Never touches the coins
// cache (races the chain thread); the address index is the source of truth.
_esplora_find_spend :: proc(srv: ^Esplora_Server, outpoint: wire.Outpoint, spk: []byte) -> (spent: bool, spender: Hash256, vin: int, meta: _Esplora_Tx_Meta) {
	// 1. Spent by an unconfirmed mempool tx?
	if stxid, ok := srv.mp.spent_outpoints[outpoint]; ok {
		v := 0
		if entry, efound := mempool.mempool_get(srv.mp, stxid); efound {
			for i in 0 ..< len(entry.tx.inputs) {
				if entry.tx.inputs[i].previous_output == outpoint { v = i; break }
			}
		}
		return true, stxid, v, _Esplora_Tx_Meta{confirmed = false}
	}

	sh := crypto.sha256_hash(spk)

	// 2. Still unspent? A live U row means the coin exists in the confirmed set.
	for u in storage.addr_index_get_utxos(srv.chain.addr_index, sh, context.temp_allocator) {
		if u.txid == outpoint.hash && u.vout == outpoint.index {
			return false, {}, 0, {}
		}
	}

	// 3. Spent by a confirmed tx — find the spending input among this
	//    scripthash's spending history.
	for e in storage.addr_index_get_history(srv.chain.addr_index, sh, context.temp_allocator) {
		if e.io != 1 { continue }
		stx, sbh, sheight, spos, ok := chain.addr_index_lookup_tx(srv.chain, e.txid)
		if !ok || int(e.idx) >= len(stx.inputs) { continue }
		if stx.inputs[e.idx].previous_output == outpoint {
			block_time: u32 = 0
			if be, bok := srv.chain.block_index.entries[sbh]; bok { block_time = be.timestamp }
			return true, e.txid, int(e.idx), _Esplora_Tx_Meta{
				confirmed = true, height = sheight, block_hash = sbh,
				block_time = block_time, position = spos,
			}
		}
	}

	// 4. No spender found (e.g. an unspendable OP_RETURN output) → unspent.
	return false, {}, 0, {}
}

// --- tx merkle proofs ---

// GET /tx/:txid/merkle-proof — { block_height, merkle: [hex,...], pos }.
_esplora_tx_merkle_proof :: proc(srv: ^Esplora_Server, txid: Hash256, meta: _Esplora_Tx_Meta) -> (int, string, []byte) {
	if !meta.confirmed { return 404, "text/plain", transmute([]byte)string("Transaction not confirmed") }
	block, _, ok := _esplora_load_block(srv, _hash_to_hex(meta.block_hash))
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	all_txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) { all_txids[i] = wire.tx_id(&block.txs[i]) }

	branch := _esplora_merkle_branch(all_txids, meta.position)
	marr := make(json.Array, len(branch), context.temp_allocator)
	for i in 0 ..< len(branch) { marr[i] = _es(_hash_to_hex(branch[i])) }

	o := make(json.Object, 3, context.temp_allocator)
	o["block_height"] = _ei(i64(meta.height))
	o["merkle"] = json.Value(marr)
	o["pos"] = _ei(i64(meta.position))
	return _json_ok(string(_json_bytes(json.Value(o))))
}

// GET /tx/:txid/merkleblock-proof — hex-encoded BIP37 merkleblock (as gettxoutproof).
_esplora_tx_merkleblock_proof :: proc(srv: ^Esplora_Server, txid: Hash256, meta: _Esplora_Tx_Meta) -> (int, string, []byte) {
	if !meta.confirmed { return 404, "text/plain", transmute([]byte)string("Transaction not confirmed") }
	block, _, ok := _esplora_load_block(srv, _hash_to_hex(meta.block_hash))
	if !ok { return 404, "text/plain", transmute([]byte)string("block not found") }
	all_txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) { all_txids[i] = wire.tx_id(&block.txs[i]) }
	match_set := make(map[Hash256]bool, 1, context.temp_allocator)
	match_set[txid] = true

	hashes, flags, flags_len := crypto.merkle_build_partial_tree(all_txids, match_set)
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_block_header(&w, &block.header)
	wire.write_u32le(&w, u32(len(block.txs)))
	wire.write_compact_size(&w, u64(len(hashes)))
	for h in hashes { h := h; wire.write_bytes(&w, h[:]) }
	wire.write_compact_size(&w, u64(flags_len))
	wire.write_bytes(&w, flags[:flags_len])
	return _txt(_bytes_to_hex(wire.writer_bytes(&w)))
}

// Merkle authentication branch (sibling hashes bottom→top) for tx at `pos`.
_esplora_merkle_branch :: proc(all_txids: []Hash256, pos: int) -> []Hash256 {
	branch := make([dynamic]Hash256, 0, 16, context.temp_allocator)
	level := make([dynamic]Hash256, len(all_txids), context.temp_allocator)
	copy(level[:], all_txids)
	index := pos
	for len(level) > 1 {
		if len(level) % 2 == 1 { append(&level, level[len(level) - 1]) }
		sib := index + 1 if index % 2 == 0 else index - 1
		append(&branch, level[sib])
		next := make([dynamic]Hash256, 0, len(level) / 2, context.temp_allocator)
		for i := 0; i < len(level); i += 2 {
			a := level[i]; b := level[i + 1]
			append(&next, crypto.sha256d_multi(a[:], b[:]))
		}
		level = next
		index /= 2
	}
	return branch[:]
}

// --- mempool endpoints ---

// GET /mempool — { count, vsize, total_fee, fee_histogram }.
_esplora_mempool_info :: proc(srv: ^Esplora_Server) -> (int, string, []byte) {
	count := len(srv.mp.entries)
	total_vsize := 0
	total_fee: i64 = 0
	// bucket vsize by integer sat/vB for the histogram
	buckets := make(map[int]i64, 64, context.temp_allocator)
	for _, entry in srv.mp.entries {
		total_vsize += entry.vsize
		total_fee += entry.fee
		rate := int(mempool.fee_rate_per_kvb(entry.fee_rate) / 1000) // sat/vB floor
		buckets[rate] = buckets[rate] + i64(entry.vsize)
	}
	rates := make([dynamic]int, 0, len(buckets), context.temp_allocator)
	for r in buckets { append(&rates, r) }
	slice.sort(rates[:])
	slice.reverse(rates[:])
	hist := make(json.Array, 0, len(rates), context.temp_allocator)
	for r in rates {
		pair := make(json.Array, 2, context.temp_allocator)
		pair[0] = _ef(f64(r))
		pair[1] = _ei(buckets[r])
		append(&hist, json.Value(pair))
	}

	o := make(json.Object, 4, context.temp_allocator)
	o["count"] = _ei(i64(count))
	o["vsize"] = _ei(i64(total_vsize))
	o["total_fee"] = _ei(total_fee)
	o["fee_histogram"] = json.Value(hist)
	return _json_ok(string(_json_bytes(json.Value(o))))
}

// GET /mempool/txids — [ txid, ... ] for every mempool entry.
_esplora_mempool_txids :: proc(srv: ^Esplora_Server) -> (int, string, []byte) {
	arr := make(json.Array, 0, len(srv.mp.entries), context.temp_allocator)
	for txid in srv.mp.entries {
		append(&arr, _es(_hash_to_hex(txid)))
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// GET /mempool/recent — [ { txid, fee, vsize, value }, ... ] newest-first.
_esplora_mempool_recent :: proc(srv: ^Esplora_Server) -> (int, string, []byte) {
	entries := make([dynamic]^mempool.Mempool_Entry, 0, len(srv.mp.entries), context.temp_allocator)
	for _, entry in srv.mp.entries { append(&entries, entry) }
	slice.sort_by(entries[:], proc(a, b: ^mempool.Mempool_Entry) -> bool { return a.time > b.time })
	arr := make(json.Array, 0, ESPLORA_RECENT, context.temp_allocator)
	for entry in entries {
		if len(arr) >= ESPLORA_RECENT { break }
		value: i64 = 0
		for o in entry.tx.outputs { value += o.value }
		obj := make(json.Object, 4, context.temp_allocator)
		obj["txid"] = _es(_hash_to_hex(entry.txid))
		obj["fee"] = _ei(entry.fee)
		obj["vsize"] = _ei(i64(entry.vsize))
		obj["value"] = _ei(value)
		append(&arr, json.Value(obj))
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// Scripthash summaries key on FORWARD sha256(spk) hex (Esplora convention).
_scripthash_to_hex :: proc(sh: Hash256) -> string {
	sh := sh
	return _bytes_to_hex(sh[:])
}

// --- script disassembly (rust-bitcoin / Esplora asm style) ---
//
// Distinct from script.script_to_asm (Core decodescript style, kept for
// getrawtransaction/decodescript): Esplora spells out the push opcode before
// each data push (OP_PUSHBYTES_N / OP_PUSHDATA{1,2,4}) and names the numeric
// pushes OP_0 / OP_PUSHNUM_1..16 / OP_PUSHNUM_NEG1 — the format bdk / block
// explorers deserialize.
_esplora_script_to_asm :: proc(s: []byte) -> string {
	b := strings.builder_make(0, len(s) * 3, context.temp_allocator)
	i := 0
	first := true
	write_data :: proc(b: ^strings.Builder, name: string, data: []byte) {
		strings.write_string(b, name)
		strings.write_byte(b, ' ')
		strings.write_string(b, _bytes_to_hex(data))
	}
	for i < len(s) {
		if !first { strings.write_byte(&b, ' ') }
		first = false
		op := s[i]
		i += 1
		if op >= 0x01 && op <= 0x4b {
			n := int(op)
			if i + n > len(s) { strings.write_string(&b, "OP_PUSHBYTES_UNEXPECTED_END"); break }
			write_data(&b, fmt.tprintf("OP_PUSHBYTES_%d", n), s[i:i + n]); i += n
		} else if op == 0x4c { // OP_PUSHDATA1
			if i >= len(s) { break }
			n := int(s[i]); i += 1
			if i + n > len(s) { break }
			write_data(&b, "OP_PUSHDATA1", s[i:i + n]); i += n
		} else if op == 0x4d { // OP_PUSHDATA2
			if i + 1 >= len(s) { break }
			n := int(s[i]) | int(s[i + 1]) << 8; i += 2
			if i + n > len(s) { break }
			write_data(&b, "OP_PUSHDATA2", s[i:i + n]); i += n
		} else if op == 0x4e { // OP_PUSHDATA4
			if i + 3 >= len(s) { break }
			n := int(s[i]) | int(s[i + 1]) << 8 | int(s[i + 2]) << 16 | int(s[i + 3]) << 24; i += 4
			if i + n > len(s) { break }
			write_data(&b, "OP_PUSHDATA4", s[i:i + n]); i += n
		} else {
			strings.write_string(&b, _esplora_opcode_name(op))
		}
	}
	return strings.to_string(b)
}

// Opcode names, overriding the three that differ from rust-bitcoin's spelling.
_esplora_opcode_name :: proc(op: u8) -> string {
	switch {
	case op == 0x00:            return "OP_0"
	case op == 0x4f:            return "OP_PUSHNUM_NEG1"
	case op >= 0x51 && op <= 0x60: return fmt.tprintf("OP_PUSHNUM_%d", int(op) - 0x50)
	}
	return script.opcode_name(op)
}

// Last data push in a script (the redeem script of a P2SH scriptSig).
_esplora_last_push :: proc(s: []byte) -> ([]byte, bool) {
	i := 0
	last: []byte
	found := false
	for i < len(s) {
		op := s[i]; i += 1
		n := 0
		if op >= 0x01 && op <= 0x4b {
			n = int(op)
		} else if op == 0x4c {
			if i >= len(s) { break }
			n = int(s[i]); i += 1
		} else if op == 0x4d {
			if i + 1 >= len(s) { break }
			n = int(s[i]) | int(s[i + 1]) << 8; i += 2
		} else if op == 0x4e {
			if i + 3 >= len(s) { break }
			n = int(s[i]) | int(s[i + 1]) << 8 | int(s[i + 2]) << 16 | int(s[i + 3]) << 24; i += 4
		} else {
			continue // non-push opcode
		}
		if i + n > len(s) { break }
		last = s[i:i + n]; found = true; i += n
	}
	return last, found
}

// Compute inner_redeemscript_asm / inner_witnessscript_asm for an input,
// mirroring Esplora: redeem script for P2SH prevouts (last scriptSig push),
// witness script for P2WSH prevouts and P2SH-wrapped P2WSH (last witness item).
// Returned so the caller mutates its own input map in-scope (passing a map by
// value and inserting is unsafe across a call if the insert triggers a grow).
_esplora_inner_scripts :: proc(prev_spk: []byte, script_sig: []byte, witness: [][]byte) -> (redeem_asm: string, has_redeem: bool, witness_asm: string, has_witness: bool) {
	#partial switch script.classify_script(prev_spk) {
	case .P2SH:
		if rs, ok := _esplora_last_push(script_sig); ok {
			redeem_asm = _esplora_script_to_asm(rs); has_redeem = true
			if script.classify_script(rs) == .P2WSH && len(witness) > 0 {
				witness_asm = _esplora_script_to_asm(witness[len(witness) - 1]); has_witness = true
			}
		}
	case .P2WSH:
		if len(witness) > 0 {
			witness_asm = _esplora_script_to_asm(witness[len(witness) - 1]); has_witness = true
		}
	}
	return
}
