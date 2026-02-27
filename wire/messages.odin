package wire

// Individual P2P message types and their serialization.

// --- Version message (handshake) ---

Version_Message :: struct {
	version:     i32,
	services:    u64,
	timestamp:   i64,
	addr_recv:   Net_Address,
	addr_from:   Net_Address,
	nonce:       u64,
	user_agent:  string,
	start_height: i32,
	relay:       bool,
}

serialize_version :: proc(w: ^Wire_Writer, msg: ^Version_Message) {
	write_i32le(w, msg.version)
	write_u64le(w, msg.services)
	write_i64le(w, msg.timestamp)

	serialize_net_address(w, &msg.addr_recv)
	serialize_net_address(w, &msg.addr_from)

	write_u64le(w, msg.nonce)
	write_var_bytes(w, transmute([]byte)msg.user_agent)
	write_i32le(w, msg.start_height)
	write_byte(w, 1 if msg.relay else 0)
}

deserialize_version :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Version_Message, err: Wire_Error) {
	msg.version = read_i32le(r) or_return
	msg.services = read_u64le(r) or_return
	msg.timestamp = read_i64le(r) or_return
	msg.addr_recv = deserialize_net_address(r) or_return
	msg.addr_from = deserialize_net_address(r) or_return
	msg.nonce = read_u64le(r) or_return

	ua_bytes := read_var_bytes(r, allocator) or_return
	msg.user_agent = string(ua_bytes)

	msg.start_height = read_i32le(r) or_return

	// relay is optional (BIP37)
	if reader_remaining(r) >= 1 {
		relay_byte := read_byte(r) or_return
		msg.relay = relay_byte != 0
	} else {
		msg.relay = true
	}

	return msg, nil
}

// --- Ping / Pong ---

Ping_Message :: struct {
	nonce: u64,
}

Pong_Message :: struct {
	nonce: u64,
}

serialize_ping :: proc(w: ^Wire_Writer, msg: ^Ping_Message) {
	write_u64le(w, msg.nonce)
}

deserialize_ping :: proc(r: ^Wire_Reader) -> (msg: Ping_Message, err: Wire_Error) {
	msg.nonce = read_u64le(r) or_return
	return msg, nil
}

serialize_pong :: proc(w: ^Wire_Writer, msg: ^Pong_Message) {
	write_u64le(w, msg.nonce)
}

deserialize_pong :: proc(r: ^Wire_Reader) -> (msg: Pong_Message, err: Wire_Error) {
	msg.nonce = read_u64le(r) or_return
	return msg, nil
}

// --- Inv / GetData ---

Inv_Message :: struct {
	inventory: []Inv_Vector,
}

Get_Data_Message :: struct {
	inventory: []Inv_Vector,
}

serialize_inv_vector :: proc(w: ^Wire_Writer, iv: ^Inv_Vector) {
	write_u32le(w, u32(iv.type))
	write_hash(w, iv.hash)
}

deserialize_inv_vector :: proc(r: ^Wire_Reader) -> (iv: Inv_Vector, err: Wire_Error) {
	type_val := read_u32le(r) or_return
	iv.type = Inv_Type(type_val)
	iv.hash = read_hash(r) or_return
	return iv, nil
}

serialize_inv :: proc(w: ^Wire_Writer, msg: ^Inv_Message) {
	write_compact_size(w, u64(len(msg.inventory)))
	for &iv in msg.inventory {
		serialize_inv_vector(w, &iv)
	}
}

deserialize_inv :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Inv_Message, err: Wire_Error) {
	count := read_compact_size(r) or_return
	if count > MAX_INV_SIZE {
		return {}, .Payload_Too_Large
	}
	msg.inventory = make([]Inv_Vector, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.inventory[i] = deserialize_inv_vector(r) or_return
	}
	return msg, nil
}

serialize_getdata :: proc(w: ^Wire_Writer, msg: ^Get_Data_Message) {
	write_compact_size(w, u64(len(msg.inventory)))
	for &iv in msg.inventory {
		serialize_inv_vector(w, &iv)
	}
}

deserialize_getdata :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Get_Data_Message, err: Wire_Error) {
	count := read_compact_size(r) or_return
	if count > MAX_INV_SIZE {
		return {}, .Payload_Too_Large
	}
	msg.inventory = make([]Inv_Vector, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.inventory[i] = deserialize_inv_vector(r) or_return
	}
	return msg, nil
}

// --- GetHeaders / GetBlocks (same wire format) ---

Get_Headers_Message :: struct {
	version:      u32,
	block_hashes: []Hash256, // block locator hashes
	hash_stop:    Hash256,
}

Get_Blocks_Message :: struct {
	version:      u32,
	block_hashes: []Hash256,
	hash_stop:    Hash256,
}

serialize_getheaders :: proc(w: ^Wire_Writer, msg: ^Get_Headers_Message) {
	write_u32le(w, msg.version)
	write_compact_size(w, u64(len(msg.block_hashes)))
	for h in msg.block_hashes {
		write_hash(w, h)
	}
	write_hash(w, msg.hash_stop)
}

deserialize_getheaders :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Get_Headers_Message, err: Wire_Error) {
	msg.version = read_u32le(r) or_return
	count := read_compact_size(r) or_return
	msg.block_hashes = make([]Hash256, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.block_hashes[i] = read_hash(r) or_return
	}
	msg.hash_stop = read_hash(r) or_return
	return msg, nil
}

serialize_getblocks :: proc(w: ^Wire_Writer, msg: ^Get_Blocks_Message) {
	write_u32le(w, msg.version)
	write_compact_size(w, u64(len(msg.block_hashes)))
	for h in msg.block_hashes {
		write_hash(w, h)
	}
	write_hash(w, msg.hash_stop)
}

deserialize_getblocks :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Get_Blocks_Message, err: Wire_Error) {
	msg.version = read_u32le(r) or_return
	count := read_compact_size(r) or_return
	msg.block_hashes = make([]Hash256, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.block_hashes[i] = read_hash(r) or_return
	}
	msg.hash_stop = read_hash(r) or_return
	return msg, nil
}

// --- Headers message ---

Headers_Message :: struct {
	headers: []Block_Header,
}

serialize_headers :: proc(w: ^Wire_Writer, msg: ^Headers_Message) {
	write_compact_size(w, u64(len(msg.headers)))
	for &hdr in msg.headers {
		serialize_block_header(w, &hdr)
		// Each header in a "headers" message is followed by a tx_count of 0.
		write_compact_size(w, 0)
	}
}

deserialize_headers :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Headers_Message, err: Wire_Error) {
	count := read_compact_size(r) or_return
	msg.headers = make([]Block_Header, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.headers[i] = deserialize_block_header(r) or_return
		// Consume the tx_count (always 0 in headers message).
		_ = read_compact_size(r) or_return
	}
	return msg, nil
}

// --- Addr message ---

Addr_Message :: struct {
	addresses: []Net_Address_Timestamp,
}

serialize_net_address :: proc(w: ^Wire_Writer, addr: ^Net_Address) {
	write_u64le(w, addr.services)
	write_bytes(w, addr.ip[:])
	// Port is big-endian on the wire.
	write_byte(w, u8(addr.port >> 8))
	write_byte(w, u8(addr.port))
}

deserialize_net_address :: proc(r: ^Wire_Reader) -> (addr: Net_Address, err: Wire_Error) {
	addr.services = read_u64le(r) or_return
	ip_bytes := read_bytes_no_copy(r, 16) or_return
	copy(addr.ip[:], ip_bytes)
	// Port is big-endian on the wire.
	hi := read_byte(r) or_return
	lo := read_byte(r) or_return
	addr.port = u16(hi) << 8 | u16(lo)
	return addr, nil
}

serialize_addr :: proc(w: ^Wire_Writer, msg: ^Addr_Message) {
	write_compact_size(w, u64(len(msg.addresses)))
	for &entry in msg.addresses {
		write_u32le(w, entry.timestamp)
		serialize_net_address(w, &entry.address)
	}
}

deserialize_addr :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Addr_Message, err: Wire_Error) {
	count := read_compact_size(r) or_return
	if count > 1000 {
		return {}, .Payload_Too_Large
	}
	msg.addresses = make([]Net_Address_Timestamp, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.addresses[i].timestamp = read_u32le(r) or_return
		msg.addresses[i].address = deserialize_net_address(r) or_return
	}
	return msg, nil
}

// --- SendHeaders (empty payload, BIP130) ---
// No struct needed — just send/expect an empty payload.

// --- SendCmpct (BIP152) ---

Send_Compact_Message :: struct {
	announce:        bool,
	version:         u64,
}

serialize_sendcmpct :: proc(w: ^Wire_Writer, msg: ^Send_Compact_Message) {
	write_byte(w, 1 if msg.announce else 0)
	write_u64le(w, msg.version)
}

deserialize_sendcmpct :: proc(r: ^Wire_Reader) -> (msg: Send_Compact_Message, err: Wire_Error) {
	b := read_byte(r) or_return
	msg.announce = b != 0
	msg.version = read_u64le(r) or_return
	return msg, nil
}

// --- FeeFilter (BIP133) ---

Fee_Filter_Message :: struct {
	feerate: i64, // minimum fee rate in satoshis per kB
}

serialize_feefilter :: proc(w: ^Wire_Writer, msg: ^Fee_Filter_Message) {
	write_i64le(w, msg.feerate)
}

deserialize_feefilter :: proc(r: ^Wire_Reader) -> (msg: Fee_Filter_Message, err: Wire_Error) {
	msg.feerate = read_i64le(r) or_return
	return msg, nil
}
