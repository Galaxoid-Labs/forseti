# Dashboards (GUI & TUI)

Two ways to get the dashboard (raylib/raygui, Cascadia Code, dark theme):

**In-process** — `./btcnode --gui ...` renders on the otherwise-idle main
thread. Closing the window is a graceful shutdown. Without `--gui` the node is
fully headless (the status snapshot is still maintained for RPC).

**Standalone remote client** — `make gui` builds `btcnode-gui`, which polls any
node's `getnodestatus` RPC once a second and renders the same dashboard:

```bash
# Local node
./btcnode-gui --cookie=<datadir>/.cookie

# Remote node (RPC binds localhost only — tunnel first)
ssh -L 8332:localhost:8332 myserver
./btcnode-gui --connect=127.0.0.1:8332 --rpcuser=user --rpcpassword=pass

# One-shot health check, no window
./btcnode-gui --probe --cookie=<datadir>/.cookie

# Terminal dashboard (SSH-friendly, no window server needed; q quits)
./btcnode --tui ...                       # in-process
./btcnode-gui --tui --cookie=...          # remote, e.g. inside an SSH session
```

The client shows a "connection lost" banner and retries when the node goes
away. `getnodestatus` returns the full snapshot (chain, sync progress + ETA,
per-peer table, mempool, UTXO cache, block profile, disk usage) as JSON.


The node window opens instantly on `--gui`: node initialization runs on a
background thread while the loading screen shows live stages (database open,
block index build, crash recovery progress). Closing the window holds it open
with a "shutting down" status until the final flush completes.

During sync the **block profile** reports two complementary numbers:
`ms/block` is pure validation time (how fast the machine *can* process a
block), while `blocks/sec` is wall-clock throughput over a ~2-minute window
(actual sync speed, including download and time spent waiting on peers). Early
in a chain, blocks are near-empty and validate sub-millisecond, so the panel
shows the rate and skips the per-phase breakdown until blocks are large enough
to split meaningfully. Sync progress is measured in transactions verified
(Bitcoin Core's `chainTxData` model), capped at the fraction of blocks
downloaded so it stays monotonic on every network.

Both dashboards show a red **VALIDATION HALTED at height N (reason)** banner
if block validation ever wedges (cleared automatically on the next
successful connect), and display 100% once the node is in sync.
