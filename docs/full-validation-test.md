# Full-Validation Sync Test (`--assumevalid=0`)

The strongest correctness test forseti can run: a mainnet IBD that **executes
the script interpreter and verifies every signature from genesis**, instead of
trusting historical scripts. Run it on a fast box (a Grace/DGX Spark is ideal —
fast enough to make full validation tractable).

## Why this matters

Assumevalid skips *script/signature* verification below a hardcoded height
(mainnet 880k). Everything else — PoW, merkle roots, block/tx structure, the
UTXO set (inputs exist, no double-spends, amounts), and all consensus rules — is
always validated. But it means **forseti has never script-verified most of
mainnet history**; only the last ~77k blocks (880k→tip) had their scripts run.

`--assumevalid=0` turns full script + signature verification on for the entire
chain. That exercises 15 years of real mainnet transactions against the script
interpreter, sighash computation (BIP143/BIP341), and secp256k1 verify — a far
larger surface than the curated unit tests. If there's a consensus bug the test
corpus doesn't cover, this sync finds it: the offending block fails, the node
halts, and you get the exact height.

Historical minefields it walks through: early P2PK/bare-pubkey outputs and
pre-standardness scripts, the 2010 value-overflow block (74638), BIP66
strict-DER, BIP65 CLTV / BIP112 CSV, SegWit activation + BIP143 sighash variety,
then Taproot (BIP341/342 Schnorr + tapscript), plus every oddball multisig and
edge-case sighash that actually shipped.

Two outcomes, both wins:
- **Halts at some height** → a real consensus bug is caught → capture it and add a regression test (below).
- **Reaches the tip clean** → strongest possible evidence the validation is correct against all of mainnet. (This is exactly what Core devs do — a full reindex with assumevalid off.)

## 1. Dev environment (fresh box)

Full build details in [docs/build.md](build.md). Quick version:

- **Prereqs:** the Odin compiler, LLVM 15+, `make`, `git`. (On Linux also the raylib X11/GL dev packages if you want `--gui`; not needed for a headless validation run.)
- **Clone with submodules** (libsecp256k1 is a submodule):
  ```bash
  git clone --recursive https://github.com/Galaxoid-Labs/forseti.git
  cd forseti
  ```
- **Build:**
  ```bash
  make            # builds C deps (libsecp256k1, LevelDB, ripemd160, sha256) + forseti
  make test       # optional sanity: 364 tests / 12 pkgs
  ```
  If C-dep link warnings appear on a fresh toolchain, see the build-notes in the repo CLAUDE.md (`rm -f deps/lib/*.a && ./deps/build.sh`).

## 2. Run the test

Use a **throwaway datadir** so it never touches a real node, and a big cache
(the recovery cost is bounded now, but a large cache just makes IBD faster):

```bash
ulimit -c unlimited                                   # arm core dumps in case it crashes
sudo sysctl -w kernel.core_pattern=$HOME/core.%e.%p   # (Linux)

./forseti --network=mainnet \
  --datadir=$HOME/mainnet-fullvalidate \
  --assumevalid=0 \
  --dbcache=16384 \
  --daemon
tail -f $HOME/mainnet-fullvalidate/debug.log
```

Confirm scripts are actually being verified: the startup log should **NOT**
print an `Assumevalid: skip script verification below height N` line (that line
only appears when assumevalid is on). No line = full verification.

Expect it to take meaningfully longer than an assumevalid sync — every input's
script now runs. On a Grace/Spark it should still be very reasonable.

## 3. What to watch for

- **Success:** height climbs to the tip and the log shows the in-sync state.
  Then verify (see §5).
- **Failure / halt** — grep the log for either:
  ```bash
  grep -E "Block validation failed|sync halted" $HOME/mainnet-fullvalidate/debug.log
  ```
  The line looks like: `Block validation failed at height <H>: <error> — sync halted`.
  The process stays up (RPC still answers); `getnodestatus` reports
  `halt_height` / `halt_reason`, and the GUI/TUI shows a red **VALIDATION
  HALTED** banner. A `Bad_Script` error = a script/signature verification
  mismatch (the interesting case for this test).

## 4. If it HALTS — capture the bug

The failing block is at **halt_height + 1**. RPC is still up, so grab it:

```bash
C="user:pass"   # or --cookie contents
H=<halt_height>
BH=$(curl -s -u $C --data "{\"method\":\"getblockhash\",\"params\":[$((H+1))],\"id\":1}" http://127.0.0.1:8332/ | grep -o '"result":"[0-9a-f]*"')
echo "failing block: $BH"
# raw block (verbose=0 → hex):
curl -s -u $C --data "{\"method\":\"getblock\",\"params\":[$BH,0],\"id\":1}" http://127.0.0.1:8332/ > failing_block.json
```

Then, per the project's regression convention (see `test_signet_250058_tx11_p2wpkh`
in `script/script_test.odin`):
1. Identify the specific tx + input the interpreter rejected (the error/height narrows it; cross-check the block on mempool.space).
2. Save the failing tx hex (and the spent prevouts — fetch prevouts from the mempool.space API) into `script/testdata/`.
3. Write a focused test that reproduces the exact script/sighash/verify path.
4. **Report to Claude** with: halt height, block hash, error, failing txid/vin, and the saved hex. That's everything needed to root-cause and fix.

Do NOT just bump assumevalid past it — a real halt here is a genuine consensus
bug worth fixing.

## 5. If it REACHES the tip — record the pass

```bash
# tip hash must match a block explorer at the same height:
curl -s -u $C --data '{"method":"getbestblockhash","params":[],"id":1}' http://127.0.0.1:8332/
# UTXO total must match circulating supply minus known burns:
curl -s -u $C --data '{"method":"gettxoutsetinfo","params":[],"id":1}' http://127.0.0.1:8332/
```

If both check out, that's a full-consensus pass from genesis. Record the machine
+ wall-clock time in [docs/hardware.md](hardware.md).

## 6. Optional: unattended watchdog

So you don't have to babysit — alerts on halt or tip:

```bash
LOG=$HOME/mainnet-fullvalidate/debug.log
while true; do
  if grep -qE "Block validation failed|sync halted" "$LOG"; then
    echo "!!! VALIDATION HALTED at $(date):"; grep -E "Block validation failed|sync halted" "$LOG" | tail -3
    break
  fi
  if grep -qiE "In sync at height|Block download complete" "$LOG"; then
    echo ">>> REACHED TIP at $(date) — run the §5 checks."
    break
  fi
  sleep 60
done
```

## Notes

- secp256k1 *verification* is thread-safe, so `--par=N` parallel script checks
  are fine during this run. (The "flaky secp256k1 with parallel threads" caveat
  in CLAUDE.md is about the *test harness* under `ODIN_TEST_THREADS`, not the
  node.)
- assumevalid=0 also re-verifies scripts above 880k — redundant but harmless.
- The bounded-recovery fix means a mid-run crash/kill recovers cheaply; still
  prefer the `stop` RPC over `kill -9`.
