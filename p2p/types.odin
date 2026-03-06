package p2p

import crypto "../crypto"

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
	V2_Handshake,     // BIP324: v2 key exchange in progress
	Version_Sent,
	Handshake_Complete,
	Active,
	Disconnecting,
	Disconnected,
}

Peer_Id :: distinct u64

// BIP133/339: relay queue item with wtxid + fee rate for filtering.
Relay_Item :: struct {
	txid:         Hash256,
	wtxid:        Hash256,
	fee_rate_kvb: i64,
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
TESTNET4_SEEDS :: [2]string{
	"seed.testnet4.bitcoin.sprovoost.nl",
	"seed.testnet4.wiz.biz",
}
REGTEST_SEEDS :: [0]string{}
SIGNET_SEEDS :: [2]string{
	"seed.signet.bitcoin.sprovoost.nl",
	"seed.dlsouza.lol",
}

DEFAULT_PORT_MAINNET  :: 8333
DEFAULT_PORT_TESTNET3 :: 18333
DEFAULT_PORT_TESTNET4 :: 48333
DEFAULT_PORT_REGTEST  :: 18444
DEFAULT_PORT_SIGNET   :: 38333

MAX_OUTBOUND_FULL_RELAY     :: 8
DEFAULT_MAX_CONNECTIONS     :: 125
INBOUND_HANDSHAKE_TIMEOUT   :: 60  // seconds before disconnecting inbound peers stuck in handshake
MAX_HEADERS_PER_MSG         :: 2000
MAX_BLOCKS_PER_PEER         :: 16   // Bitcoin Core: 16 per peer max
MIN_BLOCKS_PER_PEER         :: 4
PEER_TRIAL_BLOCKS           :: 8
PEER_TRIAL_SECS             :: 30
PING_INTERVAL_SECS          :: 120
HANDSHAKE_TIMEOUT_SECS      :: 10
STALE_TIP_SECS              :: 600
BLOCK_STALL_TIMEOUT_DEFAULT :: 10  // Seconds before disconnecting a stalling peer
BLOCK_STALL_TIMEOUT_MAX     :: 64  // Max after repeated doublings
STALL_CHECK_INTERVAL_SECS   :: 1
HEADER_REQUEST_TIMEOUT_SECS :: 60
HEADER_REFRESH_SECS         :: 120  // Periodic getheaders while In_Sync
COMPACT_BLOCK_VERSION       :: u64(2) // v2 = wtxid-based short IDs (BIP152)
COMPACT_BLOCK_TIMEOUT       :: 10     // seconds before fallback to full block
V2_HANDSHAKE_TIMEOUT_SECS   :: 5      // seconds before v2 → v1 fallback

// Services flags.
NODE_NETWORK         :: u64(1)
NODE_BLOOM           :: u64(1 << 2)   // BIP111: bloom filter support
NODE_WITNESS         :: u64(1 << 3)
NODE_COMPACT_FILTERS :: u64(1 << 6)
NODE_NETWORK_LIMITED :: u64(1 << 10)
NODE_P2P_V2          :: u64(1 << 11)

// Our advertised services (base — compact filters and P2P_V2 added at runtime if enabled).
LOCAL_SERVICES :: NODE_NETWORK | NODE_NETWORK_LIMITED | NODE_WITNESS
