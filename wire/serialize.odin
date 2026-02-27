package wire

import "../crypto"

// --- Wire_Reader: cursor-based reader over a byte slice ---

Wire_Reader :: struct {
	data: []byte,
	pos:  int,
}

reader_init :: proc(data: []byte) -> Wire_Reader {
	return Wire_Reader{data = data, pos = 0}
}

reader_remaining :: proc(r: ^Wire_Reader) -> int {
	return len(r.data) - r.pos
}

reader_has :: proc(r: ^Wire_Reader, n: int) -> bool {
	return r.pos + n <= len(r.data)
}

// --- Primitive reads (little-endian) ---

read_byte :: proc(r: ^Wire_Reader) -> (val: u8, err: Wire_Error) {
	if !reader_has(r, 1) { return 0, .Unexpected_EOF }
	val = r.data[r.pos]
	r.pos += 1
	return val, nil
}

read_u16le :: proc(r: ^Wire_Reader) -> (val: u16, err: Wire_Error) {
	if !reader_has(r, 2) { return 0, .Unexpected_EOF }
	d := r.data[r.pos:]
	val = u16(d[0]) | u16(d[1]) << 8
	r.pos += 2
	return val, nil
}

read_u32le :: proc(r: ^Wire_Reader) -> (val: u32, err: Wire_Error) {
	if !reader_has(r, 4) { return 0, .Unexpected_EOF }
	d := r.data[r.pos:]
	val = u32(d[0]) | u32(d[1]) << 8 | u32(d[2]) << 16 | u32(d[3]) << 24
	r.pos += 4
	return val, nil
}

read_u64le :: proc(r: ^Wire_Reader) -> (val: u64, err: Wire_Error) {
	if !reader_has(r, 8) { return 0, .Unexpected_EOF }
	d := r.data[r.pos:]
	val =
		u64(d[0]) |
		u64(d[1]) << 8 |
		u64(d[2]) << 16 |
		u64(d[3]) << 24 |
		u64(d[4]) << 32 |
		u64(d[5]) << 40 |
		u64(d[6]) << 48 |
		u64(d[7]) << 56
	r.pos += 8
	return val, nil
}

read_i32le :: proc(r: ^Wire_Reader) -> (val: i32, err: Wire_Error) {
	v := read_u32le(r) or_return
	return transmute(i32)v, nil
}

read_i64le :: proc(r: ^Wire_Reader) -> (val: i64, err: Wire_Error) {
	v := read_u64le(r) or_return
	return transmute(i64)v, nil
}

// Reads a Hash256 (32 bytes, as-is — no byte reversal).
read_hash :: proc(r: ^Wire_Reader) -> (h: Hash256, err: Wire_Error) {
	if !reader_has(r, 32) { return {}, .Unexpected_EOF }
	copy(h[:], r.data[r.pos:r.pos + 32])
	r.pos += 32
	return h, nil
}

// Reads exactly n bytes. Allocates using context.allocator.
read_bytes :: proc(r: ^Wire_Reader, n: int, allocator := context.allocator) -> (data: []byte, err: Wire_Error) {
	if !reader_has(r, n) { return nil, .Unexpected_EOF }
	data = make([]byte, n, allocator)
	copy(data, r.data[r.pos:r.pos + n])
	r.pos += n
	return data, nil
}

// Reads exactly n bytes as a slice into the underlying buffer (no allocation).
read_bytes_no_copy :: proc(r: ^Wire_Reader, n: int) -> (data: []byte, err: Wire_Error) {
	if !reader_has(r, n) { return nil, .Unexpected_EOF }
	data = r.data[r.pos:r.pos + n]
	r.pos += n
	return data, nil
}

// Reads CompactSize from the reader.
read_compact_size :: proc(r: ^Wire_Reader) -> (val: u64, err: Wire_Error) {
	remaining := r.data[r.pos:]
	v, size, e := compact_size_decode(remaining)
	if e != nil { return 0, e }
	r.pos += size
	return v, nil
}

// Reads CompactSize-prefixed byte slice.
read_var_bytes :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (data: []byte, err: Wire_Error) {
	length := read_compact_size(r) or_return
	if length > u64(MAX_MESSAGE_PAYLOAD) {
		return nil, .Payload_Too_Large
	}
	return read_bytes(r, int(length), allocator)
}

// --- Wire_Writer: appends to a dynamic byte buffer ---

Wire_Writer :: struct {
	buf: [dynamic]byte,
}

writer_init :: proc(allocator := context.allocator) -> Wire_Writer {
	return Wire_Writer{buf = make([dynamic]byte, 0, 256, allocator)}
}

writer_destroy :: proc(w: ^Wire_Writer) {
	delete(w.buf)
}

writer_bytes :: proc(w: ^Wire_Writer) -> []byte {
	return w.buf[:]
}

writer_len :: proc(w: ^Wire_Writer) -> int {
	return len(w.buf)
}

writer_reset :: proc(w: ^Wire_Writer) {
	clear(&w.buf)
}

// --- Primitive writes (little-endian) ---

write_byte :: proc(w: ^Wire_Writer, val: u8) {
	append(&w.buf, val)
}

write_u16le :: proc(w: ^Wire_Writer, val: u16) {
	append(&w.buf, u8(val), u8(val >> 8))
}

write_u32le :: proc(w: ^Wire_Writer, val: u32) {
	append(&w.buf, u8(val), u8(val >> 8), u8(val >> 16), u8(val >> 24))
}

write_u64le :: proc(w: ^Wire_Writer, val: u64) {
	append(
		&w.buf,
		u8(val),
		u8(val >> 8),
		u8(val >> 16),
		u8(val >> 24),
		u8(val >> 32),
		u8(val >> 40),
		u8(val >> 48),
		u8(val >> 56),
	)
}

write_i32le :: proc(w: ^Wire_Writer, val: i32) {
	write_u32le(w, transmute(u32)val)
}

write_i64le :: proc(w: ^Wire_Writer, val: i64) {
	write_u64le(w, transmute(u64)val)
}

write_hash :: proc(w: ^Wire_Writer, h: Hash256) {
	h := h
	append(&w.buf, ..h[:])
}

write_bytes :: proc(w: ^Wire_Writer, data: []byte) {
	append(&w.buf, ..data)
}

write_compact_size :: proc(w: ^Wire_Writer, val: u64) {
	buf, size := compact_size_encode(val)
	append(&w.buf, ..buf[:size])
}

// Writes CompactSize-prefixed byte slice.
write_var_bytes :: proc(w: ^Wire_Writer, data: []byte) {
	write_compact_size(w, u64(len(data)))
	write_bytes(w, data)
}

// --- Block_Header serialization ---

serialize_block_header :: proc(w: ^Wire_Writer, hdr: ^Block_Header) {
	write_i32le(w, hdr.version)
	write_hash(w, hdr.prev_hash)
	write_hash(w, hdr.merkle_root)
	write_u32le(w, hdr.timestamp)
	write_u32le(w, hdr.bits)
	write_u32le(w, hdr.nonce)
}

deserialize_block_header :: proc(r: ^Wire_Reader) -> (hdr: Block_Header, err: Wire_Error) {
	hdr.version = read_i32le(r) or_return
	hdr.prev_hash = read_hash(r) or_return
	hdr.merkle_root = read_hash(r) or_return
	hdr.timestamp = read_u32le(r) or_return
	hdr.bits = read_u32le(r) or_return
	hdr.nonce = read_u32le(r) or_return
	return hdr, nil
}

// Computes the double-SHA256 hash of a block header.
block_header_hash :: proc(hdr: ^Block_Header) -> Hash256 {
	w := writer_init(context.temp_allocator)
	serialize_block_header(&w, hdr)
	return crypto.sha256d(writer_bytes(&w))
}

// --- Outpoint serialization ---

serialize_outpoint :: proc(w: ^Wire_Writer, op: ^Outpoint) {
	write_hash(w, op.hash)
	write_u32le(w, op.index)
}

deserialize_outpoint :: proc(r: ^Wire_Reader) -> (op: Outpoint, err: Wire_Error) {
	op.hash = read_hash(r) or_return
	op.index = read_u32le(r) or_return
	return op, nil
}

// --- Tx_In serialization ---

serialize_tx_in :: proc(w: ^Wire_Writer, txin: ^Tx_In) {
	serialize_outpoint(w, &txin.previous_output)
	write_var_bytes(w, txin.script_sig)
	write_u32le(w, txin.sequence)
}

deserialize_tx_in :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (txin: Tx_In, err: Wire_Error) {
	txin.previous_output = deserialize_outpoint(r) or_return
	txin.script_sig = read_var_bytes(r, allocator) or_return
	txin.sequence = read_u32le(r) or_return
	return txin, nil
}

// --- Tx_Out serialization ---

serialize_tx_out :: proc(w: ^Wire_Writer, txout: ^Tx_Out) {
	write_i64le(w, txout.value)
	write_var_bytes(w, txout.script_pubkey)
}

deserialize_tx_out :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (txout: Tx_Out, err: Wire_Error) {
	txout.value = read_i64le(r) or_return
	txout.script_pubkey = read_var_bytes(r, allocator) or_return
	return txout, nil
}

// --- Witness serialization ---

// Reads witness data for all inputs.
deserialize_witness :: proc(r: ^Wire_Reader, input_count: int, allocator := context.allocator) -> (witness: [][][]byte, err: Wire_Error) {
	witness = make([][][]byte, input_count, allocator)
	for i in 0 ..< input_count {
		item_count := read_compact_size(r) or_return
		items := make([][]byte, int(item_count), allocator)
		for j in 0 ..< int(item_count) {
			items[j] = read_var_bytes(r, allocator) or_return
		}
		witness[i] = items
	}
	return witness, nil
}

serialize_witness :: proc(w: ^Wire_Writer, witness: [][][]byte) {
	for stack in witness {
		write_compact_size(w, u64(len(stack)))
		for item in stack {
			write_var_bytes(w, item)
		}
	}
}

// --- Transaction serialization ---

// Serializes a transaction with witness data if present.
serialize_tx :: proc(w: ^Wire_Writer, tx: ^Tx) {
	has_wit := tx_has_witness(tx)
	write_i32le(w, tx.version)

	if has_wit {
		// SegWit marker and flag
		write_byte(w, 0x00)
		write_byte(w, 0x01)
	}

	// Inputs
	write_compact_size(w, u64(len(tx.inputs)))
	for &txin in tx.inputs {
		serialize_tx_in(w, &txin)
	}

	// Outputs
	write_compact_size(w, u64(len(tx.outputs)))
	for &txout in tx.outputs {
		serialize_tx_out(w, &txout)
	}

	// Witness data
	if has_wit {
		serialize_witness(w, tx.witness)
	}

	write_u32le(w, tx.locktime)
}

// Serializes a transaction without witness data (for txid computation).
serialize_tx_no_witness :: proc(w: ^Wire_Writer, tx: ^Tx) {
	write_i32le(w, tx.version)

	write_compact_size(w, u64(len(tx.inputs)))
	for &txin in tx.inputs {
		serialize_tx_in(w, &txin)
	}

	write_compact_size(w, u64(len(tx.outputs)))
	for &txout in tx.outputs {
		serialize_tx_out(w, &txout)
	}

	write_u32le(w, tx.locktime)
}

deserialize_tx :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (tx: Tx, err: Wire_Error) {
	tx.version = read_i32le(r) or_return

	// Read first CompactSize — could be input count or SegWit marker.
	marker := read_byte(r) or_return

	has_witness := false
	input_count: u64

	if marker == 0x00 {
		// SegWit: marker=0x00, flag must be 0x01
		flag := read_byte(r) or_return
		if flag != 0x01 {
			return {}, .Invalid_Witness_Flag
		}
		has_witness = true
		input_count = read_compact_size(r) or_return
	} else {
		// Non-SegWit: marker is the first byte of the input count CompactSize.
		// We already consumed one byte, so reconstruct the CompactSize.
		if marker < 0xFD {
			input_count = u64(marker)
		} else {
			// Need to read more bytes for the CompactSize.
			switch marker {
			case 0xFD:
				lo := read_byte(r) or_return
				hi := read_byte(r) or_return
				input_count = u64(lo) | u64(hi) << 8
				if input_count < 0xFD {
					return {}, .Non_Canonical_Compact_Size
				}
			case 0xFE:
				b0 := read_byte(r) or_return
				b1 := read_byte(r) or_return
				b2 := read_byte(r) or_return
				b3 := read_byte(r) or_return
				input_count = u64(b0) | u64(b1) << 8 | u64(b2) << 16 | u64(b3) << 24
				if input_count <= 0xFFFF {
					return {}, .Non_Canonical_Compact_Size
				}
			case 0xFF:
				v := read_u64le(r) or_return
				input_count = v
				if input_count <= 0xFFFF_FFFF {
					return {}, .Non_Canonical_Compact_Size
				}
			}
		}
	}

	// Inputs
	tx.inputs = make([]Tx_In, int(input_count), allocator)
	for i in 0 ..< int(input_count) {
		tx.inputs[i] = deserialize_tx_in(r, allocator) or_return
	}

	// Outputs
	output_count := read_compact_size(r) or_return
	tx.outputs = make([]Tx_Out, int(output_count), allocator)
	for i in 0 ..< int(output_count) {
		tx.outputs[i] = deserialize_tx_out(r, allocator) or_return
	}

	// Witness
	if has_witness {
		tx.witness = deserialize_witness(r, int(input_count), allocator) or_return
	}

	tx.locktime = read_u32le(r) or_return
	return tx, nil
}

// Computes txid (hash of non-witness serialization, displayed reversed).
tx_id :: proc(tx: ^Tx) -> Hash256 {
	w := writer_init(context.temp_allocator)
	serialize_tx_no_witness(&w, tx)
	return crypto.sha256d(writer_bytes(&w))
}

// Computes wtxid (hash of full witness serialization, displayed reversed).
tx_witness_id :: proc(tx: ^Tx) -> Hash256 {
	w := writer_init(context.temp_allocator)
	serialize_tx(&w, tx)
	return crypto.sha256d(writer_bytes(&w))
}

// --- Block serialization ---

serialize_block :: proc(w: ^Wire_Writer, blk: ^Block) {
	serialize_block_header(w, &blk.header)
	write_compact_size(w, u64(len(blk.txs)))
	for &tx in blk.txs {
		serialize_tx(w, &tx)
	}
}

deserialize_block :: proc(r: ^Wire_Reader, allocator := context.allocator) -> (blk: Block, err: Wire_Error) {
	blk.header = deserialize_block_header(r) or_return
	tx_count := read_compact_size(r) or_return
	blk.txs = make([]Tx, int(tx_count), allocator)
	for i in 0 ..< int(tx_count) {
		blk.txs[i] = deserialize_tx(r, allocator) or_return
	}
	return blk, nil
}
