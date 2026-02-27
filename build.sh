#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build C dependencies if needed
if [ ! -f "$PROJECT_DIR/deps/lib/libsecp256k1.a" ] || [ ! -f "$PROJECT_DIR/deps/lib/libripemd160.a" ]; then
    echo "Building C dependencies..."
    "$PROJECT_DIR/deps/build.sh"
fi

# Build Odin project
echo "=== Building bitcoin-node-odin ==="
odin build "$PROJECT_DIR" -out:"$PROJECT_DIR/btcnode" "$@"
echo "Built: btcnode"
