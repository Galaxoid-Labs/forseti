package p2p

import "core:fmt"
import "core:log"
import "core:nbio"
import tcp "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "../chain"
import "../consensus"
import "../mempool"
import "../wire"

Conn_Manager :: struct {
	peers:              map[Peer_Id]^Peer,
	sync_mgr:           Sync_Manager,
	chain:              ^chain.Chain_State,
	params:             ^consensus.Chain_Params,
	mp:                 ^mempool.Mempool,
	next_peer_id:       Peer_Id,
	network_magic:      u32,
	default_port:       int,
	shutdown:           bool,
	// Pool of discovered addresses for replacing disconnected peers.
	address_pool:       [dynamic]string,
	address_pool_cursor: int,
	// nbio event loop reference for cross-thread operations.
	event_loop:         ^nbio.Event_Loop,
	// Pre-configured peer address (from --connect), connected during conn_manager_run.
	connect_address:    string,
	connect_port:       int,
	// Periodic timer state.
	last_ping_check:    i64,
	last_header_refresh: i64,
	// Zombie peers: destroyed but not yet freed (deferred to avoid use-after-free in nbio callbacks).
	zombie_peers:       [dynamic]^Peer,
	// Cross-thread tx relay queue (RPC thread pushes, P2P thread drains).
	relay_mutex:        sync.Mutex,
	relay_queue:        [dynamic]Hash256,
	// Blocks-only mode: reject inbound txs, skip tx relay.
	blocks_only:        bool,
}

conn_manager_init :: proc(cm: ^Conn_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params, mp: ^mempool.Mempool = nil) -> Net_Error {
	cm.chain = cs
	cm.params = params
	cm.mp = mp
	cm.network_magic = params.network_magic
	cm.next_peer_id = 1
	cm.shutdown = false

	// Set default port based on network.
	switch params.network_magic {
	case wire.MAINNET_MAGIC:  cm.default_port = DEFAULT_PORT_MAINNET
	case wire.TESTNET3_MAGIC: cm.default_port = DEFAULT_PORT_TESTNET3
	case wire.TESTNET4_MAGIC: cm.default_port = DEFAULT_PORT_TESTNET4
	case wire.SIGNET_MAGIC:   cm.default_port = DEFAULT_PORT_SIGNET
	case wire.REGTEST_MAGIC:  cm.default_port = DEFAULT_PORT_REGTEST
	case:                     cm.default_port = DEFAULT_PORT_MAINNET
	}

	cm.peers = make(map[Peer_Id]^Peer, MAX_OUTBOUND_PEERS * 2)
	cm.zombie_peers = make([dynamic]^Peer, 0, 8)
	cm.relay_queue = make([dynamic]Hash256, 0, 16)
	cm.last_ping_check = time.to_unix_seconds(time.now())
	cm.last_header_refresh = time.to_unix_seconds(time.now())

	sync_manager_init(&cm.sync_mgr, cs, params, mp)

	return .None
}

conn_manager_destroy :: proc(cm: ^Conn_Manager) {
	// Free zombie peers.
	for peer in cm.zombie_peers {
		_peer_free(peer)
	}
	delete(cm.zombie_peers)

	// Disconnect and free all active peers.
	for _, peer in cm.peers {
		peer_destroy(peer)
		_peer_free(peer)
	}
	delete(cm.peers)
	for addr in cm.address_pool {
		delete(addr)
	}
	delete(cm.address_pool)
	delete(cm.relay_queue)

	sync_manager_destroy(&cm.sync_mgr)
}

// Start an async connect to a peer. Returns immediately.
conn_manager_add_peer :: proc(cm: ^Conn_Manager, address: string, port: int) -> Net_Error {
	if len(cm.peers) >= MAX_OUTBOUND_PEERS {
		return .Too_Many_Peers
	}

	peer_id := cm.next_peer_id
	cm.next_peer_id += 1

	peer_start_connect(cm, address, port, peer_id)
	return .None
}

// Remove and destroy a peer. Defers freeing to zombie list for nbio safety.
conn_manager_remove_peer :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}
	delete_key(&cm.peers, peer_id)
	peer_destroy(peer)
	append(&cm.zombie_peers, peer)
}

// Discover peers via DNS seed resolution.
// Resolves ALL A records from each seed to maximize peer diversity.
conn_manager_discover_peers :: proc(cm: ^Conn_Manager) -> [dynamic]string {
	addresses := make([dynamic]string, 0, 32)

	seeds: []string
	switch cm.params.network_magic {
	case wire.MAINNET_MAGIC:
		s := MAINNET_SEEDS
		seeds = s[:]
	case wire.TESTNET3_MAGIC:
		s := TESTNET3_SEEDS
		seeds = s[:]
	case wire.TESTNET4_MAGIC:
		s := TESTNET4_SEEDS
		seeds = s[:]
	case wire.SIGNET_MAGIC:
		s := SIGNET_SEEDS
		seeds = s[:]
	case:
		return addresses
	}

	for seed in seeds {
		records, dns_err := tcp.get_dns_records_from_os(seed, .IP4, context.temp_allocator)
		if dns_err != nil {
			log.debugf("DNS lookup failed for %s", seed)
			continue
		}

		log.debugf("DNS seed %s returned %d addresses", seed, len(records))

		for record in records {
			rec, ok := record.(tcp.DNS_Record_IP4)
			if !ok {
				continue
			}
			addr := rec.address
			addr_str := fmt.aprintf("%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3])
			append(&addresses, addr_str)

			if len(addresses) >= MAX_OUTBOUND_PEERS * 2 {
				break
			}
		}

		if len(addresses) >= MAX_OUTBOUND_PEERS * 2 {
			break
		}
	}

	return addresses
}

// Cleanly shut down the connection manager. Safe to call from any thread.
conn_manager_shutdown :: proc(cm: ^Conn_Manager) {
	cm.shutdown = true
	// Wake up the event loop so run_until exits.
	if cm.event_loop != nil {
		nbio.wake_up(cm.event_loop)
	}
}

// Periodic timer callback — handles ping, header refresh, stall checks.
_on_periodic_timer :: proc(op: ^nbio.Operation, cm: ^Conn_Manager) {
	if cm.shutdown {
		return
	}

	// Free zombie peers from previous tick (safe now — nbio callbacks have fired).
	for peer in cm.zombie_peers {
		_peer_free(peer)
	}
	clear(&cm.zombie_peers)

	// Drain cross-thread tx relay queue (pushed by RPC thread).
	sync.mutex_lock(&cm.relay_mutex)
	for txid in cm.relay_queue {
		_conn_manager_relay_tx(cm, txid, Peer_Id(0))
	}
	clear(&cm.relay_queue)
	sync.mutex_unlock(&cm.relay_mutex)

	now := time.to_unix_seconds(time.now())

	// Force-check header sync completion after every tick.
	if cm.sync_mgr.state == .Syncing_Headers {
		_check_header_sync_complete(&cm.sync_mgr, &cm.peers)
	}

	// Check for stalled block/header requests.
	stall_peer := sync_check_stalls(&cm.sync_mgr, &cm.peers)
	if stall_peer != 0 {
		sync_handle_disconnect(&cm.sync_mgr, stall_peer, &cm.peers)
		conn_manager_remove_peer(cm, stall_peer)
		_conn_manager_replace_peer(cm)
	}

	// Periodic getheaders while in sync.
	if now - cm.last_header_refresh >= HEADER_REFRESH_SECS && cm.sync_mgr.state == .In_Sync {
		cm.last_header_refresh = now
		locator := build_block_locator(cm.sync_mgr.chain)
		for _, peer in cm.peers {
			if peer.state == .Active {
				peer_send_getheaders(peer, locator, HASH_ZERO)
				break
			}
		}
		delete(locator)
	}

	// Periodic ping.
	if now - cm.last_ping_check >= PING_INTERVAL_SECS {
		cm.last_ping_check = now
		for _, peer in cm.peers {
			if peer.state == .Active {
				peer_send_ping(peer)
			}
		}
	}

	// Free temp allocations.
	free_all(context.temp_allocator)

	// Re-arm the periodic timer (1 second).
	if !cm.shutdown {
		nbio.timeout_poly(1 * time.Second, cm, _on_periodic_timer)
	}
}

// Main event loop. Discovers peers, connects, processes messages via nbio callbacks.
conn_manager_run :: proc(cm: ^Conn_Manager) {
	context.logger = log.create_console_logger(.Debug, {.Level, .Time, .Terminal_Color})

	log.infof("Starting connection manager (network: %s)", cm.params.name)

	// Acquire the event loop for this thread.
	el_err := nbio.acquire_thread_event_loop()
	if el_err != nil {
		log.errorf("Failed to acquire event loop: %v", el_err)
		return
	}
	cm.event_loop = nbio.current_thread_event_loop()

	// If --connect was specified, add peer now (event loop is ready).
	if len(cm.connect_address) > 0 {
		err := conn_manager_add_peer(cm, cm.connect_address, cm.connect_port)
		if err == .None {
			log.infof("Connecting to manual peer %s:%d", cm.connect_address, cm.connect_port)
		} else {
			log.warnf("Failed to connect to %s:%d: %v", cm.connect_address, cm.connect_port, err)
		}
	}

	// Discover peers via DNS if no manual peer was configured.
	if len(cm.peers) == 0 {
		addresses := conn_manager_discover_peers(cm)

		connected := 0
		for addr in addresses {
			if connected >= MAX_OUTBOUND_PEERS {
				break
			}
			err := conn_manager_add_peer(cm, addr, cm.default_port)
			if err == .None {
				connected += 1
				log.infof("Connecting to %s:%d", addr, cm.default_port)
			}
		}

		// Keep remaining addresses for reconnection.
		cm.address_pool = addresses
		cm.address_pool_cursor = min(connected, len(addresses))

		if connected == 0 {
			log.warn("No peers available. Exiting.")
			nbio.release_thread_event_loop()
			return
		}
	}

	// Start periodic timer (fires every 1 second for stall checks, ping, etc.)
	nbio.timeout_poly(1 * time.Second, cm, _on_periodic_timer)

	// Run the event loop until shutdown.
	nbio.run_until(&cm.shutdown)

	nbio.release_thread_event_loop()
	log.info("Connection manager shutting down.")
}

// Called from _on_connect when async dial succeeds. Sends version and starts recv.
_conn_manager_peer_connected :: proc(cm: ^Conn_Manager, peer: ^Peer) {
	_, chain_height := chain.chain_tip(cm.chain)
	peer_send_version(peer, cm.params, chain_height)
	peer.state = .Version_Sent
	_peer_start_recv(peer)
}

// Dispatch inbound message by command (called inline from recv callback).
_conn_manager_dispatch :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, cmd: string, payload: []byte) {
	// Empty command = disconnect signal.
	if cmd == "" {
		log.infof("Peer %d disconnected", peer_id)
		sync_handle_disconnect(&cm.sync_mgr, peer_id, &cm.peers)
		conn_manager_remove_peer(cm, peer_id)
		return
	}

	switch cmd {
	case wire.CMD_VERSION:
		_conn_manager_handle_version(cm, peer_id, payload)
	case wire.CMD_VERACK:
		_conn_manager_handle_verack(cm, peer_id)
	case wire.CMD_HEADERS:
		_conn_manager_handle_headers(cm, peer_id, payload)
	case wire.CMD_BLOCK:
		_conn_manager_handle_block(cm, peer_id, payload)
	case wire.CMD_INV:
		_conn_manager_handle_inv(cm, peer_id, payload)
	case wire.CMD_PING:
		_conn_manager_handle_ping(cm, peer_id, payload)
	case wire.CMD_PONG:
		_conn_manager_handle_pong(cm, peer_id, payload)
	case wire.CMD_SENDHEADERS:
		// Peer wants headers announcements — note it.
		peer, found := cm.peers[peer_id]
		if found {
			peer.send_headers = true
		}
	case wire.CMD_TX:
		_conn_manager_handle_tx(cm, peer_id, payload)
	case wire.CMD_GETDATA:
		_conn_manager_handle_getdata(cm, peer_id, payload)
	case wire.CMD_SENDCMPCT, wire.CMD_FEEFILTER, wire.CMD_WTXIDRELAY, wire.CMD_ADDRV2, wire.CMD_ADDR:
		// Ignored for now.
	case:
		// Unknown command — ignore.
	}
}

_conn_manager_handle_version :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	r := wire.reader_init(payload)
	ver, err := wire.deserialize_version(&r, context.temp_allocator)
	if err != .None {
		log.warnf("Bad version from peer %d", peer_id)
		conn_manager_remove_peer(cm, peer_id)
		return
	}

	peer.version = ver.version
	peer.services = ver.services
	peer.user_agent = strings.clone(ver.user_agent)
	peer.start_height = ver.start_height

	log.debugf("Peer %d: version=%d, agent=%s, height=%d",
		peer_id, ver.version, ver.user_agent, ver.start_height)

	// Send verack in response.
	peer_send_verack(peer)

	// If we already sent our version and got theirs, handshake is progressing.
	if peer.state == .Version_Sent {
		peer.state = .Handshake_Complete
	}
}

_conn_manager_handle_verack :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	if peer.state == .Handshake_Complete {
		peer.state = .Active
		log.debugf("Peer %d handshake complete, now active", peer_id)

		// Send sendheaders (BIP130).
		peer_send_sendheaders(peer)

		// Register peer for sync tracking.
		sync_add_peer(&cm.sync_mgr, peer_id)

		switch cm.sync_mgr.state {
		case .Idle:
			sync_start_header_sync(&cm.sync_mgr, &cm.peers)
		case .Syncing_Headers:
			// Add late-joining peer to the header race if no lead has been selected yet,
			// but only if we actually need more headers from this peer.
			if cm.sync_mgr.header_lead_peer == 0 && cm.sync_mgr.best_header_height < int(peer.start_height) {
				locator := build_block_locator(cm.sync_mgr.chain)
				defer delete(locator)
				peer_send_getheaders(peer, locator, HASH_ZERO)
				ps := cm.sync_mgr.peer_sync[peer_id]
				ps.getheaders_pending = true
				ps.getheaders_sent_at = time.to_unix_seconds(time.now())
				cm.sync_mgr.peer_sync[peer_id] = ps
			}
		case .Downloading_Blocks:
			// Fill new peer's available block slots.
			sync_request_blocks(&cm.sync_mgr, &cm.peers)
		case .In_Sync:
			// Nothing to do.
		}
	}
}

_conn_manager_handle_headers :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	hdrs_msg, err := wire.deserialize_headers(&r, context.temp_allocator)
	if err != .None {
		log.warnf("Bad headers message from peer %d", peer_id)
		return
	}

	log.debugf("Received %d headers from peer %d", len(hdrs_msg.headers), peer_id)
	sync_handle_headers(&cm.sync_mgr, peer_id, hdrs_msg.headers, &cm.peers)
}

_conn_manager_handle_block :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	block, err := wire.deserialize_block(&r, context.temp_allocator)
	if err != .None {
		log.warnf("Bad block from peer %d", peer_id)
		return
	}

	sync_handle_block(&cm.sync_mgr, peer_id, &block, &cm.peers)
}

_conn_manager_handle_inv :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	inv_msg, err := wire.deserialize_inv(&r, context.temp_allocator)
	if err != .None {
		return
	}

	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	wanted := make([dynamic]wire.Inv_Vector, 0, len(inv_msg.inventory), context.temp_allocator)
	has_unknown_block := false
	for iv in inv_msg.inventory {
		#partial switch iv.type {
		case .Block, .Witness_Block:
			// Block inv only matters when in sync.
			if cm.sync_mgr.state == .In_Sync {
				_, known := cm.chain.block_index.entries[iv.hash]
				if !known {
					has_unknown_block = true
					append(&wanted, wire.Inv_Vector{type = .Witness_Block, hash = iv.hash})
				}
			}
		case .Tx, .Witness_Tx:
			// Only process tx inv when in sync (no point during IBD).
			if cm.sync_mgr.state == .In_Sync && cm.mp != nil && !mempool.mempool_has(cm.mp, iv.hash) {
				append(&wanted, wire.Inv_Vector{type = .Witness_Tx, hash = iv.hash})
			}
		}
	}

	// If we got inv for unknown blocks, send getheaders to discover the chain.
	if has_unknown_block {
		locator := build_block_locator(cm.sync_mgr.chain)
		defer delete(locator)
		peer_send_getheaders(peer, locator, HASH_ZERO)
	}

	if len(wanted) > 0 {
		peer_send_getdata(peer, wanted[:])
	}
}

_conn_manager_handle_ping :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	r := wire.reader_init(payload)
	ping, err := wire.deserialize_ping(&r)
	if err != .None {
		return
	}

	peer_send_pong(peer, ping.nonce)
}

_conn_manager_handle_pong :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	r := wire.reader_init(payload)
	pong, err := wire.deserialize_pong(&r)
	if err != .None {
		return
	}

	if pong.nonce == peer.ping_nonce {
		peer.last_pong = time.to_unix_seconds(time.now())
	}
}

// Handle inbound tx message: validate, add to mempool, relay to other peers.
_conn_manager_handle_tx :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	if cm.mp == nil || cm.sync_mgr.state != .In_Sync {
		return
	}

	// In blocks-only mode, reject inbound txs from peers
	if cm.blocks_only {
		log.debugf("Ignoring tx from peer %d (blocks-only mode)", peer_id)
		return
	}

	r := wire.reader_init(payload)
	tx, err := wire.deserialize_tx(&r, context.temp_allocator)
	if err != nil {
		log.debugf("Bad tx from peer %d", peer_id)
		return
	}

	txid := wire.tx_id(&tx)
	mp_err := mempool.mempool_add(cm.mp, &tx)
	if mp_err != .None {
		// Missing_Inputs (orphan txs) and Tx_Already_Exists are normal during tx relay — don't log.
		if mp_err != .Missing_Inputs && mp_err != .Tx_Already_Exists {
			log.debugf("Rejected tx %s from peer %d: %v", _hash_to_hex_short(txid), peer_id, mp_err)
		}
		return
	}

	log.debugf("Accepted tx %s from peer %d", _hash_to_hex_short(txid), peer_id)
	_conn_manager_relay_tx(cm, txid, peer_id)
}

// Handle inbound getdata: serve txs from mempool.
_conn_manager_handle_getdata :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	gd_msg, err := wire.deserialize_getdata(&r, context.temp_allocator)
	if err != .None {
		return
	}

	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	for iv in gd_msg.inventory {
		#partial switch iv.type {
		case .Tx, .Witness_Tx:
			if cm.mp == nil {
				continue
			}
			entry, mp_found := mempool.mempool_get(cm.mp, iv.hash)
			if !mp_found {
				continue
			}
			// Serialize and send tx message.
			w := wire.writer_init(context.temp_allocator)
			wire.serialize_tx(&w, &entry.tx)
			peer_send_message(peer, wire.CMD_TX, wire.writer_bytes(&w))
		}
	}
}

// Relay a tx inv to all active peers except the sender.
_conn_manager_relay_tx :: proc(cm: ^Conn_Manager, txid: Hash256, from_peer: Peer_Id) {
	if cm.blocks_only {
		return
	}
	inv := [1]wire.Inv_Vector{{type = .Witness_Tx, hash = txid}}
	w := wire.writer_init(context.temp_allocator)
	inv_msg := wire.Inv_Message{inventory = inv[:]}
	wire.serialize_inv(&w, &inv_msg)
	payload := wire.writer_bytes(&w)

	for id, peer in cm.peers {
		if id == from_peer || peer.state != .Active {
			continue
		}
		peer_send_message(peer, wire.CMD_INV, payload)
	}
}

// Exported relay for RPC thread. Queues txid for the P2P event loop thread to relay.
conn_manager_relay_tx :: proc(cm: ^Conn_Manager, txid: Hash256) {
	sync.mutex_lock(&cm.relay_mutex)
	append(&cm.relay_queue, txid)
	sync.mutex_unlock(&cm.relay_mutex)
	if cm.event_loop != nil {
		nbio.wake_up(cm.event_loop)
	}
}


// Try to connect a replacement peer when a slot opens.
_conn_manager_replace_peer :: proc(cm: ^Conn_Manager) {
	if len(cm.peers) >= MAX_OUTBOUND_PEERS {
		return
	}

	// Try addresses from the pool.
	attempts := 0
	for cm.address_pool_cursor < len(cm.address_pool) && attempts < 5 {
		addr := cm.address_pool[cm.address_pool_cursor]
		cm.address_pool_cursor += 1
		attempts += 1

		err := conn_manager_add_peer(cm, addr, cm.default_port)
		if err == .None {
			log.infof("Replacement peer connecting: %s:%d", addr, cm.default_port)
			return
		}
	}

	// Pool exhausted — re-discover via DNS.
	if cm.address_pool_cursor >= len(cm.address_pool) {
		log.debug("Address pool exhausted, re-discovering via DNS")
		for addr in cm.address_pool {
			delete(addr)
		}
		delete(cm.address_pool)
		cm.address_pool = conn_manager_discover_peers(cm)
		cm.address_pool_cursor = 0
	}
}

// Short hex for log messages (first 8 chars).
_hash_to_hex_short :: proc(hash: Hash256) -> string {
	hex := "0123456789abcdef"
	buf: [16]byte
	// Display in reversed byte order (standard Bitcoin display).
	for i in 0 ..< 8 {
		b := hash[31 - i]
		buf[i * 2] = hex[b >> 4]
		buf[i * 2 + 1] = hex[b & 0x0f]
	}
	return fmt.tprintf("%s...", string(buf[:16]))
}
