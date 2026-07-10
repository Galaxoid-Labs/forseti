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

## CONFIRMED parameters (from `src/kernel/chainparams.cpp`, drivechain-ecash) — and a correction

Reading CryptAxe's chainparams **corrects a wrong assumption in the first draft of
this plan.** It is **NOT a separate network** — it is a **hardfork on Bitcoin
mainnet itself**, keeping Bitcoin's entire P2P/address identity:

- **Genesis: shared** — `assert(hashGenesisBlock == 000000000019d6689c...)`. Height
  fork off Bitcoin (OPEN QUESTION #1 resolved: shared history).
- **Network magic: `0xf9 0xbe 0xb4 0xd9` — Bitcoin's own magic, unchanged.**
- **Default port: 8333** (Bitcoin's). Addresses unchanged: `bech32_hrp = "bc"`,
  base58 pubkey/script/secret = 0/5/128.
- **Fork height: `consensus.DrivechainHeight = 957600`** (mainnet). `enforce_BIP94
  = false`. **This 957600 is a TESTING height** (close to the current tip so they
  can exercise the fork soon) — **NOT the final mainnet activation height**, which
  will be set later/higher. So forseti must treat the fork height as a
  **configurable param**, not a hardcoded constant; don't bake 957600 in as the
  real activation.
- **DNS seed: `seed.bip300.xyz`** — the drivechain seed, added alongside/replacing
  Bitcoin's.

**Why this matters (correction):** since the fork keeps Bitcoin's magic, port,
genesis, and addresses, drivechain nodes and vanilla Core nodes **can still peer**
— the P2P layer does not separate them. The chains split **purely at the consensus
level at height 957600** (the difficulty reset + replay protection make post-fork
blocks mutually invalid between the two rule sets). So:

- The earlier "separate network → the magic guard dissolves self-fork risk" framing
  below is **WRONG for this fork**. Following the fork *is* a deliberate consensus
  split on the same P2P network — a hardfork, not a magic-isolated sidenet.
- `seed.bip300.xyz` exists because, with shared magic, a node needs it to **find
  fork-following peers** — otherwise it may only reach Core nodes that serve the
  non-fork chain past 957600.

### Revised forseti shape (given the above)

Not a brand-new `--network=ecash` with its own magic/genesis/ports. Instead it's
**Bitcoin mainnet with a fork toggle**: a flag (e.g. `--drivechainfork` or a
`mainnet-ecash` params variant) that, when on, (a) sets `DrivechainHeight = 957600`
and activates the fork rules from that height, (b) prefers `seed.bip300.xyz` to
find fork peers, and (c) validates the ecash chain past 957600. When off, forseti
follows Core rules (rejecting the difficulty-reset block at 957600) — the same-node
opt-in you want, but implemented as a **consensus-rule choice at the fork height on
mainnet**, not a separate network. This is closer to a UASF/hardfork toggle than a
new chain. (Everything in the sections below that assumes a distinct magic/seed
network identity should be read through this correction.)

## What the ecash fork ACTUALLY implements (from the commit diffs) — the big surprise

The branch is Core **v31.1 + 8 commits** (all CryptAxe, 2026-07-09). Pulling the
diffs shows the fork is currently a **minimal hardfork**, and — importantly —
**forseti is AHEAD of it on the actual drivechain escrow consensus.**

**1. OP_DRIVECHAIN — opcode reservation ONLY (commit `3ab9c0b`).** In
`script/interpreter.cpp`:
```c++
case OP_DRIVECHAIN:                       // 0xb4 (== OP_NOP5) in script.h
    if (script.size() == 4 && script[0] == OP_DRIVECHAIN) {
        stack.push_back({0xDC});          // push truthy → the 4-byte script succeeds
        pc = pend;
    }
```
Plus `TxoutType::DRIVECHAIN` made standard across addresstype/solver/RPC/wallet.
That is the **whole** drivechain change. **NO m6id, NO M1–M6, NO CTIP, NO D1/D2,
NO withdrawal/escrow/bundle rules exist in the fork.** It just makes the 4-byte
`0xb4` output a standard, spendable opcode.

**2. Difficulty reset (commit `c0b1adf`)** — `pow.cpp` `CalculateNextWorkRequired`:
```c++
if (pindexLast->nHeight + 1 == params.DrivechainHeight) bnNew = bnPowLimit;
```
i.e. a **one-time reset to powLimit (min difficulty)** at the fork block;
`validation.cpp` enforces the fork block's `nBits == powLimit.GetCompact()` or the
block is invalid. Standard retargeting resumes after. Fork height per network:
mainnet `957600` (**a testing value, not final**), everything else `0`.

**3. Remove OP_RETURN limits (`b08f4ae`) — POLICY only, NOT consensus.** Touches
only `policy/policy.cpp`+`.h`: drops the datacarrier check in `IsStandardTx()` and
sets `MAX_OP_RETURN_RELAY = DEFAULT_BLOCK_MAX_WEIGHT` (effectively unlimited). A
block with a large OP_RETURN was always consensus-valid; this just makes nodes
relay/mempool-accept them. Does NOT remove the one-OP_RETURN-per-tx rule. For
forseti = the existing `--datacarriersize` knob (we keep 83), no consensus change.

**4. Optional replay protection (`01cfad9`) — per-tx serialization trick, NOT
sighash.** In `primitives/transaction.h`: a tx opts in by setting
`version == TX_REPLAY_VERSION (12566463)`, which makes the serializer emit an extra
byte `TX_REPLAY_BYTES (0x3f)` after the version field (read + discarded on
deserialize). The extra byte diverges the wire format so the tx won't parse
identically on Bitcoin → not replayable. **Opt-in per transaction, not
height-gated.** For forseti = a small tx (de)serializer branch on that version.

**5. Plumbing:** **drivechain seed** `seed.bip300.xyz` (`22fcef8`),
**datadir/config rename** (`f013f1a`), **GBT without IBD/peers** (`8d4592a`).

### This inverts the earlier comparison (OPEN QUESTION #2 resolved)

The "forseti's m6id must match CryptAxe's or we fork off" worry is **moot for now**
— the fork has no m6id, no withdrawal machinery at all:

- **forseti already implements the full BIP300/301** (M1–M6 codecs, D1/D2, CTIP,
  blinded m6id, BMM, enforce validation). **The ecash fork does not** — only the
  opcode reservation + difficulty reset + policy/network plumbing.
- So forseti is **ahead** on drivechain consensus; nothing to "match" yet. When
  CryptAxe adds the escrow/withdrawal rules, THAT is when the m6id/M5/M6 diff
  becomes real. Until then forseti's `drivechain/` package is a superset.

### What forseti would need to follow *today's* ecash fork (small, concrete)

NOT the escrow machinery (the fork lacks it):
1. **Difficulty reset**: in `consensus` `get_next_work_required`, force target =
   pow_limit at the (configurable) fork height + validate the fork block's nBits
   equals it. One-time, well-defined.
2. **OP_DRIVECHAIN executable**: make the 4-byte `0xb4` pattern push a truthy value
   ≥ fork height (forseti already *recognizes* it via `parse_op_drivechain`; today
   it stays a NOP). Small.
3. **Lift OP_RETURN limit** — POLICY only: raise/disable `--datacarriersize`
   (no consensus change). Optional, config-driven.
4. **Replay protection** — small (de)serializer branch: when
   `tx.version == 12566463`, emit/consume one extra `0x3f` byte after the version.
   Opt-in per tx, not height-gated. Needed to send/relay ecash-only txs and to
   parse them.
5. **Seed** `seed.bip300.xyz` + datadir/config name.

None of this touches forseti's existing drivechain package; that stays as the
(more complete) enforcement path for mainnet and a future ecash escrow layer.

## Why a network, not a mainnet overlay — SUPERSEDED (see the CONFIRMED-parameters correction above)

> The reasoning below was written before reading chainparams. It assumed ecash was
> a magic-isolated separate network that dissolves the self-fork risk. The code
> shows it is a **hardfork on mainnet with shared magic**, so following it *is* a
> deliberate consensus split, not a magic-isolated sidenet. Kept for history:

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

## Network identity — SUPERSEDED (magic is SHARED, not different — see correction above)

> Written before reading chainparams. The fork keeps Bitcoin's magic
> (`0xf9beb4d9`), port (8333), genesis, and addresses (`bc`), so magic is NOT a
> cross-chain guard here — only `seed.bip300.xyz` (peer discovery) differs. Kept
> for history:

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
