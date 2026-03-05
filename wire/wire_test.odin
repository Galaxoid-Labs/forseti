package wire

import crypto "../crypto"
import "core:encoding/hex"
import "core:testing"

// --- Helpers ---

hex_decode :: proc(s: string) -> []u8 {
	bytes, _ := hex.decode(transmute([]u8)s, context.temp_allocator)
	return bytes
}

hex_encode :: proc(data: []u8) -> string {
	return string(hex.encode(data, context.temp_allocator))
}

hash_to_hex :: proc(h: Hash256) -> string {
	h := h
	return hex_encode(h[:])
}

// --- CompactSize tests ---

@(test)
test_compact_size_single_byte :: proc(t: ^testing.T) {
	// Values 0..0xFC encode as a single byte.
	for val in ([]u64{0, 1, 0xFC}) {
		buf, size := compact_size_encode(val)
		testing.expect_value(t, size, 1)
		testing.expect_value(t, buf[0], u8(val))

		// Round-trip
		decoded, dsize, err := compact_size_decode(buf[:size])
		testing.expect(t, err == nil, "decode should succeed")
		testing.expect_value(t, decoded, val)
		testing.expect_value(t, dsize, size)
	}
}

@(test)
test_compact_size_two_byte :: proc(t: ^testing.T) {
	// 0xFD..0xFFFF use 0xFD prefix + 2 bytes LE
	for val in ([]u64{0xFD, 0xFE, 0xFF, 0x100, 0xFFFF}) {
		buf, size := compact_size_encode(val)
		testing.expect_value(t, size, 3)
		testing.expect_value(t, buf[0], u8(0xFD))

		decoded, dsize, err := compact_size_decode(buf[:size])
		testing.expect(t, err == nil, "decode should succeed")
		testing.expect_value(t, decoded, val)
		testing.expect_value(t, dsize, 3)
	}
}

@(test)
test_compact_size_four_byte :: proc(t: ^testing.T) {
	for val in ([]u64{0x10000, 0xFFFF_FFFF}) {
		buf, size := compact_size_encode(val)
		testing.expect_value(t, size, 5)
		testing.expect_value(t, buf[0], u8(0xFE))

		decoded, dsize, err := compact_size_decode(buf[:size])
		testing.expect(t, err == nil, "decode should succeed")
		testing.expect_value(t, decoded, val)
		testing.expect_value(t, dsize, 5)
	}
}

@(test)
test_compact_size_eight_byte :: proc(t: ^testing.T) {
	val: u64 = 0x1_0000_0000
	buf, size := compact_size_encode(val)
	testing.expect_value(t, size, 9)
	testing.expect_value(t, buf[0], u8(0xFF))

	decoded, dsize, err := compact_size_decode(buf[:size])
	testing.expect(t, err == nil, "decode should succeed")
	testing.expect_value(t, decoded, val)
	testing.expect_value(t, dsize, 9)
}

@(test)
test_compact_size_non_canonical_rejected :: proc(t: ^testing.T) {
	// 0xFD prefix but value < 0xFD (non-canonical)
	bad1 := [?]u8{0xFD, 0x00, 0x00}
	_, _, err1 := compact_size_decode(bad1[:])
	testing.expect_value(t, err1, Wire_Error.Non_Canonical_Compact_Size)

	// 0xFE prefix but value fits in 2 bytes
	bad2 := [?]u8{0xFE, 0xFF, 0x00, 0x00, 0x00}
	_, _, err2 := compact_size_decode(bad2[:])
	testing.expect_value(t, err2, Wire_Error.Non_Canonical_Compact_Size)

	// 0xFF prefix but value fits in 4 bytes
	bad3 := [?]u8{0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00}
	_, _, err3 := compact_size_decode(bad3[:])
	testing.expect_value(t, err3, Wire_Error.Non_Canonical_Compact_Size)
}

@(test)
test_compact_size_truncated :: proc(t: ^testing.T) {
	// Empty input
	_, _, err1 := compact_size_decode(nil)
	testing.expect_value(t, err1, Wire_Error.Unexpected_EOF)

	// 0xFD but only 2 bytes total
	bad := [?]u8{0xFD, 0xFF}
	_, _, err2 := compact_size_decode(bad[:])
	testing.expect_value(t, err2, Wire_Error.Unexpected_EOF)
}

@(test)
test_compact_size_length :: proc(t: ^testing.T) {
	testing.expect_value(t, compact_size_length(0), 1)
	testing.expect_value(t, compact_size_length(0xFC), 1)
	testing.expect_value(t, compact_size_length(0xFD), 3)
	testing.expect_value(t, compact_size_length(0xFFFF), 3)
	testing.expect_value(t, compact_size_length(0x10000), 5)
	testing.expect_value(t, compact_size_length(0xFFFF_FFFF), 5)
	testing.expect_value(t, compact_size_length(0x1_0000_0000), 9)
}

// --- Wire_Reader / Wire_Writer primitive tests ---

@(test)
test_reader_writer_u32 :: proc(t: ^testing.T) {
	w := writer_init(context.temp_allocator)
	write_u32le(&w, 0xDEADBEEF)
	write_u32le(&w, 0x01020304)

	r := reader_init(writer_bytes(&w))
	v1, e1 := read_u32le(&r)
	testing.expect(t, e1 == nil, "read should succeed")
	testing.expect_value(t, v1, u32(0xDEADBEEF))

	v2, e2 := read_u32le(&r)
	testing.expect(t, e2 == nil, "read should succeed")
	testing.expect_value(t, v2, u32(0x01020304))

	// Should be at end
	testing.expect_value(t, reader_remaining(&r), 0)
}

@(test)
test_reader_writer_i64 :: proc(t: ^testing.T) {
	w := writer_init(context.temp_allocator)
	write_i64le(&w, -1)
	write_i64le(&w, 50_000_000_00) // 50 BTC in satoshis

	r := reader_init(writer_bytes(&w))
	v1, e1 := read_i64le(&r)
	testing.expect(t, e1 == nil, "read should succeed")
	testing.expect_value(t, v1, i64(-1))

	v2, e2 := read_i64le(&r)
	testing.expect(t, e2 == nil, "read should succeed")
	testing.expect_value(t, v2, i64(50_000_000_00))
}

@(test)
test_reader_eof :: proc(t: ^testing.T) {
	data := [?]u8{0x01, 0x02}
	r := reader_init(data[:])
	_, e1 := read_u32le(&r)
	testing.expect_value(t, e1, Wire_Error.Unexpected_EOF)
}

// --- Block header tests ---

@(test)
test_block_header_serialize_roundtrip :: proc(t: ^testing.T) {
	hdr := Block_Header {
		version     = 1,
		prev_hash   = HASH_ZERO,
		merkle_root = HASH_ZERO,
		timestamp   = 1231006505,
		bits        = 0x1d00ffff,
		nonce       = 2083236893,
	}

	w := writer_init(context.temp_allocator)
	serialize_block_header(&w, &hdr)
	testing.expect_value(t, writer_len(&w), BLOCK_HEADER_SIZE)

	r := reader_init(writer_bytes(&w))
	hdr2, err := deserialize_block_header(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, hdr2.version, hdr.version)
	testing.expect_value(t, hdr2.timestamp, hdr.timestamp)
	testing.expect_value(t, hdr2.bits, hdr.bits)
	testing.expect_value(t, hdr2.nonce, hdr.nonce)
}

@(test)
test_genesis_block_header_hash :: proc(t: ^testing.T) {
	// Mainnet genesis block header (80 bytes)
	header_hex :=
		"01000000" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" +
		"29ab5f49" +
		"ffff001d" +
		"1dac2b7c"

	data := hex_decode(header_hex)
	testing.expect_value(t, len(data), BLOCK_HEADER_SIZE)

	r := reader_init(data)
	hdr, err := deserialize_block_header(&r)
	testing.expect(t, err == nil, "deserialize should succeed")

	// Verify parsed fields
	testing.expect_value(t, hdr.version, i32(1))
	testing.expect_value(t, hdr.timestamp, u32(1231006505))
	testing.expect_value(t, hdr.bits, u32(0x1d00ffff))
	testing.expect_value(t, hdr.nonce, u32(2083236893))

	// Compute hash and compare (displayed reversed)
	hash := block_header_hash(&hdr)
	display := crypto.hash_to_display(hash)
	got := hash_to_hex(display)
	testing.expect_value(t, got, "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
}

@(test)
test_testnet3_genesis_header_hash :: proc(t: ^testing.T) {
	// Testnet3 genesis block header
	header_hex :=
		"01000000" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" +
		"dae5494d" +
		"ffff001d" +
		"1aa4ae18"

	data := hex_decode(header_hex)
	r := reader_init(data)
	hdr, err := deserialize_block_header(&r)
	testing.expect(t, err == nil, "deserialize should succeed")

	hash := block_header_hash(&hdr)
	display := crypto.hash_to_display(hash)
	got := hash_to_hex(display)
	testing.expect_value(t, got, "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943")
}

// --- Transaction tests ---

@(test)
test_coinbase_tx_deserialize :: proc(t: ^testing.T) {
	// Mainnet genesis block coinbase transaction
	// (pre-SegWit, version=1, 1 input, 1 output)
	tx_hex :=
		"01000000" + // version
		"01" + // 1 input
		"0000000000000000000000000000000000000000000000000000000000000000" + // prev txid (null)
		"ffffffff" + // prev vout (0xFFFFFFFF for coinbase)
		"4d" + // script_sig length (77 bytes)
		"04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73" +
		"ffffffff" + // sequence
		"01" + // 1 output
		"00f2052a01000000" + // 50 BTC in satoshis (5000000000)
		"43" + // script_pubkey length (67 bytes)
		"4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac" +
		"00000000" // locktime

	data := hex_decode(tx_hex)
	r := reader_init(data)
	tx, err := deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")

	testing.expect_value(t, tx.version, i32(1))
	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 1)
	testing.expect_value(t, tx.locktime, u32(0))

	// Coinbase input: prev txid is all zeros, prev vout is 0xFFFFFFFF
	testing.expect_value(t, tx.inputs[0].previous_output.hash, HASH_ZERO)
	testing.expect_value(t, tx.inputs[0].previous_output.index, u32(0xFFFFFFFF))
	testing.expect_value(t, tx.inputs[0].sequence, u32(0xFFFFFFFF))

	// Output value: 50 BTC = 5,000,000,000 satoshis
	testing.expect_value(t, tx.outputs[0].value, i64(5_000_000_000))

	// Script sig should be 77 bytes
	testing.expect_value(t, len(tx.inputs[0].script_sig), 77)

	// Script pubkey should be 67 bytes
	testing.expect_value(t, len(tx.outputs[0].script_pubkey), 67)

	// No witness data
	testing.expect(t, !tx_has_witness(&tx), "genesis coinbase should have no witness")
}

@(test)
test_tx_serialize_roundtrip :: proc(t: ^testing.T) {
	// Genesis coinbase tx hex
	tx_hex :=
		"01000000" +
		"01" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"ffffffff" +
		"4d" +
		"04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73" +
		"ffffffff" +
		"01" +
		"00f2052a01000000" +
		"43" +
		"4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac" +
		"00000000"

	original := hex_decode(tx_hex)

	// Deserialize
	r := reader_init(original)
	tx, err := deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")

	// Re-serialize
	w := writer_init(context.temp_allocator)
	serialize_tx(&w, &tx)

	// Compare bytes
	reserialized := writer_bytes(&w)
	testing.expect_value(t, len(reserialized), len(original))
	for i in 0 ..< len(original) {
		testing.expectf(t, reserialized[i] == original[i], "byte mismatch at %d: got 0x%02x, want 0x%02x", i, reserialized[i], original[i])
	}
}

// --- Message header tests ---

@(test)
test_message_header_roundtrip :: proc(t: ^testing.T) {
	payload := []byte{0x01, 0x02, 0x03}

	hdr := Message_Header {
		magic        = MAINNET_MAGIC,
		command      = command_to_bytes(CMD_VERSION),
		payload_size = u32(len(payload)),
		checksum     = compute_checksum(payload),
	}

	w := writer_init(context.temp_allocator)
	serialize_message_header(&w, &hdr)
	testing.expect_value(t, writer_len(&w), MESSAGE_HEADER_SIZE)

	r := reader_init(writer_bytes(&w))
	hdr2, err := deserialize_message_header(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, hdr2.magic, MAINNET_MAGIC)
	testing.expect_value(t, hdr2.payload_size, u32(3))
	testing.expect_value(t, hdr2.checksum, hdr.checksum)

	cmd := command_from_bytes(hdr2.command)
	testing.expect_value(t, cmd, CMD_VERSION)
}

@(test)
test_command_bytes_roundtrip :: proc(t: ^testing.T) {
	cmds := []string{CMD_VERSION, CMD_VERACK, CMD_PING, CMD_GETHEADERS, CMD_TX}
	for cmd in cmds {
		bytes := command_to_bytes(cmd)
		back := command_from_bytes(bytes)
		testing.expect_value(t, back, cmd)
	}
}

@(test)
test_checksum :: proc(t: ^testing.T) {
	// Empty payload checksum = first 4 bytes of sha256d("")
	cs := compute_checksum(nil)
	expected := hex_decode("5df6e0e2")
	testing.expect_value(t, cs[0], expected[0])
	testing.expect_value(t, cs[1], expected[1])
	testing.expect_value(t, cs[2], expected[2])
	testing.expect_value(t, cs[3], expected[3])
}

@(test)
test_validate_checksum :: proc(t: ^testing.T) {
	payload := transmute([]byte)string("test payload")
	hdr := Message_Header {
		checksum = compute_checksum(payload),
	}
	testing.expect(t, validate_checksum(&hdr, payload), "valid checksum should pass")

	bad_payload := transmute([]byte)string("wrong payload")
	testing.expect(t, !validate_checksum(&hdr, bad_payload), "wrong payload should fail")
}

// --- Version message test ---

@(test)
test_version_message_roundtrip :: proc(t: ^testing.T) {
	msg := Version_Message {
		version      = 70016,
		services     = 1,
		timestamp    = 1234567890,
		nonce        = 0xDEADBEEFCAFEBABE,
		user_agent   = NODE_USER_AGENT,
		start_height = 100000,
		relay        = true,
	}

	w := writer_init(context.temp_allocator)
	serialize_version(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_version(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")

	testing.expect_value(t, msg2.version, msg.version)
	testing.expect_value(t, msg2.services, msg.services)
	testing.expect_value(t, msg2.timestamp, msg.timestamp)
	testing.expect_value(t, msg2.nonce, msg.nonce)
	testing.expect_value(t, msg2.user_agent, msg.user_agent)
	testing.expect_value(t, msg2.start_height, msg.start_height)
	testing.expect_value(t, msg2.relay, msg.relay)
}

// --- Ping/Pong test ---

@(test)
test_ping_pong_roundtrip :: proc(t: ^testing.T) {
	ping := Ping_Message{nonce = 0x1234567890ABCDEF}

	w := writer_init(context.temp_allocator)
	serialize_ping(&w, &ping)
	testing.expect_value(t, writer_len(&w), 8)

	r := reader_init(writer_bytes(&w))
	ping2, err := deserialize_ping(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, ping2.nonce, ping.nonce)
}

// --- Inv message test ---

@(test)
test_inv_message_roundtrip :: proc(t: ^testing.T) {
	h1, h2: Hash256
	h1[0] = 0xAA
	h2[0] = 0xBB

	msg := Inv_Message {
		inventory = []Inv_Vector{
			{type = .Tx, hash = h1},
			{type = .Block, hash = h2},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_inv(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_inv(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, len(msg2.inventory), 2)
	testing.expect_value(t, msg2.inventory[0].type, Inv_Type.Tx)
	testing.expect_value(t, msg2.inventory[0].hash[0], u8(0xAA))
	testing.expect_value(t, msg2.inventory[1].type, Inv_Type.Block)
	testing.expect_value(t, msg2.inventory[1].hash[0], u8(0xBB))
}

// --- Net address test ---

@(test)
test_net_address_port_encoding :: proc(t: ^testing.T) {
	// Port should be big-endian on wire
	addr := Net_Address {
		services = 1,
		port     = 8333, // 0x208D
	}
	// IPv4-mapped IPv6 for 127.0.0.1
	addr.ip[10] = 0xFF
	addr.ip[11] = 0xFF
	addr.ip[12] = 127
	addr.ip[13] = 0
	addr.ip[14] = 0
	addr.ip[15] = 1

	w := writer_init(context.temp_allocator)
	serialize_net_address(&w, &addr)

	r := reader_init(writer_bytes(&w))
	addr2, err := deserialize_net_address(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, addr2.services, u64(1))
	testing.expect_value(t, addr2.port, u16(8333))
	testing.expect_value(t, addr2.ip[12], u8(127))
	testing.expect_value(t, addr2.ip[15], u8(1))
}

// --- Headers message test ---

@(test)
test_headers_message_roundtrip :: proc(t: ^testing.T) {
	msg := Headers_Message {
		headers = []Block_Header{
			{version = 1, timestamp = 100, bits = 0x1d00ffff, nonce = 42},
			{version = 2, timestamp = 200, bits = 0x1d00ffff, nonce = 99},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_headers(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_headers(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, len(msg2.headers), 2)
	testing.expect_value(t, msg2.headers[0].version, i32(1))
	testing.expect_value(t, msg2.headers[0].nonce, u32(42))
	testing.expect_value(t, msg2.headers[1].version, i32(2))
	testing.expect_value(t, msg2.headers[1].nonce, u32(99))
}

// --- Pong message test ---

@(test)
test_pong_roundtrip :: proc(t: ^testing.T) {
	pong := Pong_Message{nonce = 0xFEDCBA9876543210}

	w := writer_init(context.temp_allocator)
	serialize_pong(&w, &pong)
	testing.expect_value(t, writer_len(&w), 8)

	r := reader_init(writer_bytes(&w))
	pong2, err := deserialize_pong(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, pong2.nonce, pong.nonce)
}

// --- GetData message test ---

@(test)
test_getdata_roundtrip :: proc(t: ^testing.T) {
	h1, h2: Hash256
	h1[0] = 0xCC
	h2[0] = 0xDD

	msg := Get_Data_Message {
		inventory = []Inv_Vector{
			{type = .Witness_Block, hash = h1},
			{type = .Witness_Tx, hash = h2},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_getdata(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_getdata(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, len(msg2.inventory), 2)
	testing.expect_value(t, msg2.inventory[0].type, Inv_Type.Witness_Block)
	testing.expect_value(t, msg2.inventory[0].hash[0], u8(0xCC))
	testing.expect_value(t, msg2.inventory[1].type, Inv_Type.Witness_Tx)
	testing.expect_value(t, msg2.inventory[1].hash[0], u8(0xDD))
}

// --- GetHeaders message test ---

@(test)
test_getheaders_roundtrip :: proc(t: ^testing.T) {
	h1, h2, stop: Hash256
	h1[0] = 0x11
	h2[0] = 0x22
	stop[0] = 0xFF

	msg := Get_Headers_Message {
		version      = u32(PROTOCOL_VERSION),
		block_hashes = []Hash256{h1, h2},
		hash_stop    = stop,
	}

	w := writer_init(context.temp_allocator)
	serialize_getheaders(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_getheaders(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.version, u32(PROTOCOL_VERSION))
	testing.expect_value(t, len(msg2.block_hashes), 2)
	testing.expect_value(t, msg2.block_hashes[0][0], u8(0x11))
	testing.expect_value(t, msg2.block_hashes[1][0], u8(0x22))
	testing.expect_value(t, msg2.hash_stop[0], u8(0xFF))
}

// --- Transaction ID computation test ---

@(test)
test_tx_id_computation :: proc(t: ^testing.T) {
	// Genesis coinbase tx — known txid
	tx_hex :=
		"01000000" +
		"01" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"ffffffff" +
		"4d" +
		"04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73" +
		"ffffffff" +
		"01" +
		"00f2052a01000000" +
		"43" +
		"4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac" +
		"00000000"

	original := hex_decode(tx_hex)
	r := reader_init(original)
	tx, err := deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")

	txid := tx_id(&tx)
	// Genesis coinbase txid (internal byte order)
	display := crypto.hash_to_display(txid)
	got := hash_to_hex(display)
	testing.expect_value(t, got, "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")
}

// --- Block serialize/deserialize roundtrip ---

@(test)
test_block_serialize_roundtrip :: proc(t: ^testing.T) {
	// Build a minimal block with one coinbase tx
	cb_inputs := make([]Tx_In, 1, context.temp_allocator)
	cb_inputs[0] = Tx_In {
		previous_output = Outpoint{hash = HASH_ZERO, index = 0xffffffff},
		script_sig = hex_decode("04ffff001d0101"),
		sequence = 0xffffffff,
	}
	cb_outputs := make([]Tx_Out, 1, context.temp_allocator)
	cb_outputs[0] = Tx_Out {
		value = 50_0000_0000,
		script_pubkey = hex_decode("76a914000000000000000000000000000000000000000088ac"),
	}

	txs := make([]Tx, 1, context.temp_allocator)
	txs[0] = Tx{version = 1, inputs = cb_inputs, outputs = cb_outputs, locktime = 0}

	block := Block {
		header = Block_Header{
			version = 1,
			timestamp = 1231006505,
			bits = 0x1d00ffff,
			nonce = 2083236893,
		},
		txs = txs,
	}

	w := writer_init(context.temp_allocator)
	serialize_block(&w, &block)
	data := writer_bytes(&w)
	testing.expect(t, len(data) > 80, "block should be larger than just the header")

	r := reader_init(data)
	block2, err := deserialize_block(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, block2.header.version, i32(1))
	testing.expect_value(t, block2.header.nonce, u32(2083236893))
	testing.expect_value(t, len(block2.txs), 1)
	testing.expect_value(t, block2.txs[0].outputs[0].value, i64(50_0000_0000))
}

// --- Build message test ---

@(test)
test_build_message :: proc(t: ^testing.T) {
	payload := transmute([]byte)string("test")
	msg := build_message(MAINNET_MAGIC, CMD_PING, payload)
	defer delete(msg)

	testing.expect(t, len(msg) == MESSAGE_HEADER_SIZE + len(payload), "message size should be header + payload")

	// Parse back the header
	r := reader_init(msg)
	hdr, err := deserialize_message_header(&r)
	testing.expect(t, err == nil, "header should parse")
	testing.expect_value(t, hdr.magic, MAINNET_MAGIC)
	testing.expect_value(t, hdr.payload_size, u32(len(payload)))
	testing.expect(t, validate_checksum(&hdr, msg[MESSAGE_HEADER_SIZE:]), "checksum should match")

	cmd := command_from_bytes(hdr.command)
	testing.expect_value(t, cmd, CMD_PING)
}

// --- BIP152 Compact Block message tests ---

@(test)
test_compact_block_roundtrip :: proc(t: ^testing.T) {
	// Build a compact block with header, nonce, 2 shortids, 1 prefilled tx (coinbase at idx 0).
	cb_inputs := make([]Tx_In, 1, context.temp_allocator)
	cb_inputs[0] = Tx_In{
		previous_output = Outpoint{hash = HASH_ZERO, index = 0xffffffff},
		script_sig = hex_decode("04ffff001d0101"),
		sequence = 0xffffffff,
	}
	cb_outputs := make([]Tx_Out, 1, context.temp_allocator)
	cb_outputs[0] = Tx_Out{value = 50_0000_0000, script_pubkey = hex_decode("6a")}

	msg := Compact_Block_Message{
		header = Block_Header{version = 1, timestamp = 1000, bits = 0x1d00ffff, nonce = 7},
		nonce = 0xDEADBEEF,
		shortids = []u64{0x112233445566, 0xAABBCCDDEEFF},
		prefilled_txs = []Prefilled_Tx{
			{index = 0, tx = Tx{version = 1, inputs = cb_inputs, outputs = cb_outputs, locktime = 0}},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_compact_block(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_compact_block(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.header.version, i32(1))
	testing.expect_value(t, msg2.nonce, u64(0xDEADBEEF))
	testing.expect_value(t, len(msg2.shortids), 2)
	testing.expect_value(t, msg2.shortids[0], u64(0x112233445566))
	testing.expect_value(t, msg2.shortids[1], u64(0xAABBCCDDEEFF))
	testing.expect_value(t, len(msg2.prefilled_txs), 1)
	testing.expect_value(t, msg2.prefilled_txs[0].index, u64(0))
	testing.expect_value(t, msg2.prefilled_txs[0].tx.outputs[0].value, i64(50_0000_0000))
}

@(test)
test_get_block_txn_roundtrip :: proc(t: ^testing.T) {
	block_hash: Hash256
	block_hash[0] = 0xAB
	block_hash[31] = 0xCD

	// Indices 1, 3, 5 — differential encoding: 1, 1, 1 (absolute diffs: 1, 3-1-1=1, 5-3-1=1).
	msg := Get_Block_Txn_Message{
		block_hash = block_hash,
		indices = []u64{1, 3, 5},
	}

	w := writer_init(context.temp_allocator)
	serialize_get_block_txn(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_get_block_txn(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.block_hash[0], u8(0xAB))
	testing.expect_value(t, msg2.block_hash[31], u8(0xCD))
	testing.expect_value(t, len(msg2.indices), 3)
	testing.expect_value(t, msg2.indices[0], u64(1))
	testing.expect_value(t, msg2.indices[1], u64(3))
	testing.expect_value(t, msg2.indices[2], u64(5))
}

@(test)
test_block_txn_roundtrip :: proc(t: ^testing.T) {
	block_hash: Hash256
	block_hash[0] = 0xEE

	inputs := make([]Tx_In, 1, context.temp_allocator)
	inputs[0] = Tx_In{
		previous_output = Outpoint{hash = HASH_ZERO, index = 0},
		script_sig = hex_decode("00"),
		sequence = 0xffffffff,
	}
	outputs := make([]Tx_Out, 1, context.temp_allocator)
	outputs[0] = Tx_Out{value = 1000, script_pubkey = hex_decode("6a")}

	msg := Block_Txn_Message{
		block_hash = block_hash,
		txs = []Tx{
			{version = 2, inputs = inputs, outputs = outputs, locktime = 0},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_block_txn(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_block_txn(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.block_hash[0], u8(0xEE))
	testing.expect_value(t, len(msg2.txs), 1)
	testing.expect_value(t, msg2.txs[0].version, i32(2))
	testing.expect_value(t, msg2.txs[0].outputs[0].value, i64(1000))
}

// --- BIP152 Compact block creation tests ---

@(test)
test_compact_block_sipkeys :: proc(t: ^testing.T) {
	// Verify compact_block_sipkeys matches manual key derivation.
	block_hash: Hash256
	block_hash[0] = 0x42
	block_hash[31] = 0xFF
	nonce: u64 = 0xDEADBEEFCAFE

	k0, k1 := crypto.compact_block_sipkeys(block_hash, nonce)

	// Manual computation: SHA256(block_hash || nonce_le) -> k0, k1
	buf: [40]byte
	copy(buf[:32], block_hash[:])
	buf[32] = u8(nonce)
	buf[33] = u8(nonce >> 8)
	buf[34] = u8(nonce >> 16)
	buf[35] = u8(nonce >> 24)
	buf[36] = u8(nonce >> 32)
	buf[37] = u8(nonce >> 40)
	buf[38] = u8(nonce >> 48)
	buf[39] = u8(nonce >> 56)
	h := crypto.sha256_hash(buf[:])

	expected_k0 := u64(h[0]) | u64(h[1])<<8 | u64(h[2])<<16 | u64(h[3])<<24 |
		u64(h[4])<<32 | u64(h[5])<<40 | u64(h[6])<<48 | u64(h[7])<<56
	expected_k1 := u64(h[8]) | u64(h[9])<<8 | u64(h[10])<<16 | u64(h[11])<<24 |
		u64(h[12])<<32 | u64(h[13])<<40 | u64(h[14])<<48 | u64(h[15])<<56

	testing.expect_value(t, k0, expected_k0)
	testing.expect_value(t, k1, expected_k1)
}

@(test)
test_create_compact_block :: proc(t: ^testing.T) {
	// Build a block with coinbase + 2 regular txs.
	cb_inputs := make([]Tx_In, 1, context.temp_allocator)
	cb_inputs[0] = Tx_In{
		previous_output = Outpoint{hash = HASH_ZERO, index = 0xffffffff},
		script_sig = hex_decode("04ffff001d0101"),
		sequence = 0xffffffff,
	}
	cb_outputs := make([]Tx_Out, 1, context.temp_allocator)
	cb_outputs[0] = Tx_Out{value = 50_0000_0000, script_pubkey = hex_decode("6a")}

	// Regular tx 1
	tx1_inputs := make([]Tx_In, 1, context.temp_allocator)
	tx1_inputs[0] = Tx_In{
		previous_output = Outpoint{index = 0},
		script_sig = hex_decode("00"),
		sequence = 0xffffffff,
	}
	tx1_outputs := make([]Tx_Out, 1, context.temp_allocator)
	tx1_outputs[0] = Tx_Out{value = 1000, script_pubkey = hex_decode("6a")}

	// Regular tx 2
	tx2_inputs := make([]Tx_In, 1, context.temp_allocator)
	tx2_inputs[0] = Tx_In{
		previous_output = Outpoint{index = 1},
		script_sig = hex_decode("0102"),
		sequence = 0xfffffffe,
	}
	tx2_outputs := make([]Tx_Out, 1, context.temp_allocator)
	tx2_outputs[0] = Tx_Out{value = 2000, script_pubkey = hex_decode("51")}

	txs := make([]Tx, 3, context.temp_allocator)
	txs[0] = Tx{version = 1, inputs = cb_inputs, outputs = cb_outputs, locktime = 0}
	txs[1] = Tx{version = 2, inputs = tx1_inputs, outputs = tx1_outputs, locktime = 0}
	txs[2] = Tx{version = 2, inputs = tx2_inputs, outputs = tx2_outputs, locktime = 100}

	block := Block{
		header = Block_Header{version = 1, timestamp = 1231006505, bits = 0x1d00ffff, nonce = 2083236893},
		txs = txs,
	}

	nonce: u64 = 0xCAFEBABE
	cmpct := create_compact_block(&block, nonce, context.temp_allocator)

	// Verify structure.
	testing.expect_value(t, cmpct.nonce, nonce)
	testing.expect_value(t, cmpct.header.version, i32(1))
	testing.expect_value(t, len(cmpct.prefilled_txs), 1)
	testing.expect_value(t, cmpct.prefilled_txs[0].index, u64(0))
	testing.expect_value(t, cmpct.prefilled_txs[0].tx.outputs[0].value, i64(50_0000_0000))
	testing.expect_value(t, len(cmpct.shortids), 2)

	// Verify shortids match independent computation.
	block_hash := block_header_hash(&block.header)
	k0, k1 := crypto.compact_block_sipkeys(block_hash, nonce)

	tx1 := txs[1]
	wtxid1 := tx_witness_id(&tx1)
	expected_sid1 := crypto.compact_block_shortid(k0, k1, wtxid1)
	testing.expect_value(t, cmpct.shortids[0], expected_sid1)

	tx2 := txs[2]
	wtxid2 := tx_witness_id(&tx2)
	expected_sid2 := crypto.compact_block_shortid(k0, k1, wtxid2)
	testing.expect_value(t, cmpct.shortids[1], expected_sid2)

	// Roundtrip: serialize → deserialize.
	w := writer_init(context.temp_allocator)
	serialize_compact_block(&w, &cmpct)
	r := reader_init(writer_bytes(&w))
	cmpct2, err := deserialize_compact_block(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, len(cmpct2.shortids), 2)
	testing.expect_value(t, cmpct2.shortids[0], expected_sid1)
	testing.expect_value(t, cmpct2.shortids[1], expected_sid2)
	testing.expect_value(t, len(cmpct2.prefilled_txs), 1)
}

@(test)
test_create_compact_block_coinbase_only :: proc(t: ^testing.T) {
	// Block with only the coinbase tx → 0 shortids, 1 prefilled.
	cb_inputs := make([]Tx_In, 1, context.temp_allocator)
	cb_inputs[0] = Tx_In{
		previous_output = Outpoint{hash = HASH_ZERO, index = 0xffffffff},
		script_sig = hex_decode("04ffff001d0101"),
		sequence = 0xffffffff,
	}
	cb_outputs := make([]Tx_Out, 1, context.temp_allocator)
	cb_outputs[0] = Tx_Out{value = 50_0000_0000, script_pubkey = hex_decode("6a")}

	txs := make([]Tx, 1, context.temp_allocator)
	txs[0] = Tx{version = 1, inputs = cb_inputs, outputs = cb_outputs, locktime = 0}

	block := Block{
		header = Block_Header{version = 1, timestamp = 1000, bits = 0x1d00ffff, nonce = 1},
		txs = txs,
	}

	cmpct := create_compact_block(&block, 12345, context.temp_allocator)
	testing.expect_value(t, len(cmpct.shortids), 0)
	testing.expect_value(t, len(cmpct.prefilled_txs), 1)
	testing.expect_value(t, cmpct.prefilled_txs[0].index, u64(0))
}

// --- BIP155 addrv2 message tests ---

@(test)
test_addrv2_roundtrip :: proc(t: ^testing.T) {
	// Build an addrv2 message with IPv4, IPv6, and TorV3 addresses.
	ipv4_addr := make([]byte, 4, context.temp_allocator)
	ipv4_addr[0] = 192; ipv4_addr[1] = 168; ipv4_addr[2] = 1; ipv4_addr[3] = 100

	ipv6_addr := make([]byte, 16, context.temp_allocator)
	ipv6_addr[0] = 0x20; ipv6_addr[1] = 0x01
	ipv6_addr[15] = 0x01

	torv3_addr := make([]byte, 32, context.temp_allocator)
	torv3_addr[0] = 0xAA; torv3_addr[31] = 0xBB

	msg := Addr_V2_Message{
		addresses = []Addr_V2_Address{
			{timestamp = 1700000000, services = 1033, net = .IPv4, addr = ipv4_addr, port = 8333},
			{timestamp = 1700000100, services = 1, net = .IPv6, addr = ipv6_addr, port = 18333},
			{timestamp = 1700000200, services = 0, net = .TorV3, addr = torv3_addr, port = 9050},
		},
	}

	w := writer_init(context.temp_allocator)
	serialize_addr_v2(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_addr_v2(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, len(msg2.addresses), 3)

	// IPv4
	testing.expect_value(t, msg2.addresses[0].net, Addr_V2_Net.IPv4)
	testing.expect_value(t, len(msg2.addresses[0].addr), 4)
	testing.expect_value(t, msg2.addresses[0].addr[0], u8(192))
	testing.expect_value(t, msg2.addresses[0].port, u16(8333))
	testing.expect_value(t, msg2.addresses[0].services, u64(1033))
	testing.expect_value(t, msg2.addresses[0].timestamp, u32(1700000000))

	// IPv6
	testing.expect_value(t, msg2.addresses[1].net, Addr_V2_Net.IPv6)
	testing.expect_value(t, len(msg2.addresses[1].addr), 16)
	testing.expect_value(t, msg2.addresses[1].addr[0], u8(0x20))
	testing.expect_value(t, msg2.addresses[1].port, u16(18333))

	// TorV3
	testing.expect_value(t, msg2.addresses[2].net, Addr_V2_Net.TorV3)
	testing.expect_value(t, len(msg2.addresses[2].addr), 32)
	testing.expect_value(t, msg2.addresses[2].addr[0], u8(0xAA))
	testing.expect_value(t, msg2.addresses[2].addr[31], u8(0xBB))
	testing.expect_value(t, msg2.addresses[2].port, u16(9050))
}

// --- BIP157 compact block filter message tests ---

@(test)
test_get_cfilters_roundtrip :: proc(t: ^testing.T) {
	stop_hash: Hash256
	stop_hash[0] = 0xAA
	stop_hash[31] = 0xBB

	msg := Get_CFilters_Message{
		filter_type = 0,
		start_height = 100000,
		stop_hash = stop_hash,
	}

	w := writer_init(context.temp_allocator)
	serialize_get_cfilters(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_get_cfilters(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.start_height, u32(100000))
	testing.expect_value(t, msg2.stop_hash[0], u8(0xAA))
	testing.expect_value(t, msg2.stop_hash[31], u8(0xBB))
}

@(test)
test_cfilter_roundtrip :: proc(t: ^testing.T) {
	block_hash: Hash256
	block_hash[0] = 0x11
	block_hash[31] = 0x22

	filter_data := []byte{0x01, 0x02, 0x03, 0x04, 0x05, 0xAA, 0xBB, 0xCC}

	msg := CFilter_Message{
		filter_type = 0,
		block_hash = block_hash,
		filter_data = filter_data,
	}

	w := writer_init(context.temp_allocator)
	serialize_cfilter(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_cfilter(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.block_hash[0], u8(0x11))
	testing.expect_value(t, msg2.block_hash[31], u8(0x22))
	testing.expect_value(t, len(msg2.filter_data), 8)
	testing.expect_value(t, msg2.filter_data[0], u8(0x01))
	testing.expect_value(t, msg2.filter_data[7], u8(0xCC))
}

@(test)
test_get_cfheaders_roundtrip :: proc(t: ^testing.T) {
	stop_hash: Hash256
	stop_hash[0] = 0xCC

	msg := Get_CFHeaders_Message{
		filter_type = 0,
		start_height = 200000,
		stop_hash = stop_hash,
	}

	w := writer_init(context.temp_allocator)
	serialize_get_cfheaders(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_get_cfheaders(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.start_height, u32(200000))
	testing.expect_value(t, msg2.stop_hash[0], u8(0xCC))
}

@(test)
test_cfheaders_roundtrip :: proc(t: ^testing.T) {
	stop_hash: Hash256
	stop_hash[0] = 0xDD

	prev_header: Hash256
	prev_header[0] = 0xEE

	h1, h2: Hash256
	h1[0] = 0x11
	h2[0] = 0x22

	msg := CFHeaders_Message{
		filter_type = 0,
		stop_hash = stop_hash,
		prev_filter_header = prev_header,
		filter_hashes = []Hash256{h1, h2},
	}

	w := writer_init(context.temp_allocator)
	serialize_cfheaders(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_cfheaders(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.stop_hash[0], u8(0xDD))
	testing.expect_value(t, msg2.prev_filter_header[0], u8(0xEE))
	testing.expect_value(t, len(msg2.filter_hashes), 2)
	testing.expect_value(t, msg2.filter_hashes[0][0], u8(0x11))
	testing.expect_value(t, msg2.filter_hashes[1][0], u8(0x22))
}

@(test)
test_get_cfcheckpt_roundtrip :: proc(t: ^testing.T) {
	stop_hash: Hash256
	stop_hash[0] = 0xFF

	msg := Get_CFCheckpt_Message{
		filter_type = 0,
		stop_hash = stop_hash,
	}

	w := writer_init(context.temp_allocator)
	serialize_get_cfcheckpt(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_get_cfcheckpt(&r)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.stop_hash[0], u8(0xFF))
}

@(test)
test_cfcheckpt_roundtrip :: proc(t: ^testing.T) {
	stop_hash: Hash256
	stop_hash[0] = 0xAB

	h1, h2, h3: Hash256
	h1[0] = 0x01
	h2[0] = 0x02
	h3[0] = 0x03

	msg := CFCheckpt_Message{
		filter_type = 0,
		stop_hash = stop_hash,
		filter_headers = []Hash256{h1, h2, h3},
	}

	w := writer_init(context.temp_allocator)
	serialize_cfcheckpt(&w, &msg)

	r := reader_init(writer_bytes(&w))
	msg2, err := deserialize_cfcheckpt(&r, context.temp_allocator)
	testing.expect(t, err == nil, "deserialize should succeed")
	testing.expect_value(t, msg2.filter_type, u8(0))
	testing.expect_value(t, msg2.stop_hash[0], u8(0xAB))
	testing.expect_value(t, len(msg2.filter_headers), 3)
	testing.expect_value(t, msg2.filter_headers[0][0], u8(0x01))
	testing.expect_value(t, msg2.filter_headers[1][0], u8(0x02))
	testing.expect_value(t, msg2.filter_headers[2][0], u8(0x03))
}

@(test)
test_sendaddrv2_command :: proc(t: ^testing.T) {
	// Verify CMD_SENDADDRV2 roundtrips through command_to_bytes/command_from_bytes.
	bytes := command_to_bytes(CMD_SENDADDRV2)
	back := command_from_bytes(bytes)
	testing.expect_value(t, back, CMD_SENDADDRV2)
}
