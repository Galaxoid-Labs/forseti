package p2p

import "../crypto"

Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

Net_Error :: enum {
	None,
	Connection_Failed,
	Handshake_Failed,
	Timeout,
	Bad_Message,
	Peer_Disconnected,
	Too_Many_Peers,
	Protocol_Violation,
	Send_Failed,
}

Peer_State :: enum {
	Connecting,
	Version_Sent,
	Handshake_Complete,
	Active,
	Disconnecting,
	Disconnected,
}

Peer_Id :: distinct u64

// Inbound message from a peer reader thread.
Peer_Message :: struct {
	peer_id: Peer_Id,
	command: string, // CMD_VERSION, CMD_HEADERS, etc. Empty = disconnect signal.
	payload: []byte, // raw payload (owned, must be freed by receiver)
}

// DNS seed hostnames per network.
MAINNET_SEEDS :: [4]string {
	"seed.bitcoin.sipa.be",
	"dnsseed.bluematt.me",
	"dnsseed.bitcoin.dashjr-list-of-hierarchical-deterministic-wallets.org",
	"seed.bitcoinstats.com",
}
TESTNET3_SEEDS :: [3]string {
	"testnet-seed.bitcoin.jonasschnelli.ch",
	"seed.tbtc.petertodd.net",
	"seed.testnet.bitcoin.sprovoost.nl",
}
REGTEST_SEEDS :: [0]string{}
SIGNET_SEEDS :: [2]string{
	"seed.signet.bitcoin.sprovoost.nl",
	"seed.dlsouza.lol",
}

DEFAULT_PORT_MAINNET  :: 8333
DEFAULT_PORT_TESTNET3 :: 18333
DEFAULT_PORT_REGTEST  :: 18444
DEFAULT_PORT_SIGNET   :: 38333

MAX_OUTBOUND_PEERS          :: 8
MAX_HEADERS_PER_MSG         :: 2000
MAX_BLOCKS_PER_PEER         :: 16
PING_INTERVAL_SECS          :: 120
HANDSHAKE_TIMEOUT_SECS      :: 10
STALE_TIP_SECS              :: 600
BLOCK_STALL_TIMEOUT_SECS    :: 30
STALL_CHECK_INTERVAL_SECS   :: 5
HEADER_REQUEST_TIMEOUT_SECS :: 60

// Services flags.
NODE_NETWORK         :: u64(1)
NODE_WITNESS         :: u64(1 << 3)
NODE_NETWORK_LIMITED :: u64(1 << 10)

// Our advertised services.
LOCAL_SERVICES :: NODE_NETWORK | NODE_WITNESS
