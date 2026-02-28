package p2p

import "core:fmt"
import "core:log"
import "core:mem"
import tcp "core:net"
import "core:sync/chan"
import "core:time"

import "../chain"
import "../consensus"
import "../wire"

Conn_Manager :: struct {
	peers:          map[Peer_Id]^Peer,
	msg_chan:        chan.Chan(Peer_Message),
	sync_mgr:       Sync_Manager,
	chain:          ^chain.Chain_State,
	params:         ^consensus.Chain_Params,
	next_peer_id:   Peer_Id,
	network_magic:  u32,
	default_port:   int,
	shutdown:        bool,
}

conn_manager_init :: proc(cm: ^Conn_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params) -> Net_Error {
	cm.chain = cs
	cm.params = params
	cm.network_magic = params.network_magic
	cm.next_peer_id = 1
	cm.shutdown = false

	// Set default port based on network.
	switch params.network_magic {
	case wire.MAINNET_MAGIC:  cm.default_port = DEFAULT_PORT_MAINNET
	case wire.TESTNET3_MAGIC: cm.default_port = DEFAULT_PORT_TESTNET3
	case wire.SIGNET_MAGIC:   cm.default_port = DEFAULT_PORT_SIGNET
	case wire.REGTEST_MAGIC:  cm.default_port = DEFAULT_PORT_REGTEST
	case:                     cm.default_port = DEFAULT_PORT_MAINNET
	}

	cm.peers = make(map[Peer_Id]^Peer, MAX_OUTBOUND_PEERS * 2)

	// Create buffered channel for peer messages.
	ch, ch_err := chan.create(chan.Chan(Peer_Message), 256, context.allocator)
	if ch_err != nil {
		return .Connection_Failed
	}
	cm.msg_chan = ch

	sync_manager_init(&cm.sync_mgr, cs, params)

	return .None
}

conn_manager_destroy :: proc(cm: ^Conn_Manager) {
	// Disconnect all peers.
	for id, peer in cm.peers {
		peer_destroy(peer)
	}
	delete(cm.peers)

	// Drain remaining messages (channel may already be closed by shutdown).
	for {
		msg, ok := chan.try_recv(cm.msg_chan)
		if !ok {
			break
		}
		if msg.payload != nil {
			delete(msg.payload)
		}
	}

	chan.destroy(cm.msg_chan)
	sync_manager_destroy(&cm.sync_mgr)
}

// Connect to a peer, perform handshake, add to peer map.
conn_manager_add_peer :: proc(cm: ^Conn_Manager, address: string, port: int) -> Net_Error {
	if len(cm.peers) >= MAX_OUTBOUND_PEERS {
		return .Too_Many_Peers
	}

	peer_id := cm.next_peer_id
	cm.next_peer_id += 1

	peer, err := peer_connect(address, port, cm.network_magic, cm.msg_chan, peer_id)
	if err != .None {
		return err
	}

	cm.peers[peer_id] = peer
	return .None
}

// Remove and destroy a peer.
conn_manager_remove_peer :: proc(cm: ^Conn_Manager, peer_id: Peer_Id) {
	peer, found := cm.peers[peer_id]
	if !found {
		return
	}
	delete_key(&cm.peers, peer_id)
	peer_destroy(peer)
}

// Discover peers via DNS seed resolution.
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
	case wire.SIGNET_MAGIC:
		s := SIGNET_SEEDS
		seeds = s[:]
	case:
		return addresses
	}

	for seed in seeds {
		ep4, _, dns_err := tcp.resolve(seed)
		if dns_err != nil {
			continue
		}
		if ep4.address == nil {
			continue
		}

		// Format the IP address as a string.
		addr := ep4.address.(tcp.IP4_Address)
		addr_str := fmt.tprintf("%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3])
		append(&addresses, addr_str)

		if len(addresses) >= MAX_OUTBOUND_PEERS * 2 {
			break
		}
	}

	return addresses
}

// Cleanly shut down the connection manager.
conn_manager_shutdown :: proc(cm: ^Conn_Manager) {
	cm.shutdown = true
	// Close the channel to unblock the recv loop.
	chan.close(cm.msg_chan)
}

// Main event loop. Discovers peers, connects, processes messages.
conn_manager_run :: proc(cm: ^Conn_Manager) {
	context.logger = log.create_console_logger(.Debug, {.Level, .Time, .Terminal_Color})

	log.infof("Starting connection manager (network: %s)", cm.params.name)

	// Skip DNS discovery if peers were already added (e.g. via --connect).
	if len(cm.peers) == 0 {
		addresses := conn_manager_discover_peers(cm)
		defer delete(addresses)

		connected := 0
		for addr in addresses {
			if connected >= MAX_OUTBOUND_PEERS {
				break
			}
			err := conn_manager_add_peer(cm, addr, cm.default_port)
			if err == .None {
				connected += 1
				log.infof("Connected to %s:%d", addr, cm.default_port)
			}
		}

		if connected == 0 {
			log.warn("No peers available. Exiting.")
			return
		}
	} else {
		log.infof("Using %d pre-configured peer(s)", len(cm.peers))
	}

	// Send version to all connected peers.
	_, chain_height := chain.chain_tip(cm.chain)
	for _, peer in cm.peers {
		peer_send_version(peer, cm.params, chain_height)
		peer.state = .Version_Sent
	}

	last_ping_check: i64 = time.to_unix_seconds(time.now())

	// Main message loop.
	for !cm.shutdown {
		msg, ok := chan.recv(cm.msg_chan)
		if !ok {
			break // Channel closed.
		}

		_conn_manager_process_message(cm, msg)

		// Free payload after processing.
		if msg.payload != nil {
			delete(msg.payload)
		}

		// Periodic ping check.
		now := time.to_unix_seconds(time.now())
		if now - last_ping_check >= PING_INTERVAL_SECS {
			last_ping_check = now
			for _, peer in cm.peers {
				if peer.state == .Active {
					peer_send_ping(peer)
				}
			}
		}
	}

	log.info("Connection manager shutting down.")
}

// Dispatch inbound message by command.
_conn_manager_process_message :: proc(cm: ^Conn_Manager, msg: Peer_Message) {
	// Empty command = disconnect signal.
	if msg.command == "" {
		log.infof("Peer %d disconnected", msg.peer_id)
		sync_handle_disconnect(&cm.sync_mgr, msg.peer_id, &cm.peers)
		conn_manager_remove_peer(cm, msg.peer_id)
		return
	}

	switch msg.command {
	case wire.CMD_VERSION:
		_conn_manager_handle_version(cm, msg.peer_id, msg.payload)
	case wire.CMD_VERACK:
		_conn_manager_handle_verack(cm, msg.peer_id)
	case wire.CMD_HEADERS:
		_conn_manager_handle_headers(cm, msg.peer_id, msg.payload)
	case wire.CMD_BLOCK:
		_conn_manager_handle_block(cm, msg.peer_id, msg.payload)
	case wire.CMD_INV:
		_conn_manager_handle_inv(cm, msg.peer_id, msg.payload)
	case wire.CMD_PING:
		_conn_manager_handle_ping(cm, msg.peer_id, msg.payload)
	case wire.CMD_PONG:
		_conn_manager_handle_pong(cm, msg.peer_id, msg.payload)
	case wire.CMD_SENDHEADERS:
		// Peer wants headers announcements — note it.
		peer, found := cm.peers[msg.peer_id]
		if found {
			peer.send_headers = true
		}
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
	peer.user_agent = ver.user_agent
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

		// If no sync in progress, start it.
		if cm.sync_mgr.state == .Idle {
			sync_start_header_sync(&cm.sync_mgr, &cm.peers)
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

	// For now, we only care about block announcements when in sync.
	if cm.sync_mgr.state != .In_Sync {
		return
	}

	peer, found := cm.peers[peer_id]
	if !found {
		return
	}

	// Request any announced blocks we don't have.
	wanted := make([dynamic]wire.Inv_Vector, 0, len(inv_msg.inventory), context.temp_allocator)
	for iv in inv_msg.inventory {
		#partial switch iv.type {
		case .Block, .Witness_Block:
			_, known := cm.chain.block_index.entries[iv.hash]
			if !known {
				append(&wanted, wire.Inv_Vector{type = .Witness_Block, hash = iv.hash})
			}
		}
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
