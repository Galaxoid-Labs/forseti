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

		nc.erase()
		if have {
			_draw(&st, info, connected)
		} else {
			_put(1, 2, "Connecting...", P_DIM, false)
		}
		nc.refresh()
		free_all(context.temp_allocator)
		time.sleep(100 * time.Millisecond)
	}
}

_put :: proc(y, x: int, s: string, pair: int, bold: bool) {
	attrs := nc.color_pair(i32(pair))
	if bold { attrs |= nc.A_BOLD }
	nc.attron(attrs)
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	nc.mvaddnstr(i32(y), i32(x), cs, i32(len(s)))
	nc.attroff(attrs)
}

_draw :: proc(st: ^p2p.Node_Status, info: Static_Info, connected: bool) {
	w := int(nc.getmaxx(nc.stdscr))
	h := int(nc.getmaxy(nc.stdscr))
	if w < 40 || h < 10 {
		_put(0, 0, "terminal too small", P_RED, true)
		return
	}

	state_label, state_pair := sync_state_label(st.sync_state)

	// Header
	_put(0, 1, fmt.tprintf("bitcoin-node-odin — %s", info.network), P_TEXT, true)
	_put(0, max(w - len(state_label) - 2, 40), state_label, state_pair, true)
	if !connected {
		_put(0, 30, "[CONNECTION LOST — retrying]", P_RED, true)
	} else if st.flushing {
		_put(0, 30, flush_label(st), P_YELLOW, true)
	}

	// Progress
	_put(1, 1, progress_line(st, w - 2), P_GREEN, false)
	_put(2, 1, blocks_line(st), P_DIM, false)

	// Peers
	y := 4
	_put(y, 1, "PEERS", P_DIM, true)
	_put(y, 8, peer_header(w), P_DIM, false)
	y += 1
	max_rows := max(h - 13, 1)
	for i in 0 ..< min(st.peer_count, max_rows) {
		_put(y, 1, peer_line(&st.peers[i], st.sync_state, w), P_TEXT, false)
		y += 1
	}

	// Network sparklines
	y += 1
	spark_w := max(w - 30, 10)
	in_rate, out_rate := current_rates()
	_put(y, 1, fmt.tprintf("IN  %s %8s/s", sparkline(g_net_in[:], g_net_idx, g_net_count, spark_w), fmt_bytes(i64(in_rate))), P_BLUE, false)
	_put(y + 1, 1, fmt.tprintf("OUT %s %8s/s", sparkline(g_net_out[:], g_net_idx, g_net_count, spark_w), fmt_bytes(i64(out_rate))), P_GREEN, false)

	// Stats + profile
	y += 3
	_put(y, 1, stats_line(st), P_TEXT, false)
	_put(y + 1, 1, profile_line(st), P_DIM, false)

	// Footer
	footer := fmt.tprintf(":%d | dbcache %d MB%s | disk %s | %s | q=quit",
		info.rpc_port, info.dbcache_mb,
		info.prune_mb > 0 ? fmt.tprintf(" | prune %d MB", info.prune_mb) : "",
		fmt_bytes(st.disk_usage), info.data_dir)
	_put(h - 1, 1, footer, P_DIM, false)
}

current_rates :: proc() -> (in_rate, out_rate: f32) {
	if g_net_count == 0 { return 0, 0 }
	cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
	return g_net_in[cur], g_net_out[cur]
}
