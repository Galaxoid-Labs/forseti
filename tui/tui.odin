// Terminal dashboard over p2p.Node_Status — the same data the GUI renders,
// for the places the GUI can't go (SSH sessions on headless servers).
// Panels mirror gui/: header, sync progress + ETA, peer table, network
// sparklines, mempool/UTXO/profile, status footer. 'q' quits (in-process:
// graceful shutdown, same as closing the GUI window).
package tui

import "core:fmt"
import "core:strings"
import "core:time"
import nc "../ncurses"
import "../p2p"

// Mirrors gui.Static_Info (tui must not import gui — that links raylib).
Static_Info :: struct {
	network:    string,
	rpc_port:   int,
	dbcache_mb: int,
	prune_mb:   int,
	data_dir:   string,
}

Status_Fetch :: proc(ud: rawptr) -> (st: p2p.Node_Status, ok: bool)

// Color pair ids.
P_TEXT :: 1
P_DIM :: 2
P_GREEN :: 3
P_YELLOW :: 4
P_BLUE :: 5
P_RED :: 6

NET_HISTORY :: 120
g_net_in: [NET_HISTORY]f32
g_net_out: [NET_HISTORY]f32
g_diskw: [NET_HISTORY]f32 // disk write bytes/sec (index/compaction work)
g_net_idx: int
g_net_count: int
g_prev_sent, g_prev_recv, g_prev_diskw: i64
g_prev_t: f64
// Tip-stall detection (for the "index compacting" header banner).
g_last_h: int
g_last_h_t: f64

_net_sample :: proc(st: ^p2p.Node_Status) {
	now := time.duration_seconds(time.since(time.Time{}))
	if g_prev_t > 0 {
		dt := now - g_prev_t
		if dt > 0.2 {
			g_net_in[g_net_idx] = f32(f64(st.total_bytes_recv - g_prev_recv) / dt)
			g_net_out[g_net_idx] = f32(f64(st.total_bytes_sent - g_prev_sent) / dt)
			dw := st.disk_write_bytes - g_prev_diskw
			g_diskw[g_net_idx] = dw > 0 ? f32(f64(dw) / dt) : 0
			g_net_idx = (g_net_idx + 1) % NET_HISTORY
			if g_net_count < NET_HISTORY { g_net_count += 1 }
		}
	}
	g_prev_recv = st.total_bytes_recv
	g_prev_sent = st.total_bytes_sent
	g_prev_diskw = st.disk_write_bytes
	g_prev_t = now
}

// Run the dashboard against any status source. Returns true if the loop ran
// (terminal initialized); false when no TTY is usable so callers can stay
// headless. quit_on_q result via return — caller decides shutdown.
run_with_source :: proc(info: Static_Info, fetch: Status_Fetch, ud: rawptr, local := false) -> bool {
	nc.setlocale(nc.LC_ALL, "")
	// Render to /dev/tty via newterm so the dashboard shows on the terminal even
	// when stdout/stderr are redirected to <datadir>/debug.log (in-process
	// --tui). Fall back to initscr (stdout) if /dev/tty isn't available.
	if tty := nc.fopen("/dev/tty", "r+"); tty != nil {
		if nc.newterm(nil, tty, tty) == nil {
			return false
		}
	} else if nc.initscr() == nil {
		return false
	}
	defer nc.endwin()
	nc.cbreak()
	nc.noecho()
	nc.curs_set(0)
	nc.keypad(nc.stdscr, true)
	nc.nodelay(nc.stdscr, true)
	if nc.has_colors() {
		nc.start_color()
		nc.use_default_colors()
		nc.init_pair(P_TEXT, nc.COLOR_WHITE, nc.COLOR_DEFAULT)
		nc.init_pair(P_DIM, nc.COLOR_CYAN, nc.COLOR_DEFAULT)
		nc.init_pair(P_GREEN, nc.COLOR_GREEN, nc.COLOR_DEFAULT)
		nc.init_pair(P_YELLOW, nc.COLOR_YELLOW, nc.COLOR_DEFAULT)
		nc.init_pair(P_BLUE, nc.COLOR_BLUE, nc.COLOR_DEFAULT)
		nc.init_pair(P_RED, nc.COLOR_RED, nc.COLOR_DEFAULT)
	}

	st: p2p.Node_Status
	have := false
	connected := false
	last_fetch: time.Tick

	for {
		ch := nc.getch()
		if ch == 'q' || ch == 'Q' {
			return true
		}

		if !have || time.duration_seconds(time.tick_since(last_fetch)) >= 1.0 {
			new_st, ok := fetch(ud)
			last_fetch = time.tick_now()
			if ok {
				st = new_st
				have = true
				connected = true
				_net_sample(&st)
				if st.chain_height != g_last_h {
					g_last_h = st.chain_height
					g_last_h_t = time.duration_seconds(time.since(time.Time{}))
				}
			} else {
				connected = false
				if local { return true } // in-process: node shut down
			}
		}

		if have {
			_draw(&st, info, connected)
		} else {
			nc.erase()
			_put(nc.stdscr, 1, 2, "Connecting...", P_DIM)
			nc.refresh()
		}
		free_all(context.temp_allocator)
		time.sleep(100 * time.Millisecond)
	}
}

_put :: proc(win: ^nc.WINDOW, y, x: int, s: string, pair: int, attrs_extra: i32 = 0) {
	attrs := nc.color_pair(i32(pair)) | attrs_extra
	nc.wattron(win, attrs)
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	nc.mvwaddnstr(win, i32(y), i32(x), cs, i32(len(s)))
	nc.wattroff(win, attrs)
}

// Bordered panel with a title on the top rule — the classic curses look.
// Created fresh each frame (cheap at dashboard framerates); batched via
// wnoutrefresh + one doupdate for a flicker-free flip.
_panel :: proc(y, x, h, w: int, title: string) -> ^nc.WINDOW {
	win := nc.newwin(i32(h), i32(w), i32(y), i32(x))
	if win == nil { return nil }
	nc.werase(win)
	nc.box(win, 0, 0)
	if title != "" {
		_put(win, 0, 2, fmt.tprintf(" %s ", title), P_DIM, nc.A_BOLD)
	}
	return win
}

_flip :: proc(win: ^nc.WINDOW) {
	if win == nil { return }
	nc.wnoutrefresh(win)
	nc.delwin(win)
}

// Solid progress bar via reverse-video spaces (the traditional widget).
_bar :: proc(win: ^nc.WINDOW, y, x, w: int, frac: f64, pair: int) {
	filled := clamp(int(frac * f64(w)), 0, w)
	nc.wattron(win, nc.color_pair(i32(pair)) | nc.A_REVERSE)
	spaces := strings.repeat(" ", filled, context.temp_allocator)
	cs := strings.clone_to_cstring(spaces, context.temp_allocator)
	nc.mvwaddnstr(win, i32(y), i32(x), cs, i32(filled))
	nc.wattroff(win, nc.color_pair(i32(pair)) | nc.A_REVERSE)
	dots := strings.repeat(".", w - filled, context.temp_allocator)
	_put(win, y, x + filled, dots, P_DIM)
}

_draw :: proc(st: ^p2p.Node_Status, info: Static_Info, connected: bool) {
	w := int(nc.getmaxx(nc.stdscr))
	h := int(nc.getmaxy(nc.stdscr))
	nc.erase()
	nc.wnoutrefresh(nc.stdscr)
	if w < 60 || h < 18 {
		_put(nc.stdscr, 0, 0, "terminal too small (min 60x18)", P_RED, nc.A_BOLD)
		nc.wnoutrefresh(nc.stdscr)
		nc.doupdate()
		return
	}

	state_label, state_pair := sync_state_label(st.sync_state)

	// Header line (no box).
	_put(nc.stdscr, 0, 1, fmt.tprintf("Forseti — %s", info.network), P_TEXT, nc.A_BOLD)
	_put(nc.stdscr, 0, w - len(state_label) - 2, state_label, state_pair, nc.A_BOLD)
	if !connected {
		_put(nc.stdscr, 0, 26, "[ CONNECTION LOST — retrying ]", P_RED, nc.A_BOLD)
	} else if st.halt_height > 0 {
		_put(nc.stdscr, 0, 26, fmt.tprintf("[ VALIDATION HALTED @ %d: %s ]",
			st.halt_height, string(st.halt_reason[:st.halt_reason_len])), P_RED, nc.A_BOLD)
	} else if st.flushing {
		_put(nc.stdscr, 0, 26, flush_label(st), P_YELLOW, nc.A_BOLD)
	} else if st.sync_state == .Downloading_Blocks && g_last_h_t > 0 {
		stall := time.duration_seconds(time.since(time.Time{})) - g_last_h_t
		if stall > 3 {
			cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
			disk_rate := g_net_count > 0 ? g_diskw[cur] : 0
			if f64(disk_rate) > 15 * 1024 * 1024 {
				_put(nc.stdscr, 0, 26, fmt.tprintf("[ INDEX COMPACTING - catching up %ds, disk %s/s ]", int(stall), fmt_bytes(i64(disk_rate))), P_YELLOW, nc.A_BOLD)
			} else {
				_put(nc.stdscr, 0, 26, fmt.tprintf("[ SYNC PAUSED - tip flat %ds (catching up) ]", int(stall)), P_DIM, nc.A_BOLD)
			}
		}
	}
	nc.wnoutrefresh(nc.stdscr)

	// Sync panel: two bars — Blocks (height %) and Verified (tx-weighted work).
	// They diverge hugely during IBD (empty early blocks), so showing both makes
	// the honest "10% of work at 44% of blocks" obvious rather than confusing.
	sync_h := 5
	sp := _panel(1, 0, sync_h, w, "Sync")
	if sp != nil {
		bx := 11
		bw := max(w - bx - 9, 4)
		block_frac := st.best_header > 0 ? clamp(f64(st.chain_height) / f64(st.best_header), 0, 1) : 0
		if st.sync_state == .In_Sync { block_frac = 1 }
		_put(sp, 1, 2, "Blocks", P_DIM)
		_bar(sp, 1, bx, bw, block_frac, P_BLUE)
		_put(sp, 1, w - 7, fmt.tprintf("%3.0f%%", block_frac * 100), P_BLUE, nc.A_BOLD)

		vpct := st.sync_state == .In_Sync ? 1.0 : st.verification_pct
		_put(sp, 2, 2, "Verified", P_DIM)
		_bar(sp, 2, bx, bw, vpct, P_GREEN)
		_put(sp, 2, w - 8, pct_label(vpct), P_GREEN, nc.A_BOLD)

		_put(sp, 3, 2, blocks_line(st), P_DIM)
		_flip(sp)
	}

	// Peers panel.
	// Panel height is pinned (8-row floor), NOT tracked to the live peer
	// count — peers churning during IBD made every panel below jump around.
	budget := max(h - sync_h - (clamp((h - 30) / 2, 2, 5) * 2 + 5) - 13, 1)
	rows := clamp(st.peer_count, 8, budget)
	shown := min(st.peer_count, rows)
	peers_h := rows + 3
	pp := _panel(1 + sync_h, 0, peers_h, w, fmt.tprintf("Peers (%d)", st.peer_count))
	if pp != nil {
		_put(pp, 1, 2, peer_header(w), P_DIM)
		for i in 0 ..< shown {
			_put(pp, 2 + i, 2, peer_line(&st.peers[i], st.sync_state, w), P_TEXT)
		}
		_flip(pp)
	}

	// Network panel: mirrored traffic chart — IN bars rise above the center
	// baseline, OUT bars hang below it. One shared scale so the halves are
	// honestly comparable; bar_rows' 1-cell floor keeps the quiet direction
	// from flatlining.
	half_rows := clamp((h - 30) / 2, 2, 5)
	net_h := half_rows * 2 + 5
	net_y := 1 + sync_h + peers_h
	// Net-in (up) vs disk-write (down): the two forces that pace IBD. When blocks
	// stall you can see whether it's the network quiet (peer-bound) or the disk
	// hammering (index/compaction-bound). Independent scales — different units.
	np := _panel(net_y, 0, net_h, w, "Net In / Disk Write")
	if np != nil {
		chart_w := max(w - 4, 20)
		in_rate, out_rate := current_rates()
		cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
		disk_rate := g_net_count > 0 ? g_diskw[cur] : 0

		// Top: network IN rising to the baseline (OUT shown as a number).
		_put(np, 1, 2, "NET IN", P_BLUE, nc.A_BOLD)
		_put(np, 1, 9, fmt.tprintf("%9s/s", fmt_bytes(i64(in_rate))), P_TEXT, nc.A_BOLD)
		_put(np, 1, 23, fmt.tprintf("(out %s/s)", fmt_bytes(i64(out_rate))), P_DIM)
		in_rows := bar_rows(g_net_in[:], g_net_idx, g_net_count, chart_w, half_rows, ring_peak(g_net_in[:]))
		for row, r in in_rows {
			_draw_bar_row(np, 2 + r, 2, row, P_BLUE)
		}

		// Center baseline.
		baseline_y := 2 + half_rows
		_put(np, baseline_y, 2, strings.repeat("-", chart_w, context.temp_allocator), P_DIM)

		// Bottom: disk-write hanging below the baseline (rows mirrored).
		disk_rows := bar_rows(g_diskw[:], g_net_idx, g_net_count, chart_w, half_rows, ring_peak(g_diskw[:]))
		for r in 0 ..< half_rows {
			_draw_bar_row(np, baseline_y + 1 + r, 2, disk_rows[half_rows - 1 - r], P_YELLOW)
		}
		oy := baseline_y + half_rows + 1
		_put(np, oy, 2, "DISK WR", P_YELLOW, nc.A_BOLD)
		_put(np, oy, 10, fmt.tprintf("%9s/s", fmt_bytes(i64(disk_rate))), P_TEXT, nc.A_BOLD)
		_put(np, oy, 24, fmt.tprintf("(peak %s/s)", fmt_bytes(i64(ring_peak(g_diskw[:])))), P_DIM)
		_flip(np)
	}

	// UTXO cache panel: entries + memory-vs-budget progress bar (turns
	// yellow while a flush is running).
	up := _panel(net_y + net_h, 0, 4, w, "UTXO Cache")
	if up != nil {
		_put(up, 1, 2, utxo_line(st), P_TEXT)
		frac := st.utxo_cache_budget > 0 ? f64(st.utxo_cache_bytes) / f64(st.utxo_cache_budget) : 0
		_bar(up, 2, 2, w - 4, clamp(frac, 0, 1), st.flushing ? P_YELLOW : P_BLUE)
		_flip(up)
	}

	// Node stats panel.
	xp := _panel(net_y + net_h + 4, 0, 4, w, "Node")
	if xp != nil {
		_put(xp, 1, 2, stats_line(st), P_TEXT)
		_put(xp, 2, 2, profile_line(st), P_DIM)
		_flip(xp)
	}

	// Wallet-backend panel — only when the address index is on (dynamic) and
	// there's vertical room above the footer.
	wb_y := net_y + net_h + 8
	if st.addr_index_on && wb_y + 3 <= h - 1 {
		wp := _panel(wb_y, 0, 3, w, "Wallet Backend")
		if wp != nil {
			_put(wp, 1, 2, wallet_backend_line(st), P_TEXT)
			_flip(wp)
		}
	}

	// Footer.
	footer := fmt.tprintf(" :%d | dbcache %d MB%s | disk %s | %s | q=quit ",
		info.rpc_port, info.dbcache_mb,
		info.prune_mb > 0 ? fmt.tprintf(" | prune %d MB", info.prune_mb) : "",
		fmt_bytes(st.disk_usage), info.data_dir)
	_put(nc.stdscr, h - 1, 1, footer, P_DIM)
	nc.wnoutrefresh(nc.stdscr)

	nc.doupdate()
}

_draw_bar_row :: proc(win: ^nc.WINDOW, y, x: int, row: string, pair: int) {
	run_start := -1
	for ci in 0 ..= len(row) {
		filled := ci < len(row) && row[ci] == '#'
		if filled && run_start < 0 {
			run_start = ci
		} else if !filled && run_start >= 0 {
			nc.wattron(win, nc.color_pair(i32(pair)) | nc.A_REVERSE)
			blanks := strings.repeat(" ", ci - run_start, context.temp_allocator)
			cs := strings.clone_to_cstring(blanks, context.temp_allocator)
			nc.mvwaddnstr(win, i32(y), i32(x + run_start), cs, i32(ci - run_start))
			nc.wattroff(win, nc.color_pair(i32(pair)) | nc.A_REVERSE)
			run_start = -1
		}
	}
}

current_rates :: proc() -> (in_rate, out_rate: f32) {
	if g_net_count == 0 { return 0, 0 }
	cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
	return g_net_in[cur], g_net_out[cur]
}
