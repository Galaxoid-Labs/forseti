package p2p

import odin_crypto "core:crypto"
import "core:log"
import "core:mem"

import crypto "../crypto"

V2_State :: enum {
	Awaiting_EllSwift,   // Waiting for peer's 64-byte ElligatorSwift pubkey
	Awaiting_Garbage_Term, // Scanning for garbage terminator in received data
	Awaiting_Version,    // Awaiting version packet (authenticates garbage via AAD)
	Active,              // Encrypted transport operational
	Failed,              // Handshake failed
}

V2_Transport :: struct {
	state:          V2_State,
	initiating:     bool,
	network_magic:  u32,
	// Ephemeral key material
	seckey:         [32]byte,
	our_ell64:      [64]byte,
	their_ell64:    [64]byte,
	// Derived keys
	keys:           BIP324_Keys,
	keys_derived:   bool,
	// Encryption contexts
	send_L:         FSChaCha20,
	send_P:         FSChaCha20Poly1305,
	recv_L:         FSChaCha20,
	recv_P:         FSChaCha20Poly1305,
	// Handshake buffer
	recv_buf:       [dynamic]byte,
	recv_aad:       []byte,   // peer's garbage bytes, used as AAD for version packet
	// Outbound handshake bytes (caller should send and clear after v2_transport_receive).
	handshake_to_send: []byte,
	// Pending decrypted length
	pending_length: int,   // -1 = no pending, >= 0 = waiting for content + tag
}

V2_Decoded_Msg :: struct {
	command: string,
	payload: []byte,
}

V2_Error :: enum {
	None,
	Need_More_Data,
	Bad_Garbage_Auth,
	Decryption_Failed,
	Invalid_Message,
}

// Maximum garbage length per BIP324.
V2_MAX_GARBAGE_LEN :: 4095

// Initialize v2 transport, generate ephemeral key, compute ElligatorSwift encoding.
v2_transport_init :: proc(t: ^V2_Transport, initiating: bool, network_magic: u32) -> bool {
	t.state = .Awaiting_EllSwift
	t.initiating = initiating
	t.network_magic = network_magic
	t.pending_length = -1
	t.recv_buf = make([dynamic]byte, 0, 4096)

	// V1 magic bytes (first byte on wire = LSB of LE u32 magic).
	v1_first_bytes := [5]byte{
		0xF9,  // mainnet (0xD9B4BEF9)
		0x0B,  // testnet3 (0x0709110B)
		0x1C,  // testnet4 (0x283F161C)
		0x0A,  // signet (0x40CF030A)
		0xFA,  // regtest (0xDAB5BFFA)
	}

	// Generate ephemeral key and ElligatorSwift encoding.
	for attempt in 0 ..< 64 {
		odin_crypto.rand_bytes(t.seckey[:])
		if !crypto.verify_seckey(t.seckey[:]) {
			continue
		}

		ell, ok := crypto.ellswift_create(t.seckey[:])
		if !ok {
			continue
		}

		// Check first byte isn't a v1 magic byte.
		is_magic := false
		for b in v1_first_bytes {
			if ell[0] == b {
				is_magic = true
				break
			}
		}
		if is_magic {
			continue
		}

		t.our_ell64 = ell
		return true
	}

	t.state = .Failed
	return false
}

v2_transport_get_ell64 :: proc(t: ^V2_Transport) -> [64]byte {
	return t.our_ell64
}

// After receiving peer's ell64, derive keys and produce handshake bytes to send.
v2_transport_complete_handshake :: proc(t: ^V2_Transport, allocator := context.allocator) -> []byte {
	shared_secret, ecdh_ok := crypto.ellswift_ecdh_bip324(
		t.our_ell64, t.their_ell64, t.seckey[:], t.initiating,
	)
	if !ecdh_ok {
		t.state = .Failed
		return nil
	}

	log.debugf("V2 ECDH: our_ell[0:4]=%02x%02x%02x%02x, their_ell[0:4]=%02x%02x%02x%02x, secret[0:4]=%02x%02x%02x%02x, magic=%08x",
		t.our_ell64[0], t.our_ell64[1], t.our_ell64[2], t.our_ell64[3],
		t.their_ell64[0], t.their_ell64[1], t.their_ell64[2], t.their_ell64[3],
		shared_secret[0], shared_secret[1], shared_secret[2], shared_secret[3],
		t.network_magic)

	t.keys = bip324_derive_keys(shared_secret, t.initiating, t.network_magic)

	fschacha20_init(&t.send_L, t.keys.send_L_key)
	fschacha20poly1305_init(&t.send_P, t.keys.send_P_key)
	fschacha20_init(&t.recv_L, t.keys.recv_L_key)
	fschacha20poly1305_init(&t.recv_P, t.keys.recv_P_key)

	// Version packet (also authenticates our garbage via AAD).
	// BIP324: no separate garbage auth — the first encrypted packet (version)
	// uses garbage bytes as AAD. We send 0 garbage, so AAD is nil.
	// Length field encodes payload size WITHOUT the 1-byte header = 0.
	version_content := [1]byte{0}   // header byte only
	version_ct: [1]byte
	version_tag: [16]byte
	version_len_plain := [3]byte{0, 0, 0}   // payload length = 0 (header excluded)
	version_len_ct: [3]byte
	fschacha20_crypt(&t.send_L, version_len_ct[:], version_len_plain[:])
	fschacha20poly1305_seal(&t.send_P, version_ct[:], version_tag[:], nil, version_content[:])

	// Total: 16 (term) + 3 (encrypted len) + 1 (encrypted header) + 16 (tag)
	total := 16 + 3 + 1 + 16
	result := make([]byte, total, allocator)
	pos := 0
	copy(result[pos:pos + 16], t.keys.send_garbage_term[:])
	pos += 16
	copy(result[pos:pos + 3], version_len_ct[:])
	pos += 3
	result[pos] = version_ct[0]
	pos += 1
	copy(result[pos:pos + 16], version_tag[:])

	return result
}

// Feed received bytes into the transport. Returns decoded messages if any.
v2_transport_receive :: proc(t: ^V2_Transport, data: []byte, allocator := context.temp_allocator) -> (messages: [dynamic]V2_Decoded_Msg, err: V2_Error) {
	messages = make([dynamic]V2_Decoded_Msg, 0, 4, allocator)

	if len(data) > 0 {
		append(&t.recv_buf, ..data)
	}

	for {
		// No-progress guard (below): every iteration must either advance the
		// state machine or consume bytes from recv_buf. Capture both up front.
		prev_state := t.state
		prev_len := len(t.recv_buf)

		switch t.state {
		case .Awaiting_EllSwift:
			if len(t.recv_buf) < 64 {
				return messages, .Need_More_Data
			}
			copy(t.their_ell64[:], t.recv_buf[:64])
			_v2_consume_recv(t, 64)

			hs_bytes := v2_transport_complete_handshake(t)
			if hs_bytes == nil {
				log.warnf("V2: ECDH or key derivation failed")
				return messages, .Invalid_Message
			}
			t.handshake_to_send = hs_bytes
			t.state = .Awaiting_Garbage_Term
			log.debugf("V2: got peer ell64, derived keys, scanning %d remaining bytes for garbage term", len(t.recv_buf))
			log.debugf("V2: recv_garbage_term=%02x%02x%02x%02x...",
				t.keys.recv_garbage_term[0], t.keys.recv_garbage_term[1],
				t.keys.recv_garbage_term[2], t.keys.recv_garbage_term[3])

		case .Awaiting_Garbage_Term:
			term := t.keys.recv_garbage_term
			found := false
			max_scan := min(len(t.recv_buf), V2_MAX_GARBAGE_LEN + 16)
			if max_scan >= 16 {
				for i in 0 ..= max_scan - 16 {
					match := true
					for j in 0 ..< 16 {
						if t.recv_buf[i + j] != term[j] {
							match = false
							break
						}
					}
					if match {
						log.debugf("V2: garbage term FOUND at offset %d (buf=%d bytes)", i, len(t.recv_buf))
						// Save garbage bytes as AAD for the version packet.
						if i > 0 {
							t.recv_aad = make([]byte, i)
							copy(t.recv_aad, t.recv_buf[:i])
						}
						// Consume garbage + terminator. No separate garbage auth —
						// garbage is authenticated via version packet's AAD.
						_v2_consume_recv(t, i + 16)
						t.state = .Awaiting_Version
						found = true
						break
					}
				}
			}
			if !found {
				if len(t.recv_buf) > V2_MAX_GARBAGE_LEN + 16 {
					log.warnf("V2: garbage term not found in %d bytes, giving up", len(t.recv_buf))
					t.state = .Failed
					return messages, .Bad_Garbage_Auth
				}
				log.debugf("V2: garbage term not found yet, have %d bytes (max scan %d)", len(t.recv_buf), max_scan)
				return messages, .Need_More_Data
			}

		case .Awaiting_Version:
			// Decrypt the version packet but ignore its contents per BIP324.
			decrypt_err := _v2_decrypt_version_packet(t)
			if decrypt_err == .Need_More_Data {
				return messages, .Need_More_Data
			}
			if decrypt_err != .None {
				t.state = .Failed
				return messages, decrypt_err
			}
			t.state = .Active
			log.infof("V2 handshake complete (session_id=%02x%02x%02x%02x...)",
				t.keys.session_id[0], t.keys.session_id[1],
				t.keys.session_id[2], t.keys.session_id[3])

		case .Active:
			msg, decrypt_err := _v2_decrypt_packet(t, allocator)
			if decrypt_err == .Need_More_Data {
				return messages, .None
			}
			if decrypt_err != .None {
				log.debugf("V2: decrypt_packet error: %v (recv_buf=%d, pending_len=%d)", decrypt_err, len(t.recv_buf), t.pending_length)
				t.state = .Failed
				return messages, decrypt_err
			}
			if msg.command != "" {
				log.debugf("V2: decoded message: %s (%d bytes)", msg.command, len(msg.payload))
				append(&messages, msg)
			}
			// fall through to the no-progress guard, then loop for the next packet

		case .Failed:
			return messages, .Invalid_Message
		}

		// Safety net: if an iteration neither advanced the state machine nor
		// consumed any bytes, continuing would spin this loop at 100% CPU (a
		// v2/io_uring edge case pegged a core on Linux mid-IBD, 2026-07-08).
		// Treat it as a protocol error and drop the peer instead of hanging.
		if t.state == prev_state && len(t.recv_buf) == prev_len {
			log.errorf("V2: receive loop made no progress (state=%v, %d buffered bytes) — dropping peer", t.state, len(t.recv_buf))
			t.state = .Failed
			return messages, .Invalid_Message
		}
	}
}

// Encrypt an outbound message. Returns owned bytes to send.
v2_transport_encrypt :: proc(t: ^V2_Transport, command: string, payload: []byte, allocator := context.allocator) -> []byte {
	content := bip324_encode_message_content(command, payload, context.temp_allocator)
	content_len := len(content)

	// Length field encodes payload size WITHOUT the 1-byte header.
	wire_len := content_len - 1
	len_plain: [3]byte
	len_plain[0] = byte(wire_len)
	len_plain[1] = byte(wire_len >> 8)
	len_plain[2] = byte(wire_len >> 16)
	len_ct: [3]byte
	fschacha20_crypt(&t.send_L, len_ct[:], len_plain[:])

	ct := make([]byte, content_len, context.temp_allocator)
	tag: [16]byte
	fschacha20poly1305_seal(&t.send_P, ct, tag[:], nil, content)

	total := 3 + content_len + 16
	result := make([]byte, total, allocator)
	copy(result[:3], len_ct[:])
	copy(result[3:3 + content_len], ct)
	copy(result[3 + content_len:], tag[:])

	return result
}

v2_transport_destroy :: proc(t: ^V2_Transport) {
	if t == nil { return }
	delete(t.recv_buf)
	if t.handshake_to_send != nil {
		delete(t.handshake_to_send)
	}
	if t.recv_aad != nil {
		delete(t.recv_aad)
	}
	mem.zero_explicit(&t.seckey, 32)
	mem.zero_explicit(&t.keys, size_of(BIP324_Keys))
}

// --- Internal helpers ---

_v2_consume_recv :: proc(t: ^V2_Transport, n: int) {
	remaining := len(t.recv_buf) - n
	if remaining > 0 {
		copy(t.recv_buf[:remaining], t.recv_buf[n:])
	}
	resize(&t.recv_buf, remaining)
}

// Decrypt the version packet and discard its contents (per BIP324, version packet contents are ignored).
// The version packet authenticates the garbage via AAD (recv_aad).
_v2_decrypt_version_packet :: proc(t: ^V2_Transport) -> V2_Error {
	if t.pending_length < 0 {
		if len(t.recv_buf) < 3 {
			return .Need_More_Data
		}
		len_ct := t.recv_buf[:3]
		len_plain: [3]byte
		fschacha20_crypt(&t.recv_L, len_plain[:], len_ct[:])
		// Length field encodes payload size WITHOUT the 1-byte header.
		// AEAD ciphertext = header(1) + payload(length) bytes.
		payload_len := int(len_plain[0]) | (int(len_plain[1]) << 8) | (int(len_plain[2]) << 16)
		t.pending_length = payload_len + 1   // +1 for the header byte
		_v2_consume_recv(t, 3)
	}

	needed := t.pending_length + 16
	if len(t.recv_buf) < needed {
		return .Need_More_Data
	}

	content_len := t.pending_length
	ciphertext := t.recv_buf[:content_len]
	tag := t.recv_buf[content_len:content_len + 16]

	plaintext := make([]byte, content_len, context.temp_allocator)
	ok := fschacha20poly1305_open(&t.recv_P, plaintext, t.recv_aad, ciphertext, tag)
	if !ok {
		return .Decryption_Failed
	}

	_v2_consume_recv(t, needed)
	t.pending_length = -1

	// Free garbage AAD now that version packet is authenticated.
	if t.recv_aad != nil {
		delete(t.recv_aad)
		t.recv_aad = nil
	}

	return .None
}

_v2_decrypt_packet :: proc(t: ^V2_Transport, allocator := context.temp_allocator) -> (msg: V2_Decoded_Msg, err: V2_Error) {
	if t.pending_length < 0 {
		if len(t.recv_buf) < 3 {
			return {}, .Need_More_Data
		}
		len_ct := t.recv_buf[:3]
		len_plain: [3]byte
		fschacha20_crypt(&t.recv_L, len_plain[:], len_ct[:])
		// Length field encodes payload size WITHOUT the 1-byte header.
		// AEAD ciphertext = header(1) + payload(length) bytes.
		payload_len := int(len_plain[0]) | (int(len_plain[1]) << 8) | (int(len_plain[2]) << 16)
		t.pending_length = payload_len + 1   // +1 for the header byte
		_v2_consume_recv(t, 3)
	}

	needed := t.pending_length + 16
	if len(t.recv_buf) < needed {
		return {}, .Need_More_Data
	}

	content_len := t.pending_length
	ciphertext := t.recv_buf[:content_len]
	tag := t.recv_buf[content_len:content_len + 16]

	plaintext := make([]byte, content_len, allocator)
	ok := fschacha20poly1305_open(&t.recv_P, plaintext, nil, ciphertext, tag)
	if !ok {
		return {}, .Decryption_Failed
	}

	_v2_consume_recv(t, needed)
	t.pending_length = -1

	if content_len == 0 {
		return V2_Decoded_Msg{}, .None
	}

	command, payload, ignore, decode_ok := bip324_decode_message_content(plaintext)
	if !decode_ok {
		return {}, .Invalid_Message
	}

	if ignore {
		return V2_Decoded_Msg{}, .None
	}

	return V2_Decoded_Msg{command = command, payload = payload}, .None
}
