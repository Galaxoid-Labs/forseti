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

// App/window icon, embedded (1024x1024 PNG). raylib SetWindowIcon sets the
// taskbar/window icon at runtime on Linux/Windows; it's a no-op on macOS,
// where the Dock icon comes from a .app bundle instead.
ICON_DATA := #load("../assets/forseti_icon.png")

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
g_diskw:   [NET_HISTORY]f32 // disk write bytes/sec (the index/compaction work)
g_net_idx: int
g_net_count: int
g_prev_diskw: i64
// Tip-stall detection (for the "index compacting" banner): wall-clock time of
// the last chain_height change. If the tip is flat for a few seconds while
// downloading, the node is stalled — on the disk (compaction) or the network.
g_last_height: int
g_last_height_t: f64
// Uptime-freshness: during a long compaction the node's status thread is blocked
// in connect_block, so the served snapshot (uptime included) stops changing. A
// frozen uptime is the reliable "node busy compacting" signal — unlike the
// served disk rate, which freezes too.
g_last_uptime: i64
g_last_uptime_t: f64

// Persistent scroll offset for the peers list (raygui GuiScrollPanel state).
g_peer_scroll: rl.Vector2
g_prev_sent, g_prev_recv: i64
g_prev_sample_t: f64

_net_sample :: proc(st: ^p2p.Node_Status) {
	now := f64(rl.GetTime())
	if g_prev_sample_t > 0 {
		dt := now - g_prev_sample_t
		if dt > 0.2 {
			g_net_in[g_net_idx] = f32(f64(st.total_bytes_recv - g_prev_recv) / dt)
			g_net_out[g_net_idx] = f32(f64(st.total_bytes_sent - g_prev_sent) / dt)
			g_diskw[g_net_idx] = f32(f64(st.disk_write_bytes - g_prev_diskw) / dt)
			g_net_idx = (g_net_idx + 1) % NET_HISTORY
			if g_net_count < NET_HISTORY { g_net_count += 1 }
		}
	}
	g_prev_sent = st.total_bytes_sent
	g_prev_recv = st.total_bytes_recv
	g_prev_diskw = st.disk_write_bytes
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
	if !_window_open("Forseti") {
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
		_draw_shutdown(boot, frame)
		rl.EndDrawing()
		frame += 1
	}
	return true
}

_draw_shutdown :: proc(boot: ^Boot, frame: int) {
	cy := i32(WIN_H/2 - 60)
	_text_centered("Forseti", cy, 26, COL_TEXT)
	_text_centered("Shutting down", cy + 40, 20, COL_ORANGE)

	// Real UTXO-flush progress when the shutdown flush is running (the coins
	// cache publishes flush_progress/flush_total/flushing — plain ints, safe
	// to read cross-thread). flush_progress == flush_total = the commit phase.
	flushing := boot.cs != nil && boot.cs.coins.flushing
	prog := flushing ? boot.cs.coins.flush_progress : 0
	total := flushing ? boot.cs.coins.flush_total : 0
	scanning := flushing && total > 0 && prog < total

	stage: string
	switch {
	case scanning: stage = "Flushing UTXO cache to disk"
	case flushing: stage = "Committing UTXO cache to LevelDB"
	case:
		stage = string(chain.Boot_Stage)
		if stage == "" { stage = "Stopping network and RPC" }
	}
	stage_c := fmt.ctprintf("%s", stage)
	sw: f32 = g_fonts_ok ? rl.MeasureTextEx(_font_for(16)^, stage_c, 16, 0).x : f32(rl.MeasureText(stage_c, 16))
	sx := i32((f32(WIN_W) - sw) / 2)
	_text(stage_c, sx, cy + 70, 16, COL_TEXT)
	if !scanning {
		// Animated dots only while the phase is indeterminate.
		ellipsis := "..."
		dots := (frame / (FPS / 2)) % 4
		_text(fmt.ctprintf("%s", ellipsis[:dots]), sx + i32(sw), cy + 70, 16, COL_TEXT)
	}

	if scanning {
		pct := 100 * prog / total
		_text_centered(fmt.ctprintf("%d%%   %s / %s entries", pct, _commas(prog), _commas(total)), cy + 94, 14, COL_DIM)
	} else {
		_text_centered(fmt.ctprintf("%ds elapsed", frame / FPS), cy + 94, 14, COL_DIM)
	}
	_text_centered("Do NOT force-quit - the window closes itself when done.", cy + 148, 15, COL_ORANGE)

	// Real bar while scanning; the sweep animation otherwise.
	bar_w := i32(340)
	bx := i32(WIN_W/2 - 170)
	by := cy + 180
	rl.DrawRectangle(bx, by, bar_w, 8, COL_PANEL)
	if scanning {
		fill := i32(f32(bar_w) * clamp(f32(prog) / f32(total), 0, 1))
		rl.DrawRectangle(bx, by, fill, 8, COL_GREEN)
	} else {
		sweep_w := i32(70)
		span := int(bar_w - sweep_w)
		pos := frame * 3 % (span * 2)
		if pos > span { pos = 2*span - pos }
		rl.DrawRectangle(bx + i32(pos), by, sweep_w, 8, COL_ORANGE)
	}
}

_draw_boot :: proc(boot: ^Boot, frame: int) {
	cy := i32(WIN_H/2 - 60)
	_text_centered("Forseti", cy, 26, COL_TEXT)
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
		_text_centered(fmt.ctprintf("%d / %d blocks - %ds elapsed",
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
	// Create with a STABLE title so GLFW derives a clean X11 WM_CLASS from it
	// ("forseti-gui") instead of the full dynamic title (which includes the connect
	// address). WM_CLASS is fixed at window-creation time; SetWindowTitle below only
	// updates the visible title. A stable WM_CLASS gives GNOME/Mutter a fixed
	// identity to key its icon off — it ignores the runtime _NET_WM_ICON that other
	// WMs (KDE/XFCE/i3/…) honor, so this is the one runtime lever that may help there.
	rl.InitWindow(WIN_W, WIN_H, "forseti-gui")
	if !rl.IsWindowReady() {
		// No display session (SSH, daemon context). Log and return — main
		// falls through to the normal headless thread.join path.
		fmt.eprintln("GUI: window creation failed (no display session?) — continuing headless")
		return false
	}
	rl.SetWindowTitle(title) // actual display title (WM_CLASS stays "forseti-gui")
	apply_transparent_titlebar({COL_BG.r, COL_BG.g, COL_BG.b, COL_BG.a}) // macOS unified titlebar; no-op elsewhere

	// Window/taskbar icon (Linux/Windows). macOS windows have no per-window icon
	// — GLFW logs "Regular windows do not have icons on macOS" — so skip there and
	// use the Dock icon (set_dock_icon) instead. On Linux, a lone 1024x1024 icon is
	// commonly ignored by panels/taskbars/alt-tab, which expect the standard
	// 16..256 sizes; feed a SET via SetWindowIcons and let the WM pick. GLFW copies
	// the pixels, so unload right after. SetWindowIcon(s) requires R8G8B8A8.
	when ODIN_OS != .Darwin {
		base := rl.LoadImageFromMemory(".png", raw_data(ICON_DATA), i32(len(ICON_DATA)))
		if base.data != nil {
			rl.ImageFormat(&base, .UNCOMPRESSED_R8G8B8A8)
			sizes := [?]i32{256, 128, 64, 48, 32, 24, 16}
			icons: [len(sizes)]rl.Image
			for s, i in sizes {
				img := rl.ImageCopy(base)
				rl.ImageResize(&img, s, s)
				icons[i] = img
			}
			rl.SetWindowIcons(raw_data(icons[:]), c.int(len(icons)))
			for img in icons {
				rl.UnloadImage(img)
			}
			rl.UnloadImage(base)
		}
	}
	set_dock_icon(ICON_DATA) // macOS Dock icon (no-op elsewhere)

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
				if st.chain_height != g_last_height {
					g_last_height = st.chain_height
					g_last_height_t = rl.GetTime()
				}
				if st.uptime_secs != g_last_uptime {
					g_last_uptime = st.uptime_secs
					g_last_uptime_t = rl.GetTime()
				}
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
				_text(fmt.ctprintf("VALIDATION HALTED at height %d (%s) - chain cannot progress; see log",
					st.halt_height, string(st.halt_reason[:st.halt_reason_len])), 16, 6, 14, rl.WHITE)
			} else if st.flushing {
				rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x6d, 0x1a, 0xff})
				if st.flush_progress < st.flush_total {
					pct := st.flush_total > 0 ? 100 * st.flush_progress / st.flush_total : 0
					_text(fmt.ctprintf("FLUSHING UTXO CACHE - scanning %d%% (%s / %s entries)",
						pct, _commas(st.flush_progress), _commas(st.flush_total)), 16, 6, 14, rl.WHITE)
				} else {
					_text(fmt.ctprintf("FLUSHING UTXO CACHE - committing %s entries to LevelDB (can take minutes)",
						_commas(st.flush_total)), 16, 6, 14, rl.WHITE)
				}
			} else if st.sync_state == .Downloading_Blocks && g_last_height_t > 0 && rl.GetTime() - g_last_height_t > 3 {
				// Tip flat for >3 s while downloading. If the node's uptime also
				// froze, its status thread is blocked in connect_block on a big
				// compaction (node busy, will resume). If uptime keeps ticking but
				// the tip is flat, it's the download side (waiting for blocks).
				secs := int(rl.GetTime() - g_last_height_t)
				uptime_frozen := g_last_uptime_t > 0 && rl.GetTime() - g_last_uptime_t > 3
				if uptime_frozen {
					rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x8a, 0x6d, 0x1a, 0xff})
					_text(fmt.ctprintf("INDEX COMPACTING - node busy, tip catching up (%ds) - normal, resumes when done", secs),
						16, 6, 14, rl.WHITE)
				} else {
					rl.DrawRectangle(0, 0, WIN_W, 26, rl.Color{0x4a, 0x4a, 0x52, 0xff})
					_text(fmt.ctprintf("WAITING FOR BLOCKS - tip flat %ds (downloading)", secs), 16, 6, 14, rl.WHITE)
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
	// Pulsing activity dot: animates every FRAME (driven by wall-clock, not the
	// 1 Hz data poll) so the dashboard never looks frozen while the node grinds.
	if st.sync_state == .Downloading_Blocks || st.sync_state == .Syncing_Headers {
		saw := f32(i64(rl.GetTime() * 1400) % 1000) / 1000.0 // ~1.4 Hz sawtooth
		tri := saw < 0.5 ? saw * 2 : (1 - saw) * 2           // 0 -> 1 -> 0 triangle
		dot := rl.Color{state_col.r, state_col.g, state_col.b, u8(70 + tri * 185)}
		rl.DrawCircle(718, 23, 5, dot)
	}
	_text(fmt.ctprintf("Uptime: %s", _fmt_uptime(st.uptime_secs)), pad, 38, 14, COL_DIM)
	// Wallet-backend strip — only when the address index is on (dynamic).
	if st.addr_index_on {
		synced := st.addr_index_height >= st.chain_height && st.chain_height > 0
		idx_state := synced ? "synced" : fmt.ctprintf("@ %s", _commas(st.addr_index_height))
		esp := ""
		if st.esplora_on && st.esplora_addr_len > 0 {
			esp = fmt.tprintf("   |   Esplora %s (%s reqs)", string(st.esplora_addr[:st.esplora_addr_len]), _commas(int(st.esplora_requests)))
		}
		_text(
			fmt.ctprintf("Wallet backend:  Address index %s, %s%s", _fmt_bytes(st.addr_index_bytes), idx_state, esp),
			260, 38, 14, COL_ACCENT)
	}

	// --- Sync progress ---
	// Two bars, because block-count and validation-work diverge hugely during
	// IBD: old blocks are near-empty, so you can be ~44% through the BLOCKS while
	// only ~10% of the transaction work is done. One bar for each so the fill
	// levels tell that story at a glance rather than a confusing single number.
	_group_box(rl.Rectangle{pad, 64, WIN_W - 2 * pad, 74}, "Sync Progress")

	// Bar geometry: fixed-width bars with the value drawn by our own _text at a
	// controlled x — raygui's textRight runs off the window edge and gets clipped.
	bar_x: f32 = f32(pad) + 74
	bar_w: f32 = 360
	val_x := i32(bar_x + bar_w) + 16

	// Bar 1: blocks downloaded/connected (chain_height / best_header).
	block_frac := f32(0)
	if st.best_header > 0 {
		block_frac = clamp(f32(st.chain_height) / f32(st.best_header), 0, 1)
	}
	if st.sync_state == .In_Sync { block_frac = 1 }
	_text("Blocks", pad + 12, 80, 13, COL_DIM)
	rl.GuiProgressBar(rl.Rectangle{bar_x, 78, bar_w, 14}, nil, nil, &block_frac, 0, 1)
	inflight := st.sync_state == .Downloading_Blocks ? fmt.tprintf("    |    %d in-flight", st.blocks_in_flight) : ""
	_text(fmt.ctprintf("%.0f%%    %s / %s blocks%s", block_frac * 100, _commas(st.chain_height), _commas(st.best_header), inflight),
		val_x, 78, 14, COL_TEXT)

	// Bar 2: verification work in transactions (Core's verificationprogress) —
	// the honest "how much is left". Asymptotes at ~99.99%; show 100% in sync.
	progress := st.sync_state == .In_Sync ? f32(1) : f32(st.verification_pct)
	eta: string = ""
	if st.sync_state == .Downloading_Blocks {
		// The tx-throughput estimator is meaningless in the empty-block era
		// (network-bound on ~1-tx blocks): withhold the ETA until real volume flows.
		if st.verification_pct >= 0.01 && st.eta_secs > 0 {
			eta = fmt.tprintf("    ETA ~%s", _fmt_uptime(st.eta_secs))
		} else {
			eta = "    ETA estimating..."
		}
	}
	_text("Verified", pad + 12, 104, 13, COL_DIM)
	rl.GuiProgressBar(rl.Rectangle{bar_x, 102, bar_w, 14}, nil, nil, &progress, 0, 1)
	_text(fmt.ctprintf("%.2f%% by tx weight%s", progress * 100, eta), val_x, 102, 14, COL_ACCENT)

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

	// Scrollable rows inside the SAME fixed-height box: a raygui scroll panel
	// over the row area, so overflow peers (up to STATUS_MAX_PEERS) are reachable
	// via scrollbar/mouse-wheel without growing the panel. Headers + separator
	// above stay fixed. The scrollbar only appears when content overflows.
	row_h :: i32(18)
	rows_top: i32 = 172
	rows_bottom: i32 = 140 + i32(peers_h) - 4
	rows_bounds := rl.Rectangle{f32(pad + 4), f32(rows_top), f32(WIN_W - 2 * (pad + 4)), f32(rows_bottom - rows_top)}
	content_h := max(f32(st.peer_count * int(row_h) + 6), rows_bounds.height)
	content := rl.Rectangle{rows_bounds.x, rows_bounds.y, rows_bounds.width - 14, content_h}
	view: rl.Rectangle
	rl.GuiScrollPanel(rows_bounds, nil, content, &g_peer_scroll, &view)
	rl.BeginScissorMode(i32(view.x), i32(view.y), i32(view.width), i32(view.height))
	for i in 0 ..< st.peer_count {
		p := &st.peers[i]
		y := i32(rows_bounds.y) + i32(g_peer_scroll.y) + i32(i) * row_h + 2
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
	}
	rl.EndScissorMode()

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
	_group_box(rl.Rectangle{pad, prof_y, WIN_W - 2 * pad, 110}, fmt.ctprintf("Block Profile (last %d blocks)", st.prof_blocks))
	if st.prof_blocks > 0 {
		rate_part := st.blocks_per_sec > 0 ? fmt.ctprintf("   |   %.1f blocks/sec", st.blocks_per_sec) : ""
		_text(fmt.ctprintf("Total: %.2f ms/block%s", st.prof_ms_per_block, rate_part), pad + 12, i32(prof_y) + 18, 15, COL_ACCENT)
		if st.prof_ms_per_block >= 0.5 {
			// Show Index only when an index is actually being written (addr/tx/
			// filter) — otherwise it's 0 and just clutters the line.
			index_part := st.prof_index_pct >= 0.5 ? fmt.ctprintf("   Index: %.0f%%", st.prof_index_pct) : fmt.ctprintf("")
			_text(
				fmt.ctprintf("Read: %.0f%%   Prefetch: %.0f%%   Validate: %.0f%%   UTXO: %.0f%%   Scripts: %.0f%%   Undo: %.0f%%%s",
					st.prof_read_pct, st.prof_prefetch_pct, st.prof_valid_pct,
					st.prof_utxo_pct, st.prof_scripts_pct, st.prof_undo_pct, index_part),
				pad + 12, i32(prof_y) + 46, 14, COL_TEXT)
		} else {
			// Sub-millisecond blocks (empty early chain) are too fast for a
			// meaningful per-phase split — show the rate, skip the breakdown.
			_text("Blocks too fast to break down by phase (early chain)", pad + 12, i32(prof_y) + 46, 14, COL_DIM)
		}
	} else {
		_text("Waiting for the first block to profile...", pad + 12, i32(prof_y) + 32, 14, COL_DIM)
	}

	// Live DISK-WRITE sparkline — the real index/compaction work. Block connection
	// is bursty (stall on LevelDB compaction between bursts), so blocks/sec goes
	// flat while the disk keeps writing ~130 MB/s. This graph stays lit through
	// those flatlines — showing the work that's actually happening.
	{
		sx := i32(pad) + 12
		sy := i32(prof_y) + 74
		sw := i32(WIN_W) - 2 * i32(pad) - 24 - 110 // leave room for the value label
		sh: i32 = 28
		rl.DrawRectangleLines(sx, sy, sw, sh, COL_LINE)
		peak: f32 = 1024 * 1024 // 1 MB/s floor so an idle line stays flat
		for i in 0 ..< g_net_count { peak = max(peak, g_diskw[i]) }
		if g_net_count >= 2 {
			step := f32(sw) / f32(NET_HISTORY - 1)
			for i in 1 ..< g_net_count {
				a := (g_net_idx - g_net_count + i - 1 + 2 * NET_HISTORY) % NET_HISTORY
				b := (a + 1) % NET_HISTORY
				x0 := f32(sx) + f32(i - 1) * step
				x1 := f32(sx) + f32(i) * step
				y0 := f32(sy + sh) - (g_diskw[a] / peak) * f32(sh - 2)
				y1 := f32(sy + sh) - (g_diskw[b] / peak) * f32(sh - 2)
				rl.DrawLineEx(rl.Vector2{x0, y0}, rl.Vector2{x1, y1}, 1.5, COL_ORANGE)
			}
		}
		cur := (g_net_idx - 1 + NET_HISTORY) % NET_HISTORY
		_text("disk write", sx + sw + 10, sy - 2, 12, COL_DIM)
		_text(fmt.ctprintf("%s/s", _fmt_bytes(i64(g_diskw[cur]))), sx + sw + 10, sy + 12, 14, COL_ORANGE)
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
