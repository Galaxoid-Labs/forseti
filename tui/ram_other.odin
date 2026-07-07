#+build !darwin
package tui

import "core:os"
import "core:strconv"
import "core:strings"

// Total physical memory in bytes from /proc/meminfo (Linux), or 0 if unknown.
total_ram_bytes :: proc() -> u64 {
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil {
		return 0
	}
	// Line format: "MemTotal:       16333764 kB"
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "MemTotal:") {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			return 0
		}
		kb, parse_ok := strconv.parse_u64(fields[1])
		if !parse_ok {
			return 0
		}
		return kb * 1024
	}
	return 0
}
