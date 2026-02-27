package storage

import "../wire"

Block_Location :: struct {
	file_num:    u32,
	data_offset: u32,
	data_size:   u32,
}

Block_DB :: struct {
	files:         Flat_File_Manager,
	network_magic: u32,
}

// Open block database backed by flat files in data_dir.
block_db_open :: proc(data_dir: string, network_magic: u32) -> (db: Block_DB, err: Storage_Error) {
	db.network_magic = network_magic
	db.files, err = flat_file_open(data_dir, "blk")
	return db, err
}

// Close the block database.
block_db_close :: proc(db: ^Block_DB) {
	flat_file_close(&db.files)
}

// Store a block by serializing it, then writing with magic+size prefix.
block_db_store :: proc(db: ^Block_DB, block: ^wire.Block) -> (loc: Block_Location, err: Storage_Error) {
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_block(&w, block)
	raw := wire.writer_bytes(&w)
	return block_db_store_raw(db, raw)
}

// Store pre-serialized block bytes with [magic:4 LE][size:4 LE][raw_block] framing.
block_db_store_raw :: proc(db: ^Block_DB, raw_block: []byte) -> (loc: Block_Location, err: Storage_Error) {
	// Build 8-byte header: magic(4) + size(4), both little-endian
	header: [8]byte
	magic := db.network_magic
	header[0] = byte(magic)
	header[1] = byte(magic >> 8)
	header[2] = byte(magic >> 16)
	header[3] = byte(magic >> 24)
	size := u32(len(raw_block))
	header[4] = byte(size)
	header[5] = byte(size >> 8)
	header[6] = byte(size >> 16)
	header[7] = byte(size >> 24)

	// Write header
	hdr_pos, herr := flat_file_write(&db.files, header[:])
	if herr != .None {
		return {}, herr
	}

	// Write raw block data
	_, werr := flat_file_write(&db.files, raw_block)
	if werr != .None {
		return {}, werr
	}

	loc.file_num = hdr_pos.file_num
	loc.data_offset = hdr_pos.offset + 8 // skip the 8-byte header
	loc.data_size = size
	return loc, .None
}

// Read and deserialize a block from the given location.
block_db_read :: proc(db: ^Block_DB, loc: Block_Location, allocator := context.allocator) -> (block: wire.Block, err: Storage_Error) {
	raw, rerr := block_db_read_raw(db, loc, context.temp_allocator)
	if rerr != .None {
		return {}, rerr
	}

	r := wire.reader_init(raw)
	blk, wire_err := wire.deserialize_block(&r, allocator)
	if wire_err != nil {
		return {}, .Corrupt_Data
	}
	return blk, .None
}

// Read raw block bytes from the given location.
block_db_read_raw :: proc(db: ^Block_DB, loc: Block_Location, allocator := context.allocator) -> (data: []byte, err: Storage_Error) {
	pos := File_Pos{file_num = loc.file_num, offset = loc.data_offset}
	return flat_file_read(&db.files, pos, loc.data_size, allocator)
}
