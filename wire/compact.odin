package wire

// BIP152 compact block relay message types.

Prefilled_Tx :: struct {
	index: u64, // absolute tx index within the block
	tx:    Tx,
}

Compact_Block_Message :: struct {
	header:        Block_Header,
	nonce:         u64,
	shortids:      []u64,          // 6-byte short IDs (high 2 bytes zero)
	prefilled_txs: []Prefilled_Tx, // always includes coinbase at index 0
}

Get_Block_Txn_Message :: struct {
	block_hash: Hash256,
	indices:    []u64, // absolute indices (differential on wire)
}

Block_Txn_Message :: struct {
	block_hash: Hash256,
	txs:        []Tx,
}

// --- Compact Block serialization ---

serialize_compact_block :: proc(w: ^Wire_Writer, msg: ^Compact_Block_Message) {
	serialize_block_header(w, &msg.header)
	write_u64le(w, msg.nonce)

	// Short IDs: 6 bytes LE each.
	write_compact_size(w, u64(len(msg.shortids)))
	for sid in msg.shortids {
		_write_u48le(w, sid)
	}

	// Prefilled txs with differential index encoding.
	write_compact_size(w, u64(len(msg.prefilled_txs)))
	last_index: u64 = 0
	for i in 0 ..< len(msg.prefilled_txs) {
		abs_idx := msg.prefilled_txs[i].index
		diff_idx := abs_idx - last_index
		if i > 0 {
			diff_idx = abs_idx - last_index - 1
		}
		write_compact_size(w, diff_idx)
		tx := msg.prefilled_txs[i].tx
		serialize_tx(w, &tx)
		last_index = abs_idx
	}
}

deserialize_compact_block :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Compact_Block_Message, err: Wire_Error) {
	msg.header = deserialize_block_header(r) or_return
	msg.nonce = read_u64le(r) or_return

	// Short IDs.
	sid_count := read_compact_size(r) or_return
	msg.shortids = make([]u64, int(sid_count), allocator)
	for i in 0 ..< int(sid_count) {
		msg.shortids[i] = _read_u48le(r) or_return
	}

	// Prefilled txs with differential index decoding.
	ptx_count := read_compact_size(r) or_return
	msg.prefilled_txs = make([]Prefilled_Tx, int(ptx_count), allocator)
	last_index: u64 = 0
	for i in 0 ..< int(ptx_count) {
		diff_idx := read_compact_size(r) or_return
		abs_idx: u64
		if i == 0 {
			abs_idx = diff_idx
		} else {
			abs_idx = last_index + diff_idx + 1
		}
		msg.prefilled_txs[i].index = abs_idx
		msg.prefilled_txs[i].tx = deserialize_tx(r, allocator) or_return
		last_index = abs_idx
	}

	return msg, nil
}

// --- Get Block Txn serialization ---

serialize_get_block_txn :: proc(w: ^Wire_Writer, msg: ^Get_Block_Txn_Message) {
	write_hash(w, msg.block_hash)
	write_compact_size(w, u64(len(msg.indices)))
	last_index: u64 = 0
	for i in 0 ..< len(msg.indices) {
		abs_idx := msg.indices[i]
		diff_idx := abs_idx - last_index
		if i > 0 {
			diff_idx = abs_idx - last_index - 1
		}
		write_compact_size(w, diff_idx)
		last_index = abs_idx
	}
}

deserialize_get_block_txn :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Get_Block_Txn_Message, err: Wire_Error) {
	msg.block_hash = read_hash(r) or_return
	count := read_compact_size(r) or_return
	msg.indices = make([]u64, int(count), allocator)
	last_index: u64 = 0
	for i in 0 ..< int(count) {
		diff_idx := read_compact_size(r) or_return
		abs_idx: u64
		if i == 0 {
			abs_idx = diff_idx
		} else {
			abs_idx = last_index + diff_idx + 1
		}
		msg.indices[i] = abs_idx
		last_index = abs_idx
	}
	return msg, nil
}

// --- Block Txn serialization ---

serialize_block_txn :: proc(w: ^Wire_Writer, msg: ^Block_Txn_Message) {
	write_hash(w, msg.block_hash)
	write_compact_size(w, u64(len(msg.txs)))
	for &tx in msg.txs {
		serialize_tx(w, &tx)
	}
}

deserialize_block_txn :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (msg: Block_Txn_Message, err: Wire_Error) {
	msg.block_hash = read_hash(r) or_return
	count := read_compact_size(r) or_return
	msg.txs = make([]Tx, int(count), allocator)
	for i in 0 ..< int(count) {
		msg.txs[i] = deserialize_tx(r, allocator) or_return
	}
	return msg, nil
}

// --- Helpers ---

// Write a 6-byte little-endian value.
@(private)
_write_u48le :: proc(w: ^Wire_Writer, val: u64) {
	append(&w.buf,
		u8(val),
		u8(val >> 8),
		u8(val >> 16),
		u8(val >> 24),
		u8(val >> 32),
		u8(val >> 40),
	)
}

// Read a 6-byte little-endian value.
@(private)
_read_u48le :: proc(r: ^Wire_Reader) -> (val: u64, err: Wire_Error) {
	if !reader_has(r, 6) { return 0, .Unexpected_EOF }
	d := r.data[r.pos:]
	val = u64(d[0]) |
		u64(d[1]) << 8 |
		u64(d[2]) << 16 |
		u64(d[3]) << 24 |
		u64(d[4]) << 32 |
		u64(d[5]) << 40
	r.pos += 6
	return val, nil
}
