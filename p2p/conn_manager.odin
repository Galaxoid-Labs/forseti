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
import zmqpkg "../zmq"

Control_Action :: enum {
	Disconnect_Peer,
	Connect_Once,      // addnode onetry/add
	Set_Network_Active,
	Precious_Block,
	Prune_Now,
	Submit_Block,  // submitblock: validate+connect on the P2P thread, then announce
	Submit_Header, // submitheader: header-only acceptance into the block index
	Get_Block_From_Peer, // getblockfrompeer: send a getdata(block) to one peer
}

// Cross-thread node-control request (RPC thread → P2P event loop). Optional
// completion signaling for synchronous RPCs (pruneblockchain, submitblock).
Control_Request :: struct {
	action:  Control_Action,
	peer_id: Peer_Id,
	address: string, // heap clone, freed by the drain
	port:    int,
	active:  bool,
	hash:    Hash256,
	height:  int,
	block:   ^wire.Block,        // Submit_Block/Submit_Header: caller-owned, valid until done posts
	done:    ^sync.Sema, // optional: posted when the action completes
	result:  ^i64,       // optional: action-specific result
}

// Submit_Block result codes (negative values are -Chain_Error ordinals).
SUBMIT_OK :: i64(0)
SUBMIT_DUPLICATE :: i64(1)

Conn_Manager :: struct {
	zmq: ^zmqpkg.Node, // nil unless --zmqpub* configured
	control_mutex: sync.Mutex,
	control_queue: [dynamic]Control_Request,
	ban_mutex:     sync.Mutex,
	banned:        map[string]i64, // address → banned-until unix ts
	added_mutex:   sync.Mutex,
	added_nodes:   [dynamic]string, // addnode add list (heap clones)
	network_active: bool, // setnetworkactive; connects/reconnects gated
	data_dir:       string, // for anchors.dat
	last_feeler:    i64,    // unix ts of the last feeler attempt
	// -maxuploadtarget: rolling 24h upload budget (bytes; 0 = unlimited)
	max_upload_target:      i64,
	upload_window_start:    i64,
	upload_window_baseline: i64,
	// --proxy: route all outbound connections through this SOCKS5 endpoint;
	// hostname targets (.onion, DNS-seed names) resolve at the proxy.
	proxy_set:      bool,
	proxy_endpoint: tcp.Endpoint,
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
	// nbio event loop reference for cross-thread operations. Guarded by
	// event_loop_mu: cross-thread wake_up must not race the P2P thread
	// clearing the pointer and releasing the loop at shutdown (kevent on a
	// closed kqueue fails an assert in core:nbio).
	event_loop:         ^nbio.Event_Loop,
	event_loop_mu:      sync.Mutex,
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
	// Log level for the P2P thread (inherited from CLI --debug flag).
	log_level: log.Level,
	// BIP111: enable bloom filter support (also gates BIP35 mempool message).
	peer_bloom_filters: bool,
	// Addresses recently evicted as useless (stale height / no agent) —
	// skipped by replacement selection so we don't redial known crawlers.
	// Keys are heap-cloned; value = unix eviction time.
	useless_addrs: map[string]i64,
	// Node status snapshot for the GUI (populated only when status_enabled).
	status_enabled: bool,
	status:         Node_Status,
	status_mutex:   sync.Mutex,
	started_at:     i64, // unix timestamp, for uptime display
	// Ring of (chain_tx, time) samples from the 1 Hz status tick; ETA divides
	// estimated remaining txs by throughput measured over this window.
	txput_ring:     [120]struct{ chain_tx: i64, height: int, t: i64 },
	txput_idx:      int,
	txput_count:    int,
	// Last completed profile window, held on the status when the live window is
	// momentarily empty (it resets to 0 every 1000 blocks for the log line, else
	// the dashboard panel blanks for a tick mid-sync).
	last_prof:      struct{
		blocks:                                                        int,
		ms_per_block, read, prefetch, valid, utxo, scripts, undo:      f64,
	},
	disk_usage:     i64, // cached datadir usage (walking files is too heavy per tick)
	disk_check_at:  i64,
	// Lifetime traffic counters (P2P thread only) — the GUI derives per-second
	// rates client-side so the graph works identically for remote dashboards.
	total_bytes_sent: i64,
	total_bytes_recv: i64,
}

conn_manager_init :: proc(cm: ^Conn_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params, mp: ^mempool.Mempool = nil) -> Net_Error {
	cm.chain = cs
	cm.params = params
	cm.mp = mp
	cm.network_magic = params.network_magic
	cm.next_peer_id = 1
	cm.started_at = time.to_unix_seconds(time.now())
	// Snapshot updates are cheap (a map walk at 1 Hz); always on so remote
	// dashboards (getnodestatus RPC) work against headless nodes.
	cm.status_enabled = true
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
	cm.control_queue = make([dynamic]Control_Request, 0, 4)
	cm.banned = make(map[string]i64)
	cm.added_nodes = make([dynamic]string, 0, 4)
	cm.network_active = true
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
	// Free zombie peers (already destroyed, just need freeing).
	for peer in cm.zombie_peers {
		_peer_free(peer)
	}
	delete(cm.zombie_peers)

	for addr in cm.useless_addrs {
		delete(addr)
	}
	delete(cm.useless_addrs)

	// Free all peers. If conn_manager_run was called, peers were already
	// peer_destroy'd on the P2P thread; otherwise destroy them now.
	for _, peer in cm.peers {
		if peer.state != .Disconnected {
			peer_destroy(peer)
		}
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
// Full-relay outbound only — block-relay connections and feelers have
// their own budgets in the topology tick.
_count_outbound_peers :: proc(cm: ^Conn_Manager) -> int {
	count := 0
	for _, peer in cm.peers {
		if !peer.inbound && (peer.conn_type == .Full_Relay || peer.conn_type == .Manual) {
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
conn_manager_add_peer :: proc(cm: ^Conn_Manager, address: string, port: int, conn_type: Connection_Type = .Full_Relay) -> Net_Error {
	// Block-relay and feeler connections have their own budgets (topology
	// tick); only full-relay outbound counts against max_outbound.
	if conn_type == .Full_Relay && _count_outbound_peers(cm) >= cm.max_outbound {
		return .Too_Many_Peers
	}

	peer_id := cm.next_peer_id
	cm.next_peer_id += 1

	peer_start_connect(cm, address, port, peer_id, conn_type)
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

// Configure the SOCKS5 proxy from an "ip[:port]" string. Must run before
// any connections start.
conn_manager_set_proxy :: proc(cm: ^Conn_Manager, proxy: string) -> bool {
	ep, ok := parse_proxy_endpoint(proxy, 9050) // Tor's default SOCKS port
	if !ok {
		log.errorf("Invalid --proxy value: %s (want ipv4[:port])", proxy)
		return false
	}
	cm.proxy_set = true
	cm.proxy_endpoint = ep
	log.infof("All outbound P2P connections will use SOCKS5 proxy %v:%d", ep.address, ep.port)
	return true
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

	// With a proxy, local DNS lookups would leak — connect to the seed
	// hostnames THROUGH the proxy instead (Core's ADDR_FETCH behavior: the
	// seed names answer P2P on the default port, we getaddr and move on).
	if cm.proxy_set {
		for seed in seeds {
			peer_start_connect(cm, seed, cm.default_port, cm.next_peer_id)
			cm.next_peer_id += 1
		}
		return
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
	// Wake up the event loop so run_until exits. Under event_loop_mu so we
	// never poke a loop the P2P thread has already torn down.
	sync.mutex_lock(&cm.event_loop_mu)
	if cm.event_loop != nil {
		nbio.wake_up(cm.event_loop)
	}
	sync.mutex_unlock(&cm.event_loop_mu)
}

// Periodic timer callback — handles ping, header refresh, stall checks.
_on_periodic_timer :: proc(op: ^nbio.Operation, cm: ^Conn_Manager) {
	_drain_control_queue(cm)
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

	// Reap any completed background UTXO flush (blocks are rare at the tip,
	// so sync_handle_block alone might leave a finished worker unreaped).
	if completed, _ := chain.coins_cache_flush_pump(&cm.chain.coins); completed {
		cm.chain.last_flush_height = cm.chain.coins.flush_tip_height
		chain.prune_block_files(cm.chain, cm.chain.last_flush_height)
	}

	// Refresh the GUI status snapshot (reads node state on this thread — the
	// owner of chain/mempool/peers — and publishes under status_mutex).
	if cm.status_enabled {
		_update_node_status(cm, now)
	}

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
					log.debugf("Inbound peer %d: v2 handshake timeout, disconnecting", id)
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
			log.debugf("Inbound peer %d: handshake timeout, disconnecting", id)
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

	// Start inbound listener once we're in sync (deferred from startup to avoid IBD overhead).
	if !cm.listening && cm.sync_mgr.state == .In_Sync {
		_conn_manager_start_listener(cm)
	}

	// Block-relay slots + feelers.
	if cm.network_active {
		_topology_tick(cm, now)
	}

	// Periodic outbound peer replacement — fill empty slots.
	// During IBD, only try one replacement per tick to reduce connection churn.
	outbound_count := _count_outbound_peers(cm)
	if outbound_count < cm.max_outbound {
		max_attempts := 1 if cm.sync_mgr.state != .In_Sync else cm.max_outbound - outbound_count
		for _ in 0 ..< max_attempts {
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
	peer.conn_type = .Inbound_Conn
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

	if !cm.network_active || conn_manager_is_banned(cm, peer.address) {
		tcp.close(peer.socket)
		_peer_free(peer)
		return
	}
	cm.peers[peer.id] = peer

	log.debugf("Inbound connection from %s:%d (peer %d)", peer.address, peer.port, peer.id)

	if cm.v2_transport_enabled {
		// BIP324 responder: prepare v2 keys but send NOTHING — the peer's
		// first bytes decide v1 (magic+"version" prefix) vs v2 (ell64).
		// See _peer_v2_detect. Eagerly sending our ell64 here corrupted the
		// stream for every plaintext v1 client (found via electrs).
		peer.v2 = new(V2_Transport)
		if !v2_transport_init(peer.v2, false, cm.network_magic) {
			log.warnf("V2 transport init failed for inbound peer %d, falling back to v1", peer.id)
			free(peer.v2)
			peer.v2 = nil
		} else {
			peer.v2_detect = true
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
	// Console logger writes to os.stdout/os.stderr. In --tui/--daemon those fds
	// are redirected to <datadir>/debug.log at the OS level (see main). We use
	// the console logger (os.stdout) rather than a file logger because os2's
	// stream write on a freshly-opened file handle silently drops writes on
	// worker threads — only os.stdout works reliably across threads.
	context.logger = log.create_console_logger(cm.log_level, {.Level, .Time})

	log.infof("Starting connection manager (network: %s)", cm.params.name)

	// Acquire the event loop for this thread.
	el_err := nbio.acquire_thread_event_loop()
	if el_err != nil {
		log.errorf("Failed to acquire event loop: %v", el_err)
		return
	}
	cm.event_loop = nbio.current_thread_event_loop()

	// Defer TCP listener until In_Sync — inbound peers during IBD waste event loop cycles.
	// Listener is started in _on_periodic_timer when sync state transitions to In_Sync.

	// Anchors first: redial last session's block-relay peers (file is
	// consumed on read).
	anchors_connect(cm)

	// If --connect was specified, add peer now (event loop is ready).
	if len(cm.connect_address) > 0 {
		err := conn_manager_add_peer(cm, cm.connect_address, cm.connect_port, .Manual)
		if err == .None {
			log.infof("Connecting to manual peer %s:%d", cm.connect_address, cm.connect_port)
		} else {
			log.warnf("Failed to connect to %s:%d: %v", cm.connect_address, cm.connect_port, err)
		}
	}

	// Discover peers via DNS if no manual peer was configured (anchors are
	// block-relay-only and do not replace full-relay discovery).
	only_anchors := true
	for _, peer in cm.peers {
		if peer.conn_type != .Block_Relay {
			only_anchors = false
			break
		}
	}
	if len(cm.peers) == 0 || (only_anchors && len(cm.peers) > 0 && len(cm.connect_address) == 0) {
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
				log.debugf("Connecting to %s:%d", addr_str, port)
			}
			delete(addr_str)
		}

		// Under a proxy, discover_peers dials the seed hostnames directly
		// (async, already in cm.peers) instead of filling the addr manager.
		if connected == 0 && len(cm.peers) == 0 && !cm.listening {
			log.warn("No peers available. Exiting.")
			sync.mutex_lock(&cm.event_loop_mu)
			cm.event_loop = nil
			sync.mutex_unlock(&cm.event_loop_mu)
			nbio.release_thread_event_loop()
			return
		}
	}

	// Start periodic timer (fires every 1 second for stall checks, ping, etc.)
	nbio.timeout_poly(1 * time.Second, cm, _on_periodic_timer)

	// Run the event loop until shutdown.
	nbio.run_until(&cm.shutdown)

	// Remember the block-relay peers for the next start.
	anchors_save(cm)

	// Destroy all peers while the event loop is still active on this thread.
	// peer_destroy calls nbio.remove to cancel pending recv timeouts — this must
	// happen before release_thread_event_loop, otherwise it segfaults.
	for _, peer in cm.peers {
		peer_destroy(peer)
	}
	// Also free zombies that were waiting for the next tick.
	for peer in cm.zombie_peers {
		_peer_free(peer)
	}
	clear(&cm.zombie_peers)

	// Clear the loop pointer before releasing so cross-thread wake_up can
	// never target a dead kqueue.
	sync.mutex_lock(&cm.event_loop_mu)
	cm.event_loop = nil
	sync.mutex_unlock(&cm.event_loop_mu)
	nbio.release_thread_event_loop()
	log.info("Connection manager shutting down.")
}

// Called from _on_connect when async dial succeeds. Sends version (v1) or ell64 (v2) and starts recv.
_conn_manager_peer_connected :: proc(cm: ^Conn_Manager, peer: ^Peer, arm_recv := true) {
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
			if arm_recv {
				_peer_start_recv(peer)
			}
			return
		}
	}

	// V1 path.
	_, chain_height := chain.chain_tip(cm.chain)
	peer_send_version(peer, cm.params, chain_height, cm.local_services)
	peer.state = .Version_Sent
	if arm_recv {
		_peer_start_recv(peer)
	}
}

// Enqueue a control request from any thread; the P2P event loop drains it
// on its periodic tick.
conn_manager_control :: proc(cm: ^Conn_Manager, req: Control_Request) {
	sync.mutex_lock(&cm.control_mutex)
	append(&cm.control_queue, req)
	sync.mutex_unlock(&cm.control_mutex)
}

conn_manager_is_banned :: proc(cm: ^Conn_Manager, address: string) -> bool {
	sync.mutex_lock(&cm.ban_mutex)
	defer sync.mutex_unlock(&cm.ban_mutex)
	until, found := cm.banned[address]
	if !found {
		return false
	}
	if time.to_unix_seconds(time.now()) >= until {
		delete_key(&cm.banned, address)
		return false
	}
	return true
}

conn_manager_set_ban :: proc(cm: ^Conn_Manager, address: string, until: i64) {
	sync.mutex_lock(&cm.ban_mutex)
	cm.banned[strings.clone(address)] = until
	sync.mutex_unlock(&cm.ban_mutex)
}

conn_manager_remove_ban :: proc(cm: ^Conn_Manager, address: string) -> bool {
	sync.mutex_lock(&cm.ban_mutex)
	defer sync.mutex_unlock(&cm.ban_mutex)
	if address in cm.banned {
		delete_key(&cm.banned, address)
		return true
	}
	return false
}

conn_manager_clear_bans :: proc(cm: ^Conn_Manager) {
	sync.mutex_lock(&cm.ban_mutex)
	clear(&cm.banned)
	sync.mutex_unlock(&cm.ban_mutex)
}

// Drain pending control requests — runs on the P2P thread only.
_drain_control_queue :: proc(cm: ^Conn_Manager) {
	sync.mutex_lock(&cm.control_mutex)
	pending := cm.control_queue
	cm.control_queue = make([dynamic]Control_Request, 0, 4)
	sync.mutex_unlock(&cm.control_mutex)

	for req in pending {
		switch req.action {
		case .Disconnect_Peer:
			target := req.peer_id
			if target == 0 && req.address != "" {
				for id, peer in cm.peers {
					if peer.address == req.address {
						target = id
						break
					}
				}
			}
			if peer, found := cm.peers[target]; found {
				log.infof("RPC disconnect of peer %d (%s)", target, peer.address)
				sync_handle_disconnect(&cm.sync_mgr, target, &cm.peers)
				conn_manager_remove_peer(cm, target)
			}
		case .Connect_Once:
			if cm.network_active && !conn_manager_is_banned(cm, req.address) {
				peer_start_connect(cm, req.address, req.port, cm.next_peer_id, .Manual)
				cm.next_peer_id += 1
			}
		case .Set_Network_Active:
			cm.network_active = req.active
			if !req.active {
				ids := make([dynamic]Peer_Id, 0, len(cm.peers), context.temp_allocator)
				for id in cm.peers {
					append(&ids, id)
				}
				for id in ids {
					sync_handle_disconnect(&cm.sync_mgr, id, &cm.peers)
					conn_manager_remove_peer(cm, id)
				}
				log.info("Network deactivated via RPC (setnetworkactive false)")
			} else {
				log.info("Network reactivated via RPC")
			}
		case .Get_Block_From_Peer:
			if peer, found := cm.peers[req.peer_id]; found {
				inv := []wire.Inv_Vector{{type = .Witness_Block, hash = req.hash}}
				peer_send_getdata(peer, inv)
				log.infof("getblockfrompeer: requested %x from peer %d", req.hash, req.peer_id)
			} else {
				log.warnf("getblockfrompeer: peer %d not connected", req.peer_id)
			}
		case .Precious_Block:
			if entry, found := cm.chain.block_index.entries[req.hash]; found {
				cm.chain.block_index.best_header = entry
				if cerr := chain.activate_best_chain(cm.chain, allow_tie = true); cerr != .None {
					log.warnf("preciousblock: activation failed: %v", cerr)
				}
			}
		case .Prune_Now:
			chain.prune_block_files(cm.chain, cm.chain.last_flush_height)
			if req.result != nil {
				req.result^ = i64(cm.chain.last_flush_height)
			}
		case .Submit_Block:
			res := SUBMIT_OK
			hash := wire.block_header_hash(&req.block.header)
			if entry, known := cm.chain.block_index.entries[hash]; known && .Valid_Chain in entry.status {
				res = SUBMIT_DUPLICATE
			} else {
				aerr := chain.accept_block(cm.chain, req.block)
				switch {
				case aerr == .Block_Already_Known:
					res = SUBMIT_DUPLICATE
				case aerr != .None:
					res = -i64(aerr)
				case:
					if cm.mp != nil {
						mempool.mempool_remove_for_block(cm.mp, req.block)
						mempool.mempool_update_tip(cm.mp)
					}
					_announce_block(&cm.sync_mgr, 0, req.block, hash, &cm.peers)
					log.infof("submitblock: accepted %02x%02x%02x%02x... at height %d",
						hash[31], hash[30], hash[29], hash[28], chain.chain_height(cm.chain))
				}
			}
			if req.result != nil {
				req.result^ = res
			}
		case .Submit_Header:
			res := SUBMIT_OK
			hash := wire.block_header_hash(&req.block.header)
			if _, known := cm.chain.block_index.entries[hash]; known {
				res = SUBMIT_DUPLICATE
			} else if _, aerr := chain.accept_block_header(cm.chain, &req.block.header); aerr != .None {
				res = -i64(aerr)
			}
			if req.result != nil {
				req.result^ = res
			}
		}
		if req.address != "" {
			delete(req.address)
		}
		if req.done != nil {
			sync.sema_post(req.done)
		}
	}
	delete(pending)
}

// Dispatch inbound message by command (called inline from recv callback).
_conn_manager_dispatch :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, cmd: string, payload: []byte) {
	// Empty command = disconnect signal.
	if cmd == "" {
		log.debugf("Peer %d disconnected", peer_id)
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
	case wire.CMD_GETHEADERS:
		_conn_manager_handle_getheaders(cm, peer_id, payload)
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
	case wire.CMD_MEMPOOL:
		_conn_manager_handle_mempool(cm, peer_id)
	case wire.CMD_FILTERLOAD, wire.CMD_FILTERADD, wire.CMD_FILTERCLEAR:
		// BIP111: disconnect peers that send bloom filter messages when we don't advertise NODE_BLOOM.
		if !cm.peer_bloom_filters {
			log.debugf("Peer %d sent %s but we don't support bloom filters, disconnecting", peer_id, cmd)
			sync_handle_disconnect(&cm.sync_mgr, peer_id, &cm.peers)
			conn_manager_remove_peer(cm, peer_id)
		}
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

		// BIP339/BIP155: only for peers new enough to know them (Core gates
		// both on 70016; older strict clients disconnect on unknown commands).
		if peer.version >= WTXID_RELAY_VERSION {
			peer_send_wtxidrelay(peer)
			peer.wtxid_relay_us = true
			peer_send_sendaddrv2(peer)
		}

		// Send verack.
		peer_send_verack(peer)

		peer.state = .Handshake_Complete
	} else {
		// Outbound: we sent version first, they're responding.
		// BIP339/BIP155 (between version and verack), gated on 70016.
		// Block-relay-only and feeler connections skip addr relay entirely.
		if peer.version >= WTXID_RELAY_VERSION {
			peer_send_wtxidrelay(peer)
			peer.wtxid_relay_us = true
			if peer.conn_type != .Block_Relay && peer.conn_type != .Feeler {
				peer_send_sendaddrv2(peer)
			}
		}

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
		// Feeler: the handshake IS the probe — the address works. Done.
		if peer.conn_type == .Feeler {
			log.debugf("Feeler to %s succeeded", peer.address)
			conn_manager_remove_peer(cm, peer_id)
			return
		}

		// Outbound slots are scarce (8): drop peers that cannot serve blocks
		// or meaningful tx relay. Crawlers/monitors advertise start_height 0
		// or an empty user agent; deeply stale nodes are equally useless.
		// Inbound peers are exempt — they cost us nothing. The evicted
		// address goes on a cooldown so replacement doesn't redial it.
		_, our_height := chain.chain_tip(cm.chain)
		stale := our_height - int(peer.start_height) > 10_000
		no_agent := len(peer.user_agent) == 0
		if !peer.inbound && (stale || no_agent) {
			log.infof("Peer %d useless for outbound (height=%d ours=%d agent=%q) — dropping",
				peer_id, peer.start_height, our_height, peer.user_agent)
			_mark_addr_useless(cm, peer.address)
			sync_handle_disconnect(&cm.sync_mgr, peer_id, &cm.peers)
			return
		}

		peer.state = .Active
		log.debugf("Peer %d handshake complete, now active (%s)", peer_id, connection_type_string(peer.conn_type))

		// Feature messages, each gated on the peer's advertised version
		// (Core parity — old/strict peers treat unknowns as fatal).
		if peer.version >= SENDHEADERS_VERSION {
			peer_send_sendheaders(peer) // BIP130
		}
		if peer.version >= COMPACT_BLOCKS_VERSION_GATE {
			peer_send_sendcmpct(peer, true, COMPACT_BLOCK_VERSION) // BIP152
		}
		if cm.mp != nil && peer.version >= FEEFILTER_VERSION && peer.conn_type != .Block_Relay {
			our_fee := max(cm.mp.min_fee, cm.mp.config.min_relay_tx_fee)
			peer_send_feefilter(peer, our_fee) // BIP133
		}

		// Request peer's address list — outbound full-relay connections only
		// (Core never getaddrs inbound peers, and block-relay-only
		// connections do no addr relay by design).
		if !peer.inbound && peer.conn_type != .Block_Relay {
			peer_send_getaddr(peer)
		}

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
		case .WTx:
			// BIP339: wtxid-relay peers announce txs as MSG_WTX (5) with the
			// wtxid, and Core only serves WTx getdata by wtxid. Before this
			// case existed, every modern peer's tx announcements fell through
			// the #partial switch — the mempool stayed empty at the tip.
			if cm.sync_mgr.state == .In_Sync && cm.mp != nil {
				if !mempool.mempool_has_wtxid(cm.mp, iv.hash) {
					append(&wanted, wire.Inv_Vector{type = .WTx, hash = iv.hash})
				}
			}
		case .Tx:
			// Legacy announcement by txid; request witness serialization.
			if cm.sync_mgr.state == .In_Sync && cm.mp != nil {
				if !mempool.mempool_has(cm.mp, iv.hash) {
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
	zmqpkg.notify_tx(cm.zmq, txid, payload)

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
		case .Tx, .Witness_Tx, .WTx:
			if cm.mp == nil {
				continue
			}
			// .Tx/.Witness_Tx look up by txid; .WTx (BIP339) by wtxid.
			entry: ^mempool.Mempool_Entry
			mp_found: bool
			if iv.type == .WTx {
				entry, mp_found = mempool.mempool_get_by_wtxid(cm.mp, iv.hash)
			} else {
				entry, mp_found = mempool.mempool_get(cm.mp, iv.hash)
				if !mp_found && iv.type == .Witness_Tx {
					entry, mp_found = mempool.mempool_get_by_wtxid(cm.mp, iv.hash)
				}
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
			// -maxuploadtarget: once the 24h budget is spent, stop serving
			// week-old blocks to inbound peers (tip relay stays unaffected).
			if peer.inbound && cm.max_upload_target > 0 {
				now := time.to_unix_seconds(time.now())
				if upload_target_reached(cm, now) && i64(idx_entry.timestamp) < now - HISTORICAL_BLOCK_SECS {
					log.debugf("Upload target reached — refusing historical block to peer %d", peer_id)
					continue
				}
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

// Serve an inbound getheaders (Bitcoin Core semantics): find the fork point
// from the block locator, then send up to 2000 active-chain headers starting
// at its child, ending early at hash_stop. An empty locator is a single-
// header request for hash_stop itself. Always replies — an empty headers
// message tells the peer (e.g. electrs, Core) it is already at our tip.
MAX_HEADERS_RESULTS :: 2000

_conn_manager_handle_getheaders :: proc(cm: ^Conn_Manager, peer_id: Peer_Id, payload: []byte) {
	r := wire.reader_init(payload)
	msg, err := wire.deserialize_getheaders(&r, context.temp_allocator)
	if err != nil {
		return
	}

	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	headers := make([dynamic]wire.Block_Header, 0, 128, context.temp_allocator)

	if len(msg.block_hashes) == 0 {
		if entry, known := cm.chain.block_index.entries[msg.hash_stop]; known {
			if hdr, ok := _read_header_from_disk(cm, entry); ok {
				append(&headers, hdr)
			}
		}
	} else {
		// First locator hash that lies on our active chain wins; serving
		// starts at its child. No match = serve from just after genesis.
		start := 1
		for lh in msg.block_hashes {
			entry, known := cm.chain.block_index.entries[lh]
			if !known {
				continue
			}
			h := entry.height
			if h < len(cm.chain.active_chain) && cm.chain.active_chain[h] == lh {
				start = h + 1
				break
			}
		}
		for h := start; h < len(cm.chain.active_chain) && len(headers) < MAX_HEADERS_RESULTS; h += 1 {
			entry, known := cm.chain.block_index.entries[cm.chain.active_chain[h]]
			if !known {
				break
			}
			hdr, ok := _read_header_from_disk(cm, entry)
			if !ok {
				break // pruned or header-only tail — stop cleanly
			}
			append(&headers, hdr)
			if entry.hash == msg.hash_stop {
				break
			}
		}
	}

	peer_send_block_headers(peer, headers[:])
}

// Read just the 80-byte header of a stored block from the flat files (the
// block index doesn't carry the merkle root, so headers can't be rebuilt
// from index fields alone).
_read_header_from_disk :: proc(cm: ^Conn_Manager, entry: ^chain.Block_Index_Entry) -> (hdr: wire.Block_Header, ok: bool) {
	if .Has_Data not_in entry.status || entry.data_size < 80 {
		return {}, false
	}
	loc := storage.Block_Location{
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = 80,
	}
	raw, rerr := storage.block_db_read_raw(&cm.chain.block_db, loc, context.temp_allocator)
	if rerr != .None {
		return {}, false
	}
	hr := wire.reader_init(raw)
	h, derr := wire.deserialize_block_header(&hr)
	if derr != nil {
		return {}, false
	}
	return h, true
}

// BIP35: handle mempool message — reply with inv of all mempool txids.
// Gated by peer_bloom_filters (BIP111) — ignored if NODE_BLOOM is not advertised.
_conn_manager_handle_mempool :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	if !cm.peer_bloom_filters {
		log.debugf("Peer %d sent mempool but bloom filters disabled, ignoring", peer_id)
		return
	}

	peer, found := cm.peers[peer_id]
	if !found || peer.state != .Active {
		return
	}

	if cm.mp == nil {
		return
	}

	MAX_INV_SZ :: 50000
	mp_count := mempool.mempool_count(cm.mp)
	if mp_count == 0 {
		return
	}
	count := min(mp_count, MAX_INV_SZ)

	inv := make([]wire.Inv_Vector, count, context.temp_allocator)
	idx := 0
	for txid, entry in cm.mp.entries {
		if idx >= count {
			break
		}
		// BIP133: filter by peer's feefilter.
		if peer.fee_filter > 0 {
			rate := mempool.fee_rate_per_kvb(entry.fee_rate)
			if rate < peer.fee_filter {
				continue
			}
		}
		// BIP339: announce by wtxid (MSG_WTX) if peer negotiated wtxid relay.
		if peer.wtxid_relay && peer.wtxid_relay_us {
			inv[idx] = wire.Inv_Vector{type = .WTx, hash = entry.wtxid}
		} else {
			inv[idx] = wire.Inv_Vector{type = .Tx, hash = txid}
		}
		idx += 1
	}

	if idx > 0 {
		inv_msg := wire.Inv_Message{inventory = inv[:idx]}
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_inv(&w, &inv_msg)
		peer_send_message(peer, wire.CMD_INV, wire.writer_bytes(&w))
		log.debugf("BIP35: sent %d mempool inv entries to peer %d", idx, peer_id)
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
		// Never announce txs on block-relay-only connections.
		if peer.conn_type == .Block_Relay || peer.conn_type == .Feeler {
			continue
		}

		// BIP133: skip peers whose feefilter exceeds the tx's fee rate.
		if peer.fee_filter > 0 && fee_rate_kvb > 0 && peer.fee_filter > fee_rate_kvb {
			continue
		}

		// BIP339: announce with MSG_WTX + wtxid when both sides negotiated
		// wtxid relay, else legacy MSG_TX + txid. (MSG_WITNESS_TX is a
		// getdata-only type — peers ignore it inside inv messages.)
		inv: [1]wire.Inv_Vector
		if peer.wtxid_relay && peer.wtxid_relay_us {
			inv[0] = wire.Inv_Vector{type = .WTx, hash = wtxid}
		} else {
			inv[0] = wire.Inv_Vector{type = .Tx, hash = txid}
		}
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
	sync.mutex_lock(&cm.event_loop_mu)
	if cm.event_loop != nil {
		nbio.wake_up(cm.event_loop)
	}
	sync.mutex_unlock(&cm.event_loop_mu)
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
	log.debugf("V2 handshake failed for peer %d (%s), reconnecting with v1", peer.id, addr)

	// Mark address as v2-failed so reconnect uses v1.
	cm.v2_failed_addrs[strings.clone(peer.address)] = true

	// Disconnect this peer.
	sync_handle_disconnect(&cm.sync_mgr, peer.id, &cm.peers)
	conn_manager_remove_peer(cm, peer.id)

	// Reconnect to same address with v1, preserving the connection type
	// (a block-relay anchor must not silently become full-relay).
	conn_manager_add_peer(cm, addr, port, peer.conn_type)
	delete(addr)
}

// Try to connect a replacement peer when a slot opens.
_conn_manager_replace_peer :: proc(cm: ^Conn_Manager) {
	if _count_outbound_peers(cm) >= cm.max_outbound {
		return
	}

	// Try addresses from the addr manager, skipping recently-evicted ones.
	for attempt in 0 ..< 8 {
		addr_str, port, ok := addr_manager_get_connectable(&cm.addr_mgr)
		if !ok {
			break
		}
		if _addr_is_useless(cm, addr_str) || _conn_manager_already_connected(cm, addr_str) {
			delete(addr_str)
			continue
		}
		err := conn_manager_add_peer(cm, addr_str, port)
		if err == .None {
			log.debugf("Replacement peer connecting: %s:%d", addr_str, port)
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

		// TODO(BIP158): the served filter_data should be CompactSize(N) ||
		// GCS-bytes, but gcs_build_filter emits only the GCS bytes (N is not
		// stored per block). We send the raw stored filter; a strict BIP157
		// client would miscount. Store N alongside the filter to fix.
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
		// BIP157 filter_hashes carry the filter *hash* (sha256d of the filter
		// bytes), not the stored filter header — so read the filter directly
		// (the prior filter_db_get_header lookup here was wasted I/O).
		filter_data, ff := storage.filter_db_get_filter(cm.chain.filter_db, block_hash, context.temp_allocator)
		if ff && len(filter_data) > 0 {
			filter_hashes[i] = crypto.sha256d(filter_data)
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

// --- Node status snapshot (GUI support) ---

_copy_status_str :: proc(dst: []byte, s: string) -> int {
	n := min(len(dst), len(s))
	copy(dst[:n], s[:n])
	return n
}

// Populate cm.status from live node state. P2P thread only (owns all state read here).
_update_node_status :: proc(cm: ^Conn_Manager, now: i64) {
	st: Node_Status

	tip_hash, tip_height := chain.chain_tip(cm.chain)
	st.chain_height = tip_height
	st.tip_hash = tip_hash
	st.best_header = cm.sync_mgr.best_header_height

	st.sync_state = cm.sync_mgr.state
	st.blocks_remaining = max(cm.sync_mgr.best_header_height - tip_height, 0)

	// Verification progress + ETA, measured in transactions (block counts
	// misestimate remaining work by ~40x across chain eras).
	st.verification_pct = chain.verification_progress(cm.chain, now)
	tip_tx := chain.chain_tx_at_tip(cm.chain)
	cm.txput_ring[cm.txput_idx] = {tip_tx, tip_height, now}
	cm.txput_idx = (cm.txput_idx + 1) % len(cm.txput_ring)
	if cm.txput_count < len(cm.txput_ring) { cm.txput_count += 1 }
	if st.sync_state != .In_Sync && cm.txput_count > 10 {
		oldest := cm.txput_ring[(cm.txput_idx + len(cm.txput_ring) - cm.txput_count) % len(cm.txput_ring)]
		dt := now - oldest.t
		dtx := tip_tx - oldest.chain_tx
		// Wall-clock block throughput over the same window (includes download +
		// idle time, so it's the actual sync speed — distinct from the profile's
		// pure processing ms/block).
		if dblk := tip_height - oldest.height; dt > 0 && dblk > 0 {
			st.blocks_per_sec = f64(dblk) / f64(dt)
		}
		if dt > 0 && dtx > 0 {
			rate := f64(dtx) / f64(dt) // txs/sec
			// Remaining transactions. When the anchor underestimates the chain
			// (spam-heavy signet/testnet), the naive delta goes negative — fall
			// back to average txs/block over the blocks still to download.
			remaining := chain.estimated_total_chain_tx(cm.params, now) - f64(tip_tx)
			if remaining <= 0 && tip_height > 0 {
				remaining = f64(st.blocks_remaining) * (f64(tip_tx) / f64(tip_height))
			}
			if remaining > 0 && rate > 1 {
				st.eta_secs = i64(remaining / rate)
			}
		}
	}

	st.uptime_secs = now - cm.started_at

	// Peers
	i := 0
	for id, peer in cm.peers {
		if i >= STATUS_MAX_PEERS { break }
		ps := &st.peers[i]
		ps.id = id
		ps.addr_len = _copy_status_str(ps.address[:], peer.address)
		ps.agent_len = _copy_status_str(ps.user_agent[:], peer.user_agent)
		ps.state = peer.state
		ps.inbound = peer.inbound
		ps.start_height = peer.start_height
		ps.bytes_sent = peer.bytes_sent
		ps.bytes_recv = peer.bytes_recv
		if peer.last_recv > 0 {
			ps.last_recv_secs = now - peer.last_recv
		}
		if sync_ps, ok := cm.sync_mgr.peer_sync[id]; ok {
			ps.blocks_delivered = sync_ps.blocks_delivered
			ps.blocks_in_flight = sync_ps.blocks_in_flight
			st.blocks_in_flight += sync_ps.blocks_in_flight
			elapsed := now - sync_ps.tracking_since
			if elapsed > 0 {
				ps.throughput = f64(sync_ps.blocks_delivered) / f64(elapsed)
			}
		}
		i += 1
	}
	st.peer_count = i

	// Mempool
	if cm.mp != nil {
		st.mempool_count = len(cm.mp.entries)
		st.mempool_vbytes = cm.mp.usage
	}

	// Disk usage: a few thousand stat calls — refresh once a minute.
	if now - cm.disk_check_at >= 60 {
		cm.disk_usage = chain.disk_usage(cm.chain)
		cm.disk_check_at = now
	}
	st.disk_usage = cm.disk_usage
	st.total_bytes_sent = cm.total_bytes_sent
	st.total_bytes_recv = cm.total_bytes_recv

	// UTXO cache
	st.utxo_cache_count = len(cm.chain.coins.cache)
	st.utxo_cache_bytes = cm.chain.coins.mem_usage
	st.utxo_cache_budget = cm.chain.coins.budget

	// Profile window (cumulative counters since the last 1000-block log). The
	// window resets to 0 every 1000 blocks; hold the last completed window when
	// it's momentarily empty so the panel doesn't blank mid-sync.
	prof := cm.chain.prof
	if prof.blocks > 0 {
		total_ms := f64(time.duration_milliseconds(prof.t_total))
		st.prof_blocks = prof.blocks
		st.prof_ms_per_block = total_ms / f64(prof.blocks)
		if total_ms > 0 {
			st.prof_read_pct = 100 * f64(time.duration_milliseconds(prof.t_read)) / total_ms
			st.prof_prefetch_pct = 100 * f64(time.duration_milliseconds(prof.t_prefetch)) / total_ms
			st.prof_valid_pct = 100 * f64(time.duration_milliseconds(prof.t_txid)) / total_ms
			st.prof_utxo_pct = 100 * f64(time.duration_milliseconds(prof.t_utxo)) / total_ms
			st.prof_scripts_pct = 100 * f64(time.duration_milliseconds(prof.t_scripts)) / total_ms
			st.prof_undo_pct = 100 * f64(time.duration_milliseconds(prof.t_undo)) / total_ms
		}
		cm.last_prof = {
			st.prof_blocks, st.prof_ms_per_block, st.prof_read_pct, st.prof_prefetch_pct,
			st.prof_valid_pct, st.prof_utxo_pct, st.prof_scripts_pct, st.prof_undo_pct,
		}
	} else if cm.last_prof.blocks > 0 {
		st.prof_blocks = cm.last_prof.blocks
		st.prof_ms_per_block = cm.last_prof.ms_per_block
		st.prof_read_pct = cm.last_prof.read
		st.prof_prefetch_pct = cm.last_prof.prefetch
		st.prof_valid_pct = cm.last_prof.valid
		st.prof_utxo_pct = cm.last_prof.utxo
		st.prof_scripts_pct = cm.last_prof.scripts
		st.prof_undo_pct = cm.last_prof.undo
	}

	sync.mutex_lock(&cm.status_mutex)
	cm.status = st
	sync.mutex_unlock(&cm.status_mutex)
}

// Thread-safe snapshot read for the GUI thread. Returns a value copy.
conn_manager_get_status :: proc(cm: ^Conn_Manager) -> Node_Status {
	sync.mutex_lock(&cm.status_mutex)
	st := cm.status
	sync.mutex_unlock(&cm.status_mutex)
	// Injected at read time: during a flush the P2P thread is blocked and the
	// snapshot freezes — these fields keep the GUI honest about why.
	st.halt_height = cm.chain.halt_height
	if cm.chain.halt_height > 0 {
		reason := fmt.tprintf("%v", cm.chain.halt_error)
		n := copy(st.halt_reason[:], reason)
		st.halt_reason_len = n
	}
	st.flushing = cm.chain.coins.flushing
	st.flush_total = cm.chain.coins.flush_total
	st.flush_progress = cm.chain.coins.flush_progress
	return st
}

// --- Useless-address cooldown (evicted crawlers/stale peers) ---

USELESS_ADDR_COOLDOWN_SECS :: 4 * 3600

_mark_addr_useless :: proc(cm: ^Conn_Manager, address: string) {
	if address in cm.useless_addrs {
		cm.useless_addrs[address] = time.to_unix_seconds(time.now())
		return
	}
	cm.useless_addrs[strings.clone(address)] = time.to_unix_seconds(time.now())
}

_addr_is_useless :: proc(cm: ^Conn_Manager, address: string) -> bool {
	evicted_at, found := cm.useless_addrs[address]
	if !found {
		return false
	}
	if time.to_unix_seconds(time.now()) - evicted_at > USELESS_ADDR_COOLDOWN_SECS {
		// Cooldown expired — forget and allow a retry.
		key, _ := delete_key(&cm.useless_addrs, address)
		delete(key)
		return false
	}
	return true
}
