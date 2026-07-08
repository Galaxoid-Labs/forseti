#!/bin/bash
set -euo pipefail

# Odin's vendored raylib ships x64-only Linux static libs. On arm64 Linux the
# GUI link fails with "ld: incompatible target". This builds arm64 raylib 5.5 +
# raygui 4.0 (the exact versions the vendor bindings target) and drops them into
# the toolchain's vendor dir, which the bindings reference by path. Mirrors the
# linux-arm64 step in .github/workflows/release.yml.
#
# Idempotent: no-op unless we're on arm64 Linux and the vendor libs aren't
# already arm64.

[ "$(uname -s)" = "Linux" ] || { echo "raylib-arm64: not Linux, skipping"; exit 0; }
[ "$(uname -m)" = "aarch64" ] || { echo "raylib-arm64: not arm64, skipping"; exit 0; }

command -v odin >/dev/null || { echo "raylib-arm64: odin not on PATH, skipping"; exit 0; }
VENDOR="$(odin root)/vendor/raylib/linux"
[ -d "$VENDOR" ] || { echo "raylib-arm64: vendor dir $VENDOR missing, skipping"; exit 0; }

# Already arm64? Then nothing to do.
if readelf -h "$VENDOR/libraylib.a" 2>/dev/null | grep -q AArch64; then
    echo "raylib-arm64: vendor libs already arm64, skipping"
    exit 0
fi

echo "raylib-arm64: vendor raylib libs are not arm64 — building from source"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Preserve the original x64 libs once, for reference / restore.
for f in libraylib.a libraygui.a; do
    [ -f "$VENDOR/$f.x86_64.bak" ] || cp "$VENDOR/$f" "$VENDOR/$f.x86_64.bak" 2>/dev/null || true
done

git clone --depth 1 --branch 5.5 https://github.com/raysan5/raylib "$WORK/raylib"
make -C "$WORK/raylib/src" PLATFORM=PLATFORM_DESKTOP -j"$(nproc)"
cp "$WORK/raylib/src/libraylib.a" "$VENDOR/libraylib.a"

git clone --depth 1 --branch 4.0 https://github.com/raysan5/raygui "$WORK/raygui"
printf '#define RAYGUI_IMPLEMENTATION\n#include "raygui.h"\n' > "$WORK/raygui/src/raygui.c"
cc -c -O2 -I"$WORK/raylib/src" -o "$WORK/raygui.o" "$WORK/raygui/src/raygui.c"
ar rcs "$VENDOR/libraygui.a" "$WORK/raygui.o"

echo "raylib-arm64: installed arm64 raylib/raygui into $VENDOR"
