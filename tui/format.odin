// Pure string formatters for the TUI — no terminal needed, fully unit-tested.
package tui

import "core:fmt"
import "core:strings"
import "../p2p"

// ASCII ramp: the system (non-wide) curses interleaves cursor-motion
// escapes inside multibyte sequences, garbling UTF-8 block glyphs. ASCII
// renders correctly on every TERM. (Wide-curses + Unicode is a v2 nicety.)
SPARK_GLYPHS := [8]rune{'_', '.', ':', '-', '=', '+', '*', '#'}

// Render the most recent `width` samples of a rate ring as block glyphs,
// auto-scaled to the window peak (1 KB/s floor keeps idle lines flat).
sparkline :: proc(ring: []f32, idx, count, width: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	n := min(count, width)
	peak: f32 = 1024
	for i in 0 ..< count {
		peak = max(peak, ring[i])
	}
	for _ in 0 ..< width - n {
		strings.write_rune(&b, ' ')
	}
	for i in 0 ..< n {
		pos := (idx - n + i + 2 * len(ring)) % len(ring)
		level := int((ring[pos] / peak) * 7.99)
		strings.write_rune(&b, SPARK_GLYPHS[clamp(level, 0, 7)])
	}
	return strings.to_string(b)
}

// Render a rate ring as a multi-row bar chart. Returns `rows` strings of
// '#' (filled) and ' ' (empty), top row first — the renderer converts
// '#' runs to solid reverse-video cells. Pure and unit-testable.
//
// scale_peak > 0 pins the scale externally — the mirrored IN/OUT chart
// passes one shared peak so bar heights are comparable across halves
// (each half auto-scaled made a 2K/s trickle look as busy as a 40M/s
// firehose). Nonzero samples always fill at least one cell so the quiet
// direction stays visible instead of flatlining.
bar_rows :: proc(ring: []f32, idx, count, width, rows: int, scale_peak: f32 = 0, allocator := context.temp_allocator) -> []string {
	out := make([]string, rows, allocator)
	n := min(count, width)
	peak := max(scale_peak, 1024)
	if scale_peak <= 0 {
		for i in 0 ..< count {
			peak = max(peak, ring[i])
		}
	}
	levels := make([]int, width, context.temp_allocator)
	for i in 0 ..< n {
		pos := (idx - n + i + 2 * len(ring)) % len(ring)
		col := width - n + i
		levels[col] = int((ring[pos] / peak) * f32(rows) + 0.5)
		if levels[col] == 0 && ring[pos] > 0 {
			levels[col] = 1
		}
	}
	for r in 0 ..< rows {
		b := strings.builder_make(allocator)
		need := rows - r // row 0 (top) needs a full-height column
		for c in 0 ..< width {
			strings.write_byte(&b, levels[c] >= need ? '#' : ' ')
		}
		out[r] = strings.to_string(b)
	}
	return out
}

ring_peak :: proc(ring: []f32) -> f32 {
	peak: f32 = 1024
	for v in ring {
		peak = max(peak, v)
	}
	return peak
}

fmt_bytes :: proc(n: i64, allocator := context.temp_allocator) -> string {
	if n < 1024 { return fmt.aprintf("%dB", n, allocator = allocator) }
	if n < 1024 * 1024 { return fmt.aprintf("%.0fK", f64(n) / 1024, allocator = allocator) }
	if n < 1024 * 1024 * 1024 { return fmt.aprintf("%.1fM", f64(n) / 1048576, allocator = allocator) }
	return fmt.aprintf("%.2fG", f64(n) / 1073741824, allocator = allocator)
}

commas :: proc(n: int, allocator := context.temp_allocator) -> string {
	if n < 0 { return fmt.aprintf("-%s", commas(-n, allocator), allocator = allocator) }
	if n < 1000 { return fmt.aprintf("%d", n, allocator = allocator) }
	return fmt.aprintf("%s,%03d", commas(n / 1000, allocator), n % 1000, allocator = allocator)
}

fmt_uptime :: proc(secs: i64, allocator := context.temp_allocator) -> string {
	if secs < 3600 { return fmt.aprintf("%dm %02ds", secs / 60, secs % 60, allocator = allocator) }
	if secs < 86400 { return fmt.aprintf("%dh %02dm", secs / 3600, (secs % 3600) / 60, allocator = allocator) }
	return fmt.aprintf("%dd %02dh", secs / 86400, (secs % 86400) / 3600, allocator = allocator)
}

sync_state_label :: proc(s: p2p.Sync_State) -> (string, int) {
	switch s {
	case .Idle:               return "Idle", P_DIM
	case .Syncing_Headers:    return "Syncing Headers", P_YELLOW
	case .Downloading_Blocks: return "Downloading Blocks", P_YELLOW
	case .In_Sync:            return "In Sync", P_GREEN
	}
	return "Unknown", P_DIM
}

// Right-aligned percentage, space-padded to 7 chars ("45.45%", " 7.02%").
// Odin's fmt zero-pads numeric widths ("045.45%"), so pad by hand.
pct_label :: proc(pct: f64, allocator := context.temp_allocator) -> string {
	num := fmt.tprintf("%.2f%%", pct * 100)
	if len(num) >= 7 {
		return num
	}
	b := strings.builder_make(allocator)
	for _ in 0 ..< 7 - len(num) {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, num)
	return strings.to_string(b)
}

progress_line :: proc(st: ^p2p.Node_Status, width: int, allocator := context.temp_allocator) -> string {
	pct := st.sync_state == .In_Sync ? 1.0 : st.verification_pct
	bar_w := max(width - 10, 10)
	filled := int(pct * f64(bar_w))
	b := strings.builder_make(allocator)
	for i in 0 ..< bar_w {
		strings.write_rune(&b, i < filled ? '#' : '.')
	}
	strings.write_byte(&b, ' ')
	strings.write_string(&b, pct_label(pct))
	return strings.to_string(b)
}

blocks_line :: proc(st: ^p2p.Node_Status, allocator := context.temp_allocator) -> string {
	eta := ""
	if st.sync_state == .Downloading_Blocks {
		eta = st.verification_pct >= 0.01 && st.eta_secs > 0 \
			? fmt.tprintf(" | ETA ~%s", fmt_uptime(st.eta_secs)) \
			: " | ETA estimating..."
	}
	return fmt.aprintf("%s / %s blocks | %d in-flight | up %s%s",
		commas(st.chain_height), commas(st.best_header), st.blocks_in_flight,
		fmt_uptime(st.uptime_secs), eta, allocator = allocator)
}

// Left-justified fixed-width cell. Odin's fmt does not implement C's "%-Nd"
// left-justify flag (widths garble into the digits) — pad explicitly.
_cell :: proc(b: ^strings.Builder, s: string, w: int) {
	n := min(len(s), w)
	strings.write_string(b, s[:n])
	for _ in n ..< w + 1 { // +1 = column gap
		strings.write_byte(b, ' ')
	}
}

peer_header :: proc(width: int, allocator := context.temp_allocator) -> string {
	return peer_row(width, "ID", "DIR", "ADDRESS", "AGENT", "HEIGHT", "BLKS", "LAST", "SENT", "RECV", allocator)
}

peer_row :: proc(width: int, id, dir, addr, agent, height, blks, last, sent, recv: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	_cell(&b, id, 5)
	_cell(&b, dir, 3)
	_cell(&b, addr, 20)
	if width >= 100 {
		_cell(&b, agent, 22)
	}
	_cell(&b, height, 8)
	_cell(&b, blks, 6)
	_cell(&b, last, 8)
	_cell(&b, sent, 8)
	_cell(&b, recv, 8)
	return strings.to_string(b)
}

peer_line :: proc(p: ^p2p.Peer_Status, state: p2p.Sync_State, width: int, allocator := context.temp_allocator) -> string {
	addr := string(p.address[:p.addr_len])
	agent := string(p.user_agent[:p.agent_len])
	activity := state == .Downloading_Blocks \
		? fmt.tprintf("%.1f/s", p.throughput) \
		: fmt.tprintf("%ds", p.last_recv_secs)
	return peer_row(width,
		fmt.tprintf("%d", int(p.id)),
		p.inbound ? "in" : "out",
		addr, agent,
		fmt.tprintf("%d", p.start_height),
		fmt.tprintf("%d", p.blocks_delivered),
		activity, fmt_bytes(p.bytes_sent), fmt_bytes(p.bytes_recv), allocator)
}

stats_line :: proc(st: ^p2p.Node_Status, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("Mempool %s tx / %s vB",
		commas(st.mempool_count), commas(st.mempool_vbytes), allocator = allocator)
}

utxo_line :: proc(st: ^p2p.Node_Status, allocator := context.temp_allocator) -> string {
	if st.flushing {
		return fmt.aprintf("%s entries | %s / %s | %s",
			commas(st.utxo_cache_count), fmt_bytes(i64(st.utxo_cache_bytes)),
			fmt_bytes(i64(st.utxo_cache_budget)), flush_label(st), allocator = allocator)
	}
	return fmt.aprintf("%s entries | %s / %s budget",
		commas(st.utxo_cache_count), fmt_bytes(i64(st.utxo_cache_bytes)),
		fmt_bytes(i64(st.utxo_cache_budget)), allocator = allocator)
}

profile_line :: proc(st: ^p2p.Node_Status, allocator := context.temp_allocator) -> string {
	if st.prof_blocks == 0 {
		return fmt.aprintf("Profile: (waiting for first block)", allocator = allocator)
	}
	rate := st.blocks_per_sec > 0 ? fmt.tprintf(" %.1f blk/s |", st.blocks_per_sec) : ""
	if st.prof_ms_per_block < 0.5 {
		// Sub-ms early-chain blocks are too fast for a meaningful phase split.
		return fmt.aprintf("Profile %.2f ms/blk |%s (too fast to break down by phase)",
			st.prof_ms_per_block, rate, allocator = allocator)
	}
	return fmt.aprintf("Profile %.2f ms/blk |%s read %.0f%% prefetch %.0f%% validate %.0f%% utxo %.0f%% scripts %.0f%% undo %.0f%%",
		st.prof_ms_per_block, rate, st.prof_read_pct, st.prof_prefetch_pct,
		st.prof_valid_pct, st.prof_utxo_pct, st.prof_scripts_pct, st.prof_undo_pct, allocator = allocator)
}

flush_label :: proc(st: ^p2p.Node_Status, allocator := context.temp_allocator) -> string {
	if st.flush_progress < st.flush_total {
		pct := st.flush_total > 0 ? 100 * st.flush_progress / st.flush_total : 0
		return fmt.aprintf("[FLUSHING %d%%]", pct, allocator = allocator)
	}
	return fmt.aprintf("[FLUSH: committing]", allocator = allocator)
}
