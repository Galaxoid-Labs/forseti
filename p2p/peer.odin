package p2p

import "core:log"
import "core:nbio"
import tcp "core:net"
import "core:strings"
import "core:time"

import "../chain"
import "../consensus"
import "../wire"

Peer :: struct {
	id:             Peer_Id,
	socket:         tcp.TCP_Socket,
	address:        string,
	port:           int,
	inbound:        bool,
	conn_type:      Connection_Type, // topology role (full/block-relay/feeler/inbound/manual)
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
	// BIP155 addrv2
	addrv2_relay:     bool, // peer sent sendaddrv2
	addr_sent:        bool, // we sent getaddr to this peer
	// BIP152 compact block support
	compact_version:  u64,  // 0 = not negotiated, 2 = v2
	compact_announce: bool, // peer will send us cmpctblock proactively
	send_compact:     bool, // we've sent sendcmpct to this peer
	// BIP324 v2 transport (nil = v1)
	v2:             ^V2_Transport,
	v2_detect:      bool, // inbound responder: sniffing v1-vs-v2 from first bytes; nothing sent yet
	// SOCKS5 proxy handshake in progress (nil = direct / tunnel established)
	socks:          ^Socks5_State,
	// nbio fields
	read_buf:       [65536]byte,  // fixed buffer for async recv
	recv_op:        ^nbio.Operation, // pending recv operation (for cancel on destroy)
	send_op:        ^nbio.Operation, // pending send operation (for cancel on destroy)
	send_queue:     [dynamic][]byte, // queued outbound messages (owned bytes)
	sending:        bool,  // whether an async send is in-flight
	sending_msg:    []byte, // the message currently being sent (for freeing in callback)
	cm:             ^Conn_Manager, // back-reference for callbacks
}

// Start an async connect to a peer. Allocates Peer, adds to cm.peers, kicks off nbio.dial_poly.
peer_start_connect :: proc(cm: ^Conn_Manager, address: string, port: int, peer_id: Peer_Id, conn_type: Connection_Type = .Full_Relay) {
	// setnetworkactive gate + ban list (RPC-controlled).
	if !cm.network_active || conn_manager_is_banned(cm, address) {
		return
	}
	// Never open a second connection to an address we're already dialing or
	// connected to (the addr manager selects randomly and can return the
	// same address to different dial paths in one tick). Manual connections
	// bypass this — the operator asked for it explicitly.
	if conn_type != .Manual && _conn_manager_already_connected(cm, address) {
		return
	}
	// Direct: the target must be IPv4. Proxied: we dial the PROXY and hand
	// the target (IPv4 or hostname/.onion) to it during the SOCKS5 handshake.
	endpoint: tcp.Endpoint
	if cm.proxy_set {
		endpoint = cm.proxy_endpoint
	} else {
		ip4, ip4_ok := tcp.parse_ip4_address(address)
		if !ip4_ok {
			log.debugf("Failed to parse address: %s", address)
			return
		}
		endpoint = tcp.Endpoint{address = ip4, port = port}
	}

	peer := new(Peer)
	peer.id = peer_id
	peer.address = strings.clone(address)
	peer.port = port
	peer.state = .Connecting
	peer.conn_type = conn_type
	peer.network_magic = cm.network_magic
	peer.cm = cm
	peer.recv_buf = make([dynamic]byte, 0, 8192)
	peer.send_queue = make([dynamic][]byte, 0, 16)
	peer.connected_at = time.to_unix_seconds(time.now())
	if cm.proxy_set {
		peer.socks = new(Socks5_State)
		peer.socks.target_host = peer.address // peer owns the clone
		peer.socks.target_port = port
	}

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

	log.debugf("Connected to %s (peer %d)", peer.address, peer.id)

	// Proxied: run the SOCKS5 handshake first; the Bitcoin transport starts
	// when the tunnel reply arrives (see _peer_process_messages).
	if peer.socks != nil {
		_peer_socks5_start(peer)
		_peer_start_recv(peer)
		return
	}

	// Send version message and start recv — delegated to conn_manager.
	_conn_manager_peer_connected(peer.cm, peer)
}

// Post one async recv on the peer's read_buf.
_peer_start_recv :: proc(peer: ^Peer) {
	if peer.state == .Disconnected {
		return
	}
	bufs := [1][]byte{peer.read_buf[:]}
	// Inactivity timeout — Core's TIMEOUT_INTERVAL (20 min), NOT the ping
	// cadence. With timeout == PING_INTERVAL a peer that never initiates
	// traffic (electrs only ever replies) races our ping round and gets
	// dropped the moment the phases misalign.
	peer.recv_op = nbio.recv_poly(peer.socket, bufs[:], peer, _on_recv, timeout = 1200 * time.Second)
}

// Callback when async recv completes.
_on_recv :: proc(op: ^nbio.Operation, peer: ^Peer) {
	peer.recv_op = nil // Operation is completing, no longer pending.
	if peer.state == .Disconnected {
		return
	}

	// Check for error/EOF.
	if op.recv.err != nil || op.recv.received == 0 {
		// If in v2 handshake, fall back to v1 instead of just disconnecting (outbound only).
		if peer.v2 != nil && peer.state == .V2_Handshake && !peer.inbound {
			log.debugf("Peer %d: EOF during v2 handshake, falling back to v1", peer.id)
			_conn_manager_v2_fallback(peer.cm, peer)
			return
		}
		_peer_handle_disconnect(peer)
		return
	}

	peer.bytes_recv += i64(op.recv.received)
	peer.cm.total_bytes_recv += i64(op.recv.received)
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
	if peer.socks != nil {
		if !_peer_socks5_process(peer) {
			return // mid-handshake (or disconnected on failure)
		}
		// Tunnel established — start the Bitcoin transport. recv is already
		// armed by our caller's loop, so don't arm it again.
		_conn_manager_peer_connected(peer.cm, peer, arm_recv = false)
		if len(peer.recv_buf) == 0 {
			return
		}
		// (A proxy shouldn't have peer bytes for us this early, but fall
		// through and parse whatever arrived just in case.)
	}
	if peer.v2 != nil && peer.v2_detect {
		if !_peer_v2_detect(peer) {
			return // not enough bytes to decide yet
		}
	}
	if peer.v2 != nil {
		_peer_process_messages_v2(peer)
	} else {
		_peer_process_messages_v1(peer)
	}
}

// BIP324 responder transport detection. The responder must send NOTHING
// until the initiator's first bytes classify the connection: a v1 peer
// opens with `magic || "version"` (16 bytes); anything else is a v2
// initiator's ell64. Eagerly sending our ell64 (the old behavior) corrupts
// the stream for every plaintext client — Core waits, and so must we.
// Returns false while undecided (need more bytes).
_peer_v2_detect :: proc(peer: ^Peer) -> bool {
	V1_PREFIX_LEN :: 16
	prefix: [V1_PREFIX_LEN]byte
	prefix[0] = byte(peer.network_magic)
	prefix[1] = byte(peer.network_magic >> 8)
	prefix[2] = byte(peer.network_magic >> 16)
	prefix[3] = byte(peer.network_magic >> 24)
	copy(prefix[4:], "version") // remainder stays zero — the padded command field

	n := min(len(peer.recv_buf), V1_PREFIX_LEN)
	for i in 0 ..< n {
		if peer.recv_buf[i] != prefix[i] {
			// v2 initiator — now (and only now) reveal ourselves as v2.
			peer.v2_detect = false
			ell := v2_transport_get_ell64(peer.v2)
			_peer_send_raw(peer, ell[:])
			return true
		}
	}
	if n < V1_PREFIX_LEN {
		return false
	}

	// Full v1 prefix — plaintext peer (e.g. electrs, older Core). Drop the
	// v2 transport and let the v1 parser consume the buffered bytes.
	log.debugf("Inbound peer %d speaks v1 — disabling v2 transport", peer.id)
	v2_transport_destroy(peer.v2)
	free(peer.v2)
	peer.v2 = nil
	peer.v2_detect = false
	peer.state = .Connecting
	return true
}

// V1 message processing (existing logic).
_peer_process_messages_v1 :: proc(peer: ^Peer) {
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

// V2 encrypted message processing (BIP324).
_peer_process_messages_v2 :: proc(peer: ^Peer) {
	cm := peer.cm
	t := peer.v2

	// Early v1 detection: if awaiting peer's ell64 and the first received byte
	// matches the v1 network magic, the peer is v1-only — reconnect with v1.
	if t.state == .Awaiting_EllSwift {
		first_byte: byte
		has_first := false
		if len(t.recv_buf) > 0 {
			first_byte = t.recv_buf[0]
			has_first = true
		} else if len(peer.recv_buf) > 0 {
			first_byte = peer.recv_buf[0]
			has_first = true
		}
		if has_first {
			if first_byte == byte(peer.network_magic) {
				if peer.inbound {
					// Inbound V1 fallback: destroy V2, feed buffered data back, process as V1.
					log.debugf("Inbound peer %d sent v1 magic byte (0x%02x), switching to v1", peer.id, first_byte)
					// Collect all buffered data (v2 recv_buf + peer recv_buf).
					v1_data := make([dynamic]byte, 0, len(t.recv_buf) + len(peer.recv_buf), context.temp_allocator)
					append(&v1_data, ..t.recv_buf[:])
					append(&v1_data, ..peer.recv_buf[:])
					// Destroy V2 transport.
					v2_transport_destroy(t)
					free(peer.v2)
					peer.v2 = nil
					// Feed buffered data back into recv_buf.
					resize(&peer.recv_buf, len(v1_data))
					copy(peer.recv_buf[:], v1_data[:])
					peer.state = .Connecting
					_peer_process_messages_v1(peer)
					return
				} else {
					log.debugf("Peer %d sent v1 magic byte (0x%02x), not v2 — reconnecting with v1", peer.id, first_byte)
					_conn_manager_v2_fallback(cm, peer)
					return
				}
			}
		}
	}

	// Feed all recv_buf data into the v2 transport.
	data := peer.recv_buf[:]
	// Clear recv_buf (transport has its own buffer).
	resize(&peer.recv_buf, 0)

	msgs, v2_err := v2_transport_receive(t, data)

	// Send handshake bytes if ready (after receiving peer's ell64).
	if t.handshake_to_send != nil {
		_peer_send_raw(peer, t.handshake_to_send)
		delete(t.handshake_to_send)
		t.handshake_to_send = nil
	}

	switch v2_err {
	case .None, .Need_More_Data:
		if t.state == .Active && peer.state == .V2_Handshake {
			log.debugf("V2 handshake complete with peer %d", peer.id)
			if peer.inbound {
				// Inbound: V2 handshake done, wait for their version message.
				peer.state = .Connecting
			} else {
				// Outbound: V2 handshake done, send our version message (encrypted via v2).
				_, chain_height := chain.chain_tip(cm.chain)
				peer_send_version(peer, cm.params, chain_height, cm.local_services)
				peer.state = .Version_Sent
			}
		}
	case .Bad_Garbage_Auth, .Decryption_Failed, .Invalid_Message:
		if peer.state == .V2_Handshake {
			if peer.inbound {
				// Inbound V2 handshake failed — disconnect (can't reconnect to them).
				log.debugf("Inbound peer %d: V2 error %v, disconnecting", peer.id, v2_err)
				_peer_handle_disconnect(peer)
				return
			} else {
				// Outbound V2 handshake failed — reconnect with v1.
				log.debugf("V2 error for peer %d: %v (transport state: %v, recv_buf: %d bytes)",
					peer.id, v2_err, t.state, len(t.recv_buf))
				_conn_manager_v2_fallback(cm, peer)
				return
			}
		}
		// Post-handshake decryption error — genuine connection problem.
		log.warnf("V2 decryption error for peer %d: %v", peer.id, v2_err)
		_peer_handle_disconnect(peer)
		return
	}

	// Dispatch decoded messages.
	// NOTE: Unlike v1, we must NOT call free_all(context.temp_allocator) between
	// dispatches. The msgs array and its entries' command/payload data are all
	// temp-allocated by v2_transport_receive. Calling free_all after dispatching
	// the first message would reset the arena cursor, and subsequent temp
	// allocations (from v2_transport_encrypt inside handlers) would overwrite
	// later msgs entries — corrupting command strings and causing false disconnects.
	for &msg in msgs {
		_conn_manager_dispatch(cm, peer.id, msg.command, msg.payload)

		if peer.state == .Disconnected {
			return
		}
	}
	free_all(context.temp_allocator)
}

// Send raw bytes to peer (unframed, for v2 handshake ell64 + handshake data).
_peer_send_raw :: proc(peer: ^Peer, data: []byte) {
	if peer.state == .Disconnected || len(data) == 0 {
		return
	}
	msg := make([]byte, len(data))
	copy(msg, data)
	append(&peer.send_queue, msg)
	if !peer.sending {
		_peer_flush_send_queue(peer)
	}
}

// Handle peer disconnect — notify conn_manager inline.
_peer_handle_disconnect :: proc(peer: ^Peer) {
	if peer.state == .Disconnected {
		return
	}
	log.debugf("Peer %d disconnected", peer.id)
	cm := peer.cm
	sync_handle_disconnect(&cm.sync_mgr, peer.id, &cm.peers)
	conn_manager_remove_peer(cm, peer.id)
}

// Send a framed message to the peer. Queues for async send.
// Uses v2 encryption if v2 transport is active, otherwise v1 wire framing.
peer_send_message :: proc(peer: ^Peer, command: string, payload: []byte) -> Net_Error {
	if peer.state == .Disconnected {
		return .Send_Failed
	}

	msg: []byte
	if peer.v2 != nil && peer.v2.state == .Active {
		msg = v2_transport_encrypt(peer.v2, command, payload)
	} else {
		msg = wire.build_message(peer.network_magic, command, payload)
	}
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
	// Track the send op so peer_destroy can cancel it. On io_uring a submitted
	// send completes on its own schedule regardless of socket close, so without
	// cancelling it the _on_send callback fires on an already-freed peer
	// (use-after-free → heap corruption; kqueue closes synchronously so macOS
	// never saw this).
	peer.send_op = nbio.send_poly(peer.socket, bufs[:], peer, _on_send, all = true, timeout = 30 * time.Second)
}

// Callback when async send completes.
_on_send :: proc(op: ^nbio.Operation, peer: ^Peer) {
	peer.send_op = nil // this op is completing; nothing to cancel anymore
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
	peer.cm.total_bytes_sent += i64(op.send.sent)
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

	// Cancel pending recv AND send operations BEFORE closing socket. Closing
	// the fd does NOT cancel an in-flight io_uring op — its completion still
	// fires the callback later, on an already-freed peer (use-after-free →
	// heap corruption, seen on Linux mainnet IBD 2026-07-08). nbio.remove marks
	// the op so nbio suppresses the callback when the completion arrives.
	if peer.recv_op != nil {
		nbio.remove(peer.recv_op)
		peer.recv_op = nil
	}
	if peer.send_op != nil {
		nbio.remove(peer.send_op)
		peer.send_op = nil
	}

	tcp.close(peer.socket)

	// Free any unsent messages in the queue.
	for msg in peer.send_queue {
		delete(msg)
	}
	delete(peer.send_queue)

	// Free the in-flight send message. Safe to free here: we cancelled the send
	// op above, so nbio will suppress _on_send (which would otherwise free it).
	if peer.sending_msg != nil {
		delete(peer.sending_msg)
		peer.sending_msg = nil
	}

	// Clean up v2 transport.
	if peer.v2 != nil {
		v2_transport_destroy(peer.v2)
		free(peer.v2)
		peer.v2 = nil
	}
}

// Free peer memory (without closing socket — used by both destroy and failed connect).
_peer_free :: proc(peer: ^Peer) {
	delete(peer.recv_buf)
	if peer.socks != nil {
		free(peer.socks)
		peer.socks = nil
	}
	if len(peer.address) > 0 {
		delete(peer.address)
	}
	if len(peer.user_agent) > 0 {
		delete(peer.user_agent)
	}
	free(peer)
}

// Build and send a version message.
peer_send_version :: proc(peer: ^Peer, params: ^consensus.Chain_Params, chain_height: int, local_services: u64 = LOCAL_SERVICES) -> Net_Error {
	// Block-relay-only connections advertise fRelay=false (BIP37 field):
	// the peer must not send us transaction invs.
	now := time.now()
	timestamp := time.to_unix_seconds(now)

	ver := wire.Version_Message {
		version      = i32(wire.PROTOCOL_VERSION),
		services     = local_services,
		timestamp    = timestamp,
		addr_recv    = wire.Net_Address{services = 0},
		addr_from    = wire.Net_Address{services = local_services},
		nonce        = u64(timestamp) ~ u64(peer.id), // simple nonce
		user_agent   = wire.NODE_USER_AGENT,
		start_height = i32(chain_height),
		relay        = peer.conn_type != .Block_Relay,
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

// Send cmpctblock (BIP152) announcement to a peer.
peer_send_cmpctblock :: proc(peer: ^Peer, msg: ^wire.Compact_Block_Message) -> Net_Error {
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_compact_block(&w, msg)
	return peer_send_message(peer, wire.CMD_CMPCTBLOCK, wire.writer_bytes(&w))
}

// Send blocktxn (BIP152) response to a peer's getblocktxn request.
peer_send_blocktxn :: proc(peer: ^Peer, msg: ^wire.Block_Txn_Message) -> Net_Error {
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_block_txn(&w, msg)
	return peer_send_message(peer, wire.CMD_BLOCKTXN, wire.writer_bytes(&w))
}

// Send headers (BIP130) block announcement — single-element header list.
peer_send_block_headers :: proc(peer: ^Peer, headers: []wire.Block_Header) -> Net_Error {
	msg := wire.Headers_Message{headers = headers}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_headers(&w, &msg)
	return peer_send_message(peer, wire.CMD_HEADERS, wire.writer_bytes(&w))
}

// Send inv for a block (legacy announcement).
peer_send_block_inv :: proc(peer: ^Peer, block_hash: Hash256) -> Net_Error {
	inv := [1]wire.Inv_Vector{{type = .Block, hash = block_hash}}
	inv_msg := wire.Inv_Message{inventory = inv[:]}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_inv(&w, &inv_msg)
	return peer_send_message(peer, wire.CMD_INV, wire.writer_bytes(&w))
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

// Send sendaddrv2 (BIP155, empty payload). Must be sent between version and verack.
peer_send_sendaddrv2 :: proc(peer: ^Peer) -> Net_Error {
	return peer_send_message(peer, wire.CMD_SENDADDRV2, nil)
}

// Send getaddr (empty payload). Request peer's address list.
peer_send_getaddr :: proc(peer: ^Peer) -> Net_Error {
	peer.addr_sent = true
	return peer_send_message(peer, wire.CMD_GETADDR, nil)
}

// Send addr (v1) message with a list of addresses.
peer_send_addr :: proc(peer: ^Peer, addresses: []wire.Net_Address_Timestamp) -> Net_Error {
	msg := wire.Addr_Message{addresses = addresses}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_addr(&w, &msg)
	return peer_send_message(peer, wire.CMD_ADDR, wire.writer_bytes(&w))
}

// Send addrv2 (BIP155) message with a list of v2 addresses.
peer_send_addrv2 :: proc(peer: ^Peer, addresses: []wire.Addr_V2_Address) -> Net_Error {
	msg := wire.Addr_V2_Message{addresses = addresses}
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_addr_v2(&w, &msg)
	return peer_send_message(peer, wire.CMD_ADDRV2, wire.writer_bytes(&w))
}

// Send cfilter (BIP157) response.
peer_send_cfilter :: proc(peer: ^Peer, msg: ^wire.CFilter_Message) -> Net_Error {
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_cfilter(&w, msg)
	return peer_send_message(peer, wire.CMD_CFILTER, wire.writer_bytes(&w))
}

// Send cfheaders (BIP157) response.
peer_send_cfheaders :: proc(peer: ^Peer, msg: ^wire.CFHeaders_Message) -> Net_Error {
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_cfheaders(&w, msg)
	return peer_send_message(peer, wire.CMD_CFHEADERS, wire.writer_bytes(&w))
}

// Send cfcheckpt (BIP157) response.
peer_send_cfcheckpt :: proc(peer: ^Peer, msg: ^wire.CFCheckpt_Message) -> Net_Error {
	w := wire.writer_init()
	defer wire.writer_destroy(&w)
	wire.serialize_cfcheckpt(&w, msg)
	return peer_send_message(peer, wire.CMD_CFCHECKPT, wire.writer_bytes(&w))
}
