// First-run setup wizard (`btcnode --wizard`): a small ncurses flow that
// asks the handful of decisions that genuinely vary per user, writes a
// btcnode.conf into the chosen data directory, creates that directory, and
// prints the exact command to start the node. Everything not asked here has
// a sensible default and can be edited in the conf afterward.
package tui

import nc "../ncurses"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// lxdialog color pairs (10+ to avoid the dashboard's 1..6).
D_SCREEN     :: 10
D_SHADOW     :: 11
D_BODY       :: 12
D_BORDER     :: 13
D_TITLE      :: 14
D_ITEMKEY    :: 15
D_ITEMSEL    :: 16
D_ITEMSELKEY :: 17
D_BTNSEL     :: 18
D_TOPBAR     :: 19

g_color: bool

Wiz_Action :: enum {
	Next,
	Back,
	Quit,
}

Wiz_State :: struct {
	network:    string, // mainnet / testnet4 / signet / regtest
	datadir:    string,
	prune_mb:   int,    // 0 = full node
	dbcache_mb: int,
	rpc_cookie: bool,   // true = cookie auth, false = user/pass
	rpc_user:   string,
	rpc_pass:   string,
	// Advanced toggles (defaults match the node's built-ins).
	adv_server:      bool, // RPC server on
	adv_listen:      bool, // accept inbound connections
	adv_v2:          bool, // BIP324 v2 transport
	adv_txindex:     bool, // full transaction index
	adv_blockfilter: bool, // BIP157/158 compact block filters
	adv_fullrbf:     bool, // full replace-by-fee
	adv_persistmp:   bool, // persist mempool across restarts
	adv_bloom:       bool, // BIP37 peer bloom filters
	adv_blocksonly:  bool, // blocks-only (no tx relay)
}

// Entry point. Returns true if a config was written, false if cancelled.
run_wizard :: proc() -> bool {
	// Interactive-only: a piped/redirected stdin would spin getch() on EOF.
	if !posix.isatty(posix.STDIN_FILENO) {
		fmt.eprintln("The setup wizard needs an interactive terminal (a TTY).")
		return false
	}
	nc.setlocale(nc.LC_ALL, "")
	if nc.initscr() == nil {
		fmt.eprintln("Setup wizard needs an interactive terminal.")
		return false
	}
	nc.cbreak()
	nc.noecho()
	nc.curs_set(0)
	nc.keypad(nc.stdscr, true)
	g_color = nc.has_colors()
	if g_color {
		nc.start_color()
		// Classic lxdialog/menuconfig palette. "Gray" is COLOR_WHITE as a
		// background (light gray on most terminals); bright white is A_BOLD.
		nc.init_pair(D_SCREEN,     nc.COLOR_CYAN,  nc.COLOR_BLUE)   // blue backdrop
		nc.init_pair(D_SHADOW,     nc.COLOR_BLACK, nc.COLOR_BLACK)  // dialog shadow
		nc.init_pair(D_BODY,       nc.COLOR_BLACK, nc.COLOR_WHITE)  // dialog surface
		nc.init_pair(D_BORDER,     nc.COLOR_WHITE, nc.COLOR_WHITE)  // raised border (bold)
		nc.init_pair(D_TITLE,      nc.COLOR_BLUE,  nc.COLOR_WHITE)  // dialog title
		nc.init_pair(D_ITEMKEY,    nc.COLOR_RED,   nc.COLOR_WHITE)  // hotkey letter
		nc.init_pair(D_ITEMSEL,    nc.COLOR_WHITE, nc.COLOR_BLUE)   // selected item bar
		nc.init_pair(D_ITEMSELKEY, nc.COLOR_YELLOW, nc.COLOR_BLUE)  // selected hotkey
		nc.init_pair(D_BTNSEL,     nc.COLOR_WHITE, nc.COLOR_BLUE)   // active button
		nc.init_pair(D_TOPBAR,     nc.COLOR_WHITE, nc.COLOR_BLUE)   // top title line
	}

	st := Wiz_State {
		network       = "mainnet",
		datadir       = _default_datadir(),
		dbcache_mb    = 2048,
		rpc_cookie    = true,
		adv_server    = true,
		adv_listen    = true,
		adv_v2        = true,
		adv_fullrbf   = true,
		adv_persistmp = true,
	}
	completed := _run_steps(&st)
	nc.endwin()

	if !completed {
		fmt.println("Setup cancelled — no config written.")
		return false
	}

	// Terminal is restored now; write files and print the plan to stdout so
	// it stays in the scrollback.
	conf_path, ok := _write_config(&st)
	if !ok {
		fmt.eprintln("Failed to write configuration.")
		return false
	}
	_print_next_steps(&st, conf_path)
	return true
}

// Printed to stdout after the wizard exits (terminal already restored, so it
// stays in the scrollback). Shows every way to start the node and every way to
// watch it — the run mode is a launch-time flag, not a config setting, so we
// list them all rather than bake one in.
_print_next_steps :: proc(st: ^Wiz_State, conf_path: string) {
	dd := st.datadir
	port := _rpc_port(st.network)
	// btcnode-gui auth args, matching the RPC auth chosen in the wizard.
	auth := st.rpc_cookie \
		? fmt.tprintf("--cookie=%s/.cookie", dd) \
		: fmt.tprintf("--rpcuser=%s --rpcpassword=%s", st.rpc_user, st.rpc_pass)

	fmt.println()
	fmt.printfln("  Created  %s", dd)
	fmt.printfln("  Wrote    %s", conf_path)
	fmt.println()
	fmt.println("  Start the node (everything else comes from the conf):")
	fmt.printfln("      ./btcnode --datadir=%s              # foreground, logs to terminal", dd)
	fmt.printfln("      ./btcnode --datadir=%s --gui        # desktop dashboard window", dd)
	fmt.printfln("      ./btcnode --datadir=%s --tui        # terminal dashboard (SSH-friendly)", dd)
	fmt.printfln("      ./btcnode --datadir=%s --daemon     # background, logs to %s/debug.log", dd, dd)
	fmt.println()
	fmt.println("  Watch a running node from here or another machine (build once: make gui):")
	fmt.printfln("      ./btcnode-gui --connect=127.0.0.1:%d %s        # desktop window", port, auth)
	fmt.printfln("      ./btcnode-gui --tui --connect=127.0.0.1:%d %s  # terminal", port, auth)
	fmt.println()
	fmt.println("  RPC binds localhost by default. To reach it from another host, either")
	fmt.printfln("  tunnel it:   ssh -L %d:localhost:%d <server>", port, port)
	fmt.println("  or open it with --rpcbind/--rpcallowip (see docs/usage.md).")
	fmt.println()
}

// --- step machine ---

_run_steps :: proc(st: ^Wiz_State) -> bool {
	step := 0
	TOTAL :: 6
	for {
		act: Wiz_Action
		switch step {
		case 0: act = _step_network(st, step + 1, TOTAL)
		case 1: act = _step_datadir(st, step + 1, TOTAL)
		case 2: act = _step_disk(st, step + 1, TOTAL)
		case 3: act = _step_dbcache(st, step + 1, TOTAL)
		case 4: act = _step_rpc(st, step + 1, TOTAL)
		case 5: act = _step_review(st, step + 1, TOTAL)
		}
		switch act {
		case .Next:
			if step == 5 { return true } // review confirmed → write
			step += 1
		case .Back:
			if step > 0 { step -= 1 }
		case .Quit:
			return false
		}
	}
}

// --- screens ---

_step_network :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	opts := []string{"mainnet", "testnet4", "signet", "regtest"}
	sel := _index_of(opts, st.network, 0)
	idx, act := _menu(step, total, "Network",
		"Which Bitcoin network should this node join?", opts, sel)
	if act == .Next { st.network = opts[idx] }
	return act
}

_step_datadir :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	text, act := _field(step, total, "Data directory",
		"Where should blocks, the chainstate, and the config live?",
		st.datadir, false, "")
	if act == .Next {
		trimmed := strings.trim_space(text)
		if len(trimmed) == 0 { return _step_datadir(st, step, total) }
		st.datadir = _expand_home(trimmed)
	}
	return act
}

_step_disk :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	full_note := st.network == "mainnet" ? " (~700 GB on mainnet)" : ""
	opts := []string{
		fmt.tprintf("Full node — keep every block%s", full_note),
		"Pruned — keep only recent blocks (choose a size)",
	}
	sel := st.prune_mb > 0 ? 1 : 0
	idx, act := _menu(step, total, "Disk usage",
		"How much disk do you want the node to use?", opts, sel)
	if act != .Next { return act }
	if idx == 0 {
		st.prune_mb = 0
		return .Next
	}
	// Pruned: ask a size in GB.
	initial := st.prune_mb > 0 ? fmt.tprintf("%d", st.prune_mb / 1000) : "10"
	for {
		text, fact := _field(step, total, "Prune target",
			"Target size in GB to keep (minimum 0.55):", initial, false, "")
		if fact != .Next { return fact }
		gb, ok := strconv.parse_f64(strings.trim_space(text))
		mb := int(gb * 1000)
		if !ok || mb < 550 {
			initial = text
			// re-prompt with the same field (shows the error line)
			_err_flash("Enter at least 0.55 GB")
			continue
		}
		st.prune_mb = mb
		return .Next
	}
}

_step_dbcache :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	ram := total_ram_bytes()
	balanced := 2048
	fast := 8192
	ram_note := "RAM: unknown"
	if ram > 0 {
		gb := f64(ram) / (1024 * 1024 * 1024)
		balanced = clamp(int(gb * 1024 / 4), 450, 8192) // ~25% of RAM
		fast = clamp(int(gb * 1024 / 2), balanced, 16384)
		ram_note = fmt.tprintf("Detected RAM: %.1f GB", gb)
	}
	opts := []string{
		"Low — 450 MB",
		fmt.tprintf("Balanced — %d MB (~25%% of RAM)", balanced),
		fmt.tprintf("Fast initial sync — %d MB", fast),
		"Custom…",
	}
	idx, act := _menu(step, total, "Performance (dbcache)",
		fmt.tprintf("%s. More cache = faster sync, more memory.", ram_note), opts, 1)
	if act != .Next { return act }
	switch idx {
	case 0: st.dbcache_mb = 450
	case 1: st.dbcache_mb = balanced
	case 2: st.dbcache_mb = fast
	case 3:
		initial := fmt.tprintf("%d", st.dbcache_mb)
		for {
			text, fact := _field(step, total, "Custom dbcache",
				"Database cache in MB (minimum 4):", initial, false, "")
			if fact != .Next { return fact }
			mb, ok := strconv.parse_int(strings.trim_space(text))
			if !ok || mb < 4 {
				initial = text
				_err_flash("Enter at least 4")
				continue
			}
			st.dbcache_mb = mb
			return .Next
		}
	}
	return .Next
}

_step_rpc :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	opts := []string{
		"Cookie file (recommended — auto-generated, secure)",
		"Username + password",
	}
	sel := st.rpc_cookie ? 0 : 1
	idx, act := _menu(step, total, "RPC access",
		"How should RPC clients (bitcoin-cli, electrs) authenticate?", opts, sel)
	if act != .Next { return act }
	if idx == 0 {
		st.rpc_cookie = true
		return .Next
	}
	st.rpc_cookie = false
	// Username, then password.
	user, uact := _field(step, total, "RPC username", "Choose an RPC username:", st.rpc_user, false, "")
	if uact != .Next { return uact }
	if len(strings.trim_space(user)) == 0 {
		_err_flash("Username cannot be empty")
		return _step_rpc(st, step, total)
	}
	st.rpc_user = strings.trim_space(user)
	pass, pact := _field(step, total, "RPC password", "Choose an RPC password:", st.rpc_pass, true, "")
	if pact != .Next { return pact }
	if len(pass) == 0 {
		_err_flash("Password cannot be empty")
		return _step_rpc(st, step, total)
	}
	st.rpc_pass = pass
	return .Next
}

_step_review :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	btn := 0 // focused button: 0 Write, 1 Advanced, 2 Back, 3 Quit
	for {
		rows := []([2]string){
			{"Network", st.network},
			{"Data directory", st.datadir},
			{"Disk", st.prune_mb > 0 ? fmt.tprintf("pruned to ~%.2f GB", f64(st.prune_mb) / 1000) : "full node"},
			{"dbcache", fmt.tprintf("%d MB", st.dbcache_mb)},
			{"RPC auth", st.rpc_cookie ? "cookie file" : fmt.tprintf("user %q", st.rpc_user)},
			{"Advanced", _advanced_summary(st)},
		}
		f := _frame_open(step, total, "Review", "Confirm your setup, then write the config:", len(rows))
		for kv, i in rows {
			_wtext(f.lst, i + 1, 2, fmt.tprintf("%-16s %s", fmt.tprintf("%s:", kv[0]), kv[1]), _pair(D_BODY))
		}
		_frame_close(f, {"Write", "Advanced", "Back", "Quit"}, btn)
		switch nc.getch() {
		case nc.KEY_LEFT:  btn = (btn - 1 + 4) % 4
		case nc.KEY_RIGHT: btn = (btn + 1) % 4
		case nc.KEY_ENTER, 10, 13:
			switch btn {
			case 0: return .Next
			case 1: _advanced_screen(st)
			case 2: return .Back
			case 3: return .Quit
			}
		case 'a', 'A': _advanced_screen(st)
		case 'b', 'B': return .Back
		case 'q', 'Q': return .Quit
		case nc.KEY_RESIZE: continue
		}
	}
}

// Compact one-line summary of toggles that differ from the defaults.
_advanced_summary :: proc(st: ^Wiz_State) -> string {
	changes := make([dynamic]string, 0, 4, context.temp_allocator)
	if !st.adv_server    { append(&changes, "no RPC") }
	if !st.adv_listen    { append(&changes, "no inbound") }
	if !st.adv_v2        { append(&changes, "v1 only") }
	if st.adv_txindex    { append(&changes, "txindex") }
	if st.adv_blockfilter { append(&changes, "cfilters") }
	if !st.adv_fullrbf   { append(&changes, "no fullrbf") }
	if !st.adv_persistmp { append(&changes, "no mempool save") }
	if st.adv_bloom      { append(&changes, "bloom") }
	if st.adv_blocksonly { append(&changes, "blocks-only") }
	if len(changes) == 0 { return "defaults (press A to change)" }
	return strings.join(changes[:], ", ", context.temp_allocator)
}

// Opt-in advanced checklist (menuconfig-style [*] toggles). Returns to the
// review screen when finished. Not a numbered step.
_advanced_screen :: proc(st: ^Wiz_State) {
	Toggle :: struct { label: string, on: ^bool }
	toggles := []Toggle{
		{"RPC server (bitcoin-cli / electrs)",       &st.adv_server},
		{"Accept inbound connections",               &st.adv_listen},
		{"v2 encrypted transport (BIP324)",          &st.adv_v2},
		{"Transaction index (getrawtransaction)",    &st.adv_txindex},
		{"Compact block filters (BIP157/158)",       &st.adv_blockfilter},
		{"Full replace-by-fee",                      &st.adv_fullrbf},
		{"Persist mempool across restarts",          &st.adv_persistmp},
		{"Peer bloom filters (BIP37)",               &st.adv_bloom},
		{"Blocks-only (no transaction relay)",       &st.adv_blocksonly},
	}
	cur := 0
	for {
		f := _frame_open(0, 0, "Advanced options", "Space toggles, Enter returns to review:", len(toggles))
		for t, i in toggles {
			box := t.on^ ? "[*]" : "[ ]"
			row := i + 1
			line := fmt.tprintf("%s %s", box, t.label)
			if i == cur {
				sel := g_color ? _pair(D_ITEMSEL) | nc.A_BOLD : nc.A_REVERSE
				_wfill(f.lst, row, 1, f.lw - 2, sel)
				_wtext(f.lst, row, 2, line, sel)
			} else {
				_wtext(f.lst, row, 2, line, _pair(D_BODY))
			}
		}
		_frame_close(f, {"Toggle", "Done"}, 1)
		switch ch := nc.getch(); ch {
		case nc.KEY_UP:   cur = (cur - 1 + len(toggles)) % len(toggles)
		case nc.KEY_DOWN: cur = (cur + 1) % len(toggles)
		case ' ':
			t := toggles[cur]
			// txindex is incompatible with pruning.
			if t.on == &st.adv_txindex && !st.adv_txindex && st.prune_mb > 0 {
				_err_flash("txindex is incompatible with pruning")
				continue
			}
			t.on^ = !t.on^
		case nc.KEY_ENTER, 10, 13, 'b', 'B', 'q', 'Q', nc.KEY_LEFT:
			return
		case nc.KEY_RESIZE:
			continue
		}
	}
}

// --- widgets ---

_menu :: proc(step, total: int, title, prompt: string, options: []string, initial: int) -> (int, Wiz_Action) {
	cur := clamp(initial, 0, len(options) - 1)
	btn := 0 // focused button: 0 Select, 1 Back, 2 Quit
	for {
		f := _frame_open(step, total, title, prompt, len(options))
		for opt, i in options {
			row := i + 1 // inside the list box border
			if i == cur {
				sel := g_color ? _pair(D_ITEMSEL) | nc.A_BOLD : nc.A_REVERSE
				_wfill(f.lst, row, 1, f.lw - 2, sel)
				_wtext(f.lst, row, 2, opt, sel)
				if len(opt) > 0 {
					_wtext(f.lst, row, 2, opt[:1], g_color ? _pair(D_ITEMSELKEY) | nc.A_BOLD : nc.A_REVERSE)
				}
			} else {
				_wtext(f.lst, row, 2, opt, _pair(D_BODY))
				if len(opt) > 0 {
					_wtext(f.lst, row, 2, opt[:1], _pair(D_ITEMKEY) | nc.A_BOLD)
				}
			}
		}
		_frame_close(f, {"Select", "Back", "Quit"}, btn)
		switch nc.getch() {
		case nc.KEY_UP:             cur = (cur - 1 + len(options)) % len(options)
		case nc.KEY_DOWN:           cur = (cur + 1) % len(options)
		case nc.KEY_LEFT:           btn = (btn - 1 + 3) % 3
		case nc.KEY_RIGHT:          btn = (btn + 1) % 3
		case nc.KEY_ENTER, 10, 13:
			switch btn {
			case 0: return cur, .Next
			case 1: return cur, .Back
			case 2: return cur, .Quit
			}
		case 'b', 'B':              return cur, .Back
		case 'q', 'Q':              return cur, .Quit
		case nc.KEY_RESIZE:         continue
		}
	}
}

// Text field rendered as an lxdialog inputbox. `hidden` masks input.
_field :: proc(step, total: int, title, prompt, initial: string, hidden: bool, _unused: string) -> (string, Wiz_Action) {
	buf := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&buf, initial)
	btn := 0 // focused button: 0 OK, 1 Back
	for {
		f := _frame_open(step, total, title, prompt, 1)
		shown := hidden ? strings.repeat("*", len(buf), context.temp_allocator) : string(buf[:])
		maxw := f.lw - 4
		if len(shown) > maxw { shown = shown[len(shown) - maxw:] } // scroll to end
		_wtext(f.lst, 1, 2, shown, _pair(D_BODY))
		// Block caret at the end of the input.
		_wtext(f.lst, 1, 2 + len(shown), " ", g_color ? _pair(D_ITEMSEL) : nc.A_REVERSE)
		_frame_close(f, {"OK", "Back"}, btn)
		ch := nc.getch()
		switch {
		case ch == nc.KEY_ENTER || ch == 10 || ch == 13:
			return string(buf[:]), btn == 1 ? .Back : .Next
		case ch == nc.KEY_LEFT || ch == nc.KEY_RIGHT:
			btn = (btn + 1) % 2 // OK <-> Back
		case ch == nc.KEY_BACKSPACE || ch == 127 || ch == 8:
			if len(buf) > 0 { pop(&buf) }
		case ch >= 32 && ch < 127:
			append(&buf, byte(ch))
		case ch == nc.KEY_RESIZE:
			// redraw next iteration
		}
	}
}

// --- lxdialog-style drawing layer ---

Frame :: struct {
	dlg, lst: ^nc.WINDOW,
	dh, dw:   int, // dialog size, for the button row
	lw:       int, // list-window width
}

_pair :: proc(p: int) -> c.int {
	return g_color ? nc.color_pair(c.int(p)) : 0
}

_st :: proc(y, x: int, s: string, attr: c.int) {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	nc.attron(attr)
	nc.mvaddnstr(c.int(y), c.int(x), cs, c.int(len(s)))
	nc.attroff(attr)
}

_wtext :: proc(win: ^nc.WINDOW, y, x: int, s: string, attr: c.int) {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	nc.wattron(win, attr)
	nc.mvwaddnstr(win, c.int(y), c.int(x), cs, c.int(len(s)))
	nc.wattroff(win, attr)
}

_wfill :: proc(win: ^nc.WINDOW, y, x, w: int, attr: c.int) {
	if w <= 0 { return }
	_wtext(win, y, x, strings.repeat(" ", w, context.temp_allocator), attr)
}

// Draw the full menuconfig frame for one screen: blue backdrop + top bar,
// a shadowed gray dialog with a bordered title and prompt, and an inner
// bordered list box sized for `rows` content rows. Returns the windows;
// the caller fills the list box, then calls _frame_close.
_frame_open :: proc(step, total: int, title, prompt: string, rows: int) -> Frame {
	W := int(nc.getmaxx(nc.stdscr))
	H := int(nc.getmaxy(nc.stdscr))
	nc.erase()

	// Blue backdrop + top title line.
	if g_color {
		blank := strings.repeat(" ", W, context.temp_allocator)
		for y in 0 ..< H { _st(y, 0, blank, _pair(D_SCREEN)) }
	}
	_st(0, 1, "bitcoin-node-odin  Setup", _pair(D_TOPBAR) | nc.A_BOLD)

	dw := min(72, W - 4)
	list_h := rows + 2
	dh := min(list_h + 8, H - 2)
	dy := max((H - dh) / 2, 1)
	dx := max((W - dw) / 2, 1)

	// Drop shadow on the backdrop (down + right of the dialog).
	if g_color {
		sh := strings.repeat(" ", dw, context.temp_allocator)
		for y in dy + 1 ..= min(dy + dh, H - 1) {
			_st(y, dx + dw, "  ", _pair(D_SHADOW))
		}
		_st(min(dy + dh, H - 1), dx + 2, sh, _pair(D_SHADOW))
	}
	nc.wnoutrefresh(nc.stdscr)

	// Dialog surface.
	dlg := nc.newwin(c.int(dh), c.int(dw), c.int(dy), c.int(dx))
	body := _pair(D_BODY)
	fillrow := strings.repeat(" ", dw, context.temp_allocator)
	for y in 0 ..< dh { _wtext(dlg, y, 0, fillrow, body) }
	nc.wattron(dlg, _pair(D_BORDER) | nc.A_BOLD)
	nc.box(dlg, 0, 0)
	nc.wattroff(dlg, _pair(D_BORDER) | nc.A_BOLD)
	tt := fmt.tprintf(" %s ", title)
	_wtext(dlg, 0, max((dw - len(tt)) / 2, 2), tt, _pair(D_TITLE) | nc.A_BOLD)
	if total > 0 {
		sc := fmt.tprintf(" %d/%d ", step, total)
		_wtext(dlg, 0, dw - len(sc) - 3, sc, _pair(D_TITLE))
	}
	_wtext(dlg, 2, 3, prompt, body)

	// Inner list box.
	lw := dw - 6
	lst := nc.newwin(c.int(list_h), c.int(lw), c.int(dy + 4), c.int(dx + 3))
	lrow := strings.repeat(" ", lw, context.temp_allocator)
	for y in 0 ..< list_h { _wtext(lst, y, 0, lrow, body) }
	nc.wattron(lst, _pair(D_BORDER) | nc.A_BOLD)
	nc.box(lst, 0, 0)
	nc.wattroff(lst, _pair(D_BORDER) | nc.A_BOLD)

	return Frame{dlg = dlg, lst = lst, dh = dh, dw = dw, lw = lw}
}

// Draw the button row, flip both windows in one update, and free them.
_frame_close :: proc(f: Frame, buttons: []string, active: int) {
	total_w := 0
	for b in buttons { total_w += len(b) + 4 + 2 }
	x := max((f.dw - total_w) / 2, 2)
	for b, i in buttons {
		label := fmt.tprintf("< %s >", b)
		if i == active {
			_wtext(f.dlg, f.dh - 2, x, label, g_color ? _pair(D_BTNSEL) | nc.A_BOLD : nc.A_REVERSE)
		} else {
			_wtext(f.dlg, f.dh - 2, x, label, _pair(D_BODY))
			if len(b) > 0 { _wtext(f.dlg, f.dh - 2, x + 2, b[:1], _pair(D_ITEMKEY) | nc.A_BOLD) }
		}
		x += len(label) + 2
	}
	nc.wnoutrefresh(f.dlg)
	nc.wnoutrefresh(f.lst)
	nc.doupdate()
	nc.delwin(f.lst)
	nc.delwin(f.dlg)
}

// Flash a transient error line over the backdrop, then wait for a keypress.
_err_flash :: proc(msg: string) {
	h := int(nc.getmaxy(nc.stdscr))
	_st(h - 1, 2, fmt.tprintf(" ! %s — press any key ", msg), _pair(D_TOPBAR) | nc.A_BOLD)
	nc.refresh()
	nc.getch()
}

// --- config output ---

_write_config :: proc(st: ^Wiz_State) -> (string, bool) {
	if os.make_directory(st.datadir) != nil {
		// Non-nil is fine if it already exists; verify writability by proceeding.
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Generated by btcnode --wizard. Edit freely; see\n")
	strings.write_string(&b, "# contrib/btcnode.conf.sample for every supported key.\n\n")
	fmt.sbprintfln(&b, "network=%s", st.network)
	fmt.sbprintfln(&b, "dbcache=%d", st.dbcache_mb)
	if st.prune_mb > 0 {
		fmt.sbprintfln(&b, "prune=%d", st.prune_mb)
	}
	if !st.rpc_cookie {
		fmt.sbprintfln(&b, "rpcuser=%s", st.rpc_user)
		fmt.sbprintfln(&b, "rpcpassword=%s", st.rpc_pass)
	}
	// Advanced toggles — only emit keys that differ from the node's defaults,
	// keeping the conf minimal.
	if !st.adv_server    { strings.write_string(&b, "server=0\n") }
	if !st.adv_listen    { strings.write_string(&b, "listen=0\n") }
	if !st.adv_v2        { strings.write_string(&b, "v2transport=0\n") }
	if st.adv_txindex    { strings.write_string(&b, "txindex=1\n") }
	if st.adv_blockfilter { strings.write_string(&b, "blockfilterindex=1\n") }
	if !st.adv_fullrbf   { strings.write_string(&b, "mempoolfullrbf=0\n") }
	if !st.adv_persistmp { strings.write_string(&b, "persistmempool=0\n") }
	if st.adv_bloom      { strings.write_string(&b, "peerbloomfilters=1\n") }
	if st.adv_blocksonly { strings.write_string(&b, "blocksonly=1\n") }

	path := fmt.tprintf("%s/btcnode.conf", st.datadir)
	if os.write_entire_file(path, transmute([]byte)strings.to_string(b)) != nil {
		return "", false
	}
	return path, true
}

// Default RPC port for a network (mirrors main._select_params).
_rpc_port :: proc(network: string) -> int {
	switch network {
	case "mainnet":  return 8332
	case "testnet3": return 18332
	case "testnet4": return 48332
	case "signet":   return 38332
	case:            return 18443 // regtest
	}
}

// --- small utilities ---

_default_datadir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 {
		return "./btcnode-data"
	}
	return fmt.tprintf("%s/.btcnode", home)
}

_expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") || path == "~" {
		home := os.get_env("HOME", context.temp_allocator)
		if len(home) > 0 {
			return fmt.tprintf("%s%s", home, path[1:])
		}
	}
	return strings.clone(path)
}

_index_of :: proc(opts: []string, val: string, dflt: int) -> int {
	for o, i in opts {
		if o == val { return i }
	}
	return dflt
}
