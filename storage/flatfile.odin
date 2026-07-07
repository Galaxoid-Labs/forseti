package storage

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

MAX_FILE_SIZE :: 128 * 1024 * 1024 // 128 MB

File_Pos :: struct {
	file_num: u32,
	offset:   u32,
}

FILE_POS_NULL :: File_Pos{file_num = 0xFFFFFFFF, offset = 0xFFFFFFFF}

Flat_File_Manager :: struct {
	dir:          string, // resolved directory: <data_dir>/blocks (new) or <data_dir> (legacy layout)
	prefix:       string, // "blk" or "rev"
	current_file: u32,
	current_pos:  u32,
	fd:           ^os.File,
}

// Build path like "data_dir/blk00042.dat" into caller-provided buffer.
flat_file_path :: proc(mgr: ^Flat_File_Manager, file_num: u32, buf: []byte) -> string {
	s := fmt.bprintf(buf, "%s/%s%05d.dat", mgr.dir, mgr.prefix, file_num)
	return s
}

// Open or initialize a flat file manager. Scans existing files to find current write position.
flat_file_open :: proc(data_dir: string, prefix: string) -> (mgr: Flat_File_Manager, err: Storage_Error) {
	mgr.prefix = prefix
	mgr.current_file = 0
	mgr.current_pos = 0
	mgr.fd = nil

	// Flat files live in <data_dir>/blocks/ (Core-compatible). Datadirs from
	// before this layout have them at the datadir root — keep using the root
	// if ANY prefix file lives there. Checking only for file 0 broke the
	// moment pruning deleted it: the manager flipped to an empty blocks/ dir
	// and went blind to thousands of surviving root files.
	if _dir_has_flat_files(data_dir, prefix) {
		mgr.dir = data_dir
	} else {
		blocks_buf: [512]byte
		blocks_dir := fmt.bprintf(blocks_buf[:], "%s/blocks", data_dir)
		os.make_directory(blocks_dir)
		mgr.dir = fmt.aprintf("%s/blocks", data_dir)
	}

	// Find the highest-numbered existing file by listing the directory —
	// pruning deletes old files, so scanning upward from 0 stops at the first
	// gap and would restart writing at file 0, eventually rolling forward into
	// (and overwriting) surviving higher-numbered files.
	{
		dh, derr := os.open(mgr.dir)
		if derr == nil {
			defer os.close(dh)
			entries, _ := os.read_dir(dh, -1, context.temp_allocator)
			found_any := false
			for entry in entries {
				name := entry.name
				if len(name) != len(mgr.prefix) + 9 { continue } // "blk" + 5 digits + ".dat"
				if !strings.has_prefix(name, mgr.prefix) || !strings.has_suffix(name, ".dat") { continue }
				num, num_ok := strconv.parse_uint(name[len(mgr.prefix):len(name) - 4])
				if !num_ok { continue }
				if !found_any || u32(num) > mgr.current_file {
					mgr.current_file = u32(num)
					found_any = true
				}
			}
			if found_any {
				path_buf: [512]byte
				path := flat_file_path(&mgr, mgr.current_file, path_buf[:])
				size, size_err := _file_size(path)
				if size_err != .None {
					return mgr, size_err
				}
				mgr.current_pos = u32(size)
			}
		}
	}

	// Open the current file for writing (create if needed)
	open_err := _open_current(&mgr)
	if open_err != .None {
		return mgr, open_err
	}

	return mgr, .None
}

// Close the open file descriptor.
flat_file_close :: proc(mgr: ^Flat_File_Manager) {
	if mgr.fd != nil {
		os.close(mgr.fd)
		mgr.fd = nil
	}
}

// Append data to the flat file, rolling to the next file if it would exceed MAX_FILE_SIZE.
flat_file_write :: proc(mgr: ^Flat_File_Manager, data: []byte) -> (pos: File_Pos, err: Storage_Error) {
	if len(data) == 0 {
		return FILE_POS_NULL, .None
	}

	// Roll over if this write would exceed max file size
	if u64(mgr.current_pos) + u64(len(data)) > u64(MAX_FILE_SIZE) {
		flat_file_close(mgr)
		mgr.current_file += 1
		mgr.current_pos = 0
		open_err := _open_current(mgr)
		if open_err != .None {
			return FILE_POS_NULL, open_err
		}
	}

	pos = File_Pos{file_num = mgr.current_file, offset = mgr.current_pos}

	// Write all data
	written := 0
	for written < len(data) {
		n, werr := os.write(mgr.fd, data[written:])
		if werr != nil {
			return FILE_POS_NULL, .IO_Error
		}
		written += n
	}

	mgr.current_pos += u32(len(data))
	return pos, .None
}

// Read data at a specific position. Caller owns the returned slice.
flat_file_read :: proc(mgr: ^Flat_File_Manager, pos: File_Pos, size: u32, allocator := context.allocator) -> (data: []byte, err: Storage_Error) {
	path_buf: [512]byte
	path := flat_file_path(mgr, pos.file_num, path_buf[:])

	fd, open_err := os.open(path, os.O_RDONLY)
	if open_err != nil {
		return nil, .IO_Error
	}
	defer os.close(fd)

	data = make([]byte, int(size), allocator)

	total_read := 0
	for total_read < int(size) {
		n, rerr := os.read_at(fd, data[total_read:], i64(pos.offset) + i64(total_read))
		if rerr != nil || n == 0 {
			delete(data, allocator)
			return nil, .IO_Error
		}
		total_read += n
	}

	return data, .None
}

// --- Internal helpers ---

_open_current :: proc(mgr: ^Flat_File_Manager) -> Storage_Error {
	path_buf: [512]byte
	path := flat_file_path(mgr, mgr.current_file, path_buf[:])

	fd, err := os.open(path, os.O_WRONLY | os.O_CREATE, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		return .IO_Error
	}
	mgr.fd = fd

	// Seek to current_pos for appending
	if mgr.current_pos > 0 {
		_, serr := os.seek(mgr.fd, i64(mgr.current_pos), .Start)
		if serr != nil {
			os.close(mgr.fd)
			mgr.fd = nil
			return .IO_Error
		}
	}

	return .None
}

_file_size :: proc(path: string) -> (size: i64, err: Storage_Error) {
	fd, open_err := os.open(path, os.O_RDONLY)
	if open_err != nil {
		return 0, .IO_Error
	}
	defer os.close(fd)

	sz, serr := os.file_size(fd)
	if serr != nil {
		return 0, .IO_Error
	}
	return sz, .None
}

// Delete a flat file (pruning). Never called for the currently-open file —
// prune candidates are strictly below the active write file.
flat_file_delete :: proc(mgr: ^Flat_File_Manager, file_num: u32) -> bool {
	if file_num == mgr.current_file {
		return false
	}
	path_buf: [512]byte
	path := flat_file_path(mgr, file_num, path_buf[:])
	if !os.exists(path) {
		return false
	}
	return os.remove(path) == nil
}

// Size of one flat file on disk (0 if absent) — used for prune accounting.
flat_file_size :: proc(mgr: ^Flat_File_Manager, file_num: u32) -> i64 {
	path_buf: [512]byte
	path := flat_file_path(mgr, file_num, path_buf[:])
	fd, open_err := os.open(path, os.O_RDONLY)
	if open_err != nil { return 0 }
	defer os.close(fd)
	sz, serr := os.file_size(fd)
	if serr != nil { return 0 }
	return sz
}

// Whether a directory contains any "<prefix>NNNNN.dat" flat file.
_dir_has_flat_files :: proc(dir: string, prefix: string) -> bool {
	dh, derr := os.open(dir)
	if derr != nil { return false }
	defer os.close(dh)
	entries, _ := os.read_dir(dh, -1, context.temp_allocator)
	for entry in entries {
		name := entry.name
		if len(name) != len(prefix) + 9 { continue }
		if !strings.has_prefix(name, prefix) || !strings.has_suffix(name, ".dat") { continue }
		if _, ok := strconv.parse_uint(name[len(prefix):len(name) - 4]); ok {
			return true
		}
	}
	return false
}
