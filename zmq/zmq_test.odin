package zmq

import "core:net"
import "core:testing"
import "core:time"

// End-to-end over loopback: this test IS the ZMTP subscriber — greeting,
// READY, subscribe("hashblock"), then asserts a Core-format publication
// (topic | payload | LE32 seq) arrives and an unsubscribed topic doesn't.
@(test)
test_pub_end_to_end :: proc(t: ^testing.T) {
	p := publisher_start("tcp://127.0.0.1:28399", []string{TOPIC_HASHBLOCK, TOPIC_HASHTX})
	testing.expect(t, p != nil, "publisher starts")
	defer publisher_stop(p)

	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = 28399})
	testing.expect(t, derr == nil, "subscriber connects")
	defer net.close(sock)

	// Handshake: greeting + READY(SUB) + subscribe("hashblock").
	out := make([dynamic]byte, 0, 256, context.temp_allocator)
	g := greeting()
	append(&out, ..g[:])
	{ // READY with Socket-Type SUB
		body := make([dynamic]byte, 0, 64, context.temp_allocator)
		append(&body, byte(5))
		append(&body, "READY")
		append(&body, byte(len("Socket-Type")))
		append(&body, "Socket-Type")
		append(&body, 0, 0, 0, 3)
		append(&body, "SUB")
		frame_append(&out, body[:], more = false, command = true)
	}
	{ // subscribe hashblock
		sub := make([dynamic]byte, 0, 16, context.temp_allocator)
		append(&sub, byte(1))
		append(&sub, TOPIC_HASHBLOCK)
		frame_append(&out, sub[:], more = false)
	}
	sent := 0
	for sent < len(out) {
		n, serr := net.send_tcp(sock, out[sent:])
		testing.expect(t, serr == nil, "handshake send")
		sent += n
	}

	// Let the publisher's 50ms loop process the handshake.
	time.sleep(300 * time.Millisecond)

	// Publish one hashblock (subscribed) and one hashtx (not subscribed).
	hash: [32]byte
	for i in 0 ..< 32 { hash[i] = byte(i) }
	txid: [32]byte
	txid[0] = 0xee
	notify(p, TOPIC_HASHTX, txid[:])   // must NOT arrive
	notify(p, TOPIC_HASHBLOCK, hash[:]) // must arrive

	// Receive: greeting(64) + READY frame + publication frames.
	recv_buf: [4096]byte
	got := make([dynamic]byte, 0, 4096, context.temp_allocator)
	deadline := time.tick_now()
	for time.duration_seconds(time.tick_since(deadline)) < 3 {
		n, rerr := net.recv_tcp(sock, recv_buf[:])
		if n > 0 { append(&got, ..recv_buf[:n]) }
		if rerr != nil { break }
		if len(got) >= GREETING_SIZE + 2 {
			// try full parse below each read
			rest := got[GREETING_SIZE:]
			frames := make([dynamic][]byte, 0, 8, context.temp_allocator)
			off := 0
			complete := true
			for off < len(rest) {
				body, _, consumed, ok := frame_parse(rest[off:])
				if !ok { complete = false; break }
				append(&frames, body)
				off += consumed
			}
			// Expect: READY + topic + payload + seq = 4 frames.
			if complete && len(frames) >= 4 {
				testing.expect_value(t, string(frames[1]), TOPIC_HASHBLOCK)
				testing.expect_value(t, len(frames[2]), 32)
				testing.expect_value(t, frames[2][5], byte(5))
				testing.expect_value(t, len(frames[3]), 4)
				testing.expect_value(t, frames[3][0], byte(0)) // first hashblock => seq 0
				// hashtx must not have been delivered: exactly 4 frames.
				testing.expect_value(t, len(frames), 4)
				return
			}
		}
	}
	testing.expect(t, false, "publication never arrived")
}
