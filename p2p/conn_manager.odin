package p2p

import "core:fmt"
import "core:log"
import "core:mem"
import tcp "core:net"
import "core:sync/chan"
import "core:time"

import "../chain"
import "../consensus"
import "../mempool"
import "../wire"

Conn_Manager :: struct {
	peers:          map[Peer_Id]^Peer,
	msg_chan:        chan.Chan(Peer_Message),
	sync_mgr:       Sync_Manager,
	chain:          ^chain.Chain_State,
	params:         ^consensus.Chain_Params,
	mp:             ^mempool.Mempool,
	next_peer_id:   Peer_Id,
	network_magic:  u32,
	default_port:   int,
	shutdown:        bool,
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
	case wire.SIGNET_MAGIC:   cm.default_port = DEFAULT_PORT_SIGNET
	case wire.REGTEST_MAGIC:  cm.default_port = DEFAULT_PORT_REGTEST
	case:                     cm.default_port = DEFAULT_PORT_MAINNET
	}

	cm.peers = make(map[Peer_Id]^Peer, MAX_OUTBOUND_PEERS * 2)

	// Create buffered channel for peer messages.
	ch, ch_err := chan.create(chan.Chan(Peer_Message), 4096, context.allocator)
	if ch_err != nil {
		return .Connection_Failed
	}
	cm.msg_chan = ch

	sync_manager_init(&cm.sync_mgr, cs, params, mp)

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
			addr_str := fmt.tprintf("%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3])
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
	last_header_refresh: i64 = time.to_unix_seconds(time.now())

	// Main message loop.
	for !cm.shutdown {
		// Free temp allocations from previous iteration (block deserialization,
		// inv messages, etc.) to prevent unbounded memory growth during IBD.
		free_all(context.temp_allocator)

		// Use non-blocking recv when there are pending blocks to connect,
		// so the loop keeps making progress instead of stalling on the channel.
		has_pending := _has_pending_blocks(cm)
		msg: Peer_Message
		got_msg: bool

		if has_pending {
			msg, got_msg = chan.try_recv(cm.msg_chan)
		} else {
			msg, got_msg = chan.recv(cm.msg_chan)
			if !got_msg {
				break // Channel closed.
			}
		}

		if got_msg {
			_conn_manager_process_message(cm, msg)

			// Free payload after processing.
			if msg.payload != nil {
				delete(msg.payload)
			}
		}

		// Check for stalled block/header requests.
		sync_check_stalls(&cm.sync_mgr, &cm.peers)

		// Connect any pending stored blocks (recovery catch-up).
		// During normal operation this is a no-op. After crash recovery,
		// thousands of stored blocks need connecting.
		_conn_manager_connect_pending(cm)

		now := time.to_unix_seconds(time.now())

		// Periodic getheaders while in sync — safety net for missed BIP130 announcements.
		// Bitcoin Core does this every ~15 minutes; we do it every 2 minutes since we
		// have fewer peers and signet block times are ~10 minutes.
		if now - last_header_refresh >= HEADER_REFRESH_SECS && cm.sync_mgr.state == .In_Sync {
			last_header_refresh = now
			locator := build_block_locator(cm.sync_mgr.chain)
			// Send to first active peer we find.
			for _, peer in cm.peers {
				if peer.state == .Active {
					peer_send_getheaders(peer, locator, HASH_ZERO)
					break
				}
			}
			delete(locator)
		}

		// Periodic ping check.
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
	case wire.CMD_TX:
		_conn_manager_handle_tx(cm, msg.peer_id, msg.payload)
	case wire.CMD_GETDATA:
		_conn_manager_handle_getdata(cm, msg.peer_id, msg.payload)
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

		// Register peer for sync tracking.
		sync_add_peer(&cm.sync_mgr, peer_id)

		switch cm.sync_mgr.state {
		case .Idle:
			sync_start_header_sync(&cm.sync_mgr, &cm.peers)
		case .Syncing_Headers:
			// Add late-joining peer to the header race if no lead has been selected yet.
			if cm.sync_mgr.header_lead_peer == 0 {
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
	// This handles multi-block gaps (e.g., node was offline) where the peer
	// doesn't support sendheaders or we missed the headers announcement.
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

	r := wire.reader_init(payload)
	tx, err := wire.deserialize_tx(&r, context.temp_allocator)
	if err != nil {
		log.debugf("Bad tx from peer %d", peer_id)
		return
	}

	txid := wire.tx_id(&tx)
	mp_err := mempool.mempool_add(cm.mp, &tx)
	if mp_err != .None {
		log.debugf("Rejected tx %s from peer %d: %v", _hash_to_hex_short(txid), peer_id, mp_err)
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

// Exported relay for RPC thread (no sender to exclude).
conn_manager_relay_tx :: proc(cm: ^Conn_Manager, txid: Hash256) {
	_conn_manager_relay_tx(cm, txid, Peer_Id(0))
}

// Check if there are stored blocks awaiting connection.
_has_pending_blocks :: proc(cm: ^Conn_Manager) -> bool {
	_, tip_height := chain.chain_tip(cm.chain)
	return tip_height < cm.sync_mgr.best_header_height
}

// Connect stored-but-not-connected blocks (recovery catch-up).
// After crash recovery, thousands of blocks may be on disk awaiting connection.
// This drains the backlog without waiting for new block arrivals from peers.
_conn_manager_connect_pending :: proc(cm: ^Conn_Manager) {
	_, tip_height := chain.chain_tip(cm.chain)
	best_header := cm.sync_mgr.best_header_height
	if tip_height >= best_header {
		return
	}

	prev_height := tip_height
	connected, cerr := chain.connect_pending_blocks(cm.chain)
	if connected > 0 {
		_, new_height := chain.chain_tip(cm.chain)
		cm.sync_mgr.last_tip_update = time.to_unix_seconds(time.now())

		// Periodic UTXO flush during catch-up.
		if new_height / 1000 > prev_height / 1000 {
			tip_hash, tip_h := chain.chain_tip(cm.chain)
			chain.coins_cache_flush(&cm.chain.coins, tip_hash, tip_h)
		}

		if new_height / 1000 > prev_height / 1000 || new_height >= best_header {
			log.infof("Recovery catch-up: height %d / %d", new_height, best_header)
		}
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
