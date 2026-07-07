package p2p

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:time"

import "../chain"
import "../consensus"
import crypto "../crypto"
import "../mempool"
import "../storage"
import "../wire"
import zmqpkg "../zmq"

Sync_State :: enum {
	Idle,
	Syncing_Headers,
	Downloading_Blocks,
	In_Sync,
}

Peer_Sync_State :: struct {
	last_header_hash:    Hash256,
	getheaders_pending:  bool,
	getheaders_sent_at:  i64,
	blocks_in_flight:    int,
	last_block_received: i64,
	blocks_delivered:    int,
	tracking_since:      i64,
}

Compact_Block_State :: struct {
	header:          wire.Block_Header,
	block_hash:      Hash256,
	sipkey_k0:       u64,
	sipkey_k1:       u64,
	txs:             []^wire.Tx,  // nil entries = missing
	txs_owned:       []wire.Tx,   // heap-cloned prefilled txs (owned memory)
	total_txs:       int,
	missing_count:   int,
	missing_indices: []u64,
	from_peer:       Peer_Id,
	requested_at:    i64,
}

Sync_Manager :: struct {
	zmq:                ^zmqpkg.Node, // nil unless --zmqpub* configured (set with Conn_Manager.zmq)
	chain:              ^chain.Chain_State,
	params:             ^consensus.Chain_Params,
	mp:                 ^mempool.Mempool,
	last_halt_log_height: int, // rate-limits the validation-halt error (once per height, not per tick)
	state:              Sync_State,
	headers_received:   int,
	best_header_height: int,
	blocks_in_flight:   map[Hash256]Peer_Id,
	block_request_time: map[Hash256]i64,
	blocks_to_download: [dynamic]Hash256,
	download_cursor:    int, // index into blocks_to_download for next request
	requeue_list:       [dynamic]Hash256, // priority requeue — checked before main queue
	last_tip_update:    i64,
	peer_sync:          map[Peer_Id]Peer_Sync_State,
	peer_rr_list:       [dynamic]Peer_Id,
	peer_rr_cursor:     int,
	last_stall_check:   i64,
	header_lead_peer:   Peer_Id, // fastest responder becomes lead for header sync
	last_disconnect:    i64,     // timestamp of last stall disconnect (rate limit)
	compact_state:      ^Compact_Block_State, // pending compact block reconstruction (nil = none)
}

sync_manager_init :: proc(sm: ^Sync_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params, mp: ^mempool.Mempool = nil) {
	sm.chain = cs
	sm.params = params
	sm.mp = mp
	sm.state = .Idle
	sm.blocks_in_flight = make(map[Hash256]Peer_Id, 64)
	sm.block_request_time = make(map[Hash256]i64, 64)
	sm.blocks_to_download = make([dynamic]Hash256, 0, 1024)
	sm.requeue_list = make([dynamic]Hash256, 0, 64)
	sm.last_tip_update = time.to_unix_seconds(time.now())
	sm.peer_sync = make(map[Peer_Id]Peer_Sync_State, 16)
	sm.peer_rr_list = make([dynamic]Peer_Id, 0, 16)
	sm.peer_rr_cursor = 0
	sm.last_stall_check = time.to_unix_seconds(time.now())

	// Initialize best_header_height from loaded block index
	if cs.block_index.best_header != nil {
		sm.best_header_height = cs.block_index.best_header.height
	}
}

sync_manager_destroy :: proc(sm: ^Sync_Manager) {
	_compact_state_destroy(sm)
	delete(sm.blocks_in_flight)
	delete(sm.block_request_time)
	delete(sm.blocks_to_download)
	delete(sm.requeue_list)
	delete(sm.peer_sync)
	delete(sm.peer_rr_list)
}

// Register a newly-active peer for sync tracking.
sync_add_peer :: proc(sm: ^Sync_Manager, peer_id: Peer_Id) {
	now := time.to_unix_seconds(time.now())
	sm.peer_sync[peer_id] = Peer_Sync_State{
		last_block_received = now,
		tracking_since      = now,
	}
	append(&sm.peer_rr_list, peer_id)
}

// Whether our header chain already covers the best peer's advertised height.
// Peers that advertise start_height <= 0 (crawlers, spy nodes, misconfigured
// peers) must never convince a fresh node it is synced — without the
// best_peer_height > 0 guard, the first such peer to finish its handshake
// wedged a fresh node In_Sync at height 0 and header sync never started.
_headers_up_to_date :: proc(our_best_header: int, best_peer_height: i32) -> bool {
	return best_peer_height > 0 && our_best_header >= int(best_peer_height)
}

// Start header sync by racing all active peers. The fastest responder
// becomes the lead peer for the remainder of header download.
sync_start_header_sync :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) -> Peer_Id {
	best_height: i32 = 0
	any_active := false

	for _, peer in peers {
		if peer.state != .Active {
			continue
		}
		any_active = true
		if peer.start_height > best_height {
			best_height = peer.start_height
		}
	}

	if !any_active {
		return 0
	}

	// If we already have headers up to or beyond the best peer's height, skip to block download.
	if _headers_up_to_date(sm.best_header_height, best_height) {
		log.infof("Headers already up to date (height %d). Building download queue...", sm.best_header_height)
		_build_download_queue(sm)
		if len(sm.blocks_to_download) == 0 {
			sm.state = .In_Sync
		} else {
			sm.state = .Downloading_Blocks
			log.infof("%d blocks queued for download", len(sm.blocks_to_download))
			sync_request_blocks(sm, peers)
		}
		return 0
	}

	sm.state = .Syncing_Headers
	sm.headers_received = 0
	sm.header_lead_peer = 0 // no lead yet — first responder wins

	locator := build_block_locator(sm.chain)
	defer delete(locator)

	now := time.to_unix_seconds(time.now())
	sent := 0

	// Race: send getheaders to ALL active peers.
	for id, peer in peers {
		if peer.state != .Active {
			continue
		}
		peer_send_getheaders(peer, locator, HASH_ZERO)
		ps := sm.peer_sync[id]
		ps.getheaders_pending = true
		ps.getheaders_sent_at = now
		sm.peer_sync[id] = ps
		sent += 1
	}

	log.infof("Starting header sync: racing %d peers (best height %d)", sent, best_height)
	return 0
}

// Process a batch of headers from a peer.
sync_handle_headers :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, headers: []wire.Block_Header, peers: ^map[Peer_Id]^Peer) {
	accepted, best_h := chain.accept_block_headers_batch(sm.chain, headers)
	if best_h > sm.best_header_height {
		sm.best_header_height = best_h
	}

	sm.headers_received += accepted

	// If we're not actively syncing headers, handle as a steady-state announcement.
	// BIP130: peers announce new blocks via headers messages. Request the blocks.
	if sm.state != .Syncing_Headers {
		if accepted > 0 {
			_request_announced_blocks(sm, peer_id, headers, peers)
		}
		return
	}

	if sm.headers_received % 10000 < 2000 || len(headers) < MAX_HEADERS_PER_MSG {
		log.infof("Headers: %d (best header height: %d)", sm.headers_received, sm.best_header_height)
	}

	if len(headers) >= MAX_HEADERS_PER_MSG {
		// First full response wins the race — this peer becomes lead.
		if sm.header_lead_peer == 0 {
			sm.header_lead_peer = peer_id
			log.infof("Header sync lead: peer %d (fastest responder)", peer_id)

			// Cancel other peers' pending state so we don't wait for them.
			for id, ps in sm.peer_sync {
				if id != peer_id && ps.getheaders_pending {
					new_ps := ps
					new_ps.getheaders_pending = false
					sm.peer_sync[id] = new_ps
				}
			}
		}

		// Only send follow-up getheaders to the lead peer.
		if peer_id == sm.header_lead_peer {
			peer, found := peers[peer_id]
			if found {
				last_hdr := headers[len(headers) - 1]
				last_hash := wire.block_header_hash(&last_hdr)
				locator := [1]Hash256{last_hash}
				peer_send_getheaders(peer, locator[:], HASH_ZERO)

				now := time.to_unix_seconds(time.now())
				ps := sm.peer_sync[peer_id]
				ps.last_header_hash = last_hash
				ps.getheaders_pending = true
				ps.getheaders_sent_at = now
				sm.peer_sync[peer_id] = ps
			}
		} else {
			// Non-lead peer responded — accept headers (duplicates are no-ops) but don't follow up.
			ps := sm.peer_sync[peer_id]
			ps.getheaders_pending = false
			sm.peer_sync[peer_id] = ps
		}
	} else {
		// This peer is done sending headers.
		ps := sm.peer_sync[peer_id]
		ps.getheaders_pending = false
		sm.peer_sync[peer_id] = ps

		// Check if ALL peers are done with headers.
		all_done := true
		for id, pstate in sm.peer_sync {
			if pstate.getheaders_pending {
				// Only count peers that are still active.
				p, found := peers[id]
				if found && p.state == .Active {
					all_done = false
					break
				}
			}
		}

		if all_done {
			// Header sync complete — transition to block download.
			log.info("Header sync complete. Building download queue...")
			_build_download_queue(sm)

			if len(sm.blocks_to_download) == 0 {
				log.info("No blocks to download. Already in sync.")
				sm.state = .In_Sync
			} else {
				sm.state = .Downloading_Blocks
				log.infof("%d blocks queued for download", len(sm.blocks_to_download))
				sync_request_blocks(sm, peers)
			}
		}
	}
}

// Process a received block.
sync_handle_block :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, block: ^wire.Block, peers: ^map[Peer_Id]^Peer) {
	block_hash := wire.block_header_hash(&block.header)

	// Remove from in-flight tracking — decrement the OWNER's count (the peer
	// the block was last assigned to), not the sender's. When a block stalls
	// and gets requeued to peer B, but peer A responds late, we must decrement
	// B's count (the owner) to keep per-peer counts accurate.
	owner, was_in_flight := sm.blocks_in_flight[block_hash]
	delete_key(&sm.blocks_in_flight, block_hash)
	delete_key(&sm.block_request_time, block_hash)

	if was_in_flight {
		ops, ops_found := sm.peer_sync[owner]
		if ops_found {
			ops.blocks_in_flight = max(0, ops.blocks_in_flight - 1)
			sm.peer_sync[owner] = ops
		}
	}

	// Credit delivery to the actual sender.
	ps, ps_found := sm.peer_sync[peer_id]
	if ps_found {
		ps.last_block_received = time.to_unix_seconds(time.now())
		ps.blocks_delivered += 1
		sm.peer_sync[peer_id] = ps
	}

	// Store block to disk (doesn't connect yet).
	blk := block^
	serr := chain.store_block(sm.chain, &blk)
	if serr != .None {
		log.errorf("Failed to store block: %v", serr)
		return
	}

	// Try to connect as many consecutive blocks as possible from tip.
	prev_height: int
	_, prev_height = chain.chain_tip(sm.chain)

	// Log when a block is stored but can't connect yet (out-of-order arrival).
	block_entry, block_known := sm.chain.block_index.entries[block_hash]
	if block_known && block_entry.height > prev_height + 1 {
		gap := block_entry.height - prev_height - 1
		log.debugf("Block %d stored (peer %d), waiting for %d block(s) from height %d",
			block_entry.height, peer_id, gap, prev_height + 1)
	}

	redownload := make([dynamic]Hash256, 0, 4, context.temp_allocator)
	connected, cerr := chain.connect_pending_blocks(sm.chain, &redownload)
	if cerr != .None && cerr != .Storage_Error {
		_, tip_height := chain.chain_tip(sm.chain)
		if sm.last_halt_log_height != tip_height + 1 {
			sm.last_halt_log_height = tip_height + 1
			log.errorf("Block validation failed at height %d: %v — sync halted", tip_height + 1, cerr)
		}
		// Don't requeue or request more blocks — chain is stuck.
		return
	}

	// If a competing branch now carries more work than the active chain
	// (stale tip / reorg), switch to it. Cheap no-op in the common case —
	// including all of IBD, where the tip is an ancestor of best_header.
	chain.activate_best_chain(sm.chain)

	// Re-queue blocks that need re-download (storage errors only).
	for h in redownload {
		append(&sm.requeue_list, h)
	}

	if connected > 0 {
		_, height := chain.chain_tip(sm.chain)
		sm.last_tip_update = time.to_unix_seconds(time.now())


		// Budget-based UTXO flush: flush when coins cache exceeds its memory
		// budget, or as a durability safety net — every 5000 blocks for small
		// caches, and every 25,000 blocks for ANY cache size. Large caches
		// used to skip the net entirely (flushes once froze sync for
		// minutes); with the background flush that cost is gone, and an
		// unbounded gap means unbounded crash recovery — a 16 GiB cache
		// crashed 79,532 blocks past its last flush (2026-07-06) and paid
		// ~20 minutes of undo rollback.
		should_flush := chain.coins_cache_should_flush(&sm.chain.coins)
		safety_flush := (height / 5000 > prev_height / 5000 && sm.chain.coins.budget < 1024 * 1024 * 1024) ||
			height / 25_000 > prev_height / 25_000
		if should_flush || safety_flush {
			if chain.coins_cache_flush_running(&sm.chain.coins) {
				// A flush is already in flight. Backpressure safety valve: if
				// the cache has refilled past 1.5x budget while flushing, fall
				// back to blocking until the worker finishes (old behavior).
				if sm.chain.coins.mem_usage > sm.chain.coins.budget * 3 / 2 {
					log.warn("UTXO cache overfilled during background flush — blocking until it completes")
					chain.coins_cache_flush_join(&sm.chain.coins)
				}
			} else {
				tip_hash, tip_h := chain.chain_tip(sm.chain)
				chain.coins_cache_flush_begin(&sm.chain.coins, tip_hash, tip_h)
			}
		}

		// Reap a completed background flush: only then is the flushed state
		// durable — last_flush_height and pruning advance here, not at begin.
		if completed, _ := chain.coins_cache_flush_pump(&sm.chain.coins); completed {
			sm.chain.last_flush_height = sm.chain.coins.flush_tip_height
			chain.prune_block_files(sm.chain, sm.chain.last_flush_height)
			sm.last_tip_update = time.to_unix_seconds(time.now())
		}

		// Remove confirmed/conflicting txs from mempool and update tip for BIP 68/113.
		if sm.mp != nil {
			mempool.mempool_remove_for_block(sm.mp, block)
			mempool.mempool_update_tip(sm.mp)
		}

		// Announce the new block to peers (only when in sync — skip during IBD).
		if sm.state == .In_Sync {
			_announce_block(sm, peer_id, block, block_hash, peers)
		}

		remaining := sm.best_header_height - height
		progress_pct := f64(height) / f64(max(sm.best_header_height, 1)) * 100.0
		progress_interval := height / 1000 > prev_height / 1000
		if should_flush || safety_flush || remaining == 0 || progress_interval {
			log.infof("Blocks: %d / %d (%.2f%%), remaining: %d, in-flight: %d",
				height, sm.best_header_height, progress_pct, remaining, len(sm.blocks_in_flight))

			// Log per-peer throughput stats at 5000-block intervals.
			if height / 5000 > prev_height / 5000 && height > 5000 {
				_log_peer_throughput(sm)
			}
		}
	}

	// Request more blocks.
	sync_request_blocks(sm, peers)

	// Check if we're done.
	remaining := len(sm.requeue_list) + len(sm.blocks_to_download) - sm.download_cursor
	if remaining == 0 && len(sm.blocks_in_flight) == 0 {
		_, height := chain.chain_tip(sm.chain)
		log.infof("Block download complete. In sync at height %d", height)
		sm.state = .In_Sync
	}
}

// Compute the dynamic block limit for a peer based on throughput scoring.
_peer_block_limit :: proc(ps: Peer_Sync_State, now: i64, total_rate: f64, num_scored: int) -> int {
	elapsed := now - ps.tracking_since
	if elapsed < PEER_TRIAL_SECS {
		return PEER_TRIAL_BLOCKS
	}

	if total_rate <= 0 || num_scored <= 0 {
		return PEER_TRIAL_BLOCKS
	}

	peer_rate := f64(ps.blocks_delivered) / f64(elapsed)
	share := peer_rate / total_rate
	budget := f64(MAX_BLOCKS_PER_PEER * num_scored)
	limit := int(budget * share)

	return clamp(limit, MIN_BLOCKS_PER_PEER, MAX_BLOCKS_PER_PEER)
}

// Fill in-flight window from download queue using bandwidth-weighted round-robin.
sync_request_blocks :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	remaining := len(sm.requeue_list) + len(sm.blocks_to_download) - sm.download_cursor
	if remaining == 0 || len(sm.peer_rr_list) == 0 {
		return
	}

	now := time.to_unix_seconds(time.now())

	// First pass: compute total throughput across scored peers.
	total_rate: f64 = 0
	num_scored := 0
	for pid in sm.peer_rr_list {
		ps, found := sm.peer_sync[pid]
		if !found {
			continue
		}
		elapsed := now - ps.tracking_since
		if elapsed >= PEER_TRIAL_SECS && ps.blocks_delivered > 0 {
			total_rate += f64(ps.blocks_delivered) / f64(elapsed)
			num_scored += 1
		}
	}

	// Second pass: sort peers by throughput (fastest first).
	// The fastest peer gets blocks at the front of the queue (near tip),
	// so slow peers can't block chain progress.
	sorted_pids := make([dynamic]Peer_Id, 0, len(sm.peer_rr_list), context.temp_allocator)
	sorted_rates := make([dynamic]f64, 0, len(sm.peer_rr_list), context.temp_allocator)
	for pid in sm.peer_rr_list {
		peer, found := peers[pid]
		if !found || peer.state != .Active {
			continue
		}
		ps, ps_found := sm.peer_sync[pid]
		if !ps_found {
			continue
		}
		rate: f64 = 0
		elapsed := now - ps.tracking_since
		if elapsed > 0 {
			rate = f64(ps.blocks_delivered) / f64(elapsed)
		}
		append(&sorted_pids, pid)
		append(&sorted_rates, rate)
	}
	// Simple insertion sort by rate descending (small list, max 8 peers).
	for i in 1 ..< len(sorted_pids) {
		j := i
		for j > 0 && sorted_rates[j] > sorted_rates[j - 1] {
			sorted_pids[j], sorted_pids[j - 1] = sorted_pids[j - 1], sorted_pids[j]
			sorted_rates[j], sorted_rates[j - 1] = sorted_rates[j - 1], sorted_rates[j]
			j -= 1
		}
	}

	// Allocate blocks to peers in throughput order (fastest first).
	for remaining > 0 {
		made_progress := false

		for pi in 0 ..< len(sorted_pids) {
			pid := sorted_pids[pi]
			ps := sm.peer_sync[pid]
			peer_limit := _peer_block_limit(ps, now, total_rate, num_scored)
			available := peer_limit - ps.blocks_in_flight
			if available <= 0 {
				continue
			}

			peer, found := peers[pid]
			if !found || peer.state != .Active {
				continue
			}

			// Batch up to available slots (max 16 per getdata message).
			batch_size := min(available, remaining, 16)
			inv := make([]wire.Inv_Vector, batch_size, context.temp_allocator)
			count := 0

			// Drain priority requeue list first.
			for count < batch_size && len(sm.requeue_list) > 0 {
				hash := pop(&sm.requeue_list)
				if hash in sm.blocks_in_flight {
					continue
				}
				entry, known := sm.chain.block_index.entries[hash]
				if known && .Has_Data in entry.status {
					continue
				}
				sm.blocks_in_flight[hash] = pid
				sm.block_request_time[hash] = now
				inv[count] = wire.Inv_Vector{type = .Witness_Block, hash = hash}
				count += 1
			}

			// Then continue with main download queue.
			for count < batch_size && sm.download_cursor < len(sm.blocks_to_download) {
				hash := sm.blocks_to_download[sm.download_cursor]
				sm.download_cursor += 1
				if hash in sm.blocks_in_flight {
					continue
				}
				entry, known := sm.chain.block_index.entries[hash]
				if known && .Has_Data in entry.status {
					continue
				}
				sm.blocks_in_flight[hash] = pid
				sm.block_request_time[hash] = now
				inv[count] = wire.Inv_Vector{type = .Witness_Block, hash = hash}
				count += 1
			}

			if count > 0 {
				ps.blocks_in_flight += count
				sm.peer_sync[pid] = ps
				peer_send_getdata(peer, inv[:count])
				made_progress = true
			}

			remaining = len(sm.requeue_list) + len(sm.blocks_to_download) - sm.download_cursor
			if remaining <= 0 {
				break
			}
		}

		if !made_progress {
			break
		}
	}
}

// Handle peer disconnect — requeue blocks, clean up per-peer state.
sync_handle_disconnect :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, peers: ^map[Peer_Id]^Peer) {
	// Put back any blocks that were in flight from this peer.
	to_requeue := make([dynamic]Hash256, 0, 16, context.temp_allocator)
	for hash, pid in sm.blocks_in_flight {
		if pid == peer_id {
			append(&to_requeue, hash)
		}
	}
	for hash in to_requeue {
		delete_key(&sm.blocks_in_flight, hash)
		delete_key(&sm.block_request_time, hash)
		// Priority requeue — checked before main download queue.
		append(&sm.requeue_list, hash)
	}

	// Remove from per-peer tracking.
	delete_key(&sm.peer_sync, peer_id)

	// Remove from round-robin list (with cursor adjustment).
	for i in 0 ..< len(sm.peer_rr_list) {
		if sm.peer_rr_list[i] == peer_id {
			ordered_remove(&sm.peer_rr_list, i)
			if sm.peer_rr_cursor > i {
				sm.peer_rr_cursor -= 1
			}
			if sm.peer_rr_cursor >= len(sm.peer_rr_list) && len(sm.peer_rr_list) > 0 {
				sm.peer_rr_cursor = 0
			}
			break
		}
	}

	if len(to_requeue) > 0 {
		log.debugf("Peer %d disconnected, requeued %d blocks to other peers", peer_id, len(to_requeue))
		sync_request_blocks(sm, peers)
	}

	// If syncing headers, handle the disconnect.
	if sm.state == .Syncing_Headers {
		if peer_id == sm.header_lead_peer {
			sm.header_lead_peer = 0

			// Count remaining active peers and race them all.
			locator := build_block_locator(sm.chain)
			defer delete(locator)
			now := time.to_unix_seconds(time.now())
			sent := 0

			for id, ps in sm.peer_sync {
				peer, found := peers[id]
				if !found || peer.state != .Active {
					continue
				}
				peer_send_getheaders(peer, locator, HASH_ZERO)
				new_ps := ps
				new_ps.getheaders_pending = true
				new_ps.getheaders_sent_at = now
				sm.peer_sync[id] = new_ps
				sent += 1
			}

			if sent == 0 {
				log.warn("All sync peers disconnected during header sync, going idle...")
				sm.state = .Idle
			} else {
				log.infof("Header lead peer %d disconnected, racing %d remaining peers", peer_id, sent)
			}
		} else {
			// Non-lead peer disconnected — check if all remaining peers are done.
			// This handles the case where a peer had getheaders_pending but never responded.
			_check_header_sync_complete(sm, peers)
		}
	}
}

// Check for stalled block requests and header timeouts.
// Returns a peer ID to disconnect (0 = no disconnect needed).
// Uses Bitcoin Core's approach: identify the peer holding the lowest-height
// in-flight block (the "window staller"), disconnect after adaptive timeout.
sync_check_stalls :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) -> Peer_Id {
	now := time.to_unix_seconds(time.now())
	if now - sm.last_stall_check < STALL_CHECK_INTERVAL_SECS {
		return 0
	}
	sm.last_stall_check = now

	// Check block stalls — Bitcoin Core style.
	// Only disconnect a peer if:
	// 1. Chain hasn't progressed in > stall_timeout seconds (actual stall)
	// 2. A peer is holding a block near our tip that's been in-flight > stall_timeout
	// 3. Rate-limited: at most 1 disconnect per 30 seconds
	if sm.state == .Downloading_Blocks && len(sm.blocks_in_flight) > 0 {
		// Rate limit: don't disconnect more than once per 30 seconds.
		if now - sm.last_disconnect < 30 {
			return 0
		}

		// Only act if chain hasn't progressed recently (actual stall).
		if now - sm.last_tip_update < BLOCK_STALL_TIMEOUT_DEFAULT {
			return 0
		}

		_, tip_height := chain.chain_tip(sm.chain)

		// Find the lowest-height in-flight block near our tip.
		staller_peer: Peer_Id = 0
		staller_time: i64 = 0
		staller_height := max(int)

		for hash, pid in sm.blocks_in_flight {
			entry, known := sm.chain.block_index.entries[hash]
			if !known {
				continue
			}
			// Only consider blocks within 64 of tip.
			if entry.height > tip_height + 64 {
				continue
			}
			if entry.height < staller_height {
				staller_height = entry.height
				staller_peer = pid
				req_time, has_time := sm.block_request_time[hash]
				if has_time {
					staller_time = req_time
				}
			}
		}

		// If the blocking peer's block exceeds the stall timeout, disconnect.
		if staller_peer != 0 && staller_time > 0 && now - staller_time > BLOCK_STALL_TIMEOUT_DEFAULT {
			sm.last_disconnect = now
			log.infof("Peer %d stalling chain at height %d (no progress for %ds, block in-flight %ds) — disconnecting",
				staller_peer, staller_height, now - sm.last_tip_update, now - staller_time)
			return staller_peer
		}
	}

	// Evict slow peers during block download.
	// After the trial period, if a peer's rate is < 10% of the fastest peer, drop it.
	if sm.state == .Downloading_Blocks && now - sm.last_disconnect >= 30 {
		fastest_rate: f64 = 0
		slowest_pid: Peer_Id = 0
		slowest_rate: f64 = max(f64)

		for id, ps in sm.peer_sync {
			elapsed := now - ps.tracking_since
			if elapsed < PEER_TRIAL_SECS * 2 {
				continue // Give new peers time
			}
			peer, found := peers[id]
			if !found || peer.state != .Active {
				continue
			}
			rate := f64(ps.blocks_delivered) / f64(elapsed)
			if rate > fastest_rate {
				fastest_rate = rate
			}
			if rate < slowest_rate {
				slowest_rate = rate
				slowest_pid = id
			}
		}

		// If slowest is < 10% of fastest, evict it.
		if slowest_pid != 0 && fastest_rate > 0 && slowest_rate < fastest_rate * 0.1 {
			log.infof("Evicting slow peer %d (%.1f blk/s vs fastest %.1f blk/s)", slowest_pid, slowest_rate, fastest_rate)
			sm.last_disconnect = now
			return slowest_pid
		}
	}

	// Race tip-critical blocks: if blocks near the chain tip have been in-flight
	// for > TIP_BLOCK_RACE_SECS, send duplicate requests to another peer.
	// The first response wins; duplicates are no-ops (Has_Data check).
	if sm.state == .Downloading_Blocks && len(sm.blocks_in_flight) > 0 {
		_, tip_height := chain.chain_tip(sm.chain)

		// Collect tip-critical blocks (within 16 of tip) that are slow.
		race_blocks := make([dynamic]Hash256, 0, 16, context.temp_allocator)
		race_owners := make([dynamic]Peer_Id, 0, 16, context.temp_allocator)

		for hash, owner_pid in sm.blocks_in_flight {
			entry, known := sm.chain.block_index.entries[hash]
			if !known {
				continue
			}
			// Only race blocks close to the chain tip — these are blocking progress.
			if entry.height > tip_height + 16 {
				continue
			}
			req_time, has_time := sm.block_request_time[hash]
			if has_time && now - req_time >= TIP_BLOCK_RACE_SECS {
				append(&race_blocks, hash)
				append(&race_owners, owner_pid)
			}
		}

		if len(race_blocks) > 0 {
			// Find a peer to race with — pick the one with the most delivered blocks
			// that isn't the current owner of any of these blocks.
			best_racer: Peer_Id = 0
			best_delivered := 0
			for pid in sm.peer_rr_list {
				ps, found := sm.peer_sync[pid]
				if !found {
					continue
				}
				peer, pfound := peers[pid]
				if !pfound || peer.state != .Active {
					continue
				}
				if ps.blocks_delivered > best_delivered {
					// Make sure this peer isn't already the owner of all race blocks.
					is_all_owner := true
					for oi in 0 ..< len(race_owners) {
						if race_owners[oi] != pid {
							is_all_owner = false
							break
						}
					}
					if !is_all_owner {
						best_delivered = ps.blocks_delivered
						best_racer = pid
					}
				}
			}

			if best_racer != 0 {
				racer_peer, racer_found := peers[best_racer]
				if racer_found {
					// Send duplicate getdata for tip-critical blocks to the racer.
					inv := make([dynamic]wire.Inv_Vector, 0, len(race_blocks), context.temp_allocator)
					for ri in 0 ..< len(race_blocks) {
						if race_owners[ri] != best_racer {
							append(&inv, wire.Inv_Vector{type = .Witness_Block, hash = race_blocks[ri]})
						}
					}
					if len(inv) > 0 {
						peer_send_getdata(racer_peer, inv[:])
						log.debugf("Racing %d tip-critical block(s) to peer %d (was: various, waited >%ds)",
							len(inv), best_racer, TIP_BLOCK_RACE_SECS)
					}
				}
			}
		}
	}

	// Check header stalls.
	if sm.state == .Syncing_Headers {
		locator: []Hash256 = nil
		locator_built := false

		for id, ps in sm.peer_sync {
			if ps.getheaders_pending && now - ps.getheaders_sent_at > HEADER_REQUEST_TIMEOUT_SECS {
				peer, found := peers[id]
				if !found || peer.state != .Active {
					continue
				}

				// Build locator once, reuse for all timed-out peers.
				if !locator_built {
					locator = build_block_locator(sm.chain)
					locator_built = true
				}

				peer_send_getheaders(peer, locator, HASH_ZERO)
				new_ps := ps
				new_ps.getheaders_sent_at = now
				sm.peer_sync[id] = new_ps
				log.debugf("Re-sent getheaders to stalled peer %d", id)
			}
		}

		if locator_built {
			delete(locator)
		}
	}

	return 0
}

// Decay the stall timeout toward the default after successful block connects.
// Bitcoin Core uses 0.85x decay per block connect.
// Log per-peer throughput stats.
_log_peer_throughput :: proc(sm: ^Sync_Manager) {
	now := time.to_unix_seconds(time.now())
	total_rate: f64 = 0
	num_scored := 0

	// Compute total rate for scoring context.
	for _, ps in sm.peer_sync {
		elapsed := now - ps.tracking_since
		if elapsed >= PEER_TRIAL_SECS && ps.blocks_delivered > 0 {
			total_rate += f64(ps.blocks_delivered) / f64(elapsed)
			num_scored += 1
		}
	}

	buf: [512]byte
	b := strings.builder_from_bytes(buf[:])
	strings.write_string(&b, "Peer throughput:")

	for id, ps in sm.peer_sync {
		elapsed := now - ps.tracking_since
		rate: f64 = 0
		if elapsed > 0 {
			rate = f64(ps.blocks_delivered) / f64(elapsed)
		}
		limit := _peer_block_limit(ps, now, total_rate, num_scored)
		fmt.sbprintf(&b, " [%d: %d blks, %.1f/s, lim=%d]", id, ps.blocks_delivered, rate, limit)
	}

	log.info(strings.to_string(b))
}

// Check if all peers are done with header sync and transition to block download.
_check_header_sync_complete :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	if sm.state != .Syncing_Headers {
		return
	}

	all_done := true
	for id, pstate in sm.peer_sync {
		if pstate.getheaders_pending {
			p, found := peers[id]
			if found && p.state == .Active {
				all_done = false
				break
			}
		}
	}

	if all_done {
		log.info("Header sync complete. Building download queue...")
		_build_download_queue(sm)

		if len(sm.blocks_to_download) == 0 {
			log.info("No blocks to download. Already in sync.")
			sm.state = .In_Sync
		} else {
			sm.state = .Downloading_Blocks
			log.infof("%d blocks queued for download", len(sm.blocks_to_download))
			sync_request_blocks(sm, peers)
		}
	}
}

// Build a block locator for getheaders. Walks from best known header
// via prev pointers with exponential step-back.
build_block_locator :: proc(cs: ^chain.Chain_State) -> []Hash256 {
	best := cs.block_index.best_header
	if best == nil {
		result := make([]Hash256, 1)
		result[0] = cs.params.genesis_hash
		return result
	}

	locator := make([dynamic]Hash256, 0, 32)
	step := 1
	current := best

	for current != nil {
		append(&locator, current.hash)
		if current.height == 0 { break }
		// Walk back 'step' entries via prev pointers
		for _ in 0 ..< step {
			if current.prev == nil { break }
			current = current.prev
		}
		if len(locator) >= 10 { step *= 2 }
	}

	result := make([]Hash256, len(locator))
	copy(result, locator[:])
	delete(locator)
	return result
}

// Request blocks for newly announced headers (BIP130 steady-state).
// Called when headers arrive while In_Sync or Downloading_Blocks.
_request_announced_blocks :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, headers: []wire.Block_Header, peers: ^map[Peer_Id]^Peer) {
	peer, found := peers[peer_id]
	if !found || peer.state != .Active {
		return
	}

	// Build getdata for headers that we now know about but don't have block data for.
	inv := make([dynamic]wire.Inv_Vector, 0, len(headers), context.temp_allocator)
	for i in 0 ..< len(headers) {
		hdr := headers[i]
		hash := wire.block_header_hash(&hdr)
		entry, known := sm.chain.block_index.entries[hash]
		if known && .Valid_Header in entry.status && .Has_Data not_in entry.status {
			append(&inv, wire.Inv_Vector{type = .Witness_Block, hash = hash})
		}
	}

	if len(inv) > 0 {
		log.infof("Requesting %d announced block(s) from peer %d", len(inv), peer_id)
		peer_send_getdata(peer, inv[:])
	}
}

// --- BIP152 Compact Block Reconstruction ---

// Handle an inbound compact block message. Attempts to reconstruct the full block
// from mempool transactions. If transactions are missing, sends getblocktxn.
sync_handle_compact_block :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, cmpct: ^wire.Compact_Block_Message,
	peers: ^map[Peer_Id]^Peer, mp: ^mempool.Mempool) {

	// Only process compact blocks when in sync (mempool is empty during IBD).
	if sm.state != .In_Sync {
		return
	}

	// Already processing a compact block — ignore.
	if sm.compact_state != nil {
		return
	}

	block_hash := wire.block_header_hash(&cmpct.header)

	// Validate header.
	hdr := cmpct.header
	_, herr := chain.accept_block_header(sm.chain, &hdr)
	if herr != .None {
		log.debugf("Compact block header rejected: %v", herr)
		return
	}

	// Already have block data — ignore.
	entry, known := sm.chain.block_index.entries[block_hash]
	if known && .Has_Data in entry.status {
		return
	}

	// Compute SipHash key from block_hash + nonce.
	k0, k1 := crypto.compact_block_sipkeys(block_hash, cmpct.nonce)

	// Total tx count = shortids + prefilled.
	total_txs := len(cmpct.shortids) + len(cmpct.prefilled_txs)
	if total_txs == 0 {
		return
	}

	// Build shortid→mempool tx map.
	sid_map := make(map[u64]^wire.Tx, len(cmpct.shortids) * 2, context.temp_allocator)
	collisions := make(map[u64]bool, 0, context.temp_allocator)

	if mp != nil {
		for _, mp_entry in mp.entries {
			wtxid := wire.tx_witness_id(&mp_entry.tx)
			sid := crypto.compact_block_shortid(k0, k1, wtxid)
			// Handle collision: if two mempool txs produce same shortid, mark as ambiguous.
			if sid in sid_map {
				collisions[sid] = true
			} else {
				sid_map[sid] = &mp_entry.tx
			}
		}
	}
	// Remove collisions from map.
	for sid in collisions {
		delete_key(&sid_map, sid)
	}

	// Allocate tx pointer array and fill from prefilled + shortids.
	tx_ptrs := make([]^wire.Tx, total_txs)
	// Deep-clone prefilled txs to heap (compact block data is temp-allocated).
	txs_owned := make([]wire.Tx, len(cmpct.prefilled_txs))

	// Build a set of prefilled indices for position mapping.
	prefilled_positions := make(map[u64]int, len(cmpct.prefilled_txs), context.temp_allocator)
	for i in 0 ..< len(cmpct.prefilled_txs) {
		prefilled_positions[cmpct.prefilled_txs[i].index] = i
	}

	// Fill tx_ptrs: iterate 0..total_txs, for each position check if prefilled or shortid.
	shortid_cursor := 0
	missing_count := 0
	missing_indices := make([dynamic]u64, 0, 16, context.temp_allocator)

	for pos in 0 ..< total_txs {
		pi, is_prefilled := prefilled_positions[u64(pos)]
		if is_prefilled {
			// Deep clone the prefilled tx.
			txs_owned[pi] = _clone_tx(&cmpct.prefilled_txs[pi].tx)
			tx_ptrs[pos] = &txs_owned[pi]
		} else {
			// Map from shortid.
			if shortid_cursor < len(cmpct.shortids) {
				sid := cmpct.shortids[shortid_cursor]
				shortid_cursor += 1
				mp_tx, found := sid_map[sid]
				if found {
					tx_ptrs[pos] = mp_tx
				} else {
					missing_count += 1
					append(&missing_indices, u64(pos))
				}
			} else {
				missing_count += 1
				append(&missing_indices, u64(pos))
			}
		}
	}

	if missing_count == 0 {
		// All txs found — assemble and process block.
		block := _assemble_block(&cmpct.header, tx_ptrs)
		log.infof("Compact block reconstructed from mempool (%d txs)", total_txs)

		// IMPORTANT: free owned txs AFTER sync_handle_block, because the
		// assembled block's tx slices point into txs_owned/mempool memory.
		sync_handle_block(sm, peer_id, &block, peers)

		for i in 0 ..< len(txs_owned) {
			_free_cloned_tx(&txs_owned[i])
		}
		delete(txs_owned)
		delete(tx_ptrs)
		return
	}

	// Missing txs — save state, send getblocktxn.
	now := time.to_unix_seconds(time.now())
	state := new(Compact_Block_State)
	state.header = cmpct.header
	state.block_hash = block_hash
	state.sipkey_k0 = k0
	state.sipkey_k1 = k1
	state.txs = tx_ptrs
	state.txs_owned = txs_owned
	state.total_txs = total_txs
	state.missing_count = missing_count
	state.missing_indices = make([]u64, len(missing_indices))
	copy(state.missing_indices, missing_indices[:])
	state.from_peer = peer_id
	state.requested_at = now

	sm.compact_state = state

	peer, found := peers[peer_id]
	if found {
		log.infof("Sending getblocktxn for %d missing txs", missing_count)
		peer_send_getblocktxn(peer, block_hash, state.missing_indices)
	} else {
		// Peer gone — fallback.
		_compact_state_fallback(sm, peers)
	}
}

// Handle blocktxn response: fill missing slots and assemble block.
sync_handle_block_txn :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, msg: ^wire.Block_Txn_Message, peers: ^map[Peer_Id]^Peer) {
	cs := sm.compact_state
	if cs == nil {
		return
	}

	// Verify block hash matches.
	if cs.block_hash != msg.block_hash {
		log.warnf("blocktxn hash mismatch — ignoring")
		return
	}

	// Verify tx count matches missing count.
	if len(msg.txs) != cs.missing_count {
		log.warnf("blocktxn tx count mismatch: got %d, want %d — falling back", len(msg.txs), cs.missing_count)
		_compact_state_fallback(sm, peers)
		return
	}

	// Extend owned txs array to include blocktxn responses.
	old_owned := cs.txs_owned
	new_owned := make([]wire.Tx, len(old_owned) + len(msg.txs))
	copy(new_owned, old_owned)
	owned_cursor := len(old_owned)

	// Fix up prefilled tx pointers: they currently point into old_owned,
	// which we're about to free. Redirect them to the same index in new_owned.
	for i in 0 ..< len(old_owned) {
		old_ptr := &old_owned[i]
		for j in 0 ..< len(cs.txs) {
			if cs.txs[j] == old_ptr {
				cs.txs[j] = &new_owned[i]
				break
			}
		}
	}

	// Fill missing slots.
	for i in 0 ..< cs.missing_count {
		idx := cs.missing_indices[i]
		new_owned[owned_cursor] = _clone_tx(&msg.txs[i])
		cs.txs[idx] = &new_owned[owned_cursor]
		owned_cursor += 1
	}

	// Free old owned array (new one supersedes it — all pointers redirected above).
	delete(old_owned)
	cs.txs_owned = new_owned

	// Assemble block.
	block := _assemble_block(&cs.header, cs.txs)
	log.infof("Compact block reconstructed after blocktxn (%d txs, %d were missing)", cs.total_txs, cs.missing_count)

	from_peer := cs.from_peer

	// IMPORTANT: destroy compact state AFTER sync_handle_block, because the
	// assembled block's tx slices point into cs.txs_owned memory. Destroying
	// before store_block would be use-after-free.
	sync_handle_block(sm, from_peer, &block, peers)
	_compact_state_destroy(sm)
}

// Assemble a full block from header + array of tx pointers.
_assemble_block :: proc(header: ^wire.Block_Header, tx_ptrs: []^wire.Tx) -> wire.Block {
	txs := make([]wire.Tx, len(tx_ptrs), context.temp_allocator)
	for i in 0 ..< len(tx_ptrs) {
		if tx_ptrs[i] != nil {
			txs[i] = tx_ptrs[i]^
		}
	}
	return wire.Block{header = header^, txs = txs}
}

// Fallback: request full block via getdata, destroy compact state.
_compact_state_fallback :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	cs := sm.compact_state
	if cs == nil {
		return
	}

	block_hash := cs.block_hash
	from_peer := cs.from_peer
	_compact_state_destroy(sm)

	// Request full block from the same peer (or any active peer).
	inv := [1]wire.Inv_Vector{{type = .Witness_Block, hash = block_hash}}
	peer, found := peers[from_peer]
	if found && peer.state == .Active {
		peer_send_getdata(peer, inv[:])
	} else {
		for _, p in peers {
			if p.state == .Active {
				peer_send_getdata(p, inv[:])
				break
			}
		}
	}
}

// Free compact block state and all owned resources.
_compact_state_destroy :: proc(sm: ^Sync_Manager) {
	cs := sm.compact_state
	if cs == nil {
		return
	}

	// Free owned (heap-cloned) txs.
	for i in 0 ..< len(cs.txs_owned) {
		_free_cloned_tx(&cs.txs_owned[i])
	}
	delete(cs.txs_owned)
	delete(cs.txs)
	delete(cs.missing_indices)
	free(cs)
	sm.compact_state = nil
}

// Deep-clone a transaction to heap.
_clone_tx :: proc(tx: ^wire.Tx) -> wire.Tx {
	result: wire.Tx
	result.version = tx.version
	result.locktime = tx.locktime

	// Clone inputs.
	result.inputs = make([]wire.Tx_In, len(tx.inputs))
	for i in 0 ..< len(tx.inputs) {
		result.inputs[i].previous_output = tx.inputs[i].previous_output
		result.inputs[i].sequence = tx.inputs[i].sequence
		if len(tx.inputs[i].script_sig) > 0 {
			result.inputs[i].script_sig = make([]byte, len(tx.inputs[i].script_sig))
			copy(result.inputs[i].script_sig, tx.inputs[i].script_sig)
		}
	}

	// Clone outputs.
	result.outputs = make([]wire.Tx_Out, len(tx.outputs))
	for i in 0 ..< len(tx.outputs) {
		result.outputs[i].value = tx.outputs[i].value
		if len(tx.outputs[i].script_pubkey) > 0 {
			result.outputs[i].script_pubkey = make([]byte, len(tx.outputs[i].script_pubkey))
			copy(result.outputs[i].script_pubkey, tx.outputs[i].script_pubkey)
		}
	}

	// Clone witness.
	if tx.witness != nil {
		result.witness = make([][][]byte, len(tx.witness))
		for i in 0 ..< len(tx.witness) {
			if tx.witness[i] != nil {
				result.witness[i] = make([][]byte, len(tx.witness[i]))
				for j in 0 ..< len(tx.witness[i]) {
					if len(tx.witness[i][j]) > 0 {
						result.witness[i][j] = make([]byte, len(tx.witness[i][j]))
						copy(result.witness[i][j], tx.witness[i][j])
					}
				}
			}
		}
	}

	return result
}

// Free a heap-cloned transaction.
_free_cloned_tx :: proc(tx: ^wire.Tx) {
	for i in 0 ..< len(tx.inputs) {
		delete(tx.inputs[i].script_sig)
	}
	delete(tx.inputs)

	for i in 0 ..< len(tx.outputs) {
		delete(tx.outputs[i].script_pubkey)
	}
	delete(tx.outputs)

	if tx.witness != nil {
		for i in 0 ..< len(tx.witness) {
			if tx.witness[i] != nil {
				for j in 0 ..< len(tx.witness[i]) {
					delete(tx.witness[i][j])
				}
				delete(tx.witness[i])
			}
		}
		delete(tx.witness)
	}
}

// Read u64 little-endian from a byte slice.
_u64le :: proc(data: []byte) -> u64 {
	return u64(data[0]) |
		u64(data[1]) << 8 |
		u64(data[2]) << 16 |
		u64(data[3]) << 24 |
		u64(data[4]) << 32 |
		u64(data[5]) << 40 |
		u64(data[6]) << 48 |
		u64(data[7]) << 56
}

// Announce a newly connected block to all peers (except sender).
// Compact-capable peers get a cmpctblock; sendheaders peers get headers; others get inv.
_announce_block :: proc(sm: ^Sync_Manager, from_peer: Peer_Id, block: ^wire.Block, block_hash: Hash256,
	peers: ^map[Peer_Id]^Peer) {

	// Generate a deterministic-ish nonce for the compact block.
	nonce := u64(time.to_unix_seconds(time.now())) ~ u64(block.header.nonce) ~ u64(block.header.timestamp)

	// Build compact block once (reused for all compact-capable peers).
	cmpct := wire.create_compact_block(block, nonce, context.temp_allocator)

	// ZMQ notifications (hashblock/rawblock/sequence), if configured.
	if sm.zmq != nil {
		raw: []byte
		if zmqpkg.TOPIC_RAWBLOCK in sm.zmq.by_topic {
			w := wire.writer_init(context.temp_allocator)
			wire.serialize_block(&w, block)
			raw = wire.writer_bytes(&w)
		}
		zmqpkg.notify_block(sm.zmq, block_hash, raw)
	}

	// Single-element header slice for BIP130 announcement.
	hdr_slice := [1]wire.Block_Header{block.header}

	for id, peer in peers {
		if id == from_peer || peer.state != .Active {
			continue
		}

		if peer.compact_version >= 2 && peer.send_compact {
			peer_send_cmpctblock(peer, &cmpct)
		} else if peer.send_headers {
			peer_send_block_headers(peer, hdr_slice[:])
		} else {
			peer_send_block_inv(peer, block_hash)
		}
	}
}

// Build the download queue: all block index entries that have Valid_Header but not Has_Data.
_build_download_queue :: proc(sm: ^Sync_Manager) {
	clear(&sm.blocks_to_download)
	sm.download_cursor = 0

	if sm.best_header_height < 0 {
		return
	}

	// Use height-indexed array for O(n) ordering (heights are contiguous 0..N).
	max_h := sm.best_header_height
	by_height := make([]Hash256, max_h + 1, context.temp_allocator)

	for hash, entry in sm.chain.block_index.entries {
		// Skip genesis (height 0) — peers don't serve it; connect_pending_blocks handles it.
		// Skip blocks already connected (Valid_Chain): pruned blocks lose
		// Has_Data but must never be re-downloaded — without this check a
		// mass prune queued 616k already-validated blocks for redownload.
		if .Valid_Header in entry.status && .Has_Data not_in entry.status && .Valid_Chain not_in entry.status && entry.height > 0 {
			if entry.height <= max_h {
				by_height[entry.height] = hash
			}
		}
	}

	reserve(&sm.blocks_to_download, max_h + 1)
	for h in 0 ..= max_h {
		if by_height[h] != HASH_ZERO {
			append(&sm.blocks_to_download, by_height[h])
		}
	}
}
