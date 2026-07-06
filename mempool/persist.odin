package mempool

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"
import "../wire"

// Mempool persistence file format:
// [version:u64 LE][count:u64 LE][entries...]
// Each entry: [fee:i64 LE][time:i64 LE][tx_size:u32 LE][raw_tx_bytes...]

MEMPOOL_DAT_VERSION :: u64(1)

// Save all mempool entries to <data_dir>/mempool.dat.
// Writes to a temp file and renames for crash safety.
mempool_save :: proc(mp: ^Mempool, data_dir: string) -> bool {
	tmp_path := fmt.tprintf("%s/mempool.dat.tmp", data_dir)
	final_path := fmt.tprintf("%s/mempool.dat", data_dir)

	fd, ferr := os.open(tmp_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_All + {.Write_User})
	if ferr != nil {
		log.warnf("Failed to open %s for writing: %v", tmp_path, ferr)
		return false
	}
	defer os.close(fd)

	// Write header: version + count.
	count := u64(len(mp.entries))
	if !_write_u64le(fd, MEMPOOL_DAT_VERSION) { return false }
	if !_write_u64le(fd, count) { return false }

	// Write each entry.
	for _, entry in mp.entries {
		if !_write_i64le(fd, entry.fee) { return false }
		if !_write_i64le(fd, entry.time) { return false }

		// Serialize the tx to get raw bytes.
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &entry.tx)
		raw := wire.writer_bytes(&w)

		if !_write_u32le(fd, u32(len(raw))) { return false }
		if !_write_bytes(fd, raw) { return false }
	}

	// Atomic rename for crash safety.
	tmp_cstr := fmt.ctprintf("%s", tmp_path)
	final_cstr := fmt.ctprintf("%s", final_path)
	if posix.rename(tmp_cstr, final_cstr) != 0 {
		log.warnf("Failed to rename mempool.dat.tmp to mempool.dat")
		return false
	}

	if count > 0 {
		log.infof("Saved %d mempool entries to %s", count, final_path)
	}
	return true
}

// Load mempool entries from <data_dir>/mempool.dat.
// Re-validates each tx via mempool_add (UTXOs may have changed).
// Returns (loaded, skipped) counts. No-op if file doesn't exist.
mempool_load :: proc(mp: ^Mempool, data_dir: string) -> (loaded: int, skipped: int) {
	path := fmt.tprintf("%s/mempool.dat", data_dir)

	if !os.exists(path) {
		return 0, 0
	}

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.warnf("Failed to read %s", path)
		return 0, 0
	}

	if len(data) < 16 {
		log.warnf("mempool.dat too short (%d bytes)", len(data))
		return 0, 0
	}

	r := wire.reader_init(data)

	version, ver_err := wire.read_u64le(&r)
	if ver_err != nil {
		log.warnf("mempool.dat: failed to read version")
		return 0, 0
	}
	if version != MEMPOOL_DAT_VERSION {
		log.warnf("mempool.dat unknown version %d, skipping", version)
		return 0, 0
	}

	count, count_err := wire.read_u64le(&r)
	if count_err != nil {
		log.warnf("mempool.dat: failed to read count")
		return 0, 0
	}
	if count == 0 {
		return 0, 0
	}

	loaded = 0
	skipped = 0

	// Entries are saved in map-iteration (random) order, so children can
	// appear before their unconfirmed parents. Failed Missing_Inputs entries
	// are retried in extra passes until a pass makes no progress.
	deferred := make([dynamic]_Persist_Entry, 0, 64, context.temp_allocator)
	err_counts: [Mempool_Error]int

	for _ in 0 ..< count {
		fee, fee_err := wire.read_i64le(&r)
		if fee_err != nil { break }

		orig_time, time_err := wire.read_i64le(&r)
		if time_err != nil { break }

		tx_size, size_err := wire.read_u32le(&r)
		if size_err != nil { break }

		if r.pos + int(tx_size) > len(r.data) {
			log.warnf("mempool.dat truncated at entry %d", loaded + skipped)
			break
		}

		tx_data := r.data[r.pos:r.pos + int(tx_size)]
		r.pos += int(tx_size)

		if _load_one(mp, tx_data, orig_time, &err_counts, &deferred) {
			loaded += 1
		}
	}

	// Retry passes for ordering-dependent failures.
	for len(deferred) > 0 {
		progress := 0
		still := make([dynamic]_Persist_Entry, 0, len(deferred), context.temp_allocator)
		for pe in deferred {
			tx_reader := wire.reader_init(pe.data)
			tx, tx_err := wire.deserialize_tx(&tx_reader, context.temp_allocator)
			if tx_err != nil { continue }
			mp_err := mempool_add(mp, &tx)
			if mp_err == .None {
				txid := wire.tx_id(&tx)
				if entry, found := mp.entries[txid]; found { entry.time = pe.time }
				loaded += 1
				progress += 1
			} else if mp_err == .Missing_Inputs {
				append(&still, pe)
			} else {
				err_counts[mp_err] += 1
			}
		}
		deferred = still
		if progress == 0 { break }
	}
	for pe in deferred { _ = pe; err_counts[.Missing_Inputs] += 1 }

	for err in Mempool_Error {
		if err == .None { continue }
		if err_counts[err] > 0 {
			skipped += err_counts[err]
			log.infof("mempool.dat: %d entries skipped: %v", err_counts[err], err)
		}
	}

	if loaded > 0 || skipped > 0 {
		log.infof("Loaded %d mempool entries (%d skipped) from %s", loaded, skipped, path)
	}

	return loaded, skipped
}

// --- File I/O helpers ---

_write_u64le :: proc(fd: ^os.File, val: u64) -> bool {
	buf: [8]byte
	buf[0] = byte(val)
	buf[1] = byte(val >> 8)
	buf[2] = byte(val >> 16)
	buf[3] = byte(val >> 24)
	buf[4] = byte(val >> 32)
	buf[5] = byte(val >> 40)
	buf[6] = byte(val >> 48)
	buf[7] = byte(val >> 56)
	_, err := os.write(fd, buf[:])
	return err == nil
}

_write_i64le :: proc(fd: ^os.File, val: i64) -> bool {
	return _write_u64le(fd, transmute(u64)val)
}

_write_u32le :: proc(fd: ^os.File, val: u32) -> bool {
	buf: [4]byte
	buf[0] = byte(val)
	buf[1] = byte(val >> 8)
	buf[2] = byte(val >> 16)
	buf[3] = byte(val >> 24)
	_, err := os.write(fd, buf[:])
	return err == nil
}

_write_bytes :: proc(fd: ^os.File, data: []byte) -> bool {
	if len(data) == 0 {
		return true
	}
	_, err := os.write(fd, data)
	return err == nil
}

_Persist_Entry :: struct {
	fee:  i64,
	time: i64,
	data: []byte,
}

// Try one saved entry: returns true if accepted, defers Missing_Inputs for a
// retry pass (unconfirmed parent may appear later in the file), tallies
// everything else.
_load_one :: proc(mp: ^Mempool, tx_data: []byte, orig_time: i64, err_counts: ^[Mempool_Error]int, deferred: ^[dynamic]_Persist_Entry) -> bool {
	tx_reader := wire.reader_init(tx_data)
	tx, tx_err := wire.deserialize_tx(&tx_reader, context.temp_allocator)
	if tx_err != nil {
		err_counts[.Non_Standard] += 1
		return false
	}

	mp_err := mempool_add(mp, &tx)
	if mp_err == .None {
		txid := wire.tx_id(&tx)
		if entry, found := mp.entries[txid]; found { entry.time = orig_time }
		return true
	}
	if mp_err == .Missing_Inputs {
		append(deferred, _Persist_Entry{time = orig_time, data = tx_data})
		return false
	}
	err_counts[mp_err] += 1
	return false
}
