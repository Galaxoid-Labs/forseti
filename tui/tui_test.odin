package tui

import "core:strings"
import "core:testing"
import "../p2p"

@(test)
test_sparkline :: proc(t: ^testing.T) {
	ring: [8]f32
	ring[0] = 0
	ring[1] = 4096
	ring[2] = 8192
	// idx=3 (next write), count=3 → renders ring[0..2] scaled to peak 8192.
	s := sparkline(ring[:], 3, 3, 3)
	runes := utf8_runes(s)
	testing.expect_value(t, len(runes), 3)
	testing.expect_value(t, runes[0], SPARK_GLYPHS[0]) // 0 → lowest
	testing.expect_value(t, runes[2], SPARK_GLYPHS[7]) // peak → highest
	// Idle ring stays at the floor glyph.
	idle: [4]f32
	s2 := sparkline(idle[:], 0, 4, 4)
	for r in utf8_runes(s2) {
		testing.expect_value(t, r, SPARK_GLYPHS[0])
	}
}

utf8_runes :: proc(s: string) -> []rune {
	out := make([dynamic]rune, 0, len(s), context.temp_allocator)
	for r in s {
		append(&out, r)
	}
	return out[:]
}

@(test)
test_progress_line :: proc(t: ^testing.T) {
	st: p2p.Node_Status
	st.verification_pct = 0.5
	line := progress_line(&st, 30)
	testing.expect(t, strings.contains(line, "50.00%"), "should show percent")
	testing.expect(t, strings.contains(line, "#"), "should have filled cells")
	testing.expect(t, strings.contains(line, "."), "should have empty cells")
}

@(test)
test_peer_line_widths :: proc(t: ^testing.T) {
	ps: p2p.Peer_Status
	ps.id = 7
	addr := "203.0.113.9"
	copy(ps.address[:], addr)
	ps.addr_len = len(addr)
	agent := "/Satoshi:31.0.0/"
	copy(ps.user_agent[:], agent)
	ps.agent_len = len(agent)
	ps.start_height = 956_945

	wide := peer_line(&ps, .In_Sync, 120)
	testing.expect(t, strings.contains(wide, "/Satoshi:31.0.0/"), "wide layout includes agent")
	narrow := peer_line(&ps, .In_Sync, 80)
	testing.expect(t, !strings.contains(narrow, "/Satoshi"), "narrow layout drops agent")
	testing.expect(t, strings.contains(narrow, "203.0.113.9"), "narrow layout keeps address")

	// Alignment invariant: every column starts at the same offset in the
	// header and in a data row (both widths).
	for w in ([2]int{80, 120}) {
		hdr := peer_header(w)
		row := peer_line(&ps, .In_Sync, w)
		testing.expect_value(t, strings.index(hdr, "HEIGHT") >= 0, true)
		testing.expect_value(t, strings.index(row, "956945"), strings.index(hdr, "HEIGHT"))
		testing.expect_value(t, strings.index(row, "203.0.113.9"), strings.index(hdr, "ADDRESS"))
	}
}

@(test)
test_blocks_line_eta_gate :: proc(t: ^testing.T) {
	st: p2p.Node_Status
	st.sync_state = .Downloading_Blocks
	st.chain_height = 100
	st.best_header = 200
	st.verification_pct = 0.001
	st.eta_secs = 3600
	testing.expect(t, strings.contains(blocks_line(&st), "estimating"), "ETA gated below 1%")
	st.verification_pct = 0.5
	testing.expect(t, strings.contains(blocks_line(&st), "ETA ~1h"), "ETA shown past gate")
}

@(test)
test_bar_rows :: proc(t: ^testing.T) {
	ring: [4]f32
	ring[0] = 0     // empty column
	ring[1] = 4096  // half of peak
	ring[2] = 8192  // peak
	rows := bar_rows(ring[:], 3, 3, 3, 4)
	testing.expect_value(t, len(rows), 4)
	// Peak column (last) filled in every row; zero column never filled.
	for r in 0 ..< 4 {
		testing.expect_value(t, rows[r][2], '#')
		testing.expect_value(t, rows[r][0], ' ')
	}
	// Half column fills the bottom two of four rows only.
	testing.expect_value(t, rows[0][1], ' ')
	testing.expect_value(t, rows[1][1], ' ')
	testing.expect_value(t, rows[2][1], '#')
	testing.expect_value(t, rows[3][1], '#')
}

@(test)
test_bar_rows_fills_width :: proc(t: ^testing.T) {
	// Regression (2026-07-17): a short history must STRETCH to fill a wide chart,
	// not right-align and leave a blank left gutter. 3 nonzero samples across an
	// 8-wide chart must fill all 8 columns.
	ring: [4]f32
	ring[0] = 8192
	ring[1] = 8192
	ring[2] = 8192 // ring[3] stays 0
	rows := bar_rows(ring[:], 3, 3, 8, 1) // idx=3, count=3, width=8, 1 row
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, len(rows[0]), 8)
	for c in 0 ..< 8 {
		testing.expect_value(t, rows[0][c], '#') // no blank left gutter
	}
}

@(test)
test_bar_rows_shared_scale :: proc(t: ^testing.T) {
	// OUT-style ring: tiny values against a huge external peak. Without the
	// floor these would all round to level 0; with it, nonzero samples fill
	// exactly the bottom row and zero samples fill nothing.
	ring: [4]f32
	ring[0] = 2048 // 2K/s
	ring[1] = 0
	ring[2] = 2048
	ring[3] = 2048
	rows := bar_rows(ring[:], 0, 4, 4, 4, 40_000_000) // shared peak 40M/s
	testing.expect_value(t, rows[0], "    ") // top rows empty
	testing.expect_value(t, rows[1], "    ")
	testing.expect_value(t, rows[2], "    ")
	testing.expect_value(t, rows[3], "# ##") // 1-cell floor, zero stays empty
}

@(test)
test_pct_label_no_leading_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, pct_label(0.4545), " 45.45%")
	testing.expect_value(t, pct_label(0.0702), "  7.02%")
	testing.expect_value(t, pct_label(1.0), "100.00%")
	testing.expect_value(t, pct_label(0.0), "  0.00%")
}
