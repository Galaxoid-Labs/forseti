package p2p

import "core:crypto/chacha20"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:encoding/endian"

import crypto "../crypto"

// BIP324 derived session keys.
BIP324_Keys :: struct {
	send_L_key:        [32]byte, // FSChaCha20 key for outbound length encryption
	send_P_key:        [32]byte, // FSChaCha20Poly1305 key for outbound packet encryption
	recv_L_key:        [32]byte, // FSChaCha20 key for inbound length decryption
	recv_P_key:        [32]byte, // FSChaCha20Poly1305 key for inbound packet decryption
	send_garbage_term: [16]byte, // Our garbage terminator (we send this)
	recv_garbage_term: [16]byte, // Peer's garbage terminator (we scan for this)
	session_id:        [32]byte, // Session ID
}

// Derive BIP324 session keys from ECDH shared secret.
// salt = "bitcoin_v2_shared_secret" || network_magic (per BIP324 spec).
bip324_derive_keys :: proc(shared_secret: [32]u8, initiating: bool, network_magic: u32) -> BIP324_Keys {
	keys: BIP324_Keys

	// salt = "bitcoin_v2_shared_secret" || LE32(network_magic)
	SALT_PREFIX :: "bitcoin_v2_shared_secret"
	salt: [len(SALT_PREFIX) + 4]byte
	copy(salt[:len(SALT_PREFIX)], SALT_PREFIX)
	salt[len(SALT_PREFIX) + 0] = byte(network_magic)
	salt[len(SALT_PREFIX) + 1] = byte(network_magic >> 8)
	salt[len(SALT_PREFIX) + 2] = byte(network_magic >> 16)
	salt[len(SALT_PREFIX) + 3] = byte(network_magic >> 24)

	// PRK = HKDF-Extract(salt, ikm=shared_secret)
	prk: [32]byte
	ss := shared_secret
	hkdf.extract(.SHA256, salt[:], ss[:], prk[:])

	// Expand with info strings.
	init_L: [32]byte
	init_P: [32]byte
	resp_L: [32]byte
	resp_P: [32]byte
	garbage: [32]byte
	session_id: [32]byte

	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("initiator_L"), init_L[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("initiator_P"), init_P[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("responder_L"), resp_L[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("responder_P"), resp_P[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("garbage_terminators"), garbage[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string("session_id"), session_id[:])

	keys.session_id = session_id

	if initiating {
		keys.send_L_key = init_L
		keys.send_P_key = init_P
		keys.recv_L_key = resp_L
		keys.recv_P_key = resp_P
		copy(keys.send_garbage_term[:], garbage[:16])
		copy(keys.recv_garbage_term[:], garbage[16:])
	} else {
		keys.send_L_key = resp_L
		keys.send_P_key = resp_P
		keys.recv_L_key = init_L
		keys.recv_P_key = init_P
		copy(keys.send_garbage_term[:], garbage[16:])
		copy(keys.recv_garbage_term[:], garbage[:16])
	}

	return keys
}

// --- FSChaCha20 (length encryption) ---

REKEY_INTERVAL :: u64(1 << 24) // 16777216

FSChaCha20 :: struct {
	cc:            chacha20.Context,
	chunk_counter: u32,
	rekey_counter: u64,
}

fschacha20_init :: proc(ctx: ^FSChaCha20, key: [32]byte) {
	k := key
	nonce: [12]byte // all zeros initially
	chacha20.init(&ctx.cc, k[:], nonce[:])
	ctx.chunk_counter = 0
	ctx.rekey_counter = 0
}

// FSChaCha20 uses a continuous ChaCha20 stream — each call consumes the next
// bytes of keystream (not a per-message nonce like FSChaCha20Poly1305).
fschacha20_crypt :: proc(ctx: ^FSChaCha20, dst, src: []byte) {
	chacha20.xor_bytes(&ctx.cc, dst, src)
	ctx.chunk_counter += 1
	if u64(ctx.chunk_counter) == REKEY_INTERVAL {
		_fschacha20_rekey(ctx)
	}
}

_fschacha20_rekey :: proc(ctx: ^FSChaCha20) {
	// Read 32 bytes of keystream from current position as new key.
	new_key: [32]byte
	chacha20.keystream_bytes(&ctx.cc, new_key[:])
	// Re-init with new key and nonce = LE32(0) || LE64(++rekey_counter).
	ctx.rekey_counter += 1
	nonce: [12]byte
	endian.unchecked_put_u64le(nonce[4:], ctx.rekey_counter)
	chacha20.init(&ctx.cc, new_key[:], nonce[:])
	ctx.chunk_counter = 0
}

// --- FSChaCha20Poly1305 (packet AEAD) ---

FSChaCha20Poly1305 :: struct {
	key:     [32]byte,
	counter: u64,
}

fschacha20poly1305_init :: proc(ctx: ^FSChaCha20Poly1305, key: [32]byte) {
	ctx.key = key
	ctx.counter = 0
}

fschacha20poly1305_seal :: proc(ctx: ^FSChaCha20Poly1305, dst, tag, aad, plaintext: []byte) {
	nonce: [12]byte
	block_counter := ctx.counter % REKEY_INTERVAL
	rekey_counter := ctx.counter / REKEY_INTERVAL
	endian.unchecked_put_u32le(nonce[:4], u32(block_counter))
	endian.unchecked_put_u64le(nonce[4:], rekey_counter)

	aead_ctx: chacha20poly1305.Context
	chacha20poly1305.init(&aead_ctx, ctx.key[:])
	chacha20poly1305.seal(&aead_ctx, dst, tag, nonce[:], aad, plaintext)
	chacha20poly1305.reset(&aead_ctx)

	ctx.counter += 1

	if ctx.counter % REKEY_INTERVAL == 0 {
		_fschacha20poly1305_rekey(ctx)
	}
}

fschacha20poly1305_open :: proc(ctx: ^FSChaCha20Poly1305, dst, aad, ciphertext, tag: []byte) -> bool {
	nonce: [12]byte
	block_counter := ctx.counter % REKEY_INTERVAL
	rekey_counter := ctx.counter / REKEY_INTERVAL
	endian.unchecked_put_u32le(nonce[:4], u32(block_counter))
	endian.unchecked_put_u64le(nonce[4:], rekey_counter)

	aead_ctx: chacha20poly1305.Context
	chacha20poly1305.init(&aead_ctx, ctx.key[:])
	ok := chacha20poly1305.open(&aead_ctx, dst, nonce[:], aad, ciphertext, tag)
	chacha20poly1305.reset(&aead_ctx)

	ctx.counter += 1

	if ctx.counter % REKEY_INTERVAL == 0 {
		_fschacha20poly1305_rekey(ctx)
	}

	return ok
}

_fschacha20poly1305_rekey :: proc(ctx: ^FSChaCha20Poly1305) {
	// Nonce = LE32(0) || LE64(rekey_counter) — chunk part is 0 after rekey.
	rekey_counter := ctx.counter / REKEY_INTERVAL
	nonce: [12]byte
	endian.unchecked_put_u64le(nonce[4:], rekey_counter)

	cc: chacha20.Context
	chacha20.init(&cc, ctx.key[:], nonce[:])
	new_key: [32]byte
	chacha20.keystream_bytes(&cc, new_key[:])
	chacha20.reset(&cc)

	ctx.key = new_key
}

// --- BIP324 Short Command IDs ---

V2_SHORT_COMMANDS := [28]string{
	"addr", "block", "blocktxn", "cmpctblock", "feefilter",
	"filteradd", "filterclear", "filterload", "getblocks", "getblocktxn",
	"getdata", "getheaders", "headers", "inv", "mempool",
	"merkleblock", "notfound", "ping", "pong", "sendcmpct",
	"tx", "getcfilters", "cfilter", "getcfheaders", "cfheaders",
	"getcfcheckpt", "cfcheckpt", "addrv2",
}

bip324_command_to_short_id :: proc(cmd: string) -> (id: u8, ok: bool) {
	for i in 0 ..< 28 {
		if V2_SHORT_COMMANDS[i] == cmd {
			return u8(i + 1), true
		}
	}
	return 0, false
}

bip324_short_id_to_command :: proc(id: u8) -> (cmd: string, ok: bool) {
	if id < 1 || id > 28 {
		return "", false
	}
	return V2_SHORT_COMMANDS[id - 1], true
}

// --- V2 Message Content Encoding ---

// Encode command + payload into BIP324 AEAD plaintext: header_byte || contents.
// header_byte = 0x00 (ignore=false). Contents starts with message type ID.
// Short commands: contents = [short_id, payload...]
// Long commands:  contents = [0x00, 12-byte-cmd, payload...]
bip324_encode_message_content :: proc(command: string, payload: []byte, allocator := context.allocator) -> []byte {
	short_id, has_short := bip324_command_to_short_id(command)

	content_len: int
	if has_short {
		content_len = 1 + 1 + len(payload) // header + short_id + payload
	} else {
		content_len = 1 + 1 + 12 + len(payload) // header + 0x00 + 12-byte cmd + payload
	}

	content := make([]byte, content_len, allocator)
	content[0] = 0 // header byte: ignore=false

	if has_short {
		content[1] = short_id
		if len(payload) > 0 {
			copy(content[2:], payload)
		}
	} else {
		content[1] = 0 // message type ID 0 = long encoding
		cmd_bytes := transmute([]byte)command
		cmd_len := min(len(cmd_bytes), 12)
		copy(content[2:2 + cmd_len], cmd_bytes[:cmd_len])
		if len(payload) > 0 {
			copy(content[14:], payload)
		}
	}

	return content
}

// Decode BIP324 AEAD plaintext: header_byte || contents.
// header_byte bit 7 = ignore flag. contents[0] = message type ID.
bip324_decode_message_content :: proc(content: []byte) -> (command: string, payload: []byte, ignore: bool, ok: bool) {
	if len(content) < 1 {
		return "", nil, false, false
	}

	header := content[0]
	ignore_flag := (header & 0x80) != 0

	if len(content) < 2 {
		// Empty contents (just header) — only valid as decoy/ignore packet.
		return "", nil, ignore_flag, ignore_flag
	}

	msg_type_id := content[1]

	if msg_type_id != 0 {
		// Short command — look up in table
		cmd, found := bip324_short_id_to_command(msg_type_id)
		if !found {
			return "", nil, false, false
		}
		return cmd, content[2:], ignore_flag, true
	}

	// Long command — next 12 bytes are null-padded ASCII command
	if len(content) < 14 {
		return "", nil, false, false
	}

	cmd_bytes := content[2:14]
	cmd_len := 0
	for i in 0 ..< 12 {
		if cmd_bytes[i] == 0 {
			break
		}
		cmd_len = i + 1
	}

	return string(cmd_bytes[:cmd_len]), content[14:], ignore_flag, true
}
