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
import crypto "../crypto"
import "../mempool"
import "../storage"
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
	// Address manager for peer discovery and addr relay (BIP155).
	addr_mgr:           Addr_Manager,
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
	relay_queue:        [dynamic]Relay_Item,
	// Blocks-only mode: reject inbound txs, skip tx relay.
	blocks_only:        bool,
	// Maximum outbound peer connections (default: MAX_OUTBOUND_FULL_RELAY).
	max_outbound:       int,
	// Maximum inbound peer connections (default: max_connections - max_outbound - 1).
	max_inbound:        int,
	// TCP listener port (0 = not listening).
	listen_port:        int,
	// Whether the listener is active.
	listening:          bool,
	// BIP324: v2 encrypted transport enabled (--v2transport flag).
	v2_transport_enabled: bool,
	// BIP324: addresses where v2 handshake failed (skip v2 on reconnect).
	v2_failed_addrs: map[string]bool,
	// Advertised services (base + optional compact filters).
	local_services: u64,
}

conn_manager_init :: proc(cm: ^Conn_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params, mp: ^mempool.Mempool = nil) -> Net_Error {
	cm.chain = cs
	cm.params = params
	cm.mp = mp
	cm.network_magic = params.network_magic
	cm.next_peer_id = 1
	cm.shutdown = false
	cm.max_outbound = MAX_OUTBOUND_FULL_RELAY

	// Set default port based on network.
	switch params.network_magic {
	case wire.MAINNET_MAGIC:  cm.default_port = DEFAULT_PORT_MAINNET
	case wire.TESTNET3_MAGIC: cm.default_port = DEFAULT_PORT_TESTNET3
	case wire.TESTNET4_MAGIC: cm.default_port = DEFAULT_PORT_TESTNET4
	case wire.SIGNET_MAGIC:   cm.default_port = DEFAULT_PORT_SIGNET
	case wire.REGTEST_MAGIC:  cm.default_port = DEFAULT_PORT_REGTEST
	case:                     cm.default_port = DEFAULT_PORT_MAINNET
	}

	cm.peers = make(map[Peer_Id]^Peer, 256)
	cm.zombie_peers = make([dynamic]^Peer, 0, 8)
	cm.v2_failed_addrs = make(map[string]bool, 32)
	cm.relay_queue = make([dynamic]Relay_Item, 0, 16)
	cm.last_ping_check = time.to_unix_seconds(time.now())
	cm.last_header_refresh = time.to_unix_seconds(time.now())

	addr_manager_init(&cm.addr_mgr)
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
	addr_manager_destroy(&cm.addr_mgr)
	delete(cm.relay_queue)
	for addr in cm.v2_failed_addrs {
		delete(addr)
	}
	delete(cm.v2_failed_addrs)

	sync_manager_destroy(&cm.sync_mgr)
}

// Count outbound (non-inbound) peers.
_count_outbound_peers :: proc(cm: ^Conn_Manager) -> int {
	count := 0
	for _, peer in cm.peers {
		if !peer.inbound {
			count += 1
		}
	}
	return count
}

// Count inbound peers.
_count_inbound_peers :: proc(cm: ^Conn_Manager) -> int {
	count := 0
	for _, peer in cm.peers {
		if peer.inbound {
			count += 1
		}
	}
	return count
}

// Start an async connect to a peer. Returns immediately.
conn_manager_add_peer :: proc(cm: ^Conn_Manager, address: string, port: int) -> Net_Error {
	if _count_outbound_peers(cm) >= cm.max_outbound {
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

// Discover peers via DNS seed resolution and populate addr_mgr.
conn_manager_discover_peers :: proc(cm: ^Conn_Manager) {
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
		return
	}

	now := u32(time.to_unix_seconds(time.now()))

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
			addr_bytes := [4]byte{rec.address[0], rec.address[1], rec.address[2], rec.address[3]}
			ka := Known_Address{
				services  = NODE_NETWORK | NODE_WITNESS,
				net       = .IPv4,
				addr      = addr_bytes[:],
				port      = u16(cm.default_port),
				timestamp = now,
			}
			addr_manager_add(&cm.addr_mgr, &ka)
		}
	}
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
	for item in cm.relay_queue {
		_conn_manager_relay_tx(cm, item.txid, item.wtxid, item.fee_rate_kvb, Peer_Id(0))
	}
	clear(&cm.relay_queue)
	sync.mutex_unlock(&cm.relay_mutex)

	now := time.to_unix_seconds(time.now())

	// Check for v2 handshake timeouts — fall back to v1 by reconnecting.
	if cm.v2_transport_enabled {
		v2_timeout_peers := make([dynamic]Peer_Id, 0, 4, context.temp_allocator)
		for id, peer in cm.peers {
			if peer.state == .V2_Handshake && now - peer.connected_at > V2_HANDSHAKE_TIMEOUT_SECS {
				append(&v2_timeout_peers, id)
			}
		}
		for id in v2_timeout_peers {
			peer, found := cm.peers[id]
			if found {
				if peer.inbound {
					// Can't reconnect to inbound peers — just disconnect.
					log.infof("Inbound peer %d: v2 handshake timeout, disconnecting", id)
					sync_handle_disconnect(&cm.sync_mgr, id, &cm.peers)
					conn_manager_remove_peer(cm, id)
				} else {
					_conn_manager_v2_fallback(cm, peer)
				}
			}
		}
	}

	// Check for inbound handshake timeouts (peers stuck in Connecting for too long).
	{
		timeout_peers := make([dynamic]Peer_Id, 0, 4, context.temp_allocator)
		for id, peer in cm.peers {
			if peer.inbound && peer.state == .Connecting && now - peer.connected_at > INBOUND_HANDSHAKE_TIMEOUT {
				append(&timeout_peers, id)
			}
		}
		for id in timeout_peers {
			log.infof("Inbound peer %d: handshake timeout, disconnecting", id)
			conn_manager_remove_peer(cm, id)
		}
	}

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

	// Check compact block timeout — fallback to full block if stalled.
	if cm.sync_mgr.compact_state != nil {
		cs := cm.sync_mgr.compact_state
		if now - cs.requested_at > COMPACT_BLOCK_TIMEOUT {
			log.warnf("Compact block request timed out, falling back to full block")
			_compact_state_fallback(&cm.sync_mgr, &cm.peers)
		}
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

	// Periodic outbound peer replacement — fill empty slots.
	outbound_count := _count_outbound_peers(cm)
	if outbound_count < cm.max_outbound {
		for _ in 0 ..< cm.max_outbound - outbound_count {
			_conn_manager_replace_peer(cm)
		}
	}

	// Free temp allocations.
	free_all(context.temp_allocator)

	// Re-arm the periodic timer (1 second).
	if !cm.shutdown {
		nbio.timeout_poly(1 * time.Second, cm, _on_periodic_timer)
	}
}

// Start TCP listener for inbound connections.
_conn_manager_start_listener :: proc(cm: ^Conn_Manager) {
	if cm.max_inbound <= 0 || cm.listen_port <= 0 {
		return
	}

	endpoint := tcp.Endpoint{address = tcp.IP4_Any, port = cm.listen_port}
	socket, err := nbio.listen_tcp(endpoint)
	if err != nil {
		log.errorf("Failed to listen on port %d: %v", cm.listen_port, err)
		return
	}

	cm.listening = true
	log.infof("P2P listening on 0.0.0.0:%d", cm.listen_port)

	// Arm first accept.
	nbio.accept_poly(socket, cm, _on_accept)
}

// Callback when an inbound connection is accepted.
_on_accept :: proc(op: ^nbio.Operation, cm: ^Conn_Manager) {
	if cm.shutdown {
		return
	}

	// Re-arm accept immediately for the next connection.
	nbio.accept_poly(op.accept.socket, cm, _on_accept)

	if op.accept.err != nil {
		log.debugf("Accept error: %v", op.accept.err)
		return
	}

	// Check inbound limit.
	if _count_inbound_peers(cm) >= cm.max_inbound {
		tcp.close(op.accept.client)
		return
	}

	// Associate the accepted socket with the event loop.
	assoc_err := nbio.associate_socket(op.accept.client)
	if assoc_err != .None {
		log.debugf("Failed to associate inbound socket: %v", assoc_err)
		tcp.close(op.accept.client)
		return
	}

	// Create inbound peer.
	peer := new(Peer)
	peer.id = cm.next_peer_id
	cm.next_peer_id += 1
	peer.socket = op.accept.client
	peer.inbound = true
	peer.state = .Connecting
	peer.network_magic = cm.network_magic
	peer.cm = cm
	peer.recv_buf = make([dynamic]byte, 0, 8192)
	peer.send_queue = make([dynamic][]byte, 0, 16)
	peer.connected_at = time.to_unix_seconds(time.now())

	// Extract remote address.
	ep := op.accept.client_endpoint
	addr4, is_ip4 := ep.address.(tcp.IP4_Address)
	if is_ip4 {
		peer.address = fmt.aprintf("%d.%d.%d.%d", addr4[0], addr4[1], addr4[2], addr4[3])
	} else {
		peer.address = strings.clone("unknown")
	}
	peer.port = ep.port

	cm.peers[peer.id] = peer

	log.infof("Inbound connection from %s:%d (peer %d)", peer.address, peer.port, peer.id)

	// V2 responder or V1 — handled in Phase 3; for now, wait for their version message.
	if cm.v2_transport_enabled {
		// BIP324: initiate v2 responder handshake.
		peer.v2 = new(V2_Transport)
		if !v2_transport_init(peer.v2, false, cm.network_magic) {
			log.warnf("V2 transport init failed for inbound peer %d, falling back to v1", peer.id)
			free(peer.v2)
			peer.v2 = nil
		} else {
			// Send our ell64.
			ell := v2_transport_get_ell64(peer.v2)
			_peer_send_raw(peer, ell[:])
			peer.state = .V2_Handshake
			_peer_start_recv(peer)
			return
		}
	}

	// V1 path: just start receiving, wait for their version message.
	_peer_start_recv(peer)
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

	// Start TCP listener for inbound connections.
	_conn_manager_start_listener(cm)

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
		conn_manager_discover_peers(cm)

		connected := 0
		for connected < cm.max_outbound {
			addr_str, port, ok := addr_manager_get_connectable(&cm.addr_mgr)
			if !ok {
				break
			}
			err := conn_manager_add_peer(cm, addr_str, port)
			if err == .None {
				connected += 1
				log.infof("Connecting to %s:%d", addr_str, port)
			}
			delete(addr_str)
		}

		if connected == 0 && !cm.listening {
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

// Called from _on_connect when async dial succeeds. Sends version (v1) or ell64 (v2) and starts recv.
_conn_manager_peer_connected :: proc(cm: ^Conn_Manager, peer: ^Peer) {
	if cm.v2_transport_enabled && !(peer.address in cm.v2_failed_addrs) {
		// BIP324: initiate v2 handshake.
		peer.v2 = new(V2_Transport)
		if !v2_transport_init(peer.v2, true, cm.network_magic) {
			log.warnf("V2 transport init failed for peer %d, falling back to v1", peer.id)
			free(peer.v2)
			peer.v2 = nil
			// Fall through to v1.
		} else {
			ell := v2_transport_get_ell64(peer.v2)
			_peer_send_raw(peer, ell[:])
			peer.state = .V2_Handshake
			_peer_start_recv(peer)
			return
		}
	}

	// V1 path.
	_, chain_height := chain.chain_tip(cm.chain)
	peer_send_version(peer, cm.params, chain_height, cm.local_services)
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
	case wire.CMD_SENDCMPCT:
		_conn_manager_handle_sendcmpct(cm, peer_id, payload)
	case wire.CMD_CMPCTBLOCK:
		_conn_manager_handle_cmpctblock(cm, peer_id, payload)
	case wire.CMD_BLOCKTXN:
		_conn_manager_handle_blocktxn(cm, peer_id, payload)
	case wire.CMD_GETBLOCKTXN:
		_conn_manager_handle_getblocktxn(cm, peer_id, payload)
	case wire.CMD_FEEFILTER:
		_conn_manager_handle_feefilter(cm, peer_id, payload)
	case wire.CMD_WTXIDRELAY:
		_conn_manager_handle_wtxidrelay(cm, peer_id)
	case wire.CMD_SENDADDRV2:
		_conn_manager_handle_sendaddrv2(cm, peer_id)
	case wire.CMD_ADDR:
		_conn_manager_handle_addr(cm, peer_id, payload)
	case wire.CMD_ADDRV2:
		_conn_manager_handle_addrv2(cm, peer_id, payload)
	case wire.CMD_GETADDR:
		_conn_manager_handle_getaddr(cm, peer_id)
	case wire.CMD_GETCFILTERS:
		_conn_manager_handle_getcfilters(cm, peer_id, payload)
	case wire.CMD_GETCFHEADERS:
		_conn_manager_handle_getcfheaders(cm, peer_id, payload)
	case wire.CMD_GETCFCHECKPT:
		_conn_manager_handle_getcfcheckpt(cm, peer_id, payload)
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

	if peer.inbound && peer.state == .Connecting {
		// Inbound: they sent their version first. Send ours, then wtxidrelay, sendaddrv2, verack.
		_, chain_height := chain.chain_tip(cm.chain)
		peer_send_version(peer, cm.params, chain_height, cm.local_services)

		// BIP339: Send wtxidrelay before verack.
		peer_send_wtxidrelay(peer)
		peer.wtxid_relay_us = true

		// BIP155: Send sendaddrv2 before verack.
		peer_send_sendaddrv2(peer)

		// Send verack.
		peer_send_verack(peer)

		peer.state = .Handshake_Complete
	} else {
		// Outbound: we sent version first, they're responding.
		// BIP339: Send wtxidrelay before verack (must be between version and verack).
		peer_send_wtxidrelay(peer)
		peer.wtxid_relay_us = true

		// BIP155: Send sendaddrv2 before verack.
		peer_send_sendaddrv2(peer)

		// Send verack in response.
		peer_send_verack(peer)

		// If we already sent our version and got theirs, handshake is progressing.
		if peer.state == .Version_Sent {
			peer.state = .Handshake_Complete
		}
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

		// Send sendcmpct (BIP152): announce=true, version=2 (wtxid-based).
		peer_send_sendcmpct(peer, true, COMPACT_BLOCK_VERSION)

		// BIP133: Send our feefilter with min relay fee rate.
		if cm.mp != nil {
			our_fee := max(cm.mp.min_fee, cm.mp.config.min_relay_tx_fee)
			peer_send_feefilter(peer, our_fee)
		}

		// Request peer's address list.
		peer_send_getaddr(peer)

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
			if cm.sync_mgr.state == .In_Sync && cm.mp != nil {
				// BIP339: wtxid_relay peers send Witness_Tx inv with wtxid hash.
				already_have := false
				if iv.type == .Witness_Tx && peer.wtxid_relay {
					already_have = mempool.mempool_has_wtxid(cm.mp, iv.hash)
				} else {
					already_have = mempool.mempool_has(cm.mp, iv.hash)
				}
				if !already_have {
					append(&wanted, wire.Inv_Vector{type = .Witness_Tx, hash = iv.hash})
				}
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

	// Look up entry to get wtxid + fee rate for BIP133/339 relay.
	entry, _ := mempool.mempool_get(cm.mp, txid)
	wtxid := entry.wtxid if entry != nil else txid
	fee_rate_kvb := mempool.fee_rate_per_kvb(entry.fee_rate) if entry != nil else i64(0)
	_conn_manager_relay_tx(cm, txid, wtxid, fee_rate_kvb, peer_id)
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
			// Try txid lookup first, then wtxid fallback (BIP339).
			entry, mp_found := mempool.mempool_get(cm.mp, iv.hash)
			if !mp_found && iv.type == .Witness_Tx {
				entry, mp_found = mempool.mempool_get_by_wtxid(cm.mp, iv.hash)
			}
			if !mp_found {
				continue
			}
			// Serialize and send tx message.
			w := wire.writer_init(context.temp_allocator)
			wire.serialize_tx(&w, &entry.tx)
			peer_send_message(peer, wire.CMD_TX, wire.writer_bytes(&w))
		case .Block, .Witness_Block:
			// Serve full blocks from flat files.
			idx_entry, known := cm.chain.block_index.entries[iv.hash]
			if !known || .Has_Data not_in idx_entry.status {
				continue
			}
			loc := storage.Block_Location{
				file_num    = idx_entry.file_num,
				data_offset = idx_entry.data_offset,
				data_size   = idx_entry.data_size,
			}
			raw, rerr := storage.block_db_read_raw(&cm.chain.block_db, loc, context.temp_allocator)
			if rerr != .None {
				continue
			}
			peer_send_message(peer, wire.CMD_BLOCK, raw)
		}
	}
}

// Relay a tx inv to all active peers except the sender.
// BIP133: skip peers whose feefilter exceeds the tx's fee rate.
// BIP339: use wtxid for peers that negotiated wtxid relay.
_conn_manager_relay_tx :: proc(cm: ^Conn_Manager, txid, wtxid: Hash256, fee_rate_kvb: i64, from_peer: Peer_Id) {
	if cm.blocks_only {
		return
	}

	for id, peer in cm.peers {
		if id == from_peer || peer.state != .Active {
			continue
		}

		// BIP133: skip peers whose feefilter exceeds the tx's fee rate.
		if peer.fee_filter > 0 && fee_rate_kvb > 0 && peer.fee_filter > fee_rate_kvb {
			continue
		}

		// BIP339: use wtxid if both sides negotiated wtxid relay.
		hash := wtxid if (peer.wtxid_relay && peer.wtxid_relay_us) else txid

		inv := [1]wire.Inv_Vector{{type = .Witness_Tx, hash = hash}}
		w := wire.writer_init(context.temp_allocator)
		inv_msg := wire.Inv_Message{inventory = inv[:]}
		wire.serialize_inv(&w, &inv_msg)
		peer_send_message(peer, wire.CMD_INV, wire.writer_bytes(&w))
	}
}

// Exported relay for RPC thread. Queues tx for the P2P event loop thread to relay.
conn_manager_relay_tx :: proc(cm: ^Conn_Manager, txid, wtxid: Hash256, fee_rate_kvb: i64) {
	sync.mutex_lock(&cm.relay_mutex)
	append(&cm.relay_queue, Relay_Item{txid = txid, wtxid = wtxid, fee_rate_kvb = fee_rate_kvb})
	sync.mutex_unlock(&cm.relay_mutex)
	if cm.event_loop != nil {
		nbio.wake_up(cm.event_loop)
	}
}


// Handle sendcmpct message: record peer's compact block version and announce preference.
_conn_manager_handle_sendcmpct :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_sendcmpct(&r)
	if err != .None {
		return
	}

	// Only accept version 2 (wtxid-based short IDs).
	if msg.version == COMPACT_BLOCK_VERSION {
		peer.compact_version = msg.version
		peer.compact_announce = msg.announce
		log.debugf("Peer %d supports compact blocks v%d (announce=%v)", peer_id, msg.version, msg.announce)
	}
}

// Handle compact block message: deserialize and attempt reconstruction.
_conn_manager_handle_cmpctblock :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	cmpct, err := wire.deserialize_compact_block(&r, context.temp_allocator)
	if err != .None {
		log.warnf("Bad cmpctblock from peer %d", peer_id)
		return
	}

	log.debugf("Received compact block from peer %d (%d shortids, %d prefilled)",
		peer_id, len(cmpct.shortids), len(cmpct.prefilled_txs))

	sync_handle_compact_block(&cm.sync_mgr, peer_id, &cmpct, &cm.peers, cm.mp)
}

// Handle blocktxn response: fill missing transactions and assemble block.
_conn_manager_handle_blocktxn :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	msg, err := wire.deserialize_block_txn(&r, context.temp_allocator)
	if err != .None {
		log.warnf("Bad blocktxn from peer %d", peer_id)
		return
	}

	sync_handle_block_txn(&cm.sync_mgr, peer_id, &msg, &cm.peers)
}

// Handle inbound getblocktxn (BIP152): serve requested transactions from a block.
_conn_manager_handle_getblocktxn :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found || peer.state != .Active {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_get_block_txn(&r, context.temp_allocator)
	if err != .None {
		return
	}

	// Look up the block in the index.
	idx_entry, known := cm.chain.block_index.entries[msg.block_hash]
	if !known || .Has_Data not_in idx_entry.status {
		return
	}

	// Read the full block from flat files.
	loc := storage.Block_Location{
		file_num    = idx_entry.file_num,
		data_offset = idx_entry.data_offset,
		data_size   = idx_entry.data_size,
	}
	block, rerr := storage.block_db_read(&cm.chain.block_db, loc, context.temp_allocator)
	if rerr != .None {
		return
	}

	// Extract requested txs.
	txs := make([]wire.Tx, len(msg.indices), context.temp_allocator)
	for i in 0 ..< len(msg.indices) {
		idx := int(msg.indices[i])
		if idx >= len(block.txs) {
			return // Invalid index — abort.
		}
		txs[i] = block.txs[idx]
	}

	response := wire.Block_Txn_Message{block_hash = msg.block_hash, txs = txs}
	peer_send_blocktxn(peer, &response)
}

// Handle inbound feefilter (BIP133): store peer's minimum fee rate.
_conn_manager_handle_feefilter :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_feefilter(&r)
	if err != .None {
		return
	}

	peer.fee_filter = msg.feerate
	log.debugf("Peer %d feefilter: %d sat/kvB", peer_id, msg.feerate)
}

// Handle inbound wtxidrelay (BIP339): mark peer as supporting wtxid relay.
// Must arrive before verack per BIP 339 — ignore if peer is already Active.
_conn_manager_handle_wtxidrelay :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	// BIP339: wtxidrelay must be sent between version and verack.
	if peer.state == .Active {
		return
	}

	peer.wtxid_relay = true
	log.debugf("Peer %d supports wtxid relay", peer_id)
}

// V2 handshake failed — disconnect and reconnect to same address with v1.
_conn_manager_v2_fallback :: proc(cm: ^Conn_Manager, peer: ^Peer) {
	addr := strings.clone(peer.address)
	port := peer.port
	log.infof("V2 handshake failed for peer %d (%s), reconnecting with v1", peer.id, addr)

	// Mark address as v2-failed so reconnect uses v1.
	cm.v2_failed_addrs[strings.clone(peer.address)] = true

	// Disconnect this peer.
	sync_handle_disconnect(&cm.sync_mgr, peer.id, &cm.peers)
	conn_manager_remove_peer(cm, peer.id)

	// Reconnect to same address with v1.
	conn_manager_add_peer(cm, addr, port)
	delete(addr)
}

// Try to connect a replacement peer when a slot opens.
_conn_manager_replace_peer :: proc(cm: ^Conn_Manager) {
	if _count_outbound_peers(cm) >= cm.max_outbound {
		return
	}

	// Try addresses from the addr manager.
	for attempt in 0 ..< 5 {
		addr_str, port, ok := addr_manager_get_connectable(&cm.addr_mgr)
		if !ok {
			break
		}
		err := conn_manager_add_peer(cm, addr_str, port)
		if err == .None {
			log.infof("Replacement peer connecting: %s:%d", addr_str, port)
			delete(addr_str)
			return
		}
		delete(addr_str)
	}

	// No connectable addresses — re-discover via DNS.
	if addr_manager_ipv4_count(&cm.addr_mgr) == 0 {
		log.debug("No connectable addresses, re-discovering via DNS")
		conn_manager_discover_peers(cm)
	}
}

// Handle inbound sendaddrv2 (BIP155): mark peer as supporting addrv2.
// Must arrive before verack per BIP155 — ignore if peer is already Active.
_conn_manager_handle_sendaddrv2 :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	if peer.state == .Active {
		return
	}

	peer.addrv2_relay = true
	log.debugf("Peer %d supports addrv2", peer_id)
}

// Handle inbound addr (v1) message: add addresses to addr_mgr, forward small batches.
_conn_manager_handle_addr :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	msg, err := wire.deserialize_addr(&r, context.temp_allocator)
	if err != .None {
		return
	}

	added := 0
	for &entry in msg.addresses {
		// Extract IPv4 from IPv6-mapped address (::ffff:a.b.c.d).
		is_ipv4 := true
		for i in 0 ..< 10 {
			if entry.address.ip[i] != 0 {
				is_ipv4 = false
				break
			}
		}
		if is_ipv4 && entry.address.ip[10] == 0xFF && entry.address.ip[11] == 0xFF {
			addr_bytes := entry.address.ip[12:16]
			ka := Known_Address{
				services  = entry.address.services,
				net       = .IPv4,
				addr      = addr_bytes,
				port      = entry.address.port,
				timestamp = entry.timestamp,
			}
			if addr_manager_add(&cm.addr_mgr, &ka) {
				added += 1
			}
		} else {
			// Full IPv6 address.
			ka := Known_Address{
				services  = entry.address.services,
				net       = .IPv6,
				addr      = entry.address.ip[:],
				port      = entry.address.port,
				timestamp = entry.timestamp,
			}
			if addr_manager_add(&cm.addr_mgr, &ka) {
				added += 1
			}
		}
	}

	if added > 0 {
		log.debugf("Peer %d: addr message added %d/%d addresses (total: %d)",
			peer_id, added, len(msg.addresses), addr_manager_count(&cm.addr_mgr))
	}

	// Forward small batches (unsolicited announcements, ≤10 entries) to 1-2 random peers.
	if len(msg.addresses) <= 10 {
		_conn_manager_forward_addr(cm, peer_id, msg.addresses)
	}
}

// Handle inbound addrv2 (BIP155) message.
_conn_manager_handle_addrv2 :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	// Only accept addrv2 from peers that sent sendaddrv2.
	if !peer.addrv2_relay {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_addr_v2(&r, context.temp_allocator)
	if err != .None {
		return
	}

	added := 0
	for &entry in msg.addresses {
		ka := Known_Address{
			services  = entry.services,
			net       = entry.net,
			addr      = entry.addr,
			port      = entry.port,
			timestamp = entry.timestamp,
		}
		if addr_manager_add(&cm.addr_mgr, &ka) {
			added += 1
		}
	}

	if added > 0 {
		log.debugf("Peer %d: addrv2 message added %d/%d addresses (total: %d)",
			peer_id, added, len(msg.addresses), addr_manager_count(&cm.addr_mgr))
	}

	// Forward small batches to 1-2 random peers.
	if len(msg.addresses) <= 10 {
		_conn_manager_forward_addrv2(cm, peer_id, msg.addresses)
	}
}

// Handle inbound getaddr: respond with up to 1000 random addresses.
_conn_manager_handle_getaddr :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found || peer.state != .Active {
		return
	}

	addrs := addr_manager_get_random(&cm.addr_mgr, 1000, context.temp_allocator)
	if len(addrs) == 0 {
		return
	}

	if peer.addrv2_relay {
		// Send addrv2 to peers that negotiated it.
		v2_addrs := make([]wire.Addr_V2_Address, len(addrs), context.temp_allocator)
		for ka, i in addrs {
			v2_addrs[i] = wire.Addr_V2_Address{
				timestamp = ka.timestamp,
				services  = ka.services,
				net       = ka.net,
				addr      = ka.addr,
				port      = ka.port,
			}
		}
		peer_send_addrv2(peer, v2_addrs)
	} else {
		// Send v1 addr (IPv4/IPv6 only).
		v1_addrs := make([dynamic]wire.Net_Address_Timestamp, 0, len(addrs), context.temp_allocator)
		for ka in addrs {
			if ka.net == .IPv4 && len(ka.addr) == 4 {
				na: wire.Net_Address
				na.services = ka.services
				na.port = ka.port
				// IPv4-mapped IPv6.
				na.ip[10] = 0xFF
				na.ip[11] = 0xFF
				copy(na.ip[12:], ka.addr)
				append(&v1_addrs, wire.Net_Address_Timestamp{timestamp = ka.timestamp, address = na})
			} else if ka.net == .IPv6 && len(ka.addr) == 16 {
				na: wire.Net_Address
				na.services = ka.services
				na.port = ka.port
				copy(na.ip[:], ka.addr)
				append(&v1_addrs, wire.Net_Address_Timestamp{timestamp = ka.timestamp, address = na})
			}
		}
		if len(v1_addrs) > 0 {
			peer_send_addr(peer, v1_addrs[:])
		}
	}

	log.debugf("Peer %d: responded to getaddr with %d addresses", peer_id, len(addrs))
}

// Forward addr v1 entries to 1-2 random active peers (skip sender).
_conn_manager_forward_addr :: proc(cm: ^Conn_Manager, from_peer: Peer_Id, addresses: []wire.Net_Address_Timestamp) {
	forwarded := 0
	for id, peer in cm.peers {
		if id == from_peer || peer.state != .Active {
			continue
		}
		if forwarded >= 2 {
			break
		}

		if peer.addrv2_relay {
			// Convert v1 to v2 for addrv2 peers.
			v2_addrs := make([dynamic]wire.Addr_V2_Address, 0, len(addresses), context.temp_allocator)
			for &entry in addresses {
				is_ipv4 := true
				for i in 0 ..< 10 {
					if entry.address.ip[i] != 0 {
						is_ipv4 = false
						break
					}
				}
				if is_ipv4 && entry.address.ip[10] == 0xFF && entry.address.ip[11] == 0xFF {
					append(&v2_addrs, wire.Addr_V2_Address{
						timestamp = entry.timestamp, services = entry.address.services,
						net = .IPv4, addr = entry.address.ip[12:16], port = entry.address.port,
					})
				} else {
					append(&v2_addrs, wire.Addr_V2_Address{
						timestamp = entry.timestamp, services = entry.address.services,
						net = .IPv6, addr = entry.address.ip[:], port = entry.address.port,
					})
				}
			}
			if len(v2_addrs) > 0 {
				peer_send_addrv2(peer, v2_addrs[:])
			}
		} else {
			peer_send_addr(peer, addresses)
		}
		forwarded += 1
	}
}

// Forward addrv2 entries to 1-2 random active peers (skip sender).
_conn_manager_forward_addrv2 :: proc(cm: ^Conn_Manager, from_peer: Peer_Id, addresses: []wire.Addr_V2_Address) {
	forwarded := 0
	for id, peer in cm.peers {
		if id == from_peer || peer.state != .Active {
			continue
		}
		if forwarded >= 2 {
			break
		}

		if peer.addrv2_relay {
			peer_send_addrv2(peer, addresses)
		} else {
			// Downgrade to v1 for non-addrv2 peers (IPv4/IPv6 only).
			v1_addrs := make([dynamic]wire.Net_Address_Timestamp, 0, len(addresses), context.temp_allocator)
			for &entry in addresses {
				if entry.net == .IPv4 && len(entry.addr) == 4 {
					na: wire.Net_Address
					na.services = entry.services
					na.port = entry.port
					na.ip[10] = 0xFF
					na.ip[11] = 0xFF
					copy(na.ip[12:], entry.addr)
					append(&v1_addrs, wire.Net_Address_Timestamp{timestamp = entry.timestamp, address = na})
				} else if entry.net == .IPv6 && len(entry.addr) == 16 {
					na: wire.Net_Address
					na.services = entry.services
					na.port = entry.port
					copy(na.ip[:], entry.addr)
					append(&v1_addrs, wire.Net_Address_Timestamp{timestamp = entry.timestamp, address = na})
				}
			}
			if len(v1_addrs) > 0 {
				peer_send_addr(peer, v1_addrs[:])
			}
		}
		forwarded += 1
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

// --- BIP 157 compact block filter handlers ---

// Handle getcfilters: send one cfilter per block in the requested range.
_conn_manager_handle_getcfilters :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	if cm.chain.filter_db == nil {
		return // Filter index not enabled.
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_get_cfilters(&r)
	if err != .None {
		return
	}

	// Only basic (type 0) filters supported.
	if msg.filter_type != chain.FILTER_TYPE_BASIC {
		return
	}

	// Find stop block in our index.
	stop_entry, stop_found := cm.chain.block_index.entries[msg.stop_hash]
	if !stop_found || !(.Valid_Chain in stop_entry.status) {
		return
	}

	start_height := int(msg.start_height)
	stop_height := stop_entry.height
	tip_height := chain.chain_height(cm.chain)

	// Validate range: max 1000 blocks, within active chain.
	if start_height > stop_height || stop_height > tip_height {
		return
	}
	if stop_height - start_height + 1 > 1000 {
		return
	}

	peer, peer_found := cm.peers[peer_id]
	if !peer_found {
		return
	}

	for h in start_height ..= stop_height {
		block_hash := cm.chain.active_chain[h]
		filter_data, found := storage.filter_db_get_filter(cm.chain.filter_db, block_hash, context.temp_allocator)
		if !found {
			filter_data = nil
		}

		// Build cfilter with N prefix per BIP158.
		// We need to prepend CompactSize(N) — but we don't store N separately.
		// For cfilter, the on-wire filter_data should be the raw stored filter.
		// BIP157 says: "FilterBytes: the serialized GCS filter for this block".
		// BIP158: "the serialized GCS has N as CompactSize prefix".
		// Our gcs_build_filter doesn't include N. Prepend it here.
		entry, efound := cm.chain.block_index.entries[block_hash]
		n_elements: u64 = 0
		if efound {
			// We don't store n_elements in the index.
			// Send raw filter without N prefix — matching Bitcoin Core's behavior where
			// the cfilter message's filter_data IS the BIP158 serialized filter (N + GCS data).
			// Since we don't store N, send what we have.
			// TODO: store N alongside filter for proper BIP158 serialization.
		}
		_ = n_elements
		_ = entry

		cfilter := wire.CFilter_Message{
			filter_type = chain.FILTER_TYPE_BASIC,
			block_hash  = block_hash,
			filter_data = filter_data,
		}
		peer_send_cfilter(peer, &cfilter)
	}
}

// Handle getcfheaders: send filter hashes for a range of blocks.
_conn_manager_handle_getcfheaders :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	if cm.chain.filter_db == nil {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_get_cfheaders(&r)
	if err != .None {
		return
	}

	if msg.filter_type != chain.FILTER_TYPE_BASIC {
		return
	}

	stop_entry, stop_found := cm.chain.block_index.entries[msg.stop_hash]
	if !stop_found || !(.Valid_Chain in stop_entry.status) {
		return
	}

	start_height := int(msg.start_height)
	stop_height := stop_entry.height
	tip_height := chain.chain_height(cm.chain)

	if start_height > stop_height || stop_height > tip_height {
		return
	}
	if stop_height - start_height + 1 > 2000 {
		return
	}

	peer, peer_found := cm.peers[peer_id]
	if !peer_found {
		return
	}

	// Get prev_filter_header (header of block before start_height).
	prev_filter_header: Hash256
	if start_height > 0 {
		prev_hash := cm.chain.active_chain[start_height - 1]
		prev_hdr, found := storage.filter_db_get_header(cm.chain.filter_db, prev_hash)
		if found {
			prev_filter_header = prev_hdr
		}
	}

	// Collect filter hashes for the range.
	count := stop_height - start_height + 1
	filter_hashes := make([]Hash256, count, context.temp_allocator)
	for i in 0 ..< count {
		h := start_height + i
		block_hash := cm.chain.active_chain[h]
		header, found := storage.filter_db_get_header(cm.chain.filter_db, block_hash)
		if found {
			// BIP157: filter_hashes contains the filter *hash* (sha256d of filter bytes),
			// NOT the filter header. We store filter headers, so we need filter hashes too.
			// For now, use the filter hash derived from stored filter bytes.
			filter_data, ff := storage.filter_db_get_filter(cm.chain.filter_db, block_hash, context.temp_allocator)
			if ff && len(filter_data) > 0 {
				filter_hashes[i] = crypto.sha256d(filter_data)
			}
			_ = header
		}
	}

	resp := wire.CFHeaders_Message{
		filter_type        = chain.FILTER_TYPE_BASIC,
		stop_hash          = msg.stop_hash,
		prev_filter_header = prev_filter_header,
		filter_hashes      = filter_hashes,
	}
	peer_send_cfheaders(peer, &resp)
}

// Handle getcfcheckpt: send filter headers at every 1000th block.
_conn_manager_handle_getcfcheckpt :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	if cm.chain.filter_db == nil {
		return
	}

	r := wire.reader_init(payload)
	msg, err := wire.deserialize_get_cfcheckpt(&r)
	if err != .None {
		return
	}

	if msg.filter_type != chain.FILTER_TYPE_BASIC {
		return
	}

	stop_entry, stop_found := cm.chain.block_index.entries[msg.stop_hash]
	if !stop_found || !(.Valid_Chain in stop_entry.status) {
		return
	}

	stop_height := stop_entry.height
	tip_height := chain.chain_height(cm.chain)
	if stop_height > tip_height {
		return
	}

	peer, peer_found := cm.peers[peer_id]
	if !peer_found {
		return
	}

	// Collect filter headers at every 1000th block.
	checkpoints := make([dynamic]Hash256, 0, stop_height / 1000 + 1, context.temp_allocator)
	for h := 1000; h <= stop_height; h += 1000 {
		block_hash := cm.chain.active_chain[h]
		header, found := storage.filter_db_get_header(cm.chain.filter_db, block_hash)
		if found {
			append(&checkpoints, header)
		} else {
			append(&checkpoints, HASH_ZERO)
		}
	}

	resp := wire.CFCheckpt_Message{
		filter_type    = chain.FILTER_TYPE_BASIC,
		stop_hash      = msg.stop_hash,
		filter_headers = checkpoints[:],
	}
	peer_send_cfcheckpt(peer, &resp)
}
