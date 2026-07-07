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
TIP_BLOCK_RACE_SECS         :: 3   // Seconds before racing tip blocks to a faster peer
STALL_CHECK_INTERVAL_SECS   :: 1
HEADER_REQUEST_TIMEOUT_SECS :: 60
HEADER_REFRESH_SECS         :: 120  // Periodic getheaders while In_Sync
COMPACT_BLOCK_VERSION       :: u64(2) // v2 = wtxid-based short IDs (BIP152)
COMPACT_BLOCK_TIMEOUT       :: 10     // seconds before fallback to full block
V2_HANDSHAKE_TIMEOUT_SECS   :: 5      // seconds before v2 → v1 fallback

// Protocol version gates for feature messages (Bitcoin Core net_processing
// parity). Sending these to older peers is a protocol violation — strict
// clients (electrs parses an 8-command allowlist) disconnect outright.
SENDHEADERS_VERSION :: 70012 // BIP130
FEEFILTER_VERSION   :: 70013 // BIP133
COMPACT_BLOCKS_VERSION_GATE :: 70014 // BIP152
WTXID_RELAY_VERSION :: 70016 // BIP339 (also gates BIP155 sendaddrv2)

// Services flags.
NODE_NETWORK         :: u64(1)
NODE_BLOOM           :: u64(1 << 2)   // BIP111: bloom filter support
NODE_WITNESS         :: u64(1 << 3)
NODE_COMPACT_FILTERS :: u64(1 << 6)
NODE_NETWORK_LIMITED :: u64(1 << 10)
NODE_P2P_V2          :: u64(1 << 11)

// Our advertised services (base — compact filters and P2P_V2 added at runtime if enabled).
LOCAL_SERVICES :: NODE_NETWORK | NODE_NETWORK_LIMITED | NODE_WITNESS

// --- Node status snapshot (for --gui and future getnodestatus RPC) ---
//
// The P2P thread fills this under status_mutex once per second in
// _on_periodic_timer; the GUI thread reads a copy at render time. Fixed-size
// buffers throughout — populating the snapshot never allocates.

STATUS_MAX_PEERS :: 16

Peer_Status :: struct {
	id:               Peer_Id,
	address:          [64]byte,
	addr_len:         int,
	user_agent:       [96]byte,
	agent_len:        int,
	state:            Peer_State,
	inbound:          bool,
	start_height:     i32,
	bytes_sent:       i64,
	bytes_recv:       i64,
	blocks_delivered: int,
	blocks_in_flight: int,
	throughput:       f64, // blocks/sec since tracking began
	last_recv_secs:   i64, // seconds since last message from this peer
}

Node_Status :: struct {
	// Chain
	chain_height:      int,
	best_header:       int,
	tip_hash:          Hash256,

	// Sync
	sync_state:        Sync_State,
	blocks_remaining:  int,
	blocks_in_flight:  int,
	verification_pct:  f64, // txs verified / estimated chain total (0..1)
	eta_secs:          i64, // estimated seconds to full sync (0 = unknown/at tip)

	// Peers
	peer_count:        int,
	peers:             [STATUS_MAX_PEERS]Peer_Status,

	// Mempool
	mempool_count:     int,
	mempool_vbytes:    int,

	// UTXO cache
	utxo_cache_count:  int,
	utxo_cache_bytes:  int,
	utxo_cache_budget: int,

	// Last profile window (cumulative since last 1000-block log)
	prof_blocks:       int,
	prof_ms_per_block: f64,
	prof_read_pct:     f64,
	prof_prefetch_pct: f64,
	prof_valid_pct:    f64,
	prof_utxo_pct:     f64,
	prof_scripts_pct:  f64,
	prof_undo_pct:     f64,

	// System
	uptime_secs:       i64,
	disk_usage:        i64, // blk+rev+chainstate bytes on disk (refreshed ~1/min)
	total_bytes_sent:  i64, // lifetime P2P traffic (GUI derives rates)
	total_bytes_recv:  i64,
	// UTXO flush in progress (snapshot freezes while it runs — see get_status)
	halt_height:       int,    // >0: block validation is stuck at this height
	halt_reason:       [24]byte, // error name, fixed buf (snapshot is copied)
	halt_reason_len:   int,
	flushing:          bool,
	flush_total:       int,
	flush_progress:    int,
}
