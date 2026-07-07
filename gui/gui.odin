package gui

import "core:c"
import "core:fmt"
import rl "vendor:raylib"
import "../chain"
import "../p2p"

// Static node configuration shown in the status bar (doesn't change at runtime).
Static_Info :: struct {
	network:    string,
	rpc_port:   int,
	dbcache_mb: int,
	prune_mb:   int,    // 0 = unpruned
	data_dir:   string,
}

WIN_W :: 900
WIN_H :: 700
FPS :: 30

// Cascadia Code (variable font; raylib loads the default weight instance),
// embedded at compile time — the binary stays self-contained.
FONT_DATA := #load("fonts/CascadiaCode-VariableFont_wght.ttf")

// One atlas per text size in use, each baked at 2x so HiDPI framebuffers map
// atlas pixels 1:1 (a single scaled atlas renders soft on retina).
FONT_SIZES :: [?]i32{13, 14, 15, 18, 24}
g_fonts: [len(FONT_SIZES)]rl.Font
g_fonts_ok: bool

_font_for :: proc(size: f32) -> ^rl.Font {
	best := 0
	for fs, i in FONT_SIZES {
		if f32(fs) <= size { best = i }
	}
	return &g_fonts[best]
}

// Group box with a legible title: raygui's GuiGroupBox renders its title in
// LINE_COLOR (the border color), which is unreadable on a dark theme. Draw
// the border with an empty title and overlay the text ourselves.
COL_TITLE :: rl.Color{0x9d, 0xb2, 0xc7, 0xff}

_group_box :: proc(rect: rl.Rectangle, title: cstring) {
	rl.GuiGroupBox(rect, nil)
	if title == nil { return }
	tw: f32 = 8 * f32(len(title)) // monospace approximation
	if g_fonts_ok {
		tw = rl.MeasureTextEx(_font_for(13)^, title, 13, 0).x
	}
	// Mask the border line behind the title, then draw it.
	rl.DrawRectangle(i32(rect.x) + 8, i32(rect.y) - 7, i32(tw) + 8, 14, COL_BG)
	_text(title, i32(rect.x) + 12, i32(rect.y) - 7, 13, COL_TITLE)
}

// Draw text with the embedded font (falls back to raylib default if load failed).
_text :: proc(text: cstring, x, y: i32, size: f32, color: rl.Color) {
	if !g_fonts_ok {
		rl.DrawText(text, x, y, i32(size), color)
		return
	}
	rl.DrawTextEx(_font_for(size)^, text, rl.Vector2{f32(x), f32(y)}, size, 0, color)
}

// Horizontally centered text (measured with the same font _text draws with).
_text_centered :: proc(text: cstring, y: i32, size: f32, color: rl.Color) {
	w: f32
	if g_fonts_ok {
		w = rl.MeasureTextEx(_font_for(size)^, text, size, 0).x
	} else {
		w = f32(rl.MeasureText(text, i32(size)))
	}
	_text(text, i32((f32(WIN_W) - w) / 2), y, size, color)
}

// Dark theme palette.
COL_BG      :: rl.Color{0x10, 0x14, 0x18, 0xff}
COL_PANEL   :: rl.Color{0x16, 0x1b, 0x21, 0xff}
COL_LINE    :: rl.Color{0x2a, 0x31, 0x38, 0xff}
COL_TEXT    :: rl.Color{0xc8, 0xd0, 0xd8, 0xff}
COL_DIM     :: rl.Color{0x7a, 0x84, 0x8e, 0xff}
COL_GREEN   :: rl.Color{0x3f, 0xb9, 0x50, 0xff}
COL_ORANGE  :: rl.Color{0xd2, 0x99, 0x22, 0xff}
COL_ACCENT  :: rl.Color{0x58, 0xa6, 0xff, 0xff}

_style_int :: proc(col: rl.Color) -> c.int {
	return transmute(c.int)rl.ColorToInt(col)
}

_apply_theme :: proc() {
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.BACKGROUND_COLOR), _style_int(COL_PANEL))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.LINE_COLOR), _style_int(COL_LINE))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE), 14)
	// DEFAULT control properties populate all controls.
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_NORMAL), _style_int(COL_TEXT))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_NORMAL), _style_int(COL_LINE))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_NORMAL), _style_int(COL_PANEL))
	rl.GuiSetStyle(.PROGRESSBAR, c.int(rl.GuiControlProperty.BASE_COLOR_PRESSED), _style_int(COL_GREEN))
	rl.GuiSetStyle(.PROGRESSBAR, c.int(rl.GuiControlProperty.BORDER_COLOR_PRESSED), _style_int(COL_LINE))
}

// Format an integer with thousands separators (temp-allocated).
_commas :: proc(n: int) -> string {
	if n < 0 { return fmt.tprintf("-%s", _commas(-n)) }
	if n < 1000 { return fmt.tprintf("%d", n) }
	return fmt.tprintf("%s,%03d", _commas(n / 1000), n % 1000)
}

_fmt_uptime :: proc(secs: i64) -> string {
	if secs < 3600 { return fmt.tprintf("%dm %02ds", secs / 60, secs % 60) }
	if secs < 86400 { return fmt.tprintf("%dh %02dm", secs / 3600, (secs % 3600) / 60) }
	return fmt.tprintf("%dd %02dh", secs / 86400, (secs % 86400) / 3600)
}

_fmt_bytes :: proc(n: i64) -> string {
	if n < 1024 { return fmt.tprintf("%dB", n) }
	if n < 1024 * 1024 { return fmt.tprintf("%.0fK", f64(n) / 1024) }
	if n < 1024 * 1024 * 1024 { return fmt.tprintf("%.1fM", f64(n) / 1048576) }
	return fmt.tprintf("%.2fG", f64(n) / 1073741824)
}

// Network rate history for the traffic graph: sampled once per fetch (~1s)
// from the lifetime counters, so it works for local and remote sources alike.
NET_HISTORY :: 120
g_net_in:  [NET_HISTORY]f32
g_net_out: [NET_HISTORY]f32
g_net_idx: int
g_net_count: int
g_prev_sent, g_prev_recv: i64
g_prev_sample_t: f64

_net_sample :: proc(st: ^p2p.Node_Status) {
	now := f64(rl.GetTime())
	if g_prev_sample_t > 0 {
		dt := now - g_prev_sample_t
		if dt > 0.2 {
			g_net_in[g_net_idx] = f32(f64(st.total_bytes_recv - g_prev_recv) / dt)
			g_net_out[g_net_idx] = f32(f64(st.total_bytes_sent - g_prev_sent) / dt)
			g_net_idx = (g_net_idx + 1) % NET_HISTORY
			if g_net_count < NET_HISTORY { g_net_count += 1 }
		}
	}
	g_prev_sent = st.total_bytes_sent
	g_prev_recv = st.total_bytes_recv
	g_prev_sample_t = now
}

_sync_state_label :: proc(s: p2p.Sync_State) -> (string, rl.Color) {
	switch s {
	case .Idle:               return "Idle", COL_DIM
	case .Syncing_Headers:    return "Syncing Headers", COL_ORANGE
	case .Downloading_Blocks: return "Downloading Blocks", COL_ORANGE
	case .In_Sync:            return "In Sync", COL_GREEN
	}
	return "Unknown", COL_DIM
}

// Status provider: fetch the next snapshot. ok=false means the source is
// currently unavailable (remote node unreachable) — the dashboard keeps the
// last snapshot on screen with a disconnected banner.
Status_Fetch :: proc(ud: rawptr) -> (st: p2p.Node_Status, ok: bool)


// Run the dashboard against any status source (e.g. a remote node polled over
// RPC). fetch is called about once a second; on failure the last snapshot
// stays on screen with a "connection lost" banner and fetching retries.
run_with_source :: proc(title: cstring, info: Static_Info, fetch: Status_Fetch, ud: rawptr) -> bool {
	return _run_window(title, info, fetch, ud, nil, local = false)
}

// Handoff between the background node-init thread and the GUI main thread.
// The init thread fills cm/cs then sets ready; the GUI polls. Plain bools —
// single-byte stores, written by one thread, read by the other.
Boot :: struct {
	ready:   bool, // node init complete; cm/cs are valid
	failed:  bool, // node init failed; GUI shows the error and exits
	closing: bool, // window closed during init; node shuts down once ready
	stopped: bool, // node teardown fully complete (set by _node_main's last defer)
	cm:      ^p2p.Conn_Manager,
	cs:      ^chain.Chain_State,
	info:    Static_Info,
	request_shutdown: proc(), // set by main: stops RPC + P2P (idempotent)
}

// GUI-first startup: open the window immediately and animate init progress
// (stages published by chain.Boot_Stage) while the node boots on a worker
// thread; switch to the live dashboard when it's ready. Returns false only
// if no window could be created (headless session).
run_boot :: proc(boot: ^Boot) -> bool {
	if !_window_open("bitcoin-node-odin") {
		return false
	}
	defer _window_close()

	frame := 0
	for !boot.ready && !boot.failed {
		if rl.WindowShouldClose() {
			boot.closing = true
		}
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		_draw_boot(boot, frame)
		rl.EndDrawing()
		frame += 1
	}

	if !boot.failed && !boot.closing {
		if boot.cm == nil {
			_dashboard_loop(boot.info, nil, nil, boot.cs, local = true)
		} else {
			fetch :: proc(ud: rawptr) -> (p2p.Node_Status, bool) {
				cm := cast(^p2p.Conn_Manager)ud
				if cm.shutdown { return {}, false }
				return p2p.conn_manager_get_status(cm), true
			}
			_dashboard_loop(boot.info, fetch, boot.cm, nil, local = true)
		}
	}

	// Shutdown hold: the flush can take minutes, and a vanished window
	// reads as "safe to force-quit" — exactly when it isn't. Trigger the
	// stop, then keep the window up narrating teardown until the node
	// thread has fully finished.
	if boot.request_shutdown != nil {
		boot.request_shutdown()
	}
	frame = 0
	for !boot.stopped {
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		_draw_shutdown(frame)
		rl.EndDrawing()
		frame += 1
	}
	return true
}

_draw_shutdown :: proc(frame: int) {
	cy := i32(WIN_H/2 - 60)
	_text_centered("bitcoin-node-odin", cy, 26, COL_TEXT)
	_text_centered("Shutting down", cy + 40, 20, COL_ORANGE)

	stage := string(chain.Boot_Stage)
	if stage == "" {
		stage = "Stopping network and RPC"
	}
	stage_c := fmt.ctprintf("%s", stage)
	sw: f32 = g_fonts_ok ? rl.MeasureTextEx(_font_for(16)^, stage_c, 16, 0).x : f32(rl.MeasureText(stage_c, 16))
	sx := i32((f32(WIN_W) - sw) / 2)
	_text(stage_c, sx, cy + 70, 16, COL_TEXT)
	ellipsis := "..."
	dots := (frame / (FPS / 2)) % 4
	_text(fmt.ctprintf("%s", ellipsis[:dots]), sx + i32(sw), cy + 70, 16, COL_TEXT)

	elapsed := frame / FPS
	_text_centered(fmt.ctprintf("%ds elapsed", elapsed), cy + 94, 14, COL_DIM)
	_text_centered("Flushing the UTXO cache to disk can take a few minutes.", cy + 126, 15, COL_TEXT)
	_text_centered("Do NOT force-quit — the window closes itself when done.", cy + 148, 15, COL_ORANGE)

	bar_w := i32(340)
	bx := i32(WIN_W/2 - 170)
	by := cy + 180
	rl.DrawRectangle(bx, by, bar_w, 8, COL_PANEL)
	sweep_w := i32(70)
	span := int(bar_w - sweep_w)
	pos := frame * 3 % (span * 2)
	if pos > span { pos = 2*span - pos }
	rl.DrawRectangle(bx + i32(pos), by, sweep_w, 8, COL_ORANGE)
}

_draw_boot :: proc(boot: ^Boot, frame: int) {
	cy := i32(WIN_H/2 - 60)
	_text_centered("bitcoin-node-odin", cy, 26, COL_TEXT)
	_text_centered(fmt.ctprintf("network: %s", boot.info.network), cy + 34, 15, COL_DIM)

	// Stage centered WITHOUT the animated dots (centering a changing string
	// makes the whole line shimmer side to side); dots dangle off the end.
	stage := string(chain.Boot_Stage)
	if stage == "" {
		stage = "Starting"
	}
	stage_c := fmt.ctprintf("%s", stage)
	sw: f32 = g_fonts_ok ? rl.MeasureTextEx(_font_for(17)^, stage_c, 17, 0).x : f32(rl.MeasureText(stage_c, 17))
	sx := i32((f32(WIN_W) - sw) / 2)
	_text(stage_c, sx, cy + 66, 17, COL_ORANGE)
	ellipsis := "..."
	dots := (frame / (FPS / 2)) % 4
	_text(fmt.ctprintf("%s", ellipsis[:dots]), sx + i32(sw), cy + 66, 17, COL_ORANGE)

	elapsed := frame / FPS
	if chain.Boot_Rollback_Total > 0 {
		_text_centered(fmt.ctprintf("%d / %d blocks — %ds elapsed",
			chain.Boot_Rollback_Done, chain.Boot_Rollback_Total, elapsed), cy + 92, 14, COL_DIM)
	} else {
		_text_centered(fmt.ctprintf("%ds elapsed", elapsed), cy + 92, 14, COL_DIM)
	}

	// Indeterminate sweep bar.
	bar_w := i32(340)
	bx := i32(WIN_W/2 - 170)
	by := cy + 120
	rl.DrawRectangle(bx, by, bar_w, 8, COL_PANEL)
	sweep_w := i32(70)
	span := int(bar_w - sweep_w)
	pos := frame * 3 % (span * 2)
	if pos > span { pos = 2*span - pos } // bounce
	rl.DrawRectangle(bx + i32(pos), by, sweep_w, 8, COL_ORANGE)

	if boot.closing {
		rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x2a, 0x2a, 0xff})
		_text("Finishing startup, then shutting down...", 16, 6, 14, rl.WHITE)
	}
}

_window_open :: proc(title: cstring) -> bool {
	rl.SetConfigFlags({.WINDOW_HIGHDPI})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(WIN_W, WIN_H, title)
	if !rl.IsWindowReady() {
		// No display session (SSH, daemon context). Log and return — main
		// falls through to the normal headless thread.join path.
		fmt.eprintln("GUI: window creation failed (no display session?) — continuing headless")
		return false
	}
	rl.SetTargetFPS(FPS)
	_apply_theme()

	g_fonts_ok = true
	for fs, i in FONT_SIZES {
		g_fonts[i] = rl.LoadFontFromMemory(".ttf", raw_data(FONT_DATA), i32(len(FONT_DATA)), fs * 2, nil, 0)
		if g_fonts[i].texture.id == 0 { g_fonts_ok = false; continue }
		rl.SetTextureFilter(g_fonts[i].texture, .BILINEAR)
	}
	if g_fonts_ok {
		rl.GuiSetFont(g_fonts[2]) // 15px atlas for raygui widget text
		rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE), 15)
	}
	return true
}

_window_close :: proc() {
	for &f in g_fonts {
		if f.texture.id != 0 { rl.UnloadFont(f) }
	}
	rl.CloseWindow()
}

_run_window :: proc(title: cstring, info: Static_Info, fetch: Status_Fetch, ud: rawptr, cs: ^chain.Chain_State, local: bool) -> bool {
	if !_window_open(title) {
		return false
	}
	defer _window_close()
	_dashboard_loop(info, fetch, ud, cs, local)
	return true
}

_dashboard_loop :: proc(info: Static_Info, fetch: Status_Fetch, ud: rawptr, cs: ^chain.Chain_State, local: bool) {
	st: p2p.Node_Status
	have_status := false
	connected := false
	frame := 0

	for !rl.WindowShouldClose() {
		// Fetch about once a second (every FPS frames), starting immediately.
		if fetch != nil && frame % FPS == 0 {
			new_st, ok := fetch(ud)
			if ok {
				st = new_st
				have_status = true
				connected = true
				_net_sample(&st)
			} else {
				connected = false
				if local { break } // local node shut down → close the window
			}
		}
		frame += 1

		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)

		if fetch == nil {
			_draw_no_p2p(cs, info)
		} else if have_status {
			_draw_dashboard(&st, info)
			if st.halt_height > 0 {
				rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x2a, 0x2a, 0xff})
				_text(fmt.ctprintf("VALIDATION HALTED at height %d (%s) — chain cannot progress; see log",
					st.halt_height, string(st.halt_reason[:st.halt_reason_len])), 16, 6, 14, rl.WHITE)
			} else if st.flushing {
				rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x6d, 0x1a, 0xff})
				if st.flush_progress < st.flush_total {
					pct := st.flush_total > 0 ? 100 * st.flush_progress / st.flush_total : 0
					_text(fmt.ctprintf("FLUSHING UTXO CACHE — scanning %d%% (%s / %s entries)",
						pct, _commas(st.flush_progress), _commas(st.flush_total)), 16, 6, 14, rl.WHITE)
				} else {
					_text(fmt.ctprintf("FLUSHING UTXO CACHE — committing %s entries to LevelDB (can take minutes)",
						_commas(st.flush_total)), 16, 6, 14, rl.WHITE)
				}
			}
			if !connected {
				rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x2a, 0x2a, 0xff})
				_text("CONNECTION LOST - retrying...", 16, 6, 14, rl.WHITE)
			}
		} else {
			_text(connected ? "Loading..." : "Connecting...", 16, 16, 18, COL_DIM)
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

_draw_dashboard :: proc(st: ^p2p.Node_Status, info: Static_Info) {
	pad :: 16

	// --- Header ---
	state_label, state_col := _sync_state_label(st.sync_state)
	_text(fmt.ctprintf("Network: %s", info.network), pad, 14, 18, COL_TEXT)
	_text(fmt.ctprintf("Height: %s", _commas(st.chain_height)), 260, 14, 18, COL_TEXT)
	_text(fmt.ctprintf("Headers: %s", _commas(st.best_header)), 500, 14, 18, COL_DIM)
	_text(fmt.ctprintf("%s", state_label), 730, 14, 18, state_col)
	_text(fmt.ctprintf("Uptime: %s", _fmt_uptime(st.uptime_secs)), pad, 38, 14, COL_DIM)

	// --- Sync progress ---
	_group_box(rl.Rectangle{pad, 64, WIN_W - 2 * pad, 58}, "Sync Progress")
	// Bar shows verification progress in transactions — the honest measure of
	// work — not block count (blocks get ~40x heavier across eras).
	// Tx-based progress asymptotes at ~99.99% (denominator extrapolates to
	// "now", like Core's verificationprogress) — display 100% once in sync.
	progress := st.sync_state == .In_Sync ? f32(1) : f32(st.verification_pct)
	rl.GuiProgressBar(rl.Rectangle{pad + 12, 76, WIN_W - 2 * pad - 90, 18}, nil, fmt.ctprintf("%.2f%%", progress * 100), &progress, 0, 1)
	eta: string = ""
	if st.sync_state == .Downloading_Blocks {
		// The tx-throughput estimator is meaningless in the empty-block era
		// (network-bound on ~1-tx blocks): don't show an ETA until enough
		// real transaction volume has flowed to measure against.
		if st.verification_pct >= 0.01 && st.eta_secs > 0 {
			eta = fmt.tprintf("    |    ETA ~%s", _fmt_uptime(st.eta_secs))
		} else {
			eta = "    |    ETA estimating..."
		}
	}
	_text(
		fmt.ctprintf("%s / %s blocks    |    %d in-flight    |    %s remaining%s",
			_commas(st.chain_height), _commas(st.best_header), st.blocks_in_flight, _commas(st.blocks_remaining), eta),
		pad + 12, 100, 14, COL_DIM)

	// --- Peers table ---
	peers_h: f32 = 200
	_group_box(rl.Rectangle{pad, 140, WIN_W - 2 * pad, peers_h}, fmt.ctprintf("Peers (%d)", st.peer_count))
	col_x := [?]i32{pad + 12, pad + 52, pad + 96, pad + 296, pad + 500, pad + 580, pad + 640, pad + 710, pad + 786}
	// RATE (blocks/s) only means something during bulk download; at the tip
	// show LAST — seconds since the peer's last message (liveness).
	downloading := st.sync_state == .Downloading_Blocks
	headers := [?]cstring{"ID", "DIR", "ADDRESS", "AGENT", "HEIGHT", "BLKS", downloading ? "RATE" : "LAST", "SENT", "RECV"}
	for h, i in headers {
		_text(h, col_x[i], 152, 13, COL_DIM)
	}
	rl.DrawLine(pad + 8, 168, WIN_W - pad - 8, 168, COL_LINE)
	y: i32 = 176
	for i in 0 ..< st.peer_count {
		p := &st.peers[i]
		if y > 140 + i32(peers_h) - 18 { break }
		addr := string(p.address[:p.addr_len])
		agent := string(p.user_agent[:p.agent_len])
		if len(agent) > 22 { agent = agent[:22] }
		dir: cstring = p.inbound ? "in" : "out"
		_text(fmt.ctprintf("%d", p.id), col_x[0], y, 13, COL_TEXT)
		_text(dir, col_x[1], y, 13, p.inbound ? COL_ACCENT : COL_DIM)
		_text(fmt.ctprintf("%s", addr), col_x[2], y, 13, COL_TEXT)
		_text(fmt.ctprintf("%s", agent), col_x[3], y, 13, COL_DIM)
		_text(fmt.ctprintf("%d", p.start_height), col_x[4], y, 13, COL_TEXT)
		_text(fmt.ctprintf("%d", p.blocks_delivered), col_x[5], y, 13, COL_TEXT)
		if downloading {
			_text(fmt.ctprintf("%.1f/s", p.throughput), col_x[6], y, 13, COL_TEXT)
		} else {
			_text(fmt.ctprintf("%ds", p.last_recv_secs), col_x[6], y, 13, p.last_recv_secs > 90 ? COL_ORANGE : COL_TEXT)
		}
		_text(fmt.ctprintf("%s", _fmt_bytes(p.bytes_sent)), col_x[7], y, 13, COL_TEXT)
		_text(fmt.ctprintf("%s", _fmt_bytes(p.bytes_recv)), col_x[8], y, 13, COL_TEXT)
		y += 18
	}

	// --- Network traffic graph (last 2 minutes, in/out bytes per second) ---
	net_y: f32 = 352
	_group_box(rl.Rectangle{pad, net_y, WIN_W - 2 * pad, 88}, "Network")
	{
		gx := i32(pad) + 12
		gy := i32(net_y) + 12
		gw := i32(WIN_W - 2 * pad - 190)
		gh: i32 = 64
		// Auto-scale to the window peak.
		peak: f32 = 1024 // floor: 1 KB/s so an idle line stays flat
		for i in 0 ..< g_net_count {
			peak = max(peak, g_net_in[i])
			peak = max(peak, g_net_out[i])
		}
		rl.DrawRectangleLines(gx, gy, gw, gh, COL_LINE)
		if g_net_count >= 2 {
			step := f32(gw) / f32(NET_HISTORY - 1)
			for i in 1 ..< g_net_count {
				a := (g_net_idx - g_net_count + i - 1 + 2 * NET_HISTORY) % NET_HISTORY
				b := (a + 1) % NET_HISTORY
				x0 := f32(gx) + f32(i - 1) * step
				x1 := f32(gx) + f32(i) * step
				y_in0 := f32(gy + gh) - (g_net_in[a] / peak) * f32(gh - 2)
				y_in1 := f32(gy + gh) - (g_net_in[b] / peak) * f32(gh - 2)
				y_out0 := f32(gy + gh) - (g_net_out[a] / peak) * f32(gh - 2)
				y_out1 := f32(gy + gh) - (g_net_out[b] / peak) * f32(gh - 2)
				rl.DrawLineEx(rl.Vector2{x0, y_in0}, rl.Vector2{x1, y_in1}, 1.5, COL_ACCENT)
				rl.DrawLineEx(rl.Vector2{x0, y_out0}, rl.Vector2{x1, y_out1}, 1.5, COL_GREEN)
			}
		}
		// Current rates + peak label.
		cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
		lx := gx + gw + 14
		_text("IN", lx, gy + 2, 13, COL_ACCENT)
		_text(fmt.ctprintf("%s/s", _fmt_bytes(i64(g_net_in[cur]))), lx + 40, gy + 2, 13, COL_TEXT)
		_text("OUT", lx, gy + 22, 13, COL_GREEN)
		_text(fmt.ctprintf("%s/s", _fmt_bytes(i64(g_net_out[cur]))), lx + 40, gy + 22, 13, COL_TEXT)
		_text(fmt.ctprintf("peak %s/s", _fmt_bytes(i64(peak))), lx, gy + 46, 13, COL_DIM)
	}

	// --- Mempool + UTXO cache ---
	row2_y: f32 = 458
	_group_box(rl.Rectangle{pad, row2_y, 280, 84}, "Mempool")
	_text(fmt.ctprintf("Txs:  %s", _commas(st.mempool_count)), pad + 12, i32(row2_y) + 16, 14, COL_TEXT)
	_text(fmt.ctprintf("Size: %s vB", _commas(st.mempool_vbytes)), pad + 12, i32(row2_y) + 40, 14, COL_TEXT)

	_group_box(rl.Rectangle{pad + 296, row2_y, WIN_W - 2 * pad - 296, 84}, "UTXO Cache")
	_text(fmt.ctprintf("Entries: %s", _commas(st.utxo_cache_count)), pad + 308, i32(row2_y) + 16, 14, COL_TEXT)
	_text(
		fmt.ctprintf("Memory:  %s / %s MB", _commas(st.utxo_cache_bytes / 1_048_576), _commas(st.utxo_cache_budget / 1_048_576)),
		pad + 308, i32(row2_y) + 40, 14, COL_TEXT)
	cache_fill: f32 = 0
	if st.utxo_cache_budget > 0 {
		cache_fill = f32(st.utxo_cache_bytes) / f32(st.utxo_cache_budget)
	}
	rl.GuiProgressBar(rl.Rectangle{pad + 308, row2_y + 62, WIN_W - 2 * pad - 296 - 24, 12}, nil, nil, &cache_fill, 0, 1)

	// --- Block profile ---
	prof_y: f32 = 554
	_group_box(rl.Rectangle{pad, prof_y, WIN_W - 2 * pad, 84}, fmt.ctprintf("Block Profile (last %d blocks)", st.prof_blocks))
	if st.prof_blocks > 0 && st.prof_ms_per_block >= 0.5 {
		// Sub-millisecond blocks (empty early chain / single blocks at tip)
		// make the percentage breakdown a divide-by-nothing.
		_text(fmt.ctprintf("Total: %.1f ms/block", st.prof_ms_per_block), pad + 12, i32(prof_y) + 18, 15, COL_ACCENT)
		_text(
			fmt.ctprintf("Read: %.0f%%   Prefetch: %.0f%%   Validate: %.0f%%   UTXO: %.0f%%   Scripts: %.0f%%   Undo: %.0f%%",
				st.prof_read_pct, st.prof_prefetch_pct, st.prof_valid_pct,
				st.prof_utxo_pct, st.prof_scripts_pct, st.prof_undo_pct),
			pad + 12, i32(prof_y) + 46, 14, COL_TEXT)
	} else {
		_text("No blocks connected in the current window yet", pad + 12, i32(prof_y) + 32, 14, COL_DIM)
	}

	// --- Status bar ---
	prune_part := info.prune_mb > 0 ? fmt.tprintf("prune=%d MB   |   ", info.prune_mb) : ""
	rl.GuiStatusBar(
		rl.Rectangle{0, WIN_H - 28, WIN_W, 28},
		fmt.ctprintf("  :%d   |   dbcache=%d MB   |   %sdisk %s   |   %s",
			info.rpc_port, info.dbcache_mb, prune_part, _fmt_bytes(st.disk_usage), info.data_dir))
}

// Minimal view when P2P is disabled (--no-p2p): chain height only, read
// directly. Display-only race with the RPC thread is acceptable here.
_draw_no_p2p :: proc(cs: ^chain.Chain_State, info: Static_Info) {
	_, height := chain.chain_tip(cs)
	_text(fmt.ctprintf("Network: %s   (P2P disabled)", info.network), 16, 14, 18, COL_TEXT)
	_text(fmt.ctprintf("Height: %s", _commas(height)), 16, 48, 24, COL_ACCENT)
	rl.GuiStatusBar(
		rl.Rectangle{0, WIN_H - 28, WIN_W, 28},
		fmt.ctprintf("  RPC on :%d   |   dbcache=%d MB   |   --no-p2p", info.rpc_port, info.dbcache_mb))
}
