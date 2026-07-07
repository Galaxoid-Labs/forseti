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

PANEL_W :: 66

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
	dashboard:  string, // "gui" / "tui" / "" (headless)
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

	st := Wiz_State {
		network    = "mainnet",
		datadir    = _default_datadir(),
		dbcache_mb = 2048,
		rpc_cookie = true,
		dashboard  = "gui",
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
	fmt.println()
	fmt.printfln("  Created  %s", st.datadir)
	fmt.printfln("  Wrote    %s", conf_path)
	fmt.println()
	fmt.println("  Start your node:")
	fmt.printfln("      ./btcnode%s", _start_command_args(&st))
	fmt.println()
	return true
}

// --- step machine ---

_run_steps :: proc(st: ^Wiz_State) -> bool {
	step := 0
	TOTAL :: 7
	for {
		act: Wiz_Action
		switch step {
		case 0: act = _step_network(st, step + 1, TOTAL)
		case 1: act = _step_datadir(st, step + 1, TOTAL)
		case 2: act = _step_disk(st, step + 1, TOTAL)
		case 3: act = _step_dbcache(st, step + 1, TOTAL)
		case 4: act = _step_rpc(st, step + 1, TOTAL)
		case 5: act = _step_dashboard(st, step + 1, TOTAL)
		case 6: act = _step_review(st, step + 1, TOTAL)
		}
		switch act {
		case .Next:
			if step == 6 { return true } // review confirmed → write
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

_step_dashboard :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	opts := []string{
		"GUI window (raylib)",
		"Terminal dashboard (TUI, SSH-friendly)",
		"Headless (no dashboard)",
	}
	sel := st.dashboard == "gui" ? 0 : (st.dashboard == "tui" ? 1 : 2)
	idx, act := _menu(step, total, "Dashboard",
		"How do you want to watch the node? (goes in the start command)", opts, sel)
	if act == .Next {
		st.dashboard = idx == 0 ? "gui" : (idx == 1 ? "tui" : "")
	}
	return act
}

_step_review :: proc(st: ^Wiz_State, step, total: int) -> Wiz_Action {
	for {
		top, left := _frame(step, total, "Review", "Confirm your setup:")
		y := top
		_kv(y + 0, left, "Network", st.network)
		_kv(y + 1, left, "Data directory", st.datadir)
		_kv(y + 2, left, "Disk", st.prune_mb > 0 ? fmt.tprintf("pruned to ~%.2f GB", f64(st.prune_mb) / 1000) : "full node")
		_kv(y + 3, left, "dbcache", fmt.tprintf("%d MB", st.dbcache_mb))
		_kv(y + 4, left, "RPC auth", st.rpc_cookie ? "cookie file" : fmt.tprintf("user %q", st.rpc_user))
		_kv(y + 5, left, "Dashboard", st.dashboard == "" ? "headless" : st.dashboard)
		_footer("Enter  write config      b  change      q  cancel")
		nc.refresh()
		switch nc.getch() {
		case nc.KEY_ENTER, 10, 13:  return .Next
		case 'b', 'B', nc.KEY_LEFT: return .Back
		case 'q', 'Q':              return .Quit
		case nc.KEY_RESIZE:         continue
		}
	}
}

// --- widgets ---

_menu :: proc(step, total: int, title, prompt: string, options: []string, initial: int) -> (int, Wiz_Action) {
	cur := clamp(initial, 0, len(options) - 1)
	for {
		top, left := _frame(step, total, title, prompt)
		for opt, i in options {
			marker := i == cur ? "> " : "  "
			attr := i == cur ? nc.A_REVERSE : nc.color_pair(P_TEXT)
			_wput(top + i, left, fmt.tprintf("%s%s", marker, opt), attr)
		}
		_footer("Up/Down  move      Enter  select      b  back      q  quit")
		nc.refresh()
		switch nc.getch() {
		case nc.KEY_UP:             cur = (cur - 1 + len(options)) % len(options)
		case nc.KEY_DOWN:           cur = (cur + 1) % len(options)
		case nc.KEY_ENTER, 10, 13:  return cur, .Next
		case 'b', 'B', nc.KEY_LEFT: return cur, .Back
		case 'q', 'Q':              return cur, .Quit
		case nc.KEY_RESIZE:         continue
		}
	}
}

// Text field. `hidden` masks input (passwords). Left arrow = back.
_field :: proc(step, total: int, title, prompt, initial: string, hidden: bool, _unused: string) -> (string, Wiz_Action) {
	buf := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&buf, initial)
	nc.curs_set(1)
	defer nc.curs_set(0)
	for {
		top, left := _frame(step, total, title, prompt)
		shown := hidden ? strings.repeat("*", len(buf), context.temp_allocator) : string(buf[:])
		_wput(top, left, fmt.tprintf("> %s", shown), nc.color_pair(P_TEXT))
		_footer("Enter  confirm      Backspace  edit      Left arrow  back")
		nc.refresh()
		ch := nc.getch()
		switch {
		case ch == nc.KEY_ENTER || ch == 10 || ch == 13:
			return string(buf[:]), .Next
		case ch == nc.KEY_LEFT:
			return string(buf[:]), .Back
		case ch == nc.KEY_BACKSPACE || ch == 127 || ch == 8:
			if len(buf) > 0 { pop(&buf) }
		case ch >= 32 && ch < 127:
			append(&buf, byte(ch))
		case ch == nc.KEY_RESIZE:
			// redraw next iteration
		}
	}
}

// --- drawing helpers ---

// Draw the standard chrome (title bar + step counter, prompt) and return the
// (top row, left col) of the content region.
_frame :: proc(step, total: int, title, prompt: string) -> (int, int) {
	nc.erase()
	w := int(nc.getmaxx(nc.stdscr))
	h := int(nc.getmaxy(nc.stdscr))
	pw := min(PANEL_W, w - 2)
	left := max((w - pw) / 2, 1)
	top := max(h / 2 - 6, 1)

	_wput(top, left, "bitcoin-node-odin — setup", nc.color_pair(P_BLUE) | nc.A_BOLD)
	_wput(top, left + pw - 8, fmt.tprintf("%d / %d", step, total), nc.color_pair(P_DIM))
	_wput(top + 1, left, strings.repeat("─", pw, context.temp_allocator), nc.color_pair(P_DIM))
	_wput(top + 3, left, title, nc.color_pair(P_YELLOW) | nc.A_BOLD)
	_wput(top + 4, left, prompt, nc.color_pair(P_TEXT))
	return top + 6, left
}

_footer :: proc(hint: string) {
	h := int(nc.getmaxy(nc.stdscr))
	_wput(h - 1, 2, hint, nc.color_pair(P_DIM))
}

_kv :: proc(y, x: int, key, val: string) {
	_wput(y, x, fmt.tprintf("%-16s %s", fmt.tprintf("%s:", key), val), nc.color_pair(P_TEXT))
}

_wput :: proc(y, x: int, s: string, attr: c.int) {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	nc.attron(attr)
	nc.mvaddnstr(c.int(y), c.int(x), cs, c.int(len(s)))
	nc.attroff(attr)
}

// Flash an error message on the footer area and wait for a keypress.
_err_flash :: proc(msg: string) {
	h := int(nc.getmaxy(nc.stdscr))
	_wput(h - 2, 2, fmt.tprintf("! %s (press a key)", msg), nc.color_pair(P_RED) | nc.A_BOLD)
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

	path := fmt.tprintf("%s/btcnode.conf", st.datadir)
	if os.write_entire_file(path, transmute([]byte)strings.to_string(b)) != nil {
		return "", false
	}
	return path, true
}

// The args appended to `./btcnode` in the printed start command. datadir is
// required (that's where the conf is read from); dashboard flag as chosen.
_start_command_args :: proc(st: ^Wiz_State) -> string {
	dash := ""
	switch st.dashboard {
	case "gui": dash = " --gui"
	case "tui": dash = " --tui"
	}
	return fmt.tprintf(" --datadir=%s%s", st.datadir, dash)
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
