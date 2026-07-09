# TUI Plan for forseti

> **STATUS: DASHBOARD + WIZARD SHIPPED** — `tui/` renders Node_Status over
> ncurses (`--tui`, plus `forseti-gui --tui` remotely), and `forseti --wizard`
> runs the interactive first-run setup (tui/wizard.odin: menu + text-field
> widgets, 7 screens, RAM-aware dbcache, writes forseti.conf).

## Goal

A terminal dashboard rendering the same `Node_Status` snapshot as the GUI —
usable where the GUI can't go: SSH sessions on headless servers, no display,
no tunnel gymnastics. Later, the same ncurses foundation powers a first-run
**setup wizard** (`forseti --wizard` or auto on missing config) that writes
`forseti.conf` interactively.

## Why ncurses (vs raw ANSI)

A read-only dashboard could ship on bare ANSI escapes with zero dependencies.
The wizard cannot — text input, focus traversal, resize handling, and TERM
capability quirks are exactly what curses exists for. libncurses ships with
macOS and every Linux; bindings follow the same foreign-import pattern as
`crypto/secp256k1.odin`. One foundation, two consumers.

## Architecture

```
ncurses/   — curated FFI bindings (package ncurses)
tui/       — dashboard renderer over p2p.Node_Status (mirrors gui/ panels)
```

- **In-process**: `./forseti --tui` — main thread runs the curses loop where
  `--gui` would run raylib (mutually exclusive flags). Same Status_Fetch
  source, same 1 Hz data cadence. `q` quits = graceful shutdown (same as
  closing the GUI window).
- **Remote**: `forseti-gui --tui --connect=...` — the existing RPC-polling
  client grows a terminal renderer. SSH straight into the server and run it
  there against localhost; no tunnel needed.
- The `gui.Status_Fetch` seam is reused as-is; the TUI takes the same
  (fetch, ud, Static_Info) triple.

## Bindings scope (v1, ~25 symbols)

Lifecycle: `initscr, endwin, curs_set, cbreak, noecho, nodelay, keypad`
Drawing:   `newwin, delwin, box, mvwaddnstr, wattron, wattroff, werase,
            wnoutrefresh, doupdate, wresize, mvwin`
Color:     `start_color, use_default_colors, init_pair, COLOR_PAIR`
Input:     `wgetch` (+ KEY_ constants)
Info:      `getmaxx, getmaxy, LINES/COLS via getmaxyx on stdscr`

Deliberately excluded until the wizard: forms/menus libraries (libform,
libmenu) — evaluate then; hand-rolled fields over core ncurses may be less
dependency surface than libform.

## Dashboard layout (mirrors the GUI)

```
┌ forseti ── mainnet ── In Sync ─────────────────────────────┐
│ Height 956,945 / 956,945   ██████████████████████ 100.0%   ETA —     │
│ Peers (8)  ID DIR ADDRESS AGENT HEIGHT BLKS LAST SENT RECV           │
│ ...                                                                  │
│ Net  in ▁▂▅▇█▆▃▂▁ 22.5M/s   out ▁▁▁▁ 4K/s        (sparklines)        │
│ Mempool 5,258 tx / 2.2 MvB   UTXO 43.0M / 8.2G eff 16.4G  Flush: —   │
│ Profile 9.7ms/blk  read 24% prefetch 22% utxo 75% scripts 0%         │
└ :8332 │ dbcache 16384 │ prune 2000 │ disk 103G │ ~/forseti-mainnet ──┘
```

Network history renders as block-character sparklines (▁▂▃▄▅▆▇█) from the
same client-side rate ring the GUI uses (move the ring from gui/ into a
shared helper or duplicate the ~30 lines — decide during implementation;
tui must not import raylib).

Degradations: no color → mono; narrow terminal → drop AGENT column, then
the profile row; resize handled per frame.

## Wizard (phase 2, separate effort)

`--wizard` (and auto-prompt when no forseti.conf exists AND stdin is a TTY):
network picker, datadir, dbcache slider (with RAM detection), prune target,
RPC credentials or cookie, v2transport/GUI defaults — writes forseti.conf
and offers to start syncing immediately. Runs on the same bindings + a small
hand-rolled field/focus widget layer.

**Aesthetic: kernel-menuconfig (lxdialog) style.** lxdialog is a dialog
toolkit the kernel builds on plain ncurses — everything it does is
reproducible with our bindings plus a few additions:

- full-screen blue backdrop (`wbkgd` on stdscr with a blue color pair)
- centered light dialog box with a drop shadow (a black-filled window
  offset +1,+2 rendered beneath the dialog window)
- menu list with an `A_REVERSE` selection bar and contrast-colored hotkey
  letters; arrow-key navigation (bind `KEY_UP/KEY_DOWN/KEY_ENTER`)
- `<Select> / <Exit> / <Help>` button row, reverse-video focus, left/right
  to move between buttons
- instruction paragraph at the top of the dialog (like menuconfig's header)

Bindings to add for the wizard: `wbkgd`, `KEY_*` constants, `mvwhline`,
and echo-controlled text input for fields (`wgetnstr` or hand-rolled from
`getch` for cursor control).

## Testing

- Bindings smoke test behind a TTY check (skip in CI/non-tty test runs).
- Renderer unit tests: panel formatters are pure string builders — test the
  strings without a terminal (sparkline generator, column layout, byte/rate
  formatting shared with gui where possible).
- Manual: local node + SSH-to-server session.
```
