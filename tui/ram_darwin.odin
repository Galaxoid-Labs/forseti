package tui

import "core:c"

// macOS total physical RAM via sysctlbyname("hw.memsize").
foreign import libc_ram "system:System"

@(default_calling_convention = "c")
foreign libc_ram {
	sysctlbyname :: proc(name: cstring, oldp: rawptr, oldlenp: ^c.size_t, newp: rawptr, newlen: c.size_t) -> c.int ---
}

// Total physical memory in bytes, or 0 if unknown.
total_ram_bytes :: proc() -> u64 {
	value: u64 = 0
	size := c.size_t(size_of(value))
	if sysctlbyname("hw.memsize", &value, &size, nil, 0) != 0 {
		return 0
	}
	return value
}
