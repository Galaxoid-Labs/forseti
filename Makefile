.PHONY: all deps build test clean

all: deps build

deps:
	./deps/build.sh

build: deps
	odin build . -out:btcnode

test: deps
	odin test crypto
	odin test wire
	odin test script -define:ODIN_TEST_THREADS=1
	odin test consensus
	odin test storage
	odin test chain
	odin test p2p
	odin test mempool
	odin test rpc

debug: deps
	odin build . -out:btcnode -debug

clean:
	rm -f btcnode
	rm -f deps/lib/*.a
	cd deps/libsecp256k1 && [ -f Makefile ] && make clean || true
