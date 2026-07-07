// Outbound topology hardening: connection types, anchors.dat, feeler
// connections, and the -maxuploadtarget serving budget.
//
// - Block-relay-only connections (2): fRelay=false in the version message,
//   no tx relay, no addr relay — an attacker who controls all our full-relay
//   peers still cannot eclipse our view of the chain.
// - anchors.dat: the block-relay peers are remembered across restarts and
//   redialed first (Core behavior — the file is deleted after reading so a
//   crash loop cannot pin us to poisoned anchors).
// - Feelers: a short-lived connection every ~2 minutes probes a random
//   address-manager entry; failures evict the address, keeping the pool
//   honest. Successful feelers disconnect right after the handshake.
// - -maxuploadtarget: once the rolling 24h upload budget is spent, stop
//   serving week-old blocks to inbound peers (block relay at the tip and
//   headers stay unaffected).
package p2p

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Connection_Type :: enum u8 {
	Full_Relay,   // default outbound: blocks + txs + addrs
	Block_Relay,  // outbound, blocks only (fRelay=false)
	Feeler,       // short-lived address probe
	Inbound_Conn, // accepted connection
	Manual,       // --connect / addnode
}

connection_type_string :: proc(t: Connection_Type) -> string {
	switch t {
	case .Full_Relay:   return "outbound-full-relay"
	case .Block_Relay:  return "block-relay-only"
	case .Feeler:       return "feeler"
	case .Inbound_Conn: return "inbound"
	case .Manual:       return "manual"
	}
	return "unknown"
}

MAX_OUTBOUND_BLOCK_RELAY :: 2
FEELER_INTERVAL_SECS :: 120
MAX_ANCHORS :: 2
UPLOAD_TARGET_WINDOW_SECS :: 24 * 60 * 60
HISTORICAL_BLOCK_SECS :: 7 * 24 * 60 * 60 // "historical" = older than a week

// --- anchors.dat ---

_anchors_path :: proc(cm: ^Conn_Manager, buf: []byte) -> string {
	return fmt.bprintf(buf, "%s/anchors.dat", cm.data_dir)
}

// Persist the current block-relay peers (called on the P2P thread as the
// event loop exits, while the peer map is still alive).
anchors_save :: proc(cm: ^Conn_Manager) {
	if cm.data_dir == "" {
		return
	}
	lines := make([dynamic]byte, 0, 128, context.temp_allocator)
	count := 0
	for _, peer in cm.peers {
		if peer.conn_type != .Block_Relay || peer.state != .Active {
			continue
		}
		append(&lines, fmt.tprintf("%s:%d\n", peer.address, peer.port))
		count += 1
		if count >= MAX_ANCHORS {
			break
		}
	}
	buf: [512]byte
	path := _anchors_path(cm, buf[:])
	if count == 0 {
		os.remove(path)
		return
	}
	if os.write_entire_file(path, lines[:]) != nil {
		log.warnf("Failed to write anchors.dat")
		return
	}
	log.infof("Saved %d anchor(s) to anchors.dat", count)
}

// Read + DELETE anchors.dat, dialing each entry as a block-relay peer.
// Returns how many anchors were dialed.
anchors_connect :: proc(cm: ^Conn_Manager) -> int {
	if cm.data_dir == "" {
		return 0
	}
	buf: [512]byte
	path := _anchors_path(cm, buf[:])
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return 0
	}
	os.remove(path) // one shot — a crash loop must not re-pin these

	dialed := 0
	for line in strings.split_lines(string(data), context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || dialed >= MAX_ANCHORS {
			continue
		}
		colon := strings.last_index_byte(trimmed, ':')
		if colon <= 0 {
			continue
		}
		port, p_ok := strconv.parse_int(trimmed[colon + 1:])
		if !p_ok {
			continue
		}
		log.infof("Reconnecting to anchor %s", trimmed)
		peer_start_connect(cm, trimmed[:colon], port, cm.next_peer_id, conn_type = .Block_Relay)
		cm.next_peer_id += 1
		dialed += 1
	}
	return dialed
}

// --- periodic maintenance (runs on the P2P tick) ---

_topology_tick :: proc(cm: ^Conn_Manager, now: i64) {
	// Keep the block-relay slots filled.
	block_relay := 0
	feelers := 0
	for _, peer in cm.peers {
		switch peer.conn_type {
		case .Block_Relay:
			block_relay += 1
		case .Feeler:
			feelers += 1
		case .Full_Relay, .Inbound_Conn, .Manual:
		}
	}
	if block_relay < MAX_OUTBOUND_BLOCK_RELAY {
		if addr_str, port, ok := addr_manager_get_connectable(&cm.addr_mgr); ok {
			if !_conn_manager_already_connected(cm, addr_str) {
				log.debugf("Opening block-relay-only connection to %s:%d", addr_str, port)
				peer_start_connect(cm, addr_str, port, cm.next_peer_id, conn_type = .Block_Relay)
				cm.next_peer_id += 1
			}
			delete(addr_str)
		}
	}

	// One feeler at a time, every FEELER_INTERVAL_SECS.
	if feelers == 0 && now - cm.last_feeler >= FEELER_INTERVAL_SECS {
		cm.last_feeler = now
		if addr_str, port, ok := addr_manager_get_connectable(&cm.addr_mgr); ok {
			if !_conn_manager_already_connected(cm, addr_str) {
				log.debugf("Feeler connection to %s:%d", addr_str, port)
				peer_start_connect(cm, addr_str, port, cm.next_peer_id, conn_type = .Feeler)
				cm.next_peer_id += 1
			}
			delete(addr_str)
		}
	}

	// Feelers that linger past the handshake window get cut.
	stale_feelers := make([dynamic]Peer_Id, 0, 2, context.temp_allocator)
	for id, peer in cm.peers {
		if peer.conn_type == .Feeler && now - peer.connected_at > 30 {
			append(&stale_feelers, id)
		}
	}
	for id in stale_feelers {
		if peer, found := cm.peers[id]; found {
			log.debugf("Feeler %s timed out", peer.address)
			_mark_addr_useless(cm, peer.address)
		}
		conn_manager_remove_peer(cm, id)
	}
}

_conn_manager_already_connected :: proc(cm: ^Conn_Manager, address: string) -> bool {
	for _, peer in cm.peers {
		if peer.address == address {
			return true
		}
	}
	return false
}

// --- -maxuploadtarget ---

// True once the rolling 24h upload budget is exhausted (0 = unlimited).
upload_target_reached :: proc(cm: ^Conn_Manager, now: i64) -> bool {
	if cm.max_upload_target <= 0 {
		return false
	}
	if now - cm.upload_window_start >= UPLOAD_TARGET_WINDOW_SECS {
		cm.upload_window_start = now
		cm.upload_window_baseline = cm.total_bytes_sent
	}
	return cm.total_bytes_sent - cm.upload_window_baseline >= cm.max_upload_target
}
