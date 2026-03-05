# GUI Plan for bitcoin-node-odin

## Goal

Add an optional GUI dashboard to the node, showing sync progress, peer status, mempool stats, and chain info in real-time. Enabled via `--gui` flag; headless by default.

---

## Option Comparison

### 1. Raylib + Raygui (vendor:raylib)

**Pros:**
- Ships with Odin — zero external dependencies, `import "vendor:raylib"` just works
- Self-contained: window creation, input, rendering all in one library
- Raygui has 30+ widgets: buttons, sliders, progress bars, text boxes, list views, scroll panels, tabs, status bars
- Styleable via `.rgs` theme files
- Cross-platform: macOS, Linux, Windows
- Simple API: `InitWindow` → render loop → `CloseWindow`

**Cons:**
- Game-oriented — widgets look "gamey" by default (can be styled)
- No docking/multi-window (single window only)
- Limited table/grid support — would need to build a custom block/peer table from primitives
- No text selection or rich text editing

**Verdict:** Lowest friction. Good enough for a dashboard. Best choice for v1.

### 2. Microui (vendor:microui)

**Pros:**
- Ships with Odin — `import "vendor:microui"`
- Tiny (~1200 SLOC), immediate-mode
- Fixed memory model — no allocations
- Backend-agnostic: outputs draw commands (rects, text, icons), you provide the renderer
- Windows, panels, buttons, sliders, checkboxes, text boxes, tree nodes, headers

**Cons:**
- **Requires a rendering backend** — you must wire up a renderer (raylib, SDL, OpenGL). Microui only emits draw commands; it doesn't create windows or render pixels
- Very minimal widget set: no progress bars, no tables, no tabs, no status bars
- Tiny default font (no font scaling)
- Would need raylib anyway for the window/rendering — so you'd be using raylib without raygui's widgets

**Verdict:** Elegant but too low-level. You'd build raygui-level widgets on top of microui+raylib, which is more work than just using raygui.

### 3. Dear ImGui (odin-imgui, external)

**Pros:**
- Most powerful widget set: tables, docking, plots, tree nodes, menus, multi-viewport
- Docking branch: drag-and-drop window arrangement
- Mature ecosystem, tons of documentation
- Several Odin binding options (L-4/odin-imgui on GitLab is actively maintained, last updated July 2025)

**Cons:**
- **External dependency** — must clone, run Python build script (`build.py` with `ply` library), compile C++ (Dear ImGui + backends)
- Backend setup: need GLFW+OpenGL3 or SDL2+OpenGL3 (not just `import` and go)
- Build complexity: Python + C++ compiler + backend library linking
- Mac backends marked "untested" by maintainer
- Heavier integration: context creation, backend init, font atlas setup, descriptor pools

**Verdict:** Best UI but significant build/setup overhead. Worth it if we need docking or complex layouts later (v2+).

---

## Recommendation: Raylib + Raygui for v1

Raylib + raygui gives us a working dashboard with the least effort. Zero external deps, just `import "vendor:raylib"`. If we outgrow it, we can swap in Dear ImGui later — the data layer (Node_Status snapshot) would stay the same.

---

## Architecture

### Thread Model (current)

```
Main thread    → setup → wait for P2P thread → shutdown
RPC thread     → HTTP server loop
P2P thread     → nbio event loop (peers, sync, blocks)
Worker threads → parallel script verification
```

### Thread Model (with GUI)

```
Main thread    → setup → GUI render loop (30fps) → shutdown
RPC thread     → HTTP server loop
P2P thread     → nbio event loop (peers, sync, blocks)
Worker threads → parallel script verification
```

The main thread currently just calls `thread.join(p2p_thread)` and blocks. With `--gui`, it would instead run the raylib render loop, polling a shared `Node_Status` struct.

### Data Flow: Node_Status Snapshot

The GUI reads node state via a **snapshot struct** updated by the P2P thread on each periodic timer tick (1 second). This avoids the GUI reaching into chain/peer internals across threads.

```odin
Node_Status :: struct {
    // Chain
    chain_height:      int,
    best_header:       int,
    tip_hash:          Hash256,
    chain_size_bytes:  i64,
    verification_pct:  f64,     // assumevalid progress

    // Sync
    sync_state:        Sync_State,  // Idle, Syncing_Headers, Downloading_Blocks, In_Sync
    blocks_remaining:  int,
    blocks_in_flight:  int,
    headers_per_sec:   f64,
    blocks_per_sec:    f64,

    // Peers
    peer_count:        int,
    peers:             [MAX_OUTBOUND_PEERS]Peer_Status,

    // Mempool
    mempool_count:     int,
    mempool_bytes:     i64,

    // UTXO
    utxo_cache_count:  int,
    utxo_cache_bytes:  i64,
    utxo_cache_budget: i64,

    // Profiling (last 1000-block batch)
    last_profile:      Block_Profile,

    // System
    uptime_secs:       i64,
    network:           string,
}

Peer_Status :: struct {
    id:            Peer_Id,
    address:       [64]byte,  // fixed buffer, no allocation
    addr_len:      int,
    state:         Peer_State,
    user_agent:    [128]byte,
    agent_len:     int,
    start_height:  i32,
    bytes_sent:    i64,
    bytes_recv:    i64,
    blocks_served: int,
    throughput:    f64,     // blocks/sec
    block_limit:   int,
}
```

**Update mechanism:**
- `Node_Status` lives on `Conn_Manager` (or a separate global)
- P2P thread writes it under a `sync.Mutex` every 1 second in `_on_periodic_timer`
- GUI thread reads it under the same mutex at 30fps
- Lock contention is negligible (1 write/sec, 30 reads/sec, each <1μs)

For `--no-p2p` mode, the main thread populates `Node_Status` directly from chain state (no P2P data).

### No-GUI Path (default)

When `--gui` is not set, behavior is unchanged: main thread blocks on `thread.join(p2p_thread)`. The `Node_Status` struct is simply never allocated. Zero overhead.

---

## GUI Layout

```
┌─ bitcoin-node-odin ──────────────────────────────────────────────┐
│                                                                   │
│  Network: signet          Height: 294,062        State: In Sync   │
│  Uptime: 2h 14m           Best Header: 294,062                   │
│                                                                   │
│  ┌─ Sync Progress ──────────────────────────────────────────────┐ │
│  │ ████████████████████████████████████████████████████████ 100% │ │
│  │ 294,062 / 294,062 blocks   |   0 in-flight   |  0 remaining │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─ Peers (6/8) ────────────────────────────────────────────────┐ │
│  │ ID │ Address          │ Agent              │ Height │ Speed   │ │
│  │  1 │ 45.12.34.56      │ /Satoshi:27.1.0/   │ 294062 │  26/s  │ │
│  │  3 │ 89.67.12.34      │ /Satoshi:27.0.0/   │ 294062 │  18/s  │ │
│  │  4 │ 123.45.67.89     │ /Satoshi:27.1.0/   │ 294062 │  34/s  │ │
│  │  5 │ 56.78.90.12      │ /btcd:0.24.2/      │ 294062 │ 131/s  │ │
│  │  6 │ 34.56.78.90      │ /Satoshi:26.2.0/   │ 294062 │  24/s  │ │
│  │  8 │ 78.90.12.34      │ /Satoshi:27.1.0/   │ 294062 │  63/s  │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─ Mempool ───────────┐  ┌─ UTXO Cache ──────────────────────┐ │
│  │ Txs:  142            │  │ Entries: 63,495,756               │ │
│  │ Size: 284 KB         │  │ Memory:  13,025 MB / 16,374 MB   │ │
│  └──────────────────────┘  │ ████████████████████████████░░░░  │ │
│                             └──────────────────────────────────┘ │
│                                                                   │
│  ┌─ Last Block Profile (1000 blks @ 293999) ────────────────────┐ │
│  │ Total: 10.0ms/blk  Read: 12%  Valid: 38%  UTXO: 37%         │ │
│  │ Scripts: 12%  Undo: 1%  Index: 0%                            │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Status: RPC on :38332 │ P2P on :38333 │ dbcache=16384 MB        │
└──────────────────────────────────────────────────────────────────┘
```

Window size: ~900x700, fixed layout (no docking needed).

---

## Implementation Steps

### Step 1: Node_Status struct + mutex update

**Files:** `p2p/types.odin`, `p2p/conn_manager.odin`

1. Define `Node_Status` and `Peer_Status` in `p2p/types.odin`
2. Add `status: Node_Status` and `status_mutex: sync.Mutex` to `Conn_Manager`
3. In `_on_periodic_timer`: populate `status` under mutex lock from:
   - `cm.chain` → height, tip hash
   - `cm.sync_mgr` → state, blocks remaining, in-flight
   - `cm.peers` → peer table
   - `cm.mp` → mempool count/size
   - `cm.chain.coins_cache` → UTXO count/memory
4. Export `conn_manager_get_status(cm: ^Conn_Manager) -> Node_Status` — mutex read, returns copy

### Step 2: GUI package

**New directory:** `gui/`

**Files:**
- `gui/gui.odin` — Main render loop, window management
- `gui/panels.odin` — Individual panel drawing (sync, peers, mempool, UTXO, profile)
- `gui/theme.odin` — Dark theme colors and style configuration

**Key procs:**
```odin
gui_init :: proc(cm: ^Conn_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params)
gui_run :: proc()  // Blocking render loop, returns on window close
gui_shutdown :: proc()
```

### Step 3: Main thread integration

**File:** `main.odin`

1. Add `--gui` CLI flag
2. If `--gui`:
   - After starting RPC + P2P threads, call `gui_run()` (blocking render loop)
   - When `gui_run()` returns (window closed), trigger shutdown (same as SIGINT)
3. If no `--gui`: existing behavior (block on `thread.join`)

### Step 4: Render the panels

Using raygui widgets:
- `GuiProgressBar` for sync progress and UTXO cache fill
- `GuiPanel` / `GuiGroupBox` for sections
- `GuiStatusBar` for bottom status line
- `DrawText` / `DrawTextEx` for the peer table (raygui's `GuiListView` is limited — manual text rendering in a `GuiPanel` with `GuiScrollPanel` is cleaner for tabular data)
- Custom formatted text for numbers (commas, percentages, rates)

### Step 5: Polish

- Dark theme (set via `GuiSetStyle` calls)
- Window icon
- Graceful close: window close button → triggers same `conn_manager_shutdown` + `rpc_server_stop`
- Handle `--no-p2p` mode: show chain + mempool + RPC status only, no peer table

---

## Files Changed/Created

| File | Change |
|------|--------|
| `gui/gui.odin` | **NEW** — Window init, render loop, shutdown |
| `gui/panels.odin` | **NEW** — Panel drawing procs |
| `gui/theme.odin` | **NEW** — Dark theme configuration |
| `p2p/types.odin` | Add `Node_Status`, `Peer_Status` structs |
| `p2p/conn_manager.odin` | Add status snapshot update in timer, export getter |
| `main.odin` | Add `--gui` flag, conditional GUI loop |
| `Makefile` | No changes needed (Odin auto-discovers packages) |

---

## Future (v2)

If we outgrow raygui:
- Swap to Dear ImGui (odin-imgui) for docking, tables, plots
- Add block explorer panel (click block hash → show transactions)
- Add mempool fee histogram (ImGui has ImPlot)
- Add log viewer panel with filtering
- Add RPC console (text input → JSON-RPC → response display)
