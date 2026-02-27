#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

mkdir -p "$LIB_DIR"

echo "=== Building RIPEMD-160 ==="
cc -c -O2 -o "$SCRIPT_DIR/ripemd160/ripemd160.o" "$SCRIPT_DIR/ripemd160/ripemd160.c"
ar rcs "$LIB_DIR/libripemd160.a" "$SCRIPT_DIR/ripemd160/ripemd160.o"
rm "$SCRIPT_DIR/ripemd160/ripemd160.o"
echo "Built libripemd160.a"

echo "=== Building libsecp256k1 ==="
cd "$SCRIPT_DIR/libsecp256k1"

if [ ! -f configure ]; then
    echo "Running autogen.sh..."
    ./autogen.sh
fi

if [ ! -f Makefile ]; then
    echo "Running configure..."
    ./configure \
        --enable-module-recovery \
        --enable-module-schnorrsig \
        --enable-module-extrakeys \
        --disable-shared \
        --enable-static \
        --with-pic
fi

make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
cp .libs/libsecp256k1.a "$LIB_DIR/libsecp256k1.a"
echo "Built libsecp256k1.a"

echo "=== All dependencies built ==="
ls -la "$LIB_DIR"
