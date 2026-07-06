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
}

WIN_W :: 900
WIN_H :: 700
FPS :: 30

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
	rl.DrawText(fmt.ctprintf("Network: %s", info.network), pad, 14, 18, COL_TEXT)
	rl.DrawText(fmt.ctprintf("Height: %s", _commas(st.chain_height)), 260, 14, 18, COL_TEXT)
	rl.DrawText(fmt.ctprintf("Headers: %s", _commas(st.best_header)), 500, 14, 18, COL_DIM)
	rl.DrawText(fmt.ctprintf("%s", state_label), 730, 14, 18, state_col)
	rl.DrawText(fmt.ctprintf("Uptime: %s", _fmt_uptime(st.uptime_secs)), pad, 38, 14, COL_DIM)

	// --- Sync progress ---
	rl.GuiGroupBox(rl.Rectangle{pad, 70, WIN_W - 2 * pad, 64}, "Sync Progress")
	progress: f32 = 1
	if st.best_header > 0 {
		progress = f32(st.chain_height) / f32(st.best_header)
	}
	rl.GuiProgressBar(rl.Rectangle{pad + 12, 84, WIN_W - 2 * pad - 90, 18}, nil, fmt.ctprintf("%.2f%%", progress * 100), &progress, 0, 1)
	rl.DrawText(
		fmt.ctprintf("%s / %s blocks    |    %d in-flight    |    %s remaining",
			_commas(st.chain_height), _commas(st.best_header), st.blocks_in_flight, _commas(st.blocks_remaining)),
		pad + 12, 110, 14, COL_DIM)

	// --- Peers table ---
	peers_h: f32 = 258
	rl.GuiGroupBox(rl.Rectangle{pad, 150, WIN_W - 2 * pad, peers_h}, fmt.ctprintf("Peers (%d)", st.peer_count))
	col_x := [?]i32{pad + 12, pad + 52, pad + 96, pad + 296, pad + 500, pad + 580, pad + 640, pad + 710, pad + 786}
	headers := [?]cstring{"ID", "DIR", "ADDRESS", "AGENT", "HEIGHT", "BLKS", "RATE", "SENT", "RECV"}
	for h, i in headers {
		rl.DrawText(h, col_x[i], 162, 13, COL_DIM)
	}
	rl.DrawLine(pad + 8, 180, WIN_W - pad - 8, 180, COL_LINE)
	y: i32 = 188
	for i in 0 ..< st.peer_count {
		p := &st.peers[i]
		if y > 150 + i32(peers_h) - 20 { break }
		addr := string(p.address[:p.addr_len])
		agent := string(p.user_agent[:p.agent_len])
		if len(agent) > 22 { agent = agent[:22] }
		dir: cstring = p.inbound ? "in" : "out"
		rl.DrawText(fmt.ctprintf("%d", p.id), col_x[0], y, 13, COL_TEXT)
		rl.DrawText(dir, col_x[1], y, 13, p.inbound ? COL_ACCENT : COL_DIM)
		rl.DrawText(fmt.ctprintf("%s", addr), col_x[2], y, 13, COL_TEXT)
		rl.DrawText(fmt.ctprintf("%s", agent), col_x[3], y, 13, COL_DIM)
		rl.DrawText(fmt.ctprintf("%d", p.start_height), col_x[4], y, 13, COL_TEXT)
		rl.DrawText(fmt.ctprintf("%d", p.blocks_delivered), col_x[5], y, 13, COL_TEXT)
		rl.DrawText(fmt.ctprintf("%.1f/s", p.throughput), col_x[6], y, 13, COL_TEXT)
		rl.DrawText(fmt.ctprintf("%s", _fmt_bytes(p.bytes_sent)), col_x[7], y, 13, COL_TEXT)
		rl.DrawText(fmt.ctprintf("%s", _fmt_bytes(p.bytes_recv)), col_x[8], y, 13, COL_TEXT)
		y += 18
	}

	// --- Mempool + UTXO cache ---
	row2_y: f32 = 424
	rl.GuiGroupBox(rl.Rectangle{pad, row2_y, 280, 92}, "Mempool")
	rl.DrawText(fmt.ctprintf("Txs:  %s", _commas(st.mempool_count)), pad + 12, i32(row2_y) + 16, 14, COL_TEXT)
	rl.DrawText(fmt.ctprintf("Size: %s vB", _commas(st.mempool_vbytes)), pad + 12, i32(row2_y) + 40, 14, COL_TEXT)

	rl.GuiGroupBox(rl.Rectangle{pad + 296, row2_y, WIN_W - 2 * pad - 296, 92}, "UTXO Cache")
	rl.DrawText(fmt.ctprintf("Entries: %s", _commas(st.utxo_cache_count)), pad + 308, i32(row2_y) + 16, 14, COL_TEXT)
	rl.DrawText(
		fmt.ctprintf("Memory:  %s / %s MB", _commas(st.utxo_cache_bytes / 1_048_576), _commas(st.utxo_cache_budget / 1_048_576)),
		pad + 308, i32(row2_y) + 40, 14, COL_TEXT)
	cache_fill: f32 = 0
	if st.utxo_cache_budget > 0 {
		cache_fill = f32(st.utxo_cache_bytes) / f32(st.utxo_cache_budget)
	}
	rl.GuiProgressBar(rl.Rectangle{pad + 308, row2_y + 64, WIN_W - 2 * pad - 296 - 24, 12}, nil, nil, &cache_fill, 0, 1)

	// --- Block profile ---
	prof_y: f32 = 532
	rl.GuiGroupBox(rl.Rectangle{pad, prof_y, WIN_W - 2 * pad, 92}, fmt.ctprintf("Block Profile (last %d blocks)", st.prof_blocks))
	if st.prof_blocks > 0 {
		rl.DrawText(fmt.ctprintf("Total: %.1f ms/block", st.prof_ms_per_block), pad + 12, i32(prof_y) + 18, 15, COL_ACCENT)
		rl.DrawText(
			fmt.ctprintf("Read: %.0f%%   Prefetch: %.0f%%   Validate: %.0f%%   UTXO: %.0f%%   Scripts: %.0f%%   Undo: %.0f%%",
				st.prof_read_pct, st.prof_prefetch_pct, st.prof_valid_pct,
				st.prof_utxo_pct, st.prof_scripts_pct, st.prof_undo_pct),
			pad + 12, i32(prof_y) + 48, 14, COL_TEXT)
	} else {
		rl.DrawText("No blocks connected in the current window yet", pad + 12, i32(prof_y) + 32, 14, COL_DIM)
	}

	// --- Status bar ---
	rl.GuiStatusBar(
		rl.Rectangle{0, WIN_H - 28, WIN_W, 28},
		fmt.ctprintf("  RPC on :%d   |   dbcache=%d MB   |   %s", info.rpc_port, info.dbcache_mb, info.network))
}

// Minimal view when P2P is disabled (--no-p2p): chain height only, read
// directly. Display-only race with the RPC thread is acceptable here.
_draw_no_p2p :: proc(cs: ^chain.Chain_State, info: Static_Info) {
	_, height := chain.chain_tip(cs)
	rl.DrawText(fmt.ctprintf("Network: %s   (P2P disabled)", info.network), 16, 14, 18, COL_TEXT)
	rl.DrawText(fmt.ctprintf("Height: %s", _commas(height)), 16, 48, 24, COL_ACCENT)
	rl.GuiStatusBar(
		rl.Rectangle{0, WIN_H - 28, WIN_W, 28},
		fmt.ctprintf("  RPC on :%d   |   dbcache=%d MB   |   --no-p2p", info.rpc_port, info.dbcache_mb))
}
