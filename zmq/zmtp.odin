// Minimal ZMTP 3.0 for a PUB server — just enough for libzmq/pyzmq SUB
// clients (Bitcoin Core zmqpub* parity). No security (NULL mechanism),
// no ZMTP 3.1 commands; subscriptions arrive as 0x01-prefixed messages.
package zmq

// --- greeting ---

GREETING_SIZE :: 64

// Build our greeting: signature, version 3.0, mechanism NULL, as-server=0.
greeting :: proc() -> [GREETING_SIZE]byte {
	g: [GREETING_SIZE]byte
	g[0] = 0xff
	g[9] = 0x7f
	g[10] = 3 // major
	g[11] = 0 // minor
	copy(g[12:], "NULL") // rest of the 20-byte mechanism field stays zero
	// g[32] as-server = 0; filler zeros
	return g
}

// Validate a peer greeting (lenient: only the signature and mechanism matter).
greeting_ok :: proc(g: []byte) -> bool {
	if len(g) < GREETING_SIZE {
		return false
	}
	if g[0] != 0xff || g[9] != 0x7f {
		return false
	}
	return string(g[12:16]) == "NULL"
}

// --- frames ---

// Encode one frame: flags(1) + size(1 or 8 BE) + body.
FLAG_MORE    :: byte(0x01)
FLAG_LONG    :: byte(0x02)
FLAG_COMMAND :: byte(0x04)

frame_append :: proc(out: ^[dynamic]byte, body: []byte, more: bool, command := false) {
	flags: byte = 0
	if more { flags |= FLAG_MORE }
	if command { flags |= FLAG_COMMAND }
	if len(body) > 255 {
		flags |= FLAG_LONG
		append(out, flags)
		n := u64(len(body))
		for shift := uint(56); ; shift -= 8 {
			append(out, byte(n >> shift))
			if shift == 0 { break }
		}
	} else {
		append(out, flags)
		append(out, byte(len(body)))
	}
	append(out, ..body)
}

// READY command with Socket-Type metadata (we are PUB).
ready_command :: proc(out: ^[dynamic]byte) {
	body := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&body, byte(5))
	append(&body, "READY")
	// metadata: name-len(1) name value-len(4 BE) value
	append(&body, byte(len("Socket-Type")))
	append(&body, "Socket-Type")
	val := "PUB"
	append(&body, 0, 0, 0, byte(len(val)))
	append(&body, val)
	frame_append(out, body[:], more = false, command = true)
}

// Parse frames from a buffer; returns (frame body, flags, bytes consumed, ok).
// ok=false means incomplete data — caller retries with more bytes.
frame_parse :: proc(buf: []byte) -> (body: []byte, flags: byte, consumed: int, ok: bool) {
	if len(buf) < 2 {
		return nil, 0, 0, false
	}
	flags = buf[0]
	if flags & FLAG_LONG != 0 {
		if len(buf) < 9 {
			return nil, 0, 0, false
		}
		n := u64(0)
		for i in 1 ..= 8 {
			n = n << 8 | u64(buf[i])
		}
		if n > 64 * 1024 * 1024 || len(buf) < 9 + int(n) {
			return nil, 0, 0, false
		}
		return buf[9:9 + int(n)], flags, 9 + int(n), true
	}
	n := int(buf[1])
	if len(buf) < 2 + n {
		return nil, 0, 0, false
	}
	return buf[2:2 + n], flags, 2 + n, true
}

// Encode a Core-style publication: topic | payload | LE32 sequence.
publication :: proc(out: ^[dynamic]byte, topic: string, payload: []byte, seq: u32) {
	frame_append(out, transmute([]byte)topic, more = true)
	frame_append(out, payload, more = true)
	s := [4]byte{byte(seq), byte(seq >> 8), byte(seq >> 16), byte(seq >> 24)}
	frame_append(out, s[:], more = false)
}
