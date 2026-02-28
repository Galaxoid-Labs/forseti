package p2p

import "core:log"
import "core:time"

import "../chain"
import "../consensus"
import "../storage"
import "../wire"

Sync_State :: enum {
	Idle,
	Syncing_Headers,
	Downloading_Blocks,
	In_Sync,
}

Sync_Manager :: struct {
	chain:              ^chain.Chain_State,
	params:             ^consensus.Chain_Params,
	state:              Sync_State,
	sync_peer:          Peer_Id,
	headers_received:   int,
	best_header_height: int,
	blocks_in_flight:   map[Hash256]Peer_Id,
	blocks_to_download: [dynamic]Hash256,
	download_cursor:    int, // index into blocks_to_download for next request
	last_tip_update:    i64,
}

sync_manager_init :: proc(sm: ^Sync_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params) {
	sm.chain = cs
	sm.params = params
	sm.state = .Idle
	sm.blocks_in_flight = make(map[Hash256]Peer_Id, 64)
	sm.blocks_to_download = make([dynamic]Hash256, 0, 1024)
	sm.last_tip_update = time.to_unix_seconds(time.now())

	// Initialize best_header_height from loaded block index
	if cs.block_index.best_header != nil {
		sm.best_header_height = cs.block_index.best_header.height
	}
}

sync_manager_destroy :: proc(sm: ^Sync_Manager) {
	delete(sm.blocks_in_flight)
	delete(sm.blocks_to_download)
}

// Pick the best peer (highest start_height) and send getheaders.
sync_start_header_sync :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) -> Peer_Id {
	best_peer: ^Peer = nil
	best_id: Peer_Id = 0

	for id, peer in peers {
		if peer.state != .Active {
			continue
		}
		if best_peer == nil || peer.start_height > best_peer.start_height {
			best_peer = peer
			best_id = id
		}
	}

	if best_peer == nil {
		return 0
	}

	// If we already have headers up to or beyond the peer's height, skip to block download.
	if sm.best_header_height >= int(best_peer.start_height) {
		log.infof("Headers already up to date (height %d). Building download queue...", sm.best_header_height)
		sm.sync_peer = best_id
		sm.state = .Downloading_Blocks
		_build_download_queue(sm)
		if len(sm.blocks_to_download) == 0 {
			sm.state = .In_Sync
		} else {
			log.infof("%d blocks queued for download", len(sm.blocks_to_download))
			sync_request_blocks(sm, peers)
		}
		return best_id
	}

	sm.sync_peer = best_id
	sm.state = .Syncing_Headers
	sm.headers_received = 0

	locator := build_block_locator(sm.chain)
	defer delete(locator)

	peer_send_getheaders(best_peer, locator, HASH_ZERO)

	log.infof("Starting header sync with peer %d (height %d)", best_id, best_peer.start_height)
	return best_id
}

// Process a batch of headers from a peer.
sync_handle_headers :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, headers: []wire.Block_Header, peers: ^map[Peer_Id]^Peer) {
	accepted := 0
	for i in 0 ..< len(headers) {
		hdr := headers[i]
		entry, cerr := chain.accept_block_header(sm.chain, &hdr)
		if cerr == .None {
			accepted += 1
			if entry != nil && entry.height > sm.best_header_height {
				sm.best_header_height = entry.height
			}
		}
	}

	sm.headers_received += accepted

	if sm.headers_received % 10000 < 2000 || len(headers) < MAX_HEADERS_PER_MSG {
		log.infof("Headers: %d (best header height: %d)", sm.headers_received, sm.best_header_height)
	}

	if len(headers) >= MAX_HEADERS_PER_MSG {
		// More headers available — use last accepted header as locator.
		peer, found := peers[peer_id]
		if found {
			last_hdr := headers[len(headers) - 1]
			last_hash := wire.block_header_hash(&last_hdr)
			locator := [1]Hash256{last_hash}
			peer_send_getheaders(peer, locator[:], HASH_ZERO)
		}
	} else {
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

// Process a received block.
sync_handle_block :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, block: ^wire.Block, peers: ^map[Peer_Id]^Peer) {
	block_hash := wire.block_header_hash(&block.header)

	// Remove from in-flight.
	delete_key(&sm.blocks_in_flight, block_hash)

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

	connected, cerr := chain.connect_pending_blocks(sm.chain)
	if cerr != .None {
		_, tip_height := chain.chain_tip(sm.chain)
		log.errorf("Block validation failed at height %d: %v", tip_height + 1, cerr)
	}

	if connected > 0 {
		_, height := chain.chain_tip(sm.chain)
		sm.last_tip_update = time.to_unix_seconds(time.now())

		// Periodic UTXO flush to prevent unbounded memory growth during sync.
		// Check if we crossed a 5000-block boundary.
		if height / 5000 > prev_height / 5000 {
			tip_hash, tip_h := chain.chain_tip(sm.chain)
			chain.coins_cache_flush(&sm.chain.coins, tip_hash, tip_h)
		}

		remaining := len(sm.blocks_to_download) - sm.download_cursor
		if height / 1000 > prev_height / 1000 || remaining == 0 {
			log.debugf("Connected block at height %d (remaining: %d, in-flight: %d)",
				height, remaining, len(sm.blocks_in_flight))
		}
	}

	// Request more blocks.
	sync_request_blocks(sm, peers)

	// Check if we're done.
	remaining := len(sm.blocks_to_download) - sm.download_cursor
	if remaining == 0 && len(sm.blocks_in_flight) == 0 {
		_, height := chain.chain_tip(sm.chain)
		log.infof("Block download complete. In sync at height %d", height)
		sm.state = .In_Sync
	}
}

// Fill in-flight window from download queue.
sync_request_blocks :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	remaining := len(sm.blocks_to_download) - sm.download_cursor
	for len(sm.blocks_in_flight) < MAX_BLOCKS_IN_FLIGHT && remaining > 0 {
		// Pick a peer to request from — round-robin through active peers.
		peer := _pick_download_peer(peers)
		if peer == nil {
			break
		}

		// Batch up to 16 inventory items per getdata.
		batch_size := min(
			MAX_BLOCKS_IN_FLIGHT - len(sm.blocks_in_flight),
			remaining,
			16,
		)

		inv := make([]wire.Inv_Vector, batch_size, context.temp_allocator)

		for i in 0 ..< batch_size {
			hash := sm.blocks_to_download[sm.download_cursor]
			sm.download_cursor += 1
			sm.blocks_in_flight[hash] = peer.id
			inv[i] = wire.Inv_Vector{
				type = .Witness_Block,
				hash = hash,
			}
		}

		peer_send_getdata(peer, inv)
		remaining = len(sm.blocks_to_download) - sm.download_cursor
	}
}

// Handle peer disconnect — reassign sync peer if needed.
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
		// Append to end of download queue — will be re-requested.
		append(&sm.blocks_to_download, hash)
	}

	// If this was our sync peer, restart header sync.
	if sm.sync_peer == peer_id {
		sm.sync_peer = 0
		if sm.state == .Syncing_Headers {
			log.warn("Sync peer disconnected, finding new peer...")
			sync_start_header_sync(sm, peers)
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

// Pick an active peer for downloading blocks.
_pick_download_peer :: proc(peers: ^map[Peer_Id]^Peer) -> ^Peer {
	for _, peer in peers {
		if peer.state == .Active {
			return peer
		}
	}
	return nil
}
