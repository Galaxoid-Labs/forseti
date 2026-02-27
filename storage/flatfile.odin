package storage

import "core:fmt"
import "core:os"

MAX_FILE_SIZE :: 128 * 1024 * 1024 // 128 MB

File_Pos :: struct {
	file_num: u32,
	offset:   u32,
}

FILE_POS_NULL :: File_Pos{file_num = 0xFFFFFFFF, offset = 0xFFFFFFFF}

Flat_File_Manager :: struct {
	data_dir:     string,
	prefix:       string, // "blk" or "rev"
	current_file: u32,
	current_pos:  u32,
	fd:           os.Handle,
}

// Build path like "data_dir/blk00042.dat" into caller-provided buffer.
flat_file_path :: proc(mgr: ^Flat_File_Manager, file_num: u32, buf: []byte) -> string {
	s := fmt.bprintf(buf, "%s/%s%05d.dat", mgr.data_dir, mgr.prefix, file_num)
	return s
}

// Open or initialize a flat file manager. Scans existing files to find current write position.
flat_file_open :: proc(data_dir: string, prefix: string) -> (mgr: Flat_File_Manager, err: Storage_Error) {
	mgr.data_dir = data_dir
	mgr.prefix = prefix
	mgr.current_file = 0
	mgr.current_pos = 0
	mgr.fd = os.INVALID_HANDLE

	// Scan existing files to find the last one
	path_buf: [512]byte
	for {
		path := flat_file_path(&mgr, mgr.current_file, path_buf[:])
		if !os.exists(path) {
			break
		}
		// Check next file
		next_path := flat_file_path(&mgr, mgr.current_file + 1, path_buf[:])
		if !os.exists(next_path) {
			// This is the last file — get its size
			size, size_err := _file_size(path)
			if size_err != .None {
				return mgr, size_err
			}
			mgr.current_pos = u32(size)
			break
		}
		mgr.current_file += 1
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
	if mgr.fd != os.INVALID_HANDLE {
		os.close(mgr.fd)
		mgr.fd = os.INVALID_HANDLE
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

	fd, err := os.open(path, os.O_WRONLY | os.O_CREATE, 0o644)
	if err != nil {
		return .IO_Error
	}
	mgr.fd = fd

	// Seek to current_pos for appending
	if mgr.current_pos > 0 {
		_, serr := os.seek(mgr.fd, i64(mgr.current_pos), os.SEEK_SET)
		if serr != nil {
			os.close(mgr.fd)
			mgr.fd = os.INVALID_HANDLE
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
