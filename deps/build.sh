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

echo "=== Building LevelDB ==="
LEVELDB_DIR="$SCRIPT_DIR/leveldb"
CXX="${CXX:-c++}"
CXXFLAGS="-O2 -DNDEBUG -DLEVELDB_PLATFORM_POSIX -I$LEVELDB_DIR -I$LEVELDB_DIR/include"

SOURCES="db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc
  db/dumpfile.cc db/filename.cc db/log_reader.cc db/log_writer.cc
  db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc
  db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc
  table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc
  table/table.cc table/table_builder.cc table/two_level_iterator.cc
  util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc
  util/crc32c.cc util/env.cc util/env_posix.cc util/filter_policy.cc
  util/hash.cc util/logging.cc util/options.cc util/status.cc"

OBJS=""
for src in $SOURCES; do
    obj="$LEVELDB_DIR/${src%.cc}.o"
    mkdir -p "$(dirname "$obj")"
    $CXX $CXXFLAGS -std=c++11 -c "$LEVELDB_DIR/$src" -o "$obj"
    OBJS="$OBJS $obj"
done
ar rcs "$LIB_DIR/libleveldb.a" $OBJS
for obj in $OBJS; do rm -f "$obj"; done
echo "Built libleveldb.a"

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
