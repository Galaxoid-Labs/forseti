# "ecash" Drivechain Network for forseti (opt-in `--network=ecash`)

> **STATUS (2026-07-10): DESIGN / DATA-GATHERING ONLY — NOT IMPLEMENTED.** No code
> yet. This captures how forseti would support running as an **ecash** node (a
> drivechain hardfork chain) the same way it already runs as a Bitcoin node —
> selected at launch, one binary, no behavior change to existing networks.

## Goal

Let the *same forseti binary* run as **either** a standard Bitcoin node **or** an
ecash node, chosen by config:

```
./forseti --network=mainnet   # Bitcoin (today)
./forseti --network=ecash     # the drivechain hardfork chain
```

"ecash" becomes a first-class entry in forseti's existing multi-network design
(`mainnet|testnet3|testnet4|signet|regtest` → `+ ecash`), with its own
`Chain_Params`, DNS seeds, network magic, and height-gated consensus rules.

## What "ecash" is

A **clean-break hardfork of Bitcoin** that activates BIP300/301 drivechain
natively. (Drivechain the *concept* — BIP300/301 — is Paul Sztorc's; this fork's
implementation is by **CryptAxe**, its main dev. They are different people — don't
conflate them.) Reference implementation: **`ecash-com/bitcoin`, branch
`drivechain-ecash`** (a Bitcoin Core v31.x fork). The drivechain-specific commits
(all by CryptAxe, 2026-07-09) define the fork:

- **Add OP_DRIVECHAIN and make standard** — `0xb4` becomes a *real* executed
  opcode + a standard tx type (not a NOP).
- **Add difficulty reset at drivechain fork height** — resets difficulty when the
  chain splits off Bitcoin (minority hashrate).
- **Remove OP_RETURN limits** — unlimited datacarrier.
- **Add optional replay protection** — so a tx isn't valid on both chains.
- **Remove core seed nodes. Add drivechain seed nodes** — its own network.
- **Update default data dir and config file name** — coexists with a Bitcoin node
  on one machine.
- **Remove IBD and peer requirement from GBT RPC** — lets `getblocktemplate` mine
  the young chain without full IBD/peers (bootstrapping/solo-mining aid).

## Why a network, not a mainnet overlay (this is the key idea)

Forseti already has `--drivechain=off|track|enforce` as a **soft-fork overlay on
Bitcoin mainnet**, where `enforce` carries self-fork risk (you reject blocks the
majority accepts). Running ecash as its **own network dissolves that risk**:

- On `--network=ecash` you connect to **ecash peers** who all enforce the same
  rules. There is no "am I forking off the majority?" — you *are* the fork, on
  purpose, with everyone who chose it. Drivechain enforcement is simply *the
  consensus* there, not a risky overlay.
- So ecash-as-a-network is the more natural home for full drivechain enforcement
  than mainnet-`enforce` ever was. The two stay independent:
  - `--drivechain=track/enforce` on **mainnet** = observe/enforce BIP300/301 on
    Bitcoin (unchanged, still self-fork-risky in `enforce`).
  - `--network=ecash` = a distinct chain where drivechain is native, mandatory,
    and safe.

## The fork model (CONFIRM before building)

CryptAxe's **difficulty reset at fork height** + **replay protection** strongly
imply ecash is a **height-based hardfork *from* the Bitcoin chain**, not a fresh
genesis: it shares Bitcoin history `0..H`, then diverges at height **H**. (You
only reset difficulty when a hashrate minority splits off an existing chain.) If
so, a forseti ecash node would:

1. Connect to **ecash peers** (ecash magic + ecash seeds).
2. Sync the **shared Bitcoin history `0..H`** under Bitcoin rules — byte-for-byte
   what forseti-mainnet does today.
3. At **H**: apply the difficulty reset, then from `H+1` apply ecash rules
   (OP_DRIVECHAIN opcode, mandatory drivechain enforcement, unlimited OP_RETURN,
   replay-protected sighash).

This is a per-network **+** per-height rule switch — exactly what forseti's
height-gated flags already do (`get_script_flags`: p2sh/bip66/csv/segwit/taproot
by height). So it's mostly new **params**, not new architecture.

> **OPEN QUESTION #1 (must confirm from CryptAxe's `chainparams`):** is ecash a
> height-fork off Bitcoin (shared history) or a fresh genesis? This decides the
> sync model. Everything below assumes height-fork; revisit if it's a fresh chain.

## Network identity — seeds AND (more importantly) magic

The user's instinct is right — ecash needs its own seeds. But the **network magic
is the critical piece**: post-fork, an ecash node must **never peer with Bitcoin
nodes** (they'd serve the wrong chain). Magic bytes enforce that at the handshake.
The ecash network identity is a bundle:

- **Network magic** (message-start bytes) — *the* guard against cross-chain
  peering. Highest priority; get the exact bytes from CryptAxe's chainparams.
- **DNS seeds + hardcoded fallback** — the "drivechain seed nodes" CryptAxe added,
  replacing Bitcoin's. Slots into `p2p/types.odin` next to `MAINNET_SEEDS` etc. as
  `ECASH_SEEDS`.
- **Default P2P/RPC ports + datadir/config name** — CryptAxe's fork changes these
  so an ecash node and a Bitcoin node coexist on one machine.
- addrman/anchors are per-datadir, so they isolate automatically once the datadir
  differs.

## Consensus rule changes from H onward (map to forseti)

| ecash rule (from CryptAxe's commits) | forseti hook | notes |
|---|---|---|
| **OP_DRIVECHAIN is a real opcode** (0xb4) | `script/` interpreter + `get_script_flags` gate ≥ H | forseti today keeps `0xb4` as `OP_NOP5` and treats the 4-byte escrow pattern as a *tx-level* consensus overlay (CUSF-style). On ecash it must become an executed, standard opcode ≥ H. **Semantics must match CryptAxe exactly.** |
| **Drivechain enforcement mandatory** | `drivechain/` package, always-on ≥ H for `--network=ecash` | The existing `M1–M6` / D1/D2 / CTIP / BMM machinery becomes *native consensus* instead of opt-in `enforce`. |
| **OP_RETURN limit removed** | datacarrier gate ≥ H (see `main.odin` `datacarrier_size`) | ecash lifts the 83-byte cap; mainnet keeps 83 (our decision, docs/plans/bip110.md). Height/network-gated. |
| **Difficulty reset at H** | `consensus/` PoW/retarget, special-cased at H | Like other chains' fork EDA; a one-time reset in `get_next_work_required`. |
| **Replay protection** | sighash computation ≥ H | Likely a forkid-style sighash change so ecash txs aren't valid on Bitcoin and vice-versa. Confirm the exact scheme. |
| **GBT without IBD/peers** | `rpc/` getblocktemplate | Only needed if we want forseti to *mine* ecash; optional. |

## Drivechain becomes native — and semantic compatibility is now mandatory

Today forseti's `drivechain/` (`M1–M6` codecs, D1/D2, CTIP, blinded m6id, BMM) is
an **opt-in overlay** whose worst failure is a self-fork. On ecash it is **the
consensus** — so any deviation from CryptAxe's rules means a forseti ecash node
**forks off the ecash chain**. This makes the semantic check we already flagged
mandatory, not optional:

- **m6id / withdrawal-bundle id:** forseti computes the *blinded* m6id per the
  **CUSF enforcer** semantics (inputs cleared + output0 → zero-value OP_RETURN
  8-byte-BE fee; forseti docs note "the BIP defers to it"). CryptAxe's ecash fork
  is the reference — **diff forseti's `drivechain/validate.odin` m6id + M5/M6
  rules against his OP_DRIVECHAIN + withdrawal code.** If they differ, forseti
  would accept/reject withdrawals differently and split from ecash.
- **OP_DRIVECHAIN output/spend rules:** forseti's `parse_op_drivechain`
  (`OP_NOP5 <push1 n> OP_TRUE`, 4 bytes) and its M5-deposit / M6-withdrawal /
  CTIP-replacement checks must match CryptAxe's opcode semantics exactly.

> **OPEN QUESTION #2:** does CryptAxe's ecash m6id match the CUSF-enforcer m6id
> forseti implements, or the *original* BIP301 m6id? This is the single most
> important compatibility item — resolve it by reading his withdrawal code.

## Implementation surface (when greenlit — leverages existing machinery)

- `consensus/params.odin`: add `ECASH_PARAMS` (magic, ports, seeds handle,
  `ecash_fork_height` H, difficulty-reset params, the post-H rule heights). Reuse
  the shared Bitcoin history params for `0..H`.
- `p2p/types.odin`: add `ECASH_SEEDS`; wire `--network=ecash` seed selection.
- `main.odin`: accept `--network=ecash`; default datadir/config name per CryptAxe.
- Consensus gating: OP_DRIVECHAIN opcode, datacarrier lift, replay-sighash, and
  mandatory drivechain enforcement all gated on `network == ecash && height >= H`.
- `drivechain/`: reuse as-is for the state machine; make enforcement native for
  ecash (not behind `--drivechain=enforce`).
- `chain/` difficulty: one-time reset at H for ecash.

Most of this is **params + gating**, not new subsystems — forseti already has
multi-network params, per-height script flags, and the full drivechain package.

## Testing

- **Shared-history sync** `0..H` on ecash params must equal Bitcoin rules (regtest
  fork-height fixture; sync a few blocks past H).
- **Rule switch at H:** OP_DRIVECHAIN executes ≥ H but is a NOP < H; OP_RETURN >83
  invalid < H, valid ≥ H; difficulty reset applied exactly at H; replay-protected
  sighash ≥ H.
- **Cross-chain peering guard:** ecash magic rejects a Bitcoin-magic handshake and
  vice-versa (no accidental cross-chain peers).
- **Drivechain consensus parity:** port CryptAxe's drivechain/withdrawal tests and
  confirm forseti's `M1–M6` + m6id accept/reject identically (this is the
  fork-safety bar).
- **No regression:** `--network=mainnet` (and all existing networks) byte-for-byte
  unchanged.

## Data still to gather (no code; next research step)

1. Confirm **height-fork vs fresh genesis** (CryptAxe `chainparams`).
2. Exact **network magic, default ports, DNS seeds, `ecash_fork_height` H**, and
   **difficulty-reset** parameters.
3. The **replay-protection** sighash scheme.
4. **m6id / M5 / M6 / OP_DRIVECHAIN** semantics — diff against forseti's
   `drivechain/validate.odin` (OPEN QUESTION #2). Highest-value item.

## References

- Fork: `ecash-com/bitcoin`, branch `drivechain-ecash` (Bitcoin Core v31.x fork;
  drivechain commits by CryptAxe, 2026-07-09).
- forseti drivechain: `drivechain/` package, `docs/plans/drivechain.md`,
  `docs/bips.md` (BIP300/301 notes).
- Related: `docs/plans/bip110.md` (the datacarrier/OP_RETURN policy ecash lifts).
