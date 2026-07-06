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
g_net_idx: int
g_net_count: int
g_prev_sent, g_prev_recv: i64
g_prev_t: f64

_net_sample :: proc(st: ^p2p.Node_Status) {
	now := time.duration_seconds(time.since(time.Time{}))
	if g_prev_t > 0 {
		dt := now - g_prev_t
		if dt > 0.2 {
			g_net_in[g_net_idx] = f32(f64(st.total_bytes_recv - g_prev_recv) / dt)
			g_net_out[g_net_idx] = f32(f64(st.total_bytes_sent - g_prev_sent) / dt)
			g_net_idx = (g_net_idx + 1) % NET_HISTORY
			if g_net_count < NET_HISTORY { g_net_count += 1 }
		}
	}
	g_prev_recv = st.total_bytes_recv
	g_prev_sent = st.total_bytes_sent
	g_prev_t = now
}

// Run the dashboard against any status source. Returns true if the loop ran
// (terminal initialized); false when no TTY is usable so callers can stay
// headless. quit_on_q result via return — caller decides shutdown.
run_with_source :: proc(info: Static_Info, fetch: Status_Fetch, ud: rawptr, local := false) -> bool {
	nc.setlocale(nc.LC_ALL, "")
	if nc.initscr() == nil {
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
	_put(nc.stdscr, 0, 1, fmt.tprintf("bitcoin-node-odin — %s", info.network), P_TEXT, nc.A_BOLD)
	_put(nc.stdscr, 0, w - len(state_label) - 2, state_label, state_pair, nc.A_BOLD)
	if !connected {
		_put(nc.stdscr, 0, 26, "[ CONNECTION LOST — retrying ]", P_RED, nc.A_BOLD)
	} else if st.flushing {
		_put(nc.stdscr, 0, 26, flush_label(st), P_YELLOW, nc.A_BOLD)
	}
	nc.wnoutrefresh(nc.stdscr)

	// Sync panel.
	sync_h := 4
	sp := _panel(1, 0, sync_h, w, "Sync")
	if sp != nil {
		_bar(sp, 1, 2, w - 14, st.verification_pct, P_GREEN)
		_put(sp, 1, w - 10, fmt.tprintf("%6.2f%%", st.verification_pct * 100), P_GREEN, nc.A_BOLD)
		_put(sp, 2, 2, blocks_line(st), P_DIM)
		_flip(sp)
	}

	// Peers panel.
	rows := min(st.peer_count, max(h - sync_h - 12, 1))
	peers_h := rows + 3
	pp := _panel(1 + sync_h, 0, peers_h, w, fmt.tprintf("Peers (%d)", st.peer_count))
	if pp != nil {
		_put(pp, 1, 2, peer_header(w), P_DIM)
		for i in 0 ..< rows {
			_put(pp, 2 + i, 2, peer_line(&st.peers[i], st.sync_state, w), P_TEXT)
		}
		_flip(pp)
	}

	// Network panel.
	net_y := 1 + sync_h + peers_h
	np := _panel(net_y, 0, 4, w, "Network")
	if np != nil {
		spark_w := max(w - 28, 10)
		in_rate, out_rate := current_rates()
		_put(np, 1, 2, "IN ", P_BLUE, nc.A_BOLD)
		_put(np, 1, 6, sparkline(g_net_in[:], g_net_idx, g_net_count, spark_w), P_BLUE)
		_put(np, 1, 8 + spark_w, fmt.tprintf("%9s/s", fmt_bytes(i64(in_rate))), P_TEXT)
		_put(np, 2, 2, "OUT", P_GREEN, nc.A_BOLD)
		_put(np, 2, 6, sparkline(g_net_out[:], g_net_idx, g_net_count, spark_w), P_GREEN)
		_put(np, 2, 8 + spark_w, fmt.tprintf("%9s/s", fmt_bytes(i64(out_rate))), P_TEXT)
		_flip(np)
	}

	// Node stats panel.
	xp := _panel(net_y + 4, 0, 4, w, "Node")
	if xp != nil {
		_put(xp, 1, 2, stats_line(st), P_TEXT)
		_put(xp, 2, 2, profile_line(st), P_DIM)
		_flip(xp)
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

current_rates :: proc() -> (in_rate, out_rate: f32) {
	if g_net_count == 0 { return 0, 0 }
	cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
	return g_net_in[cur], g_net_out[cur]
}
