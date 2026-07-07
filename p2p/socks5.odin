// SOCKS5 client (RFC 1928) for --proxy: outbound P2P connections dial the
// proxy and run a two-round handshake (greeting → CONNECT) before the
// normal Bitcoin transport starts. Non-IPv4 targets (e.g. .onion) are sent
// as DOMAINNAME so the proxy resolves them — no local DNS leak. No
// authentication methods (Tor's SOCKS port needs none).
package p2p

import "core:log"
import tcp "core:net"
import "core:strconv"
import "core:strings"

Socks5_Phase :: enum {
	Greeting_Sent, // waiting for [ver, method]
	Connect_Sent,  // waiting for the CONNECT reply
}

Socks5_State :: struct {
	phase:       Socks5_Phase,
	target_host: string, // view into peer.address (peer owns it)
	target_port: int,
}

// Parse "ip:port" (default port when absent). IPv4 only — the PROXY itself
// must be directly reachable.
parse_proxy_endpoint :: proc(s: string, default_port: int) -> (tcp.Endpoint, bool) {
	host := s
	port := default_port
	if colon := strings.last_index_byte(s, ':'); colon >= 0 {
		host = s[:colon]
		p, p_ok := strconv.parse_int(s[colon + 1:])
		if !p_ok || p <= 0 || p > 65535 {
			return {}, false
		}
		port = p
	}
	addr, ok := tcp.parse_ip4_address(host)
	if !ok {
		return {}, false
	}
	return tcp.Endpoint{address = addr, port = port}, true
}

// Kick off the handshake right after the TCP connect to the proxy.
_peer_socks5_start :: proc(peer: ^Peer) {
	greeting := [3]byte{0x05, 0x01, 0x00} // ver 5, 1 method, no-auth
	_peer_send_raw(peer, greeting[:])
	peer.socks.phase = .Greeting_Sent
}

// Consume SOCKS5 handshake bytes from recv_buf. Returns true once the
// tunnel is established (peer.socks freed, remaining bytes left in
// recv_buf); false while waiting for more bytes or after a fatal error
// (peer already disconnected).
_peer_socks5_process :: proc(peer: ^Peer) -> bool {
	s := peer.socks
	switch s.phase {
	case .Greeting_Sent:
		if len(peer.recv_buf) < 2 {
			return false
		}
		if peer.recv_buf[0] != 0x05 || peer.recv_buf[1] != 0x00 {
			log.warnf("SOCKS5 proxy rejected method negotiation for %s (%02x %02x)",
				peer.address, peer.recv_buf[0], peer.recv_buf[1])
			_peer_handle_disconnect(peer)
			return false
		}
		remove_range(&peer.recv_buf, 0, 2)

		// CONNECT request.
		req := make([dynamic]byte, 0, 7 + len(s.target_host), context.temp_allocator)
		append(&req, 0x05, 0x01, 0x00) // ver, CONNECT, reserved
		if ip4, is_ip4 := tcp.parse_ip4_address(s.target_host); is_ip4 {
			append(&req, 0x01, ip4[0], ip4[1], ip4[2], ip4[3])
		} else {
			if len(s.target_host) > 255 {
				log.warnf("SOCKS5 target hostname too long: %s", s.target_host)
				_peer_handle_disconnect(peer)
				return false
			}
			append(&req, 0x03, byte(len(s.target_host)))
			append(&req, s.target_host)
		}
		append(&req, byte(s.target_port >> 8), byte(s.target_port))
		_peer_send_raw(peer, req[:])
		s.phase = .Connect_Sent
		return false // reply not here yet

	case .Connect_Sent:
		if len(peer.recv_buf) < 4 {
			return false
		}
		if peer.recv_buf[0] != 0x05 {
			log.warnf("SOCKS5 malformed CONNECT reply for %s", peer.address)
			_peer_handle_disconnect(peer)
			return false
		}
		if peer.recv_buf[1] != 0x00 {
			log.debugf("SOCKS5 CONNECT to %s:%d refused (rep=%02x)",
				peer.address, s.target_port, peer.recv_buf[1])
			_peer_handle_disconnect(peer)
			return false
		}
		reply_len := 0
		switch peer.recv_buf[3] { // ATYP of the bound address
		case 0x01:
			reply_len = 4 + 4 + 2
		case 0x03:
			if len(peer.recv_buf) < 5 {
				return false
			}
			reply_len = 4 + 1 + int(peer.recv_buf[4]) + 2
		case 0x04:
			reply_len = 4 + 16 + 2
		case:
			log.warnf("SOCKS5 unknown ATYP in reply for %s", peer.address)
			_peer_handle_disconnect(peer)
			return false
		}
		if len(peer.recv_buf) < reply_len {
			return false
		}
		remove_range(&peer.recv_buf, 0, reply_len)

		// Tunnel up — hand over to the normal transport.
		log.debugf("SOCKS5 tunnel established to %s:%d (peer %d)", peer.address, s.target_port, peer.id)
		free(peer.socks)
		peer.socks = nil
		return true
	}
	return false
}
