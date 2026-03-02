package p2p

import "core:fmt"
import "core:mem"
import tcp "core:net"
import "core:sync"
import "core:sync/chan"
import "core:thread"
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
	reader_thread:  ^thread.Thread,
	msg_chan:        chan.Chan(Peer_Message),
	send_mutex:     sync.Mutex,
	network_magic:  u32,
	recv_buf:       [dynamic]byte,
}

// Connect to a peer, allocate Peer struct, start reader thread.
peer_connect :: proc(
	address: string,
	port: int,
	network_magic: u32,
	msg_chan: chan.Chan(Peer_Message),
	peer_id: Peer_Id,
) -> (peer: ^Peer, err: Net_Error) {
	socket, net_err := tcp.dial_tcp(address, port)
	if net_err != nil {
		return nil, .Connection_Failed
	}

	peer = new(Peer)
	peer.id = peer_id
	peer.socket = socket
	peer.address = address
	peer.state = .Connecting
	peer.network_magic = network_magic
	peer.msg_chan = msg_chan
	peer.recv_buf = make([dynamic]byte, 0, 8192)

	// Start reader thread, passing peer pointer via data field.
	peer.reader_thread = thread.create_and_start_with_data(
		rawptr(peer),
		_peer_reader_proc,
	)

	return peer, .None
}

// Close socket, join thread, free memory.
peer_destroy :: proc(peer: ^Peer) {
	if peer == nil {
		return
	}
	peer.state = .Disconnected
	tcp.close(peer.socket)
	if peer.reader_thread != nil {
		thread.join(peer.reader_thread)
		thread.destroy(peer.reader_thread)
	}
	delete(peer.recv_buf)
	free(peer)
}

// Send a framed message to the peer. Acquires send_mutex.
peer_send_message :: proc(peer: ^Peer, command: string, payload: []byte) -> Net_Error {
	msg := wire.build_message(peer.network_magic, command, payload)
	defer delete(msg)

	if sync.mutex_guard(&peer.send_mutex) {
		_, send_err := tcp.send_tcp(peer.socket, msg)
		if send_err != nil {
			return .Send_Failed
		}
	}
	return .None
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
		user_agent   = "/btcnode-odin:0.1.0/",
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

// Reader thread procedure. Reads messages from the socket and sends them to the shared channel.
_peer_reader_proc :: proc(data: rawptr) {
	peer := (^Peer)(data)
	read_buf: [4096]byte

	for {
		// Read from socket.
		bytes_read, recv_err := tcp.recv_tcp(peer.socket, read_buf[:])

		if recv_err != nil || bytes_read == 0 {
			// Connection closed or error — send disconnect signal.
			chan.send(peer.msg_chan, Peer_Message{
				peer_id = peer.id,
				command = "",
				payload = nil,
			})
			return
		}

		// Accumulate into recv_buf.
		append(&peer.recv_buf, ..read_buf[:bytes_read])

		// Try to parse complete messages from the buffer.
		for {
			if len(peer.recv_buf) < wire.MESSAGE_HEADER_SIZE {
				break
			}

			// Peek at header to get payload size.
			r := wire.reader_init(peer.recv_buf[:])
			hdr, hdr_err := wire.deserialize_message_header(&r)
			if hdr_err != .None {
				// Bad header — disconnect.
				chan.send(peer.msg_chan, Peer_Message{
					peer_id = peer.id,
					command = "",
					payload = nil,
				})
				return
			}

			// Validate magic.
			if hdr.magic != peer.network_magic {
				chan.send(peer.msg_chan, Peer_Message{
					peer_id = peer.id,
					command = "",
					payload = nil,
				})
				return
			}

			// Check payload size limit.
			if hdr.payload_size > wire.MAX_MESSAGE_PAYLOAD {
				chan.send(peer.msg_chan, Peer_Message{
					peer_id = peer.id,
					command = "",
					payload = nil,
				})
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
				chan.send(peer.msg_chan, Peer_Message{
					peer_id = peer.id,
					command = "",
					payload = nil,
				})
				return
			}

			// Clone payload so the channel message owns it.
			cloned_payload := make([]byte, len(payload_data))
			copy(cloned_payload, payload_data)

			cmd := wire.command_from_bytes(hdr.command)

			// Send parsed message to main thread.
			chan.send(peer.msg_chan, Peer_Message{
				peer_id = peer.id,
				command = cmd,
				payload = cloned_payload,
			})

			// Consume processed bytes from recv_buf.
			remaining := len(peer.recv_buf) - total_size
			if remaining > 0 {
				copy(peer.recv_buf[:remaining], peer.recv_buf[total_size:])
			}
			resize(&peer.recv_buf, remaining)
		}
	}
}
