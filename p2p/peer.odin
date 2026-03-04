package p2p

import "core:log"
import "core:nbio"
import tcp "core:net"
import "core:strings"
import "core:time"

import "../consensus"
import "../wire"

Peer :: struct {
	id:             Peer_Id,
	socket:         tcp.TCP_Socket,
	address:        string,
	state:          Peer_State,
	version:        i32,
	services:       u64,
	user_agent:     string,
	start_height:   i32,
	send_headers:   bool,
	last_ping:      i64, // unix timestamp
	last_pong:      i64,
	ping_nonce:     u64,
	network_magic:  u32,
	recv_buf:       [dynamic]byte,
	connected_at:   i64,   // unix timestamp when connection established
	last_send:      i64,   // unix timestamp of last message sent
	last_recv:      i64,   // unix timestamp of last message received
	bytes_sent:     i64,   // total bytes sent
	bytes_recv:     i64,   // total bytes received
	// BIP133 feefilter
	fee_filter:       i64,  // peer's min fee rate (sat/kvB), 0 = no filter
	// BIP339 wtxid relay
	wtxid_relay:      bool, // peer sent us wtxidrelay
	wtxid_relay_us:   bool, // we sent wtxidrelay to peer
	// BIP152 compact block support
	compact_version:  u64,  // 0 = not negotiated, 2 = v2
	compact_announce: bool, // peer will send us cmpctblock proactively
	send_compact:     bool, // we've sent sendcmpct to this peer
	// nbio fields
	read_buf:       [65536]byte,  // fixed buffer for async recv
	send_queue:     [dynamic][]byte, // queued outbound messages (owned bytes)
	sending:        bool,  // whether an async send is in-flight
	sending_msg:    []byte, // the message currently being sent (for freeing in callback)
	cm:             ^Conn_Manager, // back-reference for callbacks
}

// Start an async connect to a peer. Allocates Peer, adds to cm.peers, kicks off nbio.dial_poly.
peer_start_connect :: proc(cm: ^Conn_Manager, address: string, port: int, peer_id: Peer_Id) {
	// Resolve address to endpoint (DNS is blocking — happens once at startup, acceptable).
	ip4, ip4_ok := tcp.parse_ip4_address(address)
	if !ip4_ok {
		log.debugf("Failed to parse address: %s", address)
		return
	}
	endpoint := tcp.Endpoint{address = ip4, port = port}

	peer := new(Peer)
	peer.id = peer_id
	peer.address = strings.clone(address)
	peer.state = .Connecting
	peer.network_magic = cm.network_magic
	peer.cm = cm
	peer.recv_buf = make([dynamic]byte, 0, 8192)
	peer.send_queue = make([dynamic][]byte, 0, 16)
	peer.connected_at = time.to_unix_seconds(time.now())

	// Add peer to map immediately so we can track it.
	cm.peers[peer_id] = peer

	// Kick off async dial.
	nbio.dial_poly(endpoint, peer, _on_connect, timeout = 5 * time.Second)
}

// Callback when async dial completes.
_on_connect :: proc(op: ^nbio.Operation, peer: ^Peer) {
	if op.dial.err != nil {
		log.debugf("Connection to %s failed: %v", peer.address, op.dial.err)
		// Remove from peers map and clean up.
		delete_key(&peer.cm.peers, peer.id)
		_peer_free(peer)
		return
	}

	peer.socket = op.dial.socket
	peer.state = .Connecting
	peer.connected_at = time.to_unix_seconds(time.now())

	// Associate the socket with the event loop.
	assoc_err := nbio.associate_socket(peer.socket)
	if assoc_err != .None {
		log.debugf("Failed to associate socket for peer %d: %v", peer.id, assoc_err)
		delete_key(&peer.cm.peers, peer.id)
		tcp.close(peer.socket)
		_peer_free(peer)
		return
	}

	log.infof("Connected to %s (peer %d)", peer.address, peer.id)

	// Send version message and start recv — delegated to conn_manager.
	_conn_manager_peer_connected(peer.cm, peer)
}

// Post one async recv on the peer's read_buf.
_peer_start_recv :: proc(peer: ^Peer) {
	if peer.state == .Disconnected {
		return
	}
	bufs := [1][]byte{peer.read_buf[:]}
	nbio.recv_poly(peer.socket, bufs[:], peer, _on_recv, timeout = 120 * time.Second)
}

// Callback when async recv completes.
_on_recv :: proc(op: ^nbio.Operation, peer: ^Peer) {
	if peer.state == .Disconnected {
		return
	}

	// Check for error/EOF.
	if op.recv.err != nil || op.recv.received == 0 {
		_peer_handle_disconnect(peer)
		return
	}

	peer.bytes_recv += i64(op.recv.received)
	peer.last_recv = time.to_unix_seconds(time.now())

	// Accumulate into recv_buf.
	append(&peer.recv_buf, ..peer.read_buf[:op.recv.received])

	// Parse and dispatch complete messages.
	_peer_process_messages(peer)

	// Re-arm recv.
	_peer_start_recv(peer)
}

// Parse complete messages from recv_buf and dispatch inline.
_peer_process_messages :: proc(peer: ^Peer) {
	cm := peer.cm

	for {
		if len(peer.recv_buf) < wire.MESSAGE_HEADER_SIZE {
			break
		}

		// Peek at header to get payload size.
		r := wire.reader_init(peer.recv_buf[:])
		hdr, hdr_err := wire.deserialize_message_header(&r)
		if hdr_err != .None {
			_peer_handle_disconnect(peer)
			return
		}

		// Validate magic.
		if hdr.magic != peer.network_magic {
			_peer_handle_disconnect(peer)
			return
		}

		// Check payload size limit.
		if hdr.payload_size > wire.MAX_MESSAGE_PAYLOAD {
			_peer_handle_disconnect(peer)
			return
		}

		total_size := wire.MESSAGE_HEADER_SIZE + int(hdr.payload_size)
		if len(peer.recv_buf) < total_size {
			break // Need more data.
		}

		// Extract payload and validate checksum.
		payload_start := wire.MESSAGE_HEADER_SIZE
		payload_data := peer.recv_buf[payload_start:total_size]

		if !wire.validate_checksum(&hdr, payload_data) {
			_peer_handle_disconnect(peer)
			return
		}

		cmd := wire.command_from_bytes(hdr.command)

		// Dispatch inline — payload is a slice into recv_buf, valid for duration of dispatch.
		_conn_manager_dispatch(cm, peer.id, cmd, payload_data)

		// Free temp allocations from this message (block deserialization, etc.)
		free_all(context.temp_allocator)

		// Consume processed bytes from recv_buf.
		remaining := len(peer.recv_buf) - total_size
		if remaining > 0 {
			copy(peer.recv_buf[:remaining], peer.recv_buf[total_size:])
		}
		resize(&peer.recv_buf, remaining)

		// If peer was disconnected during dispatch, stop processing.
		if peer.state == .Disconnected {
			return
		}
	}
}

// Handle peer disconnect — notify conn_manager inline.
_peer_handle_disconnect :: proc(peer: ^Peer) {
	if peer.state == .Disconnected {
		return
	}
	log.infof("Peer %d disconnected", peer.id)
	cm := peer.cm
	sync_handle_disconnect(&cm.sync_mgr, peer.id, &cm.peers)
	conn_manager_remove_peer(cm, peer.id)
}

// Send a framed message to the peer. Queues for async send.
peer_send_message :: proc(peer: ^Peer, command: string, payload: []byte) -> Net_Error {
	if peer.state == .Disconnected {
		return .Send_Failed
	}

	msg := wire.build_message(peer.network_magic, command, payload)
	// msg is owned []byte — append to send queue.
	append(&peer.send_queue, msg)

	// If not currently sending, start flushing.
	if !peer.sending {
		_peer_flush_send_queue(peer)
	}
	return .None
}

// Start sending the next message in the queue.
_peer_flush_send_queue :: proc(peer: ^Peer) {
	if len(peer.send_queue) == 0 {
		peer.sending = false
		return
	}

	// Pop front message.
	msg := peer.send_queue[0]
	ordered_remove(&peer.send_queue, 0)

	peer.sending = true
	peer.sending_msg = msg
	bufs := [1][]byte{msg}
	nbio.send_poly(peer.socket, bufs[:], peer, _on_send, all = true, timeout = 30 * time.Second)
}

// Callback when async send completes.
_on_send :: proc(op: ^nbio.Operation, peer: ^Peer) {
	// If peer was destroyed, sending_msg was already freed — bail out.
	if peer.state == .Disconnected {
		return
	}

	// Free the sent message buffer.
	if peer.sending_msg != nil {
		delete(peer.sending_msg)
		peer.sending_msg = nil
	}

	if op.send.err != nil {
		_peer_handle_disconnect(peer)
		return
	}

	peer.bytes_sent += i64(op.send.sent)
	peer.last_send = time.to_unix_seconds(time.now())

	// Send next queued message.
	_peer_flush_send_queue(peer)
}

// Mark peer as disconnected and close socket. Frees send resources but does NOT
// free the peer struct — caller must add to zombie list (or call _peer_free for shutdown).
// This prevents use-after-free when nbio callbacks still hold a ^Peer pointer.
peer_destroy :: proc(peer: ^Peer) {
	if peer == nil {
		return
	}
	peer.state = .Disconnected
	tcp.close(peer.socket)

	// Free any unsent messages in the queue.
	for msg in peer.send_queue {
		delete(msg)
	}
	delete(peer.send_queue)

	// Free the in-flight send message (callback won't fire after socket close).
	if peer.sending_msg != nil {
		delete(peer.sending_msg)
		peer.sending_msg = nil
	}
}

// Free peer memory (without closing socket — used by both destroy and failed connect).
_peer_free :: proc(peer: ^Peer) {
	delete(peer.recv_buf)
	if len(peer.address) > 0 {
		delete(peer.address)
	}
	if len(peer.user_agent) > 0 {
		delete(peer.user_agent)
	}
	free(peer)
}

// Build and send a version message.
peer_send_version :: proc(peer: ^Peer, params: ^consensus.Chain_Params, chain_height: int) -> Net_Error {
	now := time.now()
	timestamp := time.to_unix_seconds(now)

	ver := wire.Version_Message {
		version      = i32(wire.PROTOCOL_VERSION),
		services     = LOCAL_SERVICES,
		timestamp    = timestamp,
		addr_recv    = wire.Net_Address{services = 0},
		addr_from    = wire.Net_Address{services = LOCAL_SERVICES},
		nonce        = u64(timestamp) ~ u64(peer.id), // simple nonce
		user_agent   = wire.NODE_USER_AGENT,
		start_height = i32(chain_height),
		relay        = true,
	}

	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_version(&w, &ver)

	return peer_send_message(peer, wire.CMD_VERSION, wire.writer_bytes(&w))
}

// Send verack (empty payload).
peer_send_verack :: proc(peer: ^Peer) -> Net_Error {
	return peer_send_message(peer, wire.CMD_VERACK, nil)
}

// Send ping with random nonce.
peer_send_ping :: proc(peer: ^Peer) -> Net_Error {
	now := time.now()
	peer.ping_nonce = u64(time.to_unix_seconds(now)) ~ u64(peer.id) ~ 0xDEADBEEF
	peer.last_ping = time.to_unix_seconds(now)

	ping := wire.Ping_Message{nonce = peer.ping_nonce}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_ping(&w, &ping)

	return peer_send_message(peer, wire.CMD_PING, wire.writer_bytes(&w))
}

// Send pong with given nonce.
peer_send_pong :: proc(peer: ^Peer, nonce: u64) -> Net_Error {
	pong := wire.Pong_Message{nonce = nonce}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_pong(&w, &pong)

	return peer_send_message(peer, wire.CMD_PONG, wire.writer_bytes(&w))
}

// Send getheaders with block locator.
peer_send_getheaders :: proc(peer: ^Peer, locator_hashes: []Hash256, hash_stop: Hash256) -> Net_Error {
	msg := wire.Get_Headers_Message {
		version      = u32(wire.PROTOCOL_VERSION),
		block_hashes = locator_hashes,
		hash_stop    = hash_stop,
	}

	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_getheaders(&w, &msg)

	return peer_send_message(peer, wire.CMD_GETHEADERS, wire.writer_bytes(&w))
}

// Send getdata for a list of inventory vectors.
peer_send_getdata :: proc(peer: ^Peer, inventory: []wire.Inv_Vector) -> Net_Error {
	msg := wire.Get_Data_Message{inventory = inventory}

	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_getdata(&w, &msg)

	return peer_send_message(peer, wire.CMD_GETDATA, wire.writer_bytes(&w))
}

// Send sendheaders (BIP130, empty payload).
peer_send_sendheaders :: proc(peer: ^Peer) -> Net_Error {
	return peer_send_message(peer, wire.CMD_SENDHEADERS, nil)
}

// Send sendcmpct (BIP152).
peer_send_sendcmpct :: proc(peer: ^Peer, announce: bool, version: u64) -> Net_Error {
	msg := wire.Send_Compact_Message{announce = announce, version = version}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_sendcmpct(&w, &msg)
	peer.send_compact = true
	return peer_send_message(peer, wire.CMD_SENDCMPCT, wire.writer_bytes(&w))
}

// Send getblocktxn (BIP152) to request missing transactions.
peer_send_getblocktxn :: proc(peer: ^Peer, block_hash: Hash256, indices: []u64) -> Net_Error {
	msg := wire.Get_Block_Txn_Message{block_hash = block_hash, indices = indices}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_get_block_txn(&w, &msg)
	return peer_send_message(peer, wire.CMD_GETBLOCKTXN, wire.writer_bytes(&w))
}

// Send feefilter (BIP133) with our minimum fee rate.
peer_send_feefilter :: proc(peer: ^Peer, feerate: i64) -> Net_Error {
	msg := wire.Fee_Filter_Message{feerate = feerate}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_feefilter(&w, &msg)
	return peer_send_message(peer, wire.CMD_FEEFILTER, wire.writer_bytes(&w))
}

// Send wtxidrelay (BIP339, empty payload). Must be sent between version and verack.
peer_send_wtxidrelay :: proc(peer: ^Peer) -> Net_Error {
	return peer_send_message(peer, wire.CMD_WTXIDRELAY, nil)
}
