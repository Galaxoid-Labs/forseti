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
WIN_H :: 600
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

_sync_state_label :: proc(s: p2p.Sync_State) -> (string, rl.Color) {
	switch s {
	case .Idle:               return "Idle", COL_DIM
	case .Syncing_Headers:    return "Syncing Headers", COL_ORANGE
	case .Downloading_Blocks: return "Downloading Blocks", COL_ORANGE
	case .In_Sync:            return "In Sync", COL_GREEN
	}
	return "Unknown", COL_DIM
}

// Run the GUI render loop on the calling (main) thread. Returns when the
// window is closed or the node shuts down. cm may be nil (--no-p2p): a
// minimal chain-only view is shown. Returns false if no window could be
// created (no display session) so the caller can stay headless.
run :: proc(cm: ^p2p.Conn_Manager, cs: ^chain.Chain_State, info: Static_Info) -> bool {
	rl.SetConfigFlags({.WINDOW_HIGHDPI})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(WIN_W, WIN_H, "bitcoin-node-odin")
	if !rl.IsWindowReady() {
		// No display session (SSH, daemon context). Log and return — main
		// falls through to the normal headless thread.join path.
		fmt.eprintln("GUI: window creation failed (no display session?) — continuing headless")
		return false
	}
	defer rl.CloseWindow()
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
	defer for &f in g_fonts {
		if f.texture.id != 0 { rl.UnloadFont(f) }
	}

	for !rl.WindowShouldClose() {
		// Node shut down externally (SIGINT / stop RPC) → close the window too.
		if cm != nil && cm.shutdown { break }

		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)

		if cm != nil {
			st := p2p.conn_manager_get_status(cm)
			_draw_dashboard(&st, info)
		} else {
			_draw_no_p2p(cs, info)
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
	return true
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
	progress := f32(st.verification_pct)
	rl.GuiProgressBar(rl.Rectangle{pad + 12, 76, WIN_W - 2 * pad - 90, 18}, nil, fmt.ctprintf("%.2f%%", progress * 100), &progress, 0, 1)
	eta: string = ""
	if st.eta_secs > 0 && st.sync_state != .In_Sync {
		eta = fmt.tprintf("    |    ETA ~%s", _fmt_uptime(st.eta_secs))
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

	// --- Mempool + UTXO cache ---
	row2_y: f32 = 358
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
	prof_y: f32 = 460
	_group_box(rl.Rectangle{pad, prof_y, WIN_W - 2 * pad, 84}, fmt.ctprintf("Block Profile (last %d blocks)", st.prof_blocks))
	if st.prof_blocks > 0 {
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
