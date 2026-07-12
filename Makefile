.PHONY: all deps build test clean

UNAME_S := $(shell uname -s)
# RocksDB (addrindex engine) link deps. zstd (RocksDB's compression backend) is
# linked STATICALLY so the release binaries are self-contained — a dynamic
# -lzstd would make the prebuilt binaries fail to run wherever libzstd isn't
# installed (notably macOS without Homebrew). The static libzstd.a ships with
# libzstd-dev (Linux) and `brew install zstd` (macOS).
ifeq ($(UNAME_S),Darwin)
    # Homebrew zstd (arm64: /opt/homebrew, Intel: /usr/local) — link the archive
    # by full path so it's pulled in statically.
    ZSTD_PREFIX := $(shell brew --prefix zstd 2>/dev/null || brew --prefix 2>/dev/null || echo /opt/homebrew)
    CXX_LINK := -lc++ $(ZSTD_PREFIX)/lib/libzstd.a
else
    # -l:libzstd.a forces the static archive (in the default lib search path).
    CXX_LINK := -lstdc++ -l:libzstd.a -lpthread -ldl
endif

all: deps build

deps:
	git submodule update --init --recursive
	./deps/build.sh
	./deps/raylib-arm64.sh   # arm64 Linux: build vendored raylib/raygui (no-op elsewhere)

build: deps
	odin build . -out:forseti -o:speed -extra-linker-flags:"$(CXX_LINK)"

gui: deps
	odin build guiapp -out:forseti-gui -o:speed -extra-linker-flags:"$(CXX_LINK)"

test: deps
	odin test crypto -extra-linker-flags:"$(CXX_LINK)" -define:ODIN_TEST_THREADS=1
	odin test wire -extra-linker-flags:"$(CXX_LINK)"
	odin test script -extra-linker-flags:"$(CXX_LINK)" -define:ODIN_TEST_THREADS=1
	odin test consensus -extra-linker-flags:"$(CXX_LINK)"
	odin test storage -extra-linker-flags:"$(CXX_LINK)"
	odin test chain -extra-linker-flags:"$(CXX_LINK)"
	odin test p2p -extra-linker-flags:"$(CXX_LINK)" -define:ODIN_TEST_THREADS=1
	odin test mempool -extra-linker-flags:"$(CXX_LINK)"
	odin test rpc -extra-linker-flags:"$(CXX_LINK)" -define:ODIN_TEST_THREADS=1
	odin test zmq -extra-linker-flags:"$(CXX_LINK)"
	odin test drivechain -extra-linker-flags:"$(CXX_LINK)"
	odin test descriptor -extra-linker-flags:"$(CXX_LINK)" -define:ODIN_TEST_THREADS=1
	odin test psbt -extra-linker-flags:"$(CXX_LINK)"

debug: deps
	odin build . -out:forseti -debug -extra-linker-flags:"$(CXX_LINK)"

clean:
	rm -f forseti
	rm -f deps/lib/*.a
	cd deps/libsecp256k1 && [ -f Makefile ] && make clean || true
