package p2p

import "core:fmt"
import "core:math/rand"

import "../wire"

MAX_KNOWN_ADDRESSES :: 5000

Known_Address :: struct {
	services:  u64,
	net:       wire.Addr_V2_Net,
	addr:      []byte,    // heap-owned (4B IPv4, 16B IPv6, 32B Tor/I2P)
	port:      u16,
	timestamp: u32,
}

Addr_Manager :: struct {
	addresses: [dynamic]^Known_Address,
	seen:      map[u64]int,   // hash(net,addr,port) → index in addresses
}

addr_manager_init :: proc(am: ^Addr_Manager) {
	am.addresses = make([dynamic]^Known_Address, 0, 256)
	am.seen = make(map[u64]int, 512)
}

addr_manager_destroy :: proc(am: ^Addr_Manager) {
	for ka in am.addresses {
		delete(ka.addr)
		free(ka)
	}
	delete(am.addresses)
	delete(am.seen)
}

// Add an address. Deduplicates by (net, addr, port). Updates timestamp if exists.
// Returns true if newly added.
addr_manager_add :: proc(am: ^Addr_Manager, ka: ^Known_Address) -> bool {
	h := _addr_hash(ka.net, ka.addr, ka.port)

	idx, found := am.seen[h]
	if found {
		// Update timestamp if newer.
		existing := am.addresses[idx]
		if ka.timestamp > existing.timestamp {
			existing.timestamp = ka.timestamp
		}
		// Update services if non-zero.
		if ka.services != 0 {
			existing.services = ka.services
		}
		return false
	}

	// At capacity — evict the oldest entry.
	if len(am.addresses) >= MAX_KNOWN_ADDRESSES {
		oldest_idx := 0
		oldest_ts := am.addresses[0].timestamp
		for i in 1 ..< len(am.addresses) {
			if am.addresses[i].timestamp < oldest_ts {
				oldest_ts = am.addresses[i].timestamp
				oldest_idx = i
			}
		}
		_addr_manager_remove(am, oldest_idx)
	}

	// Clone addr bytes to heap.
	new_ka := new(Known_Address)
	new_ka.services = ka.services
	new_ka.net = ka.net
	new_ka.port = ka.port
	new_ka.timestamp = ka.timestamp
	new_ka.addr = make([]byte, len(ka.addr))
	copy(new_ka.addr, ka.addr)

	new_idx := len(am.addresses)
	append(&am.addresses, new_ka)
	am.seen[h] = new_idx
	return true
}

// Return up to `count` random addresses (Fisher-Yates partial shuffle).
addr_manager_get_random :: proc(am: ^Addr_Manager, count: int, allocator := context.allocator) -> []^Known_Address {
	n := min(count, len(am.addresses))
	if n == 0 {
		return nil
	}

	// Build index array.
	indices := make([]int, len(am.addresses), context.temp_allocator)
	for i in 0 ..< len(am.addresses) {
		indices[i] = i
	}

	// Fisher-Yates partial shuffle: pick n random from the array.
	for i in 0 ..< n {
		j := i + int(rand.uint32()) % (len(indices) - i)
		indices[i], indices[j] = indices[j], indices[i]
	}

	result := make([]^Known_Address, n, allocator)
	for i in 0 ..< n {
		result[i] = am.addresses[indices[i]]
	}
	return result
}

// Get next connectable IPv4 address as "ip:port" string + port int.
// Iterates from a random offset to avoid always connecting to the same peers.
addr_manager_get_connectable :: proc(am: ^Addr_Manager) -> (addr_str: string, port: int, ok: bool) {
	if len(am.addresses) == 0 {
		return "", 0, false
	}

	start := int(rand.uint32()) % len(am.addresses)
	for i in 0 ..< len(am.addresses) {
		idx := (start + i) % len(am.addresses)
		ka := am.addresses[idx]

		// Only connect to IPv4 for now (we don't have Tor/I2P/CJDNS support).
		if ka.net != .IPv4 || len(ka.addr) != 4 {
			continue
		}

		addr_str = fmt.aprintf("%d.%d.%d.%d", ka.addr[0], ka.addr[1], ka.addr[2], ka.addr[3])
		return addr_str, int(ka.port), true
	}

	return "", 0, false
}

addr_manager_count :: proc(am: ^Addr_Manager) -> int {
	return len(am.addresses)
}

addr_manager_ipv4_count :: proc(am: ^Addr_Manager) -> int {
	count := 0
	for ka in am.addresses {
		if ka.net == .IPv4 {
			count += 1
		}
	}
	return count
}

// Remove entry at index, maintaining seen map consistency.
_addr_manager_remove :: proc(am: ^Addr_Manager, idx: int) {
	ka := am.addresses[idx]
	h := _addr_hash(ka.net, ka.addr, ka.port)
	delete_key(&am.seen, h)
	delete(ka.addr)
	free(ka)

	last := len(am.addresses) - 1
	if idx != last {
		// Move last element into the vacated slot.
		moved := am.addresses[last]
		am.addresses[idx] = moved
		mh := _addr_hash(moved.net, moved.addr, moved.port)
		am.seen[mh] = idx
	}
	resize(&am.addresses, last)
}

// Simple hash for dedup: FNV-1a over (net, addr, port).
_addr_hash :: proc(net: wire.Addr_V2_Net, addr: []byte, port: u16) -> u64 {
	h: u64 = 14695981039346656037
	h ~= u64(net)
	h *= 1099511628211
	for b in addr {
		h ~= u64(b)
		h *= 1099511628211
	}
	h ~= u64(port)
	h *= 1099511628211
	h ~= u64(port >> 8)
	h *= 1099511628211
	return h
}
