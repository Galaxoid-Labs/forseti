#!/usr/bin/env bash
# End-to-end: a real BDK (bdk_wallet + bdk_esplora) descriptor wallet syncs,
# builds, signs, and broadcasts through forseti's in-node Esplora server on
# regtest. Proves --index-addresses + --esplora is a working BDK backend.
#
#   ./run.sh /path/to/forseti
#
# Fixed-seed wallet (deterministic) so each harness invocation re-scans from chain.
set -euo pipefail

FORSETI="${1:-../../forseti}"
DATADIR="${DATADIR:-/tmp/forseti-bdk-e2e}"
RPCPORT=18443
DEST="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080" # throwaway P2WPKH sink
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== build harness =="
( cd "$HERE" && cargo build -q )
HARNESS="$HERE/target/debug/harness"

rpc(){ curl -s --user u:p -H 'content-type:text/plain' \
  --data "{\"jsonrpc\":\"1.0\",\"id\":\"t\",\"method\":\"$1\",\"params\":$2}" \
  "http://127.0.0.1:$RPCPORT/"; }

echo "== start forseti (regtest, index+esplora) =="
rm -rf "$DATADIR"
"$FORSETI" --network=regtest --datadir="$DATADIR" --no-p2p \
  --index-addresses --esplora=1 --rpcuser=u --rpcpassword=p > "$DATADIR.log" 2>&1 &
NODE=$!
trap 'rpc stop "[]" >/dev/null 2>&1 || kill $NODE 2>/dev/null || true' EXIT
sleep 3

ADDR=$("$HARNESS" address | awk '{print $2}')
echo "== mine 101 to BDK addr $ADDR =="
rpc generatetoaddress "[101, \"$ADDR\"]" >/dev/null

echo "== BDK full_scan =="
"$HARNESS" balance

echo "== BDK send 10 BTC -> broadcast via POST /tx =="
TXID=$("$HARNESS" send "$DEST" 1000000000 | awk '/TXID/{print $2}')
echo "  txid=$TXID"
test "$(rpc getrawmempool "[]" | grep -c "$TXID")" = 1 && echo "  OK: in forseti mempool"

echo "== confirm + re-scan =="
rpc generatetoaddress "[1, \"$ADDR\"]" >/dev/null
curl -s "http://127.0.0.1:3000/tx/$TXID/status"; echo
"$HARNESS" balance
echo "== PASS =="
