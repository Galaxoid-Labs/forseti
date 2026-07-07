.PHONY: all deps build test clean

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    CXX_LINK := -lc++
else
    CXX_LINK := -lstdc++
endif

all: deps build

deps:
	git submodule update --init --recursive
	./deps/build.sh

build: deps
	odin build . -out:btcnode -o:speed -extra-linker-flags:"$(CXX_LINK)"

gui: deps
	odin build guiapp -out:btcnode-gui -o:speed -extra-linker-flags:"$(CXX_LINK)"

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

debug: deps
	odin build . -out:btcnode -debug -extra-linker-flags:"$(CXX_LINK)"

clean:
	rm -f btcnode
	rm -f deps/lib/*.a
	cd deps/libsecp256k1 && [ -f Makefile ] && make clean || true
