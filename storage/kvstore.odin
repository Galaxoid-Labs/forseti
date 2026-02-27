package storage

import "core:os"
import "core:sys/posix"

KV_INITIAL_BUCKETS :: 1 << 17 // 131072 buckets
KV_MAX_KEY_SIZE :: 36          // txid(32) + vout(4)
KV_MAX_VALUE_SIZE :: 128       // height+coinbase+amount+script
KV_BUCKET_SIZE :: 1 + KV_MAX_KEY_SIZE + 2 + KV_MAX_VALUE_SIZE // = 167 bytes
KV_LOAD_FACTOR_NUM :: 7
KV_LOAD_FACTOR_DEN :: 10
KV_HEADER_SIZE :: 32
KV_MAGIC :: u32(0x4B565354) // "KVST"
KV_VERSION :: u32(1)

// Bucket status bytes
KV_BUCKET_EMPTY :: u8(0x00)
KV_BUCKET_OCCUPIED :: u8(0x01)
KV_BUCKET_TOMBSTONE :: u8(0x02)

KV_Store :: struct {
	file_path:    string,
	fd:           os.Handle,
	data:         [^]byte, // mmap'd pointer
	data_len:     uint,
	bucket_count: u32,
	entry_count:  u32,
}

// Open or create an mmap-backed KV store.
kv_open :: proc(file_path: string, initial_buckets: u32 = KV_INITIAL_BUCKETS) -> (store: KV_Store, err: Storage_Error) {
	store.file_path = file_path
	store.fd = os.INVALID_HANDLE

	existed := os.exists(file_path)

	fd, open_err := os.open(file_path, os.O_RDWR | os.O_CREATE, 0o644)
	if open_err != nil {
		return store, .IO_Error
	}
	store.fd = fd

	if existed {
		// Read existing file
		file_sz, serr := os.file_size(fd)
		if serr != nil {
			os.close(fd)
			return store, .IO_Error
		}

		if file_sz < i64(KV_HEADER_SIZE) {
			os.close(fd)
			return store, .Corrupt_Data
		}

		store.data_len = uint(file_sz)
		merr := _kv_mmap(&store)
		if merr != .None {
			os.close(fd)
			return store, merr
		}

		// Validate header
		magic := _read_u32le(store.data)
		if magic != KV_MAGIC {
			_kv_munmap(&store)
			os.close(fd)
			return store, .Bad_Magic
		}
		version := _read_u32le(_ptr_offset(store.data, 4))
		if version != KV_VERSION {
			_kv_munmap(&store)
			os.close(fd)
			return store, .Bad_Version
		}
		store.bucket_count = _read_u32le(_ptr_offset(store.data, 8))
		store.entry_count = _read_u32le(_ptr_offset(store.data, 12))
	} else {
		// Create new file
		store.bucket_count = initial_buckets
		store.entry_count = 0
		store.data_len = uint(KV_HEADER_SIZE) + uint(initial_buckets) * uint(KV_BUCKET_SIZE)

		// Extend file to required size
		terr := _ftruncate(store.fd, i64(store.data_len))
		if terr != .None {
			os.close(fd)
			return store, terr
		}

		merr := _kv_mmap(&store)
		if merr != .None {
			os.close(fd)
			return store, merr
		}

		// Write header
		_write_u32le(store.data, KV_MAGIC)
		_write_u32le(_ptr_offset(store.data, 4), KV_VERSION)
		_write_u32le(_ptr_offset(store.data, 8), store.bucket_count)
		_write_u32le(_ptr_offset(store.data, 12), 0) // entry_count
	}

	return store, .None
}

// Sync, unmap, and close the KV store.
kv_close :: proc(store: ^KV_Store) -> Storage_Error {
	err := kv_flush(store)
	_kv_munmap(store)
	if store.fd != os.INVALID_HANDLE {
		os.close(store.fd)
		store.fd = os.INVALID_HANDLE
	}
	return err
}

// Look up a key. Returns a slice into the mmap'd data (do not free).
kv_get :: proc(store: ^KV_Store, key: []byte) -> (value: []byte, found: bool) {
	idx, ok := _kv_find_bucket(store, key)
	if !ok {
		return nil, false
	}

	bptr := _kv_bucket_ptr(store, idx)
	if bptr[0] != KV_BUCKET_OCCUPIED {
		return nil, false
	}

	val_len := u16(bptr[1 + KV_MAX_KEY_SIZE]) | u16(bptr[1 + KV_MAX_KEY_SIZE + 1]) << 8
	val_start := 1 + KV_MAX_KEY_SIZE + 2
	return bptr[val_start:val_start + int(val_len)], true
}

// Insert or overwrite a key-value pair. Triggers rehash if load factor exceeded.
kv_put :: proc(store: ^KV_Store, key: []byte, value: []byte) -> Storage_Error {
	if len(key) > KV_MAX_KEY_SIZE {
		return .Value_Too_Large
	}
	if len(value) > KV_MAX_VALUE_SIZE {
		return .Value_Too_Large
	}

	// Check if we need to rehash
	threshold := u64(store.bucket_count) * u64(KV_LOAD_FACTOR_NUM) / u64(KV_LOAD_FACTOR_DEN)
	if u64(store.entry_count + 1) > threshold {
		rerr := _kv_rehash(store)
		if rerr != .None {
			return rerr
		}
	}

	hash := _kv_hash(key, store.bucket_count)
	for i := u32(0); i < store.bucket_count; i += 1 {
		idx := (hash + i) & (store.bucket_count - 1)
		bptr := _kv_bucket_ptr(store, idx)

		status := bptr[0]
		if status == KV_BUCKET_EMPTY || status == KV_BUCKET_TOMBSTONE {
			// Insert here
			bptr[0] = KV_BUCKET_OCCUPIED
			// Clear and write key
			for j in 0 ..< KV_MAX_KEY_SIZE {
				bptr[1 + j] = 0
			}
			for j in 0 ..< len(key) {
				bptr[1 + j] = key[j]
			}
			// Write value length
			vlen := u16(len(value))
			bptr[1 + KV_MAX_KEY_SIZE] = byte(vlen)
			bptr[1 + KV_MAX_KEY_SIZE + 1] = byte(vlen >> 8)
			// Write value
			val_start := 1 + KV_MAX_KEY_SIZE + 2
			for j in 0 ..< KV_MAX_VALUE_SIZE {
				bptr[val_start + j] = 0
			}
			for j in 0 ..< len(value) {
				bptr[val_start + j] = value[j]
			}

			store.entry_count += 1
			_write_u32le(_ptr_offset(store.data, 12), store.entry_count)
			return .None
		}

		if status == KV_BUCKET_OCCUPIED {
			// Check if same key — overwrite
			if _keys_equal(bptr, key) {
				// Overwrite value
				vlen := u16(len(value))
				bptr[1 + KV_MAX_KEY_SIZE] = byte(vlen)
				bptr[1 + KV_MAX_KEY_SIZE + 1] = byte(vlen >> 8)
				val_start := 1 + KV_MAX_KEY_SIZE + 2
				for j in 0 ..< KV_MAX_VALUE_SIZE {
					bptr[val_start + j] = 0
				}
				for j in 0 ..< len(value) {
					bptr[val_start + j] = value[j]
				}
				return .None // no entry_count change
			}
		}
	}

	return .Full
}

// Delete a key by placing a tombstone.
kv_delete :: proc(store: ^KV_Store, key: []byte) -> Storage_Error {
	idx, ok := _kv_find_bucket(store, key)
	if !ok {
		return .Not_Found
	}

	bptr := _kv_bucket_ptr(store, idx)
	if bptr[0] != KV_BUCKET_OCCUPIED {
		return .Not_Found
	}

	bptr[0] = KV_BUCKET_TOMBSTONE
	store.entry_count -= 1
	_write_u32le(_ptr_offset(store.data, 12), store.entry_count)
	return .None
}

// Flush mmap'd data to disk.
kv_flush :: proc(store: ^KV_Store) -> Storage_Error {
	if store.data == nil {
		return .None
	}
	res := posix.msync(store.data, store.data_len, posix.MS_SYNC)
	if res != .OK {
		return .IO_Error
	}
	return .None
}

// --- Hash function ---

// Hash: XOR first 4 bytes of key with bytes at offset 32 (vout position),
// masked to bucket_count - 1 (power of 2).
_kv_hash :: proc(key: []byte, bucket_count: u32) -> u32 {
	h: u32 = 0
	if len(key) >= 4 {
		h = u32(key[0]) | u32(key[1]) << 8 | u32(key[2]) << 16 | u32(key[3]) << 24
	}
	if len(key) >= 36 {
		h ~= u32(key[32]) | u32(key[33]) << 8 | u32(key[34]) << 16 | u32(key[35]) << 24
	}
	return h & (bucket_count - 1)
}

// Find the bucket index for a given key (linear probing).
// Returns (index, true) if found occupied with matching key, or (_, false) if not found.
_kv_find_bucket :: proc(store: ^KV_Store, key: []byte) -> (u32, bool) {
	hash := _kv_hash(key, store.bucket_count)
	for i := u32(0); i < store.bucket_count; i += 1 {
		idx := (hash + i) & (store.bucket_count - 1)
		bptr := _kv_bucket_ptr(store, idx)

		status := bptr[0]
		if status == KV_BUCKET_EMPTY {
			return 0, false
		}
		if status == KV_BUCKET_OCCUPIED && _keys_equal(bptr, key) {
			return idx, true
		}
		// Tombstone or non-matching occupied: continue probing
	}
	return 0, false
}

// Get a pointer to the start of bucket at given index.
_kv_bucket_ptr :: proc(store: ^KV_Store, idx: u32) -> [^]byte {
	offset := uint(KV_HEADER_SIZE) + uint(idx) * uint(KV_BUCKET_SIZE)
	return _ptr_offset(store.data, offset)
}

// Rehash: double capacity, re-insert all occupied entries.
_kv_rehash :: proc(store: ^KV_Store) -> Storage_Error {
	old_count := store.bucket_count
	new_count := old_count * 2

	// Save old entries into temp slices of key + value
	Key_Value :: struct {
		key: [KV_MAX_KEY_SIZE]byte,
		val: [KV_MAX_VALUE_SIZE]byte,
		val_len: u16,
	}
	old_entries := make([dynamic]Key_Value, 0, int(store.entry_count), context.temp_allocator)
	for i := u32(0); i < old_count; i += 1 {
		bptr := _kv_bucket_ptr(store, i)
		if bptr[0] == KV_BUCKET_OCCUPIED {
			kv: Key_Value
			for j in 0 ..< KV_MAX_KEY_SIZE {
				kv.key[j] = bptr[1 + j]
			}
			kv.val_len = u16(bptr[1 + KV_MAX_KEY_SIZE]) | u16(bptr[1 + KV_MAX_KEY_SIZE + 1]) << 8
			val_start := 1 + KV_MAX_KEY_SIZE + 2
			for j in 0 ..< int(kv.val_len) {
				kv.val[j] = bptr[val_start + j]
			}
			append(&old_entries, kv)
		}
	}

	// Unmap
	_kv_munmap(store)

	// Resize file
	new_size := uint(KV_HEADER_SIZE) + uint(new_count) * uint(KV_BUCKET_SIZE)
	terr := _ftruncate(store.fd, i64(new_size))
	if terr != .None {
		return terr
	}

	store.data_len = new_size
	store.bucket_count = new_count
	store.entry_count = 0

	// Remap
	merr := _kv_mmap(store)
	if merr != .None {
		return merr
	}

	// Zero out all buckets
	for i := uint(KV_HEADER_SIZE); i < new_size; i += 1 {
		store.data[i] = 0
	}

	// Update header
	_write_u32le(store.data, KV_MAGIC)
	_write_u32le(_ptr_offset(store.data, 4), KV_VERSION)
	_write_u32le(_ptr_offset(store.data, 8), new_count)
	_write_u32le(_ptr_offset(store.data, 12), 0)

	// Re-insert all entries
	for &entry in old_entries {
		perr := kv_put(store, entry.key[:], entry.val[:entry.val_len])
		if perr != .None {
			return perr
		}
	}

	return .None
}

// --- mmap helpers ---

_kv_mmap :: proc(store: ^KV_Store) -> Storage_Error {
	result := posix.mmap(
		nil,
		store.data_len,
		{.READ, .WRITE},
		{.SHARED},
		posix.FD(store.fd),
		0,
	)
	if result == posix.MAP_FAILED {
		return .IO_Error
	}
	store.data = cast([^]byte)result
	return .None
}

_kv_munmap :: proc(store: ^KV_Store) {
	if store.data != nil {
		posix.munmap(store.data, store.data_len)
		store.data = nil
	}
}

_ftruncate :: proc(fd: os.Handle, size: i64) -> Storage_Error {
	res := posix.ftruncate(posix.FD(fd), posix.off_t(size))
	if res != .OK {
		return .IO_Error
	}
	return .None
}

// --- Byte helpers ---

_ptr_offset :: proc(ptr: [^]byte, offset: uint) -> [^]byte {
	return cast([^]byte)(uintptr(ptr) + uintptr(offset))
}

_read_u32le :: proc(ptr: [^]byte) -> u32 {
	return u32(ptr[0]) | u32(ptr[1]) << 8 | u32(ptr[2]) << 16 | u32(ptr[3]) << 24
}

_write_u32le :: proc(ptr: [^]byte, val: u32) {
	ptr[0] = byte(val)
	ptr[1] = byte(val >> 8)
	ptr[2] = byte(val >> 16)
	ptr[3] = byte(val >> 24)
}

// Compare a bucket's stored key (at offset 1 in bucket) against a lookup key.
// bptr points to the start of the bucket.
_keys_equal :: proc(bptr: [^]byte, key: []byte) -> bool {
	for i in 0 ..< KV_MAX_KEY_SIZE {
		stored_byte := bptr[1 + i]
		key_byte := i < len(key) ? key[i] : 0
		if stored_byte != key_byte {
			return false
		}
	}
	return true
}
