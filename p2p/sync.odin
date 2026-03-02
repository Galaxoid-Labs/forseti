package p2p

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:time"

import "../chain"
import "../consensus"
import "../mempool"
import "../storage"
import "../wire"

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

Sync_Manager :: struct {
	chain:              ^chain.Chain_State,
	params:             ^consensus.Chain_Params,
	mp:                 ^mempool.Mempool,
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
	if sm.best_header_height >= int(best_height) {
		log.infof("Headers already up to date (height %d). Building download queue...", sm.best_header_height)
		sm.state = .Downloading_Blocks
		_build_download_queue(sm)
		if len(sm.blocks_to_download) == 0 {
			sm.state = .In_Sync
		} else {
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
			sm.state = .Downloading_Blocks
			_build_download_queue(sm)

			if len(sm.blocks_to_download) == 0 {
				log.info("No blocks to download. Already in sync.")
				sm.state = .In_Sync
			} else {
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

	redownload := make([dynamic]Hash256, 0, 4, context.temp_allocator)
	connected, cerr := chain.connect_pending_blocks(sm.chain, &redownload)
	if cerr != .None && cerr != .Storage_Error {
		_, tip_height := chain.chain_tip(sm.chain)
		log.errorf("Block validation failed at height %d: %v — sync halted", tip_height + 1, cerr)
		// Don't requeue or request more blocks — chain is stuck.
		return
	}

	// Re-queue blocks that need re-download (storage errors only).
	for h in redownload {
		append(&sm.requeue_list, h)
	}

	if connected > 0 {
		_, height := chain.chain_tip(sm.chain)
		sm.last_tip_update = time.to_unix_seconds(time.now())

		// Budget-based UTXO flush: flush when coins cache exceeds its memory budget,
		// or every 5000 blocks as a durability safety net.
		should_flush := chain.coins_cache_should_flush(&sm.chain.coins)
		safety_flush := height / 5000 > prev_height / 5000
		if should_flush || safety_flush {
			tip_hash, tip_h := chain.chain_tip(sm.chain)
			chain.coins_cache_flush(&sm.chain.coins, tip_hash, tip_h)
		}

		// Remove confirmed/conflicting txs from mempool.
		if sm.mp != nil {
			mempool.mempool_remove_for_block(sm.mp, block)
		}

		remaining := len(sm.blocks_to_download) - sm.download_cursor
		if should_flush || safety_flush || remaining == 0 {
			log.debugf("Connected block at height %d (remaining: %d, in-flight: %d)",
				height, remaining, len(sm.blocks_in_flight))

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

	// Second pass: allocate blocks using dynamic per-peer limits.
	peers_tried := 0
	for peers_tried < len(sm.peer_rr_list) && remaining > 0 {
		// Wrap cursor.
		if sm.peer_rr_cursor >= len(sm.peer_rr_list) {
			sm.peer_rr_cursor = 0
		}

		pid := sm.peer_rr_list[sm.peer_rr_cursor]
		sm.peer_rr_cursor += 1
		peers_tried += 1

		peer, found := peers[pid]
		if !found || peer.state != .Active {
			continue
		}

		ps := sm.peer_sync[pid]
		peer_limit := _peer_block_limit(ps, now, total_rate, num_scored)
		available := peer_limit - ps.blocks_in_flight
		if available <= 0 {
			continue
		}

		// Batch up to available slots (max 16 per getdata message).
		batch_size := min(available, remaining, 16)

		inv := make([]wire.Inv_Vector, batch_size, context.temp_allocator)
		count := 0

		// Drain priority requeue list first (disconnected/stalled blocks).
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
			inv[count] = wire.Inv_Vector{
				type = .Witness_Block,
				hash = hash,
			}
			count += 1
		}

		// Then continue with main download queue.
		for count < batch_size && sm.download_cursor < len(sm.blocks_to_download) {
			hash := sm.blocks_to_download[sm.download_cursor]
			sm.download_cursor += 1

			// Skip blocks that are already stored or already in flight.
			if hash in sm.blocks_in_flight {
				continue
			}
			entry, known := sm.chain.block_index.entries[hash]
			if known && .Has_Data in entry.status {
				continue
			}

			sm.blocks_in_flight[hash] = pid
			sm.block_request_time[hash] = now
			inv[count] = wire.Inv_Vector{
				type = .Witness_Block,
				hash = hash,
			}
			count += 1
		}

		if count > 0 {
			ps.blocks_in_flight += count
			sm.peer_sync[pid] = ps
			peer_send_getdata(peer, inv[:count])
		}

		remaining = len(sm.requeue_list) + len(sm.blocks_to_download) - sm.download_cursor

		// Reset peers_tried so we keep going through peers while there's work.
		peers_tried = 0
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
		log.infof("Peer %d disconnected, requeued %d blocks to other peers", peer_id, len(to_requeue))
		sync_request_blocks(sm, peers)
	}

	// If syncing headers and we lost the lead peer, race remaining peers.
	if sm.state == .Syncing_Headers && peer_id == sm.header_lead_peer {
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
	}
}

// Check for stalled block requests and header timeouts.
sync_check_stalls :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	now := time.to_unix_seconds(time.now())
	if now - sm.last_stall_check < STALL_CHECK_INTERVAL_SECS {
		return
	}
	sm.last_stall_check = now

	// Check block stalls.
	if sm.state == .Downloading_Blocks {
		stalled := make([dynamic]Hash256, 0, 16, context.temp_allocator)

		for hash, req_time in sm.block_request_time {
			if now - req_time > BLOCK_STALL_TIMEOUT_SECS {
				append(&stalled, hash)
			}
		}

		if len(stalled) > 0 {
			for hash in stalled {
				// Decrement per-peer count.
				pid, found := sm.blocks_in_flight[hash]
				if found {
					ps, ps_found := sm.peer_sync[pid]
					if ps_found {
						ps.blocks_in_flight = max(0, ps.blocks_in_flight - 1)
						sm.peer_sync[pid] = ps
					}
				}
				delete_key(&sm.blocks_in_flight, hash)
				delete_key(&sm.block_request_time, hash)
				// Priority requeue — checked before main download queue.
				append(&sm.requeue_list, hash)
			}

			log.infof("Requeued %d stalled blocks (>%ds)", len(stalled), BLOCK_STALL_TIMEOUT_SECS)
			sync_request_blocks(sm, peers)
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
}

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
		if .Valid_Header in entry.status && .Has_Data not_in entry.status {
			if entry.height >= 0 && entry.height <= max_h {
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
