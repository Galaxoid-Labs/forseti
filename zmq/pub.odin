// ZMQ PUB endpoint(s) — Bitcoin Core zmqpub* parity, implemented directly
// on TCP (no libzmq). One background thread per endpoint owns the listener
// and all subscriber sockets (non-blocking, ~50ms poll cadence); node
// threads enqueue notifications through a mutex-guarded queue.
package zmq

import "core:log"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Notification :: struct {
	topic:   string, // static literal
	payload: []byte, // heap clone, owned by the publisher; freed after fan-out
}

Sub :: struct {
	socket:  net.TCP_Socket,
	inbuf:   [dynamic]byte,
	greeted: bool, // received their 64-byte greeting
	ready:   bool, // received their READY command
	subs:    [dynamic][]byte, // subscribed prefixes (heap clones)
	dead:    bool,
}

Publisher :: struct {
	endpoint: net.Endpoint,
	listener: net.TCP_Socket,
	topics:   map[string]bool, // topics configured for this endpoint
	seq:      map[string]u32,  // per-topic LE32 publication counters

	allocator: mem.Allocator, // owns every queued payload (notify may be called from any thread)
	mutex:   sync.Mutex,
	queue:   [dynamic]Notification,
	running: bool,
	th:      ^thread.Thread,

	subs: [dynamic]^Sub,
}

// Parse "tcp://127.0.0.1:28332".
parse_endpoint :: proc(s: string) -> (ep: net.Endpoint, ok: bool) {
	rest := s
	if strings.has_prefix(rest, "tcp://") {
		rest = rest[len("tcp://"):]
	} else {
		return {}, false
	}
	colon := strings.last_index_byte(rest, ':')
	if colon < 0 {
		return {}, false
	}
	addr, addr_ok := net.parse_ip4_address(rest[:colon])
	if !addr_ok {
		return {}, false
	}
	port, port_ok := strconv.parse_int(rest[colon + 1:])
	if !port_ok {
		return {}, false
	}
	return net.Endpoint{address = addr, port = port}, true
}

publisher_start :: proc(endpoint_str: string, topics: []string) -> ^Publisher {
	ep, ok := parse_endpoint(endpoint_str)
	if !ok {
		log.errorf("ZMQ: invalid endpoint %q (expected tcp://ip:port)", endpoint_str)
		return nil
	}
	listener, lerr := net.listen_tcp(ep)
	if lerr != nil {
		log.errorf("ZMQ: cannot listen on %s: %v", endpoint_str, lerr)
		return nil
	}
	net.set_blocking(listener, false)

	p := new(Publisher)
	p.allocator = context.allocator
	p.endpoint = ep
	p.listener = listener
	p.topics = make(map[string]bool)
	for t in topics {
		p.topics[t] = true
	}
	p.seq = make(map[string]u32)
	p.queue = make([dynamic]Notification, 0, 64)
	p.subs = make([dynamic]^Sub, 0, 4)
	p.running = true
	p.th = thread.create_and_start_with_data(rawptr(p), _publisher_loop)
	log.infof("ZMQ publisher on %s (%d topic(s))", endpoint_str, len(topics))
	return p
}

publisher_stop :: proc(p: ^Publisher) {
	if p == nil {
		return
	}
	p.running = false
	net.close(p.listener)
	thread.join(p.th)
	thread.destroy(p.th)
	for s in p.subs {
		net.close(s.socket)
		_sub_free(s)
	}
	delete(p.subs)
	sync.mutex_lock(&p.mutex)
	for n in p.queue {
		delete(n.payload, p.allocator)
	}
	sync.mutex_unlock(&p.mutex)
	delete(p.queue)
	delete(p.topics)
	delete(p.seq)
	free(p)
}

// Enqueue from any thread. Payload is cloned; cheap no-op when the topic
// isn't configured on this endpoint or nothing is connected yet.
notify :: proc(p: ^Publisher, topic: string, payload: []byte) {
	if p == nil || !p.running || topic not_in p.topics {
		return
	}
	cloned := make([]byte, len(payload), p.allocator)
	copy(cloned, payload)
	sync.mutex_lock(&p.mutex)
	append(&p.queue, Notification{topic = topic, payload = cloned})
	sync.mutex_unlock(&p.mutex)
}

_sub_free :: proc(s: ^Sub) {
	delete(s.inbuf)
	for pref in s.subs {
		delete(pref)
	}
	delete(s.subs)
	free(s)
}

_publisher_loop :: proc(data: rawptr) {
	p := cast(^Publisher)data
	context.logger = log.create_console_logger(.Info, {.Level, .Time, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	for p.running {
		// 1. Accept new subscribers.
		for {
			client, _, aerr := net.accept_tcp(p.listener)
			if aerr != nil {
				break // Would_Block (or listener closed at shutdown)
			}
			net.set_blocking(client, false)
			s := new(Sub)
			s.socket = client
			s.inbuf = make([dynamic]byte, 0, 512)
			s.subs = make([dynamic][]byte, 0, 4)
			append(&p.subs, s)
			log.debugf("ZMQ: accepted subscriber")
			// Send greeting + READY immediately (NULL handshake needs no reply first).
			out := make([dynamic]byte, 0, 128, context.temp_allocator)
			g := greeting()
			append(&out, ..g[:])
			ready_command(&out)
			_send_all(s, out[:])
		}

		// 2. Read handshake/subscription bytes from subscribers.
		buf: [4096]byte
		for s in p.subs {
			if s.dead {
				continue
			}
			for {
				n, rerr := net.recv_tcp(s.socket, buf[:])
				if n > 0 {
					append(&s.inbuf, ..buf[:n])
				}
				if rerr != nil {
					if rerr == .Would_Block {
						break
					}
					s.dead = true
					break
				}
				if n == 0 {
					s.dead = true // clean disconnect
					break
				}
			}
			_sub_process(s)
		}

		// 3. Drain the queue and fan out.
		sync.mutex_lock(&p.mutex)
		pending := p.queue
		p.queue = make([dynamic]Notification, 0, 64)
		sync.mutex_unlock(&p.mutex)

		for note in pending {
			p.seq[note.topic] = p.seq[note.topic] + 1
			out := make([dynamic]byte, 0, len(note.payload) + 64, context.temp_allocator)
			publication(&out, note.topic, note.payload, p.seq[note.topic] - 1)
			for s in p.subs {
				if s.dead || !s.ready || !_sub_wants(s, note.topic) {
					continue
				}
				_send_all(s, out[:])
			}
			delete(note.payload, p.allocator)
		}
		free_all(context.temp_allocator)

		// 4. Reap dead subscribers.
		for i := len(p.subs) - 1; i >= 0; i -= 1 {
			if p.subs[i].dead {
				net.close(p.subs[i].socket)
				_sub_free(p.subs[i])
				unordered_remove(&p.subs, i)
			}
		}

		time.sleep(50 * time.Millisecond)
	}
}

// Advance a subscriber's handshake / subscription state from buffered bytes.
_sub_process :: proc(s: ^Sub) {
	if !s.greeted {
		if len(s.inbuf) < GREETING_SIZE {
			return
		}
		if !greeting_ok(s.inbuf[:GREETING_SIZE]) {
			s.dead = true
			return
		}
		remove_range(&s.inbuf, 0, GREETING_SIZE)
		s.greeted = true
	}
	for {
		body, flags, consumed, ok := frame_parse(s.inbuf[:])
		if !ok {
			return
		}
		if flags & FLAG_COMMAND != 0 {
			// READY (or ERROR) — accept any command as handshake completion.
			s.ready = true
			log.debugf("ZMQ: subscriber ready")
		} else if len(body) >= 1 {
			// ZMTP 3.0 subscription message: 0x01 subscribe / 0x00 unsubscribe + prefix.
			prefix := body[1:]
			if body[0] == 1 {
				cl := make([]byte, len(prefix))
				copy(cl, prefix)
				append(&s.subs, cl)
				log.debugf("ZMQ: subscribe %q", string(cl))
			} else if body[0] == 0 {
				for i := len(s.subs) - 1; i >= 0; i -= 1 {
					if string(s.subs[i]) == string(prefix) {
						delete(s.subs[i])
						unordered_remove(&s.subs, i)
					}
				}
			}
		}
		remove_range(&s.inbuf, 0, consumed)
	}
}

_sub_wants :: proc(s: ^Sub, topic: string) -> bool {
	for pref in s.subs {
		if len(pref) <= len(topic) && string(pref) == topic[:len(pref)] {
			return true
		}
	}
	return false
}

// Best-effort send with a bounded would-block retry; slow or broken
// subscribers get dropped (PUB semantics).
_send_all :: proc(s: ^Sub, data: []byte) {
	sent := 0
	tries := 0
	for sent < len(data) {
		n, serr := net.send_tcp(s.socket, data[sent:])
		sent += n
		if serr != nil {
			if serr == .Would_Block {
				tries += 1
				if tries > 40 { // ~2s of 50ms naps: slow subscriber, drop
					s.dead = true
					return
				}
				time.sleep(50 * time.Millisecond)
				continue
			}
			s.dead = true
			return
		}
	}
}
