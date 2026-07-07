// Minimal ncurses bindings — curated for the btcnode TUI dashboard and the
// future setup wizard. libncurses ships with macOS and every Linux distro;
// binding style follows crypto/secp256k1.odin. Binds stdscr plus per-panel
// windows (newwin/box/werase/mvwaddnstr/wnoutrefresh/doupdate); panels/forms
// remain deferred until the setup wizard needs them.
package ncurses

import "core:c"

when ODIN_OS == .Darwin || ODIN_OS == .Linux {
	foreign import ncurses "system:ncurses"
}

WINDOW :: struct {} // opaque

// Attribute constants (NCURSES_BITS(x, 8+shift) layout, stable ABI).
A_NORMAL :: c.int(0)
A_BOLD :: c.int(1 << 21)
A_DIM :: c.int(1 << 20)
A_REVERSE :: c.int(1 << 18)

// COLOR_PAIR(n) — the C macro is ((n) << 8) & A_COLOR.
color_pair :: proc(n: c.int) -> c.int {
	return n << 8
}

COLOR_BLACK :: c.short(0)
COLOR_RED :: c.short(1)
COLOR_GREEN :: c.short(2)
COLOR_YELLOW :: c.short(3)
COLOR_BLUE :: c.short(4)
COLOR_MAGENTA :: c.short(5)
COLOR_CYAN :: c.short(6)
COLOR_WHITE :: c.short(7)
COLOR_DEFAULT :: c.short(-1) // with use_default_colors

ERR :: c.int(-1)
KEY_RESIZE :: c.int(0o632)

@(default_calling_convention = "c")
foreign ncurses {
	stdscr: ^WINDOW

	initscr :: proc() -> ^WINDOW ---
	endwin :: proc() -> c.int ---
	cbreak :: proc() -> c.int ---
	noecho :: proc() -> c.int ---
	curs_set :: proc(visibility: c.int) -> c.int ---
	keypad :: proc(win: ^WINDOW, yes: c.bool) -> c.int ---
	nodelay :: proc(win: ^WINDOW, yes: c.bool) -> c.int ---

	erase :: proc() -> c.int ---
	refresh :: proc() -> c.int ---
	mvaddnstr :: proc(y, x: c.int, str: cstring, n: c.int) -> c.int ---
	attron :: proc(attrs: c.int) -> c.int ---
	attroff :: proc(attrs: c.int) -> c.int ---

	start_color :: proc() -> c.int ---
	use_default_colors :: proc() -> c.int ---
	init_pair :: proc(pair, fg, bg: c.short) -> c.int ---
	has_colors :: proc() -> c.bool ---

	getch :: proc() -> c.int ---
	getmaxx :: proc(win: ^WINDOW) -> c.int ---
	getmaxy :: proc(win: ^WINDOW) -> c.int ---

	// Windows + borders (box uses the terminal's alternate charset — proper
	// line drawing that survives non-wide curses, unlike UTF-8 glyphs).
	newwin :: proc(nlines, ncols, begin_y, begin_x: c.int) -> ^WINDOW ---
	delwin :: proc(win: ^WINDOW) -> c.int ---
	box :: proc(win: ^WINDOW, verch, horch: c.uint) -> c.int ---
	werase :: proc(win: ^WINDOW) -> c.int ---
	mvwaddnstr :: proc(win: ^WINDOW, y, x: c.int, str: cstring, n: c.int) -> c.int ---
	wattron :: proc(win: ^WINDOW, attrs: c.int) -> c.int ---
	wattroff :: proc(win: ^WINDOW, attrs: c.int) -> c.int ---
	wnoutrefresh :: proc(win: ^WINDOW) -> c.int ---
	doupdate :: proc() -> c.int ---
}

// setlocale so UTF-8 box/sparkline glyphs render (must precede initscr).
when ODIN_OS == .Darwin {
	foreign import libc_ "system:System"
	LC_ALL :: c.int(0)
} else {
	foreign import libc_ "system:c"
	LC_ALL :: c.int(6)
}

@(default_calling_convention = "c")
foreign libc_ {
	setlocale :: proc(category: c.int, locale: cstring) -> cstring ---
}
