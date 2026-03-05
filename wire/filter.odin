package wire

// BIP 157 compact block filter P2P message types.

// getcfilters: request a range of compact filters.
Get_CFilters_Message :: struct {
	filter_type:  u8,
	start_height: u32,
	stop_hash:    Hash256,
}

// cfilter: a single compact filter for one block.
CFilter_Message :: struct {
	filter_type: u8,
	block_hash:  Hash256,
	filter_data: []byte, // BIP158 serialized filter (N prefix + GCS data)
}

// getcfheaders: request a range of compact filter headers.
Get_CFHeaders_Message :: struct {
	filter_type:  u8,
	start_height: u32,
	stop_hash:    Hash256,
}

// cfheaders: compact filter headers for a range of blocks.
CFHeaders_Message :: struct {
	filter_type:          u8,
	stop_hash:            Hash256,
	prev_filter_header:   Hash256,
	filter_hashes:        []Hash256,
}

// getcfcheckpt: request compact filter header checkpoints.
Get_CFCheckpt_Message :: struct {
	filter_type: u8,
	stop_hash:   Hash256,
}

// cfcheckpt: compact filter header checkpoints (every 1000 blocks).
CFCheckpt_Message :: struct {
	filter_type:    u8,
	stop_hash:      Hash256,
	filter_headers: []Hash256,
}

// --- Serialization ---

serialize_get_cfilters :: proc(w: ^Wire_Writer, msg: ^Get_CFilters_Message) {
	write_byte(w, msg.filter_type)
	write_u32le(w, msg.start_height)
	write_hash(w, msg.stop_hash)
}

deserialize_get_cfilters :: proc(r: ^Wire_Reader) -> (msg: Get_CFilters_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.start_height = read_u32le(r) or_return
	msg.stop_hash = read_hash(r) or_return
	return msg, nil
}

serialize_cfilter :: proc(w: ^Wire_Writer, msg: ^CFilter_Message) {
	write_byte(w, msg.filter_type)
	write_hash(w, msg.block_hash)
	write_compact_size(w, u64(len(msg.filter_data)))
	write_bytes(w, msg.filter_data)
}

deserialize_cfilter :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: CFilter_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.block_hash = read_hash(r) or_return
	filter_len := read_compact_size(r) or_return
	msg.filter_data = read_bytes(r, int(filter_len), allocator) or_return
	return msg, nil
}

serialize_get_cfheaders :: proc(w: ^Wire_Writer, msg: ^Get_CFHeaders_Message) {
	write_byte(w, msg.filter_type)
	write_u32le(w, msg.start_height)
	write_hash(w, msg.stop_hash)
}

deserialize_get_cfheaders :: proc(r: ^Wire_Reader) -> (msg: Get_CFHeaders_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.start_height = read_u32le(r) or_return
	msg.stop_hash = read_hash(r) or_return
	return msg, nil
}

serialize_cfheaders :: proc(w: ^Wire_Writer, msg: ^CFHeaders_Message) {
	write_byte(w, msg.filter_type)
	write_hash(w, msg.stop_hash)
	write_hash(w, msg.prev_filter_header)
	write_compact_size(w, u64(len(msg.filter_hashes)))
	for &h in msg.filter_hashes {
		write_hash(w, h)
	}
}

deserialize_cfheaders :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: CFHeaders_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.stop_hash = read_hash(r) or_return
	msg.prev_filter_header = read_hash(r) or_return
	count := read_compact_size(r) or_return
	msg.filter_hashes = make([]Hash256, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.filter_hashes[i] = read_hash(r) or_return
	}
	return msg, nil
}

serialize_get_cfcheckpt :: proc(w: ^Wire_Writer, msg: ^Get_CFCheckpt_Message) {
	write_byte(w, msg.filter_type)
	write_hash(w, msg.stop_hash)
}

deserialize_get_cfcheckpt :: proc(r: ^Wire_Reader) -> (msg: Get_CFCheckpt_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.stop_hash = read_hash(r) or_return
	return msg, nil
}

serialize_cfcheckpt :: proc(w: ^Wire_Writer, msg: ^CFCheckpt_Message) {
	write_byte(w, msg.filter_type)
	write_hash(w, msg.stop_hash)
	write_compact_size(w, u64(len(msg.filter_headers)))
	for &h in msg.filter_headers {
		write_hash(w, h)
	}
}

deserialize_cfcheckpt :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: CFCheckpt_Message, err: Wire_Error) {
	msg.filter_type = read_byte(r) or_return
	msg.stop_hash = read_hash(r) or_return
	count := read_compact_size(r) or_return
	msg.filter_headers = make([]Hash256, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.filter_headers[i] = read_hash(r) or_return
	}
	return msg, nil
}
