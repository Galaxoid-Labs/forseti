package main

import "base:runtime"
import "core:c"
import "core:flags"
import ini "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "chain"
import "consensus"
import "crypto"
import "drivechain"
import "mempool"
import "p2p"
import zmqpkg "zmq"
import "gui"
import "tui"
import "rpc"
import "storage"
import "wire"

DEFAULT_DATA_DIR :: "/tmp/forseti-data"

// Global pointers for signal handler (C-calling-convention, no closures).
_g_rpc_server: ^rpc.RPC_Server
_g_conn_manager: ^p2p.Conn_Manager

// True when logging goes to a file (--tui/--daemon): the console loggers still
// write to os.stdout/os.stderr, but those fds are dup2'd onto <datadir>/debug.log
// at the OS level (see main). We deliberately do NOT use log.create_file_logger:
// os2's stream write on a freshly-opened file handle silently drops writes on
// worker threads (the P2P thread), while os.stdout works reliably everywhere.
// So all threads use a plain console logger and the OS redirect does the rest.
_g_log_to_file: bool = false

// Build a console logger. Terminal colors only when logging to the actual
// terminal (not when redirected to debug.log). Callers assign to
// context.logger themselves — `context` has value semantics per scope.
_make_logger :: proc(level: log.Level) -> log.Logger {
	opts: log.Options = {.Level, .Date, .Time}
	if !_g_log_to_file { opts += {.Terminal_Color} }
	return log.create_console_logger(level, opts)
}

// Redirect the stdout+stderr fds onto <datadir>/debug.log (append) at the OS
// level so every thread's console-logger output lands in the file. Returns
// false if the file could not be opened.
_redirect_stdio_to_log :: proc(data_dir: string) -> bool {
	os.make_directory(data_dir)
	path := fmt.ctprintf("%s/debug.log", data_dir)
	fd := posix.open(path, {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 { return false }
	posix.dup2(fd, posix.STDOUT_FILENO)
	posix.dup2(fd, posix.STDERR_FILENO)
	if i32(fd) > 2 { posix.close(fd) }
	return true
}

_Rpc_Thread_Data :: struct {
	srv:       ^rpc.RPC_Server,
	log_level: log.Level,
}

_signal_handler :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	if _g_rpc_server != nil {
		rpc.rpc_server_stop(_g_rpc_server)
	}
	if _g_conn_manager != nil {
		p2p.conn_manager_shutdown(_g_conn_manager)
	}
}

// Fee-rate flags are decimal BTC/kvB on the command line (Core convention)
// but satoshis/kvB internally — converted by _custom_flag_setter.
Fee_Rate_Btc :: distinct i64

// --blockfilterindex accepts 0|1|basic ("basic" for Core/electrs parity) —
// normalized to a bool by _custom_flag_setter.
Filter_Index_Flag :: distinct bool

// Command-line configuration, parsed by core:flags (UNIX style: --flag,
// --flag=value). Field order is the --help order; the usage tags ARE the
// help text, so parse behavior and documentation cannot drift apart.
CLI_Config :: struct {
	network:  string `args:"name=network" usage:"Network: mainnet, testnet3, testnet4, signet, regtest (default: regtest)."`,
	data_dir: string `args:"name=datadir" usage:"Data directory (default: /tmp/forseti-data)."`,

	// RPC
	rpc_port:     int    `args:"name=rpcport" usage:"RPC port (default: network-appropriate)."`,
	rpc_user:     string `args:"name=rpcuser" usage:"RPC auth username (default: cookie auth)."`,
	rpc_password: string `args:"name=rpcpassword" usage:"RPC auth password (must set both user and password)."`,
	rpc_bind:     string `args:"name=rpcbind" usage:"Bind RPC to address (default: 127.0.0.1; non-loopback requires --rpcallowip)."`,
	rpc_allow_ips: [dynamic]string `args:"name=rpcallowip" usage:"Allow RPC from IPv4 address/CIDR, repeatable (loopback always allowed)."`,
	server:       bool   `args:"name=server" usage:"Enable the RPC server (default: 1)."`,

	// P2P
	connect:              string `args:"name=connect" usage:"Connect to a specific peer (ip:port) instead of DNS discovery."`,
	p2p_port:             int    `args:"name=p2p-port" usage:"P2P listen port (default: network-appropriate)."`,
	no_p2p:               bool   `args:"name=no-p2p" usage:"Disable P2P networking (RPC-only mode)."`,
	listen:               bool   `args:"name=listen" usage:"Accept inbound P2P connections (default: 1)."`,
	max_connections:      int    `args:"name=maxconnections" usage:"Total peer connections (default: 125)."`,
	v2_transport:         bool   `args:"name=v2transport" usage:"BIP 324 v2 encrypted P2P transport, v1 fallback (default: 1)."`,
	proxy:                string `args:"name=proxy" usage:"SOCKS5 proxy (ip[:port]) for ALL outbound P2P, e.g. Tor at 127.0.0.1:9050.\nHostname/.onion targets resolve at the proxy (no DNS leak); DNS seeds are\ncontacted through the proxy; inbound is disabled."`,
	max_upload_target_mb: int    `args:"name=maxuploadtarget" usage:"Daily upload budget in MiB; when spent, week-old blocks are not served (0=unlimited)."`,
	peer_bloom_filters:   bool   `args:"name=peerbloomfilters" usage:"Enable BIP 37 bloom filters + BIP 35 mempool message (default: 0)."`,

	// Chain / storage
	db_cache_mb:        int  `args:"name=dbcache" usage:"Database cache size in MiB (default: 450, min: 4)."`,
	par_threads:        int  `args:"name=par" usage:"Script verification threads (0=auto, 1=serial, 2+=parallel; default: 0)."`,
	prevout_fetch_threads: int `args:"name=prevoutfetchthreads" usage:"Parallel UTXO prefetch threads for connect_block (I/O; independent of --par; -1=auto, 0=off, N=threads capped 16)."`,
	assumevalid:        int  `args:"name=assumevalid" usage:"Skip script verification below height (0=disable; default: network-specific)."`,
	prune_mb:           int  `args:"name=prune" usage:"Delete old block files, keep usage under target MB (min 550, 0=off)."`,
	txindex:            bool `args:"name=txindex" usage:"Full transaction index for getrawtransaction (default: 0; incompatible with --prune)."`,
	block_filter_index: Filter_Index_Flag `args:"name=blockfilterindex" usage:"BIP 158 compact block filter index: 0, 1, or basic (default: 0)."`,

	// Mempool (matching Bitcoin Core)
	max_mempool_mb:           int          `args:"name=maxmempool" usage:"Maximum mempool size in megabytes (default: 300)."`,
	mempool_expiry_hours:     int          `args:"name=mempoolexpiry" usage:"Evict txs older than N hours (default: 336)."`,
	mempool_fullrbf:          bool         `args:"name=mempoolfullrbf" usage:"Allow full RBF replacement (default: 1)."`,
	limit_ancestor_count:     int          `args:"name=limitancestorcount" usage:"Max unconfirmed ancestor count (default: 25)."`,
	limit_ancestor_size_kb:   int          `args:"name=limitancestorsize" usage:"Max ancestor chain size in kvB (default: 101)."`,
	limit_descendant_count:   int          `args:"name=limitdescendantcount" usage:"Max unconfirmed descendant count (default: 25)."`,
	limit_descendant_size_kb: int          `args:"name=limitdescendantsize" usage:"Max descendant chain size in kvB (default: 101)."`,
	min_relay_tx_fee:         Fee_Rate_Btc `args:"name=minrelaytxfee" usage:"Minimum relay fee rate in BTC/kvB (default: 0.00001000)."`,
	incremental_relay_fee:    Fee_Rate_Btc `args:"name=incrementalrelayfee" usage:"Fee rate increment for RBF in BTC/kvB (default: 0.00001000)."`,
	dust_relay_fee:           Fee_Rate_Btc `args:"name=dustrelayfee" usage:"Dust threshold fee rate in BTC/kvB (default: 0.00003000)."`,
	datacarrier:              bool         `args:"name=datacarrier" usage:"Allow OP_RETURN outputs (default: 1)."`,
	datacarrier_size:         int          `args:"name=datacarriersize" usage:"Max OP_RETURN script size (default: 83)."`,
	permit_bare_multisig:     bool         `args:"name=permitbaremultisig" usage:"Allow bare multisig outputs (default: 1)."`,
	blocks_only:              bool         `args:"name=blocksonly" usage:"Disable tx relay, only sync blocks (default: 0)."`,
	persist_mempool:          bool         `args:"name=persistmempool" usage:"Save/load mempool on shutdown/startup (default: 1)."`,

	// ZMQ notifications
	zmq_hashblock: string `args:"name=zmqpubhashblock" usage:"ZMQ publish block hashes (tcp://ip:port)."`,
	zmq_hashtx:    string `args:"name=zmqpubhashtx" usage:"ZMQ publish tx hashes (tcp://ip:port)."`,
	zmq_rawblock:  string `args:"name=zmqpubrawblock" usage:"ZMQ publish raw blocks (tcp://ip:port)."`,
	zmq_rawtx:     string `args:"name=zmqpubrawtx" usage:"ZMQ publish raw transactions (tcp://ip:port)."`,
	zmq_sequence:  string `args:"name=zmqpubsequence" usage:"ZMQ publish sequence events (tcp://ip:port)."`,

	// Drivechain (BIP 300/301)
	drivechain: string `args:"name=drivechain" usage:"BIP 300/301: off (default), track, or enforce.\ntrack: parse M1-M6/BMM messages and maintain the sidechain + withdrawal\ndatabases without rejecting anything (zero risk).\nenforce: additionally reject blocks violating BIP300/301 rules.\nWARNING: enforce is a CUSF-style voluntary soft fork — while the rest of\nthe network does not enforce these rules, a violating block would be\nrejected by this node but accepted by everyone else, forking this node\noff the network."`,

	// Maintenance / UI
	wizard:      bool `args:"name=wizard" usage:"Interactive first-run setup: write a forseti.conf, then exit."`,
	repair_utxo: bool `args:"name=repairutxo" usage:"Sweep stale UTXO entries from local block data, then exit."`,
	check_utxo:  bool `args:"name=checkutxo" usage:"Verify UTXO-set integrity (supply cap + rolling-stats reconciliation) at the current tip, then exit."`,
	gui:         bool `args:"name=gui" usage:"Show GUI dashboard window (default: headless)."`,
	tui:         bool `args:"name=tui" usage:"Terminal dashboard (for SSH sessions; q quits)."`,
	daemon:      bool `args:"name=daemon" usage:"Run in the background (fork, detach from the terminal, log to <datadir>/debug.log)."`,
	debug:       bool `args:"name=debug" usage:"Enable debug logging (default: off)."`,
}

// core:flags hands unknown/distinct types here.
_custom_flag_setter :: proc(
	data: rawptr,
	data_type: typeid,
	unparsed_value: string,
	args_tag: string,
) -> (error: string, handled: bool, alloc_error: runtime.Allocator_Error) {
	switch data_type {
	case Fee_Rate_Btc:
		handled = true
		val, ok := strconv.parse_f64(unparsed_value)
		if !ok || val < 0 {
			error = "expected a decimal BTC/kvB fee rate (e.g. 0.00001000)"
			return
		}
		(^Fee_Rate_Btc)(data)^ = Fee_Rate_Btc(val * 100_000_000)
	case Filter_Index_Flag:
		handled = true
		switch unparsed_value {
		case "1", "true", "basic":
			(^Filter_Index_Flag)(data)^ = true
		case "0", "false":
			(^Filter_Index_Flag)(data)^ = false
		case:
			error = "expected 0, 1, or basic"
		}
	}
	return
}

// Parse the command line. Prints usage and exits on --help or bad input.
// cli_seen records which flag names appeared, so the config file only fills
// in what the CLI left unset (CLI > config file > defaults).
_parse_cli :: proc() -> (cfg: CLI_Config, cli_seen: map[string]bool) {
	cfg = CLI_Config {
		network                  = "regtest",
		data_dir                 = DEFAULT_DATA_DIR,
		mempool_fullrbf          = true,
		db_cache_mb              = 450,
		prevout_fetch_threads    = -1, // auto (independent of --par)
		assumevalid              = -1, // use network default
		max_mempool_mb           = 300,
		mempool_expiry_hours     = 336,
		limit_ancestor_count     = 25,
		limit_ancestor_size_kb   = 101,
		limit_descendant_count   = 25,
		limit_descendant_size_kb = 101,
		min_relay_tx_fee         = 1000,
		incremental_relay_fee    = 1000,
		dust_relay_fee           = 3000,
		datacarrier              = true,
		datacarrier_size         = 83,
		permit_bare_multisig     = true,
		persist_mempool          = true,
		server                   = true,
		max_connections          = 125,
		v2_transport             = true, // BIP324 on by default; automatic v1 fallback covers old peers
		listen                   = true,
		drivechain               = "off",
	}

	flags.register_type_setter(_custom_flag_setter)
	flags.parse_or_exit(&cfg, os.args, .Unix)

	// Cross-field validation the type system can't express.
	if cfg.prune_mb != 0 && cfg.prune_mb < 550 {
		fmt.eprintln("Error: --prune target must be at least 550 (MB), or 0 to disable")
		os.exit(1)
	}
	if cfg.drivechain != "off" && cfg.drivechain != "track" && cfg.drivechain != "enforce" {
		fmt.eprintln("Error: --drivechain must be off, track, or enforce")
		os.exit(1)
	}
	if cfg.max_upload_target_mb < 0 {
		fmt.eprintln("Error: invalid --maxuploadtarget value")
		os.exit(1)
	}

	cli_seen = make(map[string]bool)
	for arg in os.args[1:] {
		name := arg
		if strings.has_prefix(name, "--") {
			name = name[2:]
		} else if strings.has_prefix(name, "-") {
			name = name[1:]
		} else {
			continue
		}
		if eq := strings.index_byte(name, '='); eq >= 0 {
			name = name[:eq]
		}
		cli_seen[name] = true
	}
	return
}

_load_config_file :: proc(path: string, cfg: ^CLI_Config, cli_seen: map[string]bool) {
	// Not an error if config file doesn't exist (first run).
	if !os.exists(path) {
		return
	}

	m, _, ini_ok := ini.load_map_from_path(path, context.allocator, ini.Options{comment = "#"})
	if !ini_ok {
		log.warnf("Failed to parse config file: %s", path)
		return
	}
	defer ini.delete_map(m)

	log.infof("Loaded config file: %s", path)

	// Helper: look up key in network section first, then global (empty string) section.
	_ini_get :: proc(m: ^ini.Map, network: string, key: string) -> (string, bool) {
		// Try network-specific section first.
		if section, has_section := m[network]; has_section {
			if val, has_key := section[key]; has_key {
				return val, true
			}
		}
		// Fall back to global section.
		if global, has_global := m[""]; has_global {
			if val, has_key := global[key]; has_key {
				return val, true
			}
		}
		return "", false
	}

	// Apply config values only where CLI flags were NOT explicitly set.
	if "network" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "network"); found {
			cfg.network = strings.clone(val)
		}
	}

	if "datadir" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "datadir"); found {
			cfg.data_dir = strings.clone(val)
		}
	}

	if "rpcport" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "rpcport"); found {
			if port, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.rpc_port = port
			}
		}
	}

	if "connect" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "connect"); found {
			cfg.connect = strings.clone(val)
		}
	}

	if "p2p-port" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "p2p-port"); found {
			if port, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.p2p_port = port
			}
		}
	}

	if "no-p2p" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "no-p2p"); found {
			cfg.no_p2p = val == "1" || val == "true" || val == "yes"
		}
	}

	if "mempoolfullrbf" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "mempoolfullrbf"); found {
			cfg.mempool_fullrbf = val == "1" || val == "true" || val == "yes"
		}
	}

	if "dbcache" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "dbcache"); found {
			if mb, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.db_cache_mb = max(mb, 4)
			}
		}
	}

	if "prune" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "prune"); found {
			if mb, parse_ok := strconv.parse_int(val); parse_ok && (mb == 0 || mb >= 550) {
				cfg.prune_mb = mb
			}
		}
	}

	if "rpcbind" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "rpcbind"); found {
			cfg.rpc_bind = strings.clone(val)
		}
	}
	if "proxy" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "proxy"); found {
			cfg.proxy = strings.clone(val)
		}
	}
	if "maxuploadtarget" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "maxuploadtarget"); found {
			if n, ok := strconv.parse_int(val); ok && n >= 0 {
				cfg.max_upload_target_mb = n
			}
		}
	}
	if "rpcallowip" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "rpcallowip"); found {
			// Comma-separated list in the config file.
			for part in strings.split(val, ",", context.temp_allocator) {
				trimmed := strings.trim_space(part)
				if len(trimmed) > 0 {
					append(&cfg.rpc_allow_ips, strings.clone(trimmed))
				}
			}
		}
	}

	if "drivechain" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "drivechain"); found {
			if val == "off" || val == "track" || val == "enforce" {
				cfg.drivechain = strings.clone(val)
			} else {
				log.warnf("Config: invalid drivechain value %q (must be off, track, or enforce) — ignored", val)
			}
		}
	}

	if "par" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "par"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.par_threads = max(n, 0)
			}
		}
	}

	if "assumevalid" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "assumevalid"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.assumevalid = max(n, 0)
			}
		}
	}

	if "maxmempool" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "maxmempool"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.max_mempool_mb = max(n, 1)
			}
		}
	}

	if "mempoolexpiry" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "mempoolexpiry"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.mempool_expiry_hours = max(n, 1)
			}
		}
	}

	if "limitancestorcount" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "limitancestorcount"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_ancestor_count = max(n, 1)
			}
		}
	}

	if "limitancestorsize" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "limitancestorsize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_ancestor_size_kb = max(n, 1)
			}
		}
	}

	if "limitdescendantcount" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "limitdescendantcount"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_descendant_count = max(n, 1)
			}
		}
	}

	if "limitdescendantsize" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "limitdescendantsize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_descendant_size_kb = max(n, 1)
			}
		}
	}

	if "minrelaytxfee" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "minrelaytxfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.min_relay_tx_fee = Fee_Rate_Btc(f * 100_000_000)
			}
		}
	}

	if "incrementalrelayfee" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "incrementalrelayfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.incremental_relay_fee = Fee_Rate_Btc(f * 100_000_000)
			}
		}
	}

	if "dustrelayfee" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "dustrelayfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.dust_relay_fee = Fee_Rate_Btc(f * 100_000_000)
			}
		}
	}

	if "datacarrier" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "datacarrier"); found {
			cfg.datacarrier = val == "1" || val == "true" || val == "yes"
		}
	}

	if "datacarriersize" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "datacarriersize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.datacarrier_size = max(n, 0)
			}
		}
	}

	if "permitbaremultisig" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "permitbaremultisig"); found {
			cfg.permit_bare_multisig = val == "1" || val == "true" || val == "yes"
		}
	}

	if "blocksonly" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "blocksonly"); found {
			cfg.blocks_only = val == "1" || val == "true" || val == "yes"
		}
	}

	if "persistmempool" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "persistmempool"); found {
			cfg.persist_mempool = val == "1" || val == "true" || val == "yes"
		}
	}

	if "rpcuser" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "rpcuser"); found {
			cfg.rpc_user = strings.clone(val)
		}
	}

	if "rpcpassword" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "rpcpassword"); found {
			cfg.rpc_password = strings.clone(val)
		}
	}

	if "server" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "server"); found {
			cfg.server = val == "1" || val == "true" || val == "yes"
		}
	}

	if "maxconnections" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "maxconnections"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.max_connections = max(n, 0)
			}
		}
	}

	// Each key gets its OWN cli_seen guard — the zmq keys were once nested
	// under the v2transport guard, so any --v2transport on the CLI silently
	// disabled every zmqpub* config entry (same guard-mismatch family as the
	// 2cf544c ZMQ CLI bug).
	if "zmqpubhashblock" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "zmqpubhashblock"); found {
			cfg.zmq_hashblock = strings.clone(val)
		}
	}
	if "zmqpubhashtx" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "zmqpubhashtx"); found {
			cfg.zmq_hashtx = strings.clone(val)
		}
	}
	if "zmqpubrawblock" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "zmqpubrawblock"); found {
			cfg.zmq_rawblock = strings.clone(val)
		}
	}
	if "zmqpubrawtx" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "zmqpubrawtx"); found {
			cfg.zmq_rawtx = strings.clone(val)
		}
	}
	if "zmqpubsequence" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "zmqpubsequence"); found {
			cfg.zmq_sequence = strings.clone(val)
		}
	}
	if "v2transport" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "v2transport"); found {
			cfg.v2_transport = val == "1" || val == "true" || val == "yes"
		}
	}

	if "blockfilterindex" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "blockfilterindex"); found {
			cfg.block_filter_index = Filter_Index_Flag(val == "1" || val == "basic" || val == "true")
		}
	}
	if "txindex" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "txindex"); found {
			cfg.txindex = val == "1" || val == "true"
		}
	}

	if "listen" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "listen"); found {
			cfg.listen = val == "1" || val == "true" || val == "yes"
		}
	}

	if "peerbloomfilters" not_in cli_seen {
		if val, found := _ini_get(&m, cfg.network, "peerbloomfilters"); found {
			cfg.peer_bloom_filters = val == "1" || val == "true" || val == "yes"
		}
	}
}

// Resolve par_threads: 0 = auto-detect, 1 = serial, >= 2 = parallel.
// Returns the resolved script_threads value to pass to chain_state_init.
_resolve_par_threads :: proc(par: int) -> int {
	if par >= 2 {
		return min(par, 15)
	}
	if par == 1 {
		return 0 // serial
	}
	// Auto-detect: use available CPUs minus 2 (for main + P2P threads)
	n := os.get_processor_core_count()
	if n <= 0 {
		return 4 // fallback
	}
	result := max(n - 2, 1)
	if result < 2 {
		return 0 // serial on single/dual-core
	}
	return min(result, 15)
}

// Returns the resolved prevout-prefetch worker count. Prefetch is I/O-bound
// (parallel LevelDB reads to warm the coins cache before connect_block), so it
// is tuned independently of script verification: -1 = auto (up to 16, based on
// cores, regardless of --par), 0/1 = off, N = N workers capped at 16.
_resolve_prevout_threads :: proc(val: int) -> int {
	if val < 0 {
		n := os.get_processor_core_count()
		if n <= 1 {
			return 0 // no parallelism possible
		}
		return min(n, 16)
	}
	if val <= 1 {
		return 0 // explicitly disabled (a single worker gives no speedup)
	}
	return min(val, 16)
}

_select_params :: proc(network: string) -> (params: ^consensus.Chain_Params, rpc_port: int, ok: bool) {
	params = new(consensus.Chain_Params)

	switch network {
	case "mainnet":
		params^ = consensus.MAINNET_PARAMS
		return params, 8332, true
	case "testnet3":
		params^ = consensus.TESTNET3_PARAMS
		return params, 18332, true
	case "testnet4":
		params^ = consensus.TESTNET4_PARAMS
		return params, 48332, true
	case "signet":
		params^ = consensus.SIGNET_PARAMS
		return params, 38332, true
	case "regtest":
		params^ = consensus.REGTEST_PARAMS
		return params, 18443, true
	}

	log.errorf("Unknown network: %s", network)
	free(params)
	return nil, 0, false
}

// Parse "ip:port" into address and port components.
_parse_connect :: proc(connect: string) -> (address: string, port: int, ok: bool) {
	// Find last colon (to handle IPv4 only for now).
	last_colon := -1
	for i in 0 ..< len(connect) {
		if connect[i] == ':' {
			last_colon = i
		}
	}

	if last_colon < 0 {
		return connect, 0, false
	}

	address = connect[:last_colon]
	port_val, parse_ok := strconv.parse_int(connect[last_colon + 1:])
	if !parse_ok {
		return address, 0, false
	}

	return address, port_val, true
}

main :: proc() {
	// Start with Info level; --debug flag will switch to Debug after parsing.
	context.logger = log.create_console_logger(.Info, {.Level, .Time, .Terminal_Color})

	// Parse CLI flags.
	cfg, cli_seen := _parse_cli()

	// First-run setup wizard: writes a config and exits, before any of the
	// normal config-load / chain-init machinery.
	if cfg.wizard {
		tui.run_wizard()
		return
	}

	// Apply debug log level if requested.
	log_level: log.Level = cfg.debug ? .Debug : .Info
	context.logger = log.create_console_logger(log_level, {.Level, .Time, .Terminal_Color})
	// Registered before all other defers so it runs last, after every
	// deferred destroy/flush has finished.
	defer log.info("Shutdown complete.")


	// Load config file (CLI flags take precedence).
	_load_config_file(fmt.tprintf("%s/forseti.conf", cfg.data_dir), &cfg, cli_seen)

	if cfg.gui && cfg.tui {
		fmt.eprintln("Error: --gui and --tui are mutually exclusive")
		return
	}

	// Validate rpcuser/rpcpassword: must set both or neither.
	has_user := len(cfg.rpc_user) > 0
	has_pass := len(cfg.rpc_password) > 0
	if has_user != has_pass {
		fmt.eprintln("Error: must set both rpcuser and rpcpassword")
		return
	}

	// --daemon: detach from the terminal and run in the background (like
	// `bitcoind -daemon`). A dashboard needs the terminal/window, so it's
	// mutually exclusive with --gui/--tui. Fork BEFORE the single-instance lock
	// and any threads so the child owns them cleanly.
	if cfg.daemon {
		if cfg.gui || cfg.tui {
			fmt.eprintln("Error: --daemon cannot be combined with --gui or --tui (it detaches from the terminal)")
			return
		}
		os.make_directory(cfg.data_dir) // so the child can open the log file
		pid := posix.fork()
		if pid < 0 {
			fmt.eprintln("Error: fork() failed, cannot daemonize")
			return
		}
		if pid > 0 {
			// Parent: report where the node went and exit immediately.
			fmt.printfln("forseti started in the background (PID %d)", pid)
			fmt.printfln("Logging to %s/debug.log", cfg.data_dir)
			fmt.printfln("Stop it with:  kill %d   (or the `stop` RPC)", pid)
			os.exit(0)
		}
		// Child: session leader, stdin → /dev/null (terminal released), then
		// stdout+stderr → debug.log below.
		posix.setsid()
		if devnull := posix.open("/dev/null", {}); devnull >= 0 { // {} = O_RDONLY
			posix.dup2(devnull, posix.STDIN_FILENO)
			if i32(devnull) > 2 { posix.close(devnull) }
		}
	}

	// Send logging to <datadir>/debug.log for --tui (keeps the ncurses screen
	// clean) and --daemon (detached). We redirect the stdout/stderr fds at the
	// OS level and keep using console loggers — os2's file-logger stream write
	// silently drops writes from worker threads, but os.stdout works from all
	// threads. So the redirect below is what actually routes logs to the file.
	if cfg.tui || cfg.daemon {
		if !_redirect_stdio_to_log(cfg.data_dir) {
			fmt.eprintfln("Warning: could not redirect logging to %s/debug.log", cfg.data_dir)
		} else {
			_g_log_to_file = true
		}
	}
	context.logger = _make_logger(log_level)

	// Single-instance guard (Bitcoin Core's .lock): an flock held for the
	// whole process lifetime — including a hung teardown — so a second
	// instance on the same datadir refuses instantly instead of racing the
	// first (two GUI windows on one datadir, 2026-07-06).
	os.make_directory(cfg.data_dir)
	{
		lock_path := fmt.ctprintf("%s/.lock", cfg.data_dir)
		lock_fd := posix.open(lock_path, {.RDWR, .CREAT}, {.IRUSR, .IWUSR})
		if lock_fd == -1 {
			fmt.eprintln("Error: cannot open datadir lock file")
			return
		}
		lk := posix.flock {
			l_type   = .WRLCK,
			l_whence = c.short(posix.Whence.SET),
			l_start  = 0,
			l_len    = 0, // whole file
		}
		if posix.fcntl(lock_fd, .SETLK, &lk) == -1 {
			fmt.eprintfln("Error: another forseti instance is already running on %s (datadir is locked)", cfg.data_dir)
			return
		}
		// Deliberately never closed/unlocked — the OS releases it at process
		// exit, however the process ends.
	}

	// Generate cookie file if no explicit credentials and server is enabled.
	cookie_path := ""
	if !has_user && cfg.server {
		// Datadir may not exist yet (chain init creates it later).
		os.make_directory(cfg.data_dir)
		cookie_path = fmt.aprintf("%s/.cookie", cfg.data_dir)

		// Read 32 random bytes from /dev/urandom → 64 hex chars.
		random_bytes: [32]byte
		urandom_handle, urandom_err := os.open("/dev/urandom")
		if urandom_err != nil {
			fmt.eprintln("Error: failed to open /dev/urandom for cookie generation")
			return
		}
		_, read_err := os.read(urandom_handle, random_bytes[:])
		os.close(urandom_handle)
		if read_err != nil {
			fmt.eprintln("Error: failed to read random bytes for cookie generation")
			return
		}

		hex_chars := "0123456789abcdef"
		hex_buf: [64]byte
		for i in 0 ..< 32 {
			hex_buf[i * 2] = hex_chars[random_bytes[i] >> 4]
			hex_buf[i * 2 + 1] = hex_chars[random_bytes[i] & 0x0f]
		}
		cookie_hex := string(hex_buf[:])

		// No trailing newline — Bitcoin Core writes the cookie bare, and
		// strict readers (bitcoincore-rpc/electrs) take the file verbatim,
		// newline included, then fail auth with 401.
		cookie_content := fmt.aprintf("__cookie__:%s", cookie_hex)
		defer delete(cookie_content)

		if os.write_entire_file(cookie_path, transmute([]byte)cookie_content) != nil {
			fmt.eprintln("Error: failed to write cookie file:", cookie_path)
			delete(cookie_path)
			return
		}

		cfg.rpc_user = "__cookie__"
		cfg.rpc_password = strings.clone(cookie_hex)
		log.infof("Cookie file: %s", cookie_path)
	}
	defer {
		if len(cookie_path) > 0 {
			os.remove(cookie_path)
			delete(cookie_path)
		}
	}

	// --gui: open the window immediately; the node initializes on a worker
	// thread while the main thread (required for raylib on macOS) animates
	// the loading screen. Headless/TUI keep the classic main-thread path.
	if cfg.gui {
		boot := new(gui.Boot)
		boot.info.network = cfg.network
		boot.request_shutdown = proc() {
			if _g_rpc_server != nil {
				rpc.rpc_server_stop(_g_rpc_server)
			}
			if _g_conn_manager != nil {
				p2p.conn_manager_shutdown(_g_conn_manager)
			}
		}
		nd := new(_Node_Thread_Data)
		nd.cfg = &cfg
		nd.log_level = log_level
		nd.boot = boot
		node_thread := thread.create_and_start_with_data(rawptr(nd), proc(data: rawptr) {
			nd := cast(^_Node_Thread_Data)data
			context.logger = _make_logger(nd.log_level)
			_node_main(nd.cfg, nd.log_level, nd.boot)
		})
		// run_boot triggers shutdown itself and holds the window open until
		// boot.stopped — returning false means no display session (headless).
		gui.run_boot(boot)
		thread.join(node_thread)
		thread.destroy(node_thread)
		free(nd)
	} else {
		_node_main(&cfg, log_level, nil)
	}
}

_Node_Thread_Data :: struct {
	cfg:       ^CLI_Config,
	log_level: log.Level,
	boot:      ^gui.Boot,
}

// Full node lifecycle: init, run, teardown (defers). Runs on the main
// thread headless/TUI; on a worker thread under --gui, publishing readiness
// through `boot` while gui.run_boot animates startup on the main thread.
_node_main :: proc(cfg: ^CLI_Config, log_level: log.Level, boot: ^gui.Boot) {
	// Registered first = runs LAST, after every teardown defer below has
	// finished — the GUI holds its shutdown screen until this flips.
	defer if boot != nil {
		boot.stopped = true
	}
	// Any early-return before readiness is an init failure — tell the GUI.
	defer if boot != nil && !boot.ready {
		boot.failed = true
	}

	crypto.sha256_init_backend()
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	log.infof("Forseti v%s starting...", wire.NODE_VERSION)

	// Select network params.
	params, default_rpc_port, params_ok := _select_params(cfg.network)
	if !params_ok {
		return
	}

	rpc_port := default_rpc_port
	if cfg.rpc_port != 0 {
		rpc_port = cfg.rpc_port
	}

	// Apply assumevalid override (0 = disable, >0 = override, -1 = use default).
	if cfg.assumevalid >= 0 {
		params.assumevalid_height = cfg.assumevalid
	}

	// Resolve parallel script verification + prevout-prefetch threads.
	script_threads := _resolve_par_threads(cfg.par_threads)
	prevout_fetch_threads := _resolve_prevout_threads(cfg.prevout_fetch_threads)

	log.infof("Network: %s", params.name)
	log.infof("Data directory: %s", cfg.data_dir)
	log.infof("DB cache: %d MiB", cfg.db_cache_mb)
	if script_threads >= 2 {
		log.infof("Script verification: %d threads", script_threads)
	} else {
		log.info("Script verification: serial")
	}
	if prevout_fetch_threads >= 2 {
		log.infof("Prevout prefetch: %d threads", prevout_fetch_threads)
	} else {
		log.info("Prevout prefetch: disabled")
	}
	if params.assumevalid_height > 0 {
		log.infof("Assumevalid: skip script verification below height %d", params.assumevalid_height)
	} else {
		log.info("Assumevalid: disabled (verifying all scripts)")
	}

	dc_mode: drivechain.Mode = .Off
	switch cfg.drivechain {
	case "track":
		dc_mode = .Track
		log.info("Drivechain (BIP300/301): TRACK mode — maintaining sidechain/withdrawal databases, rejecting nothing")
	case "enforce":
		dc_mode = .Enforce
		log.warn("Drivechain (BIP300/301): ENFORCE mode — blocks violating BIP300/301 will be REJECTED.")
		log.warn("While the rest of the network does not enforce these rules, this node can fork itself off the network.")
	}

	// Initialize chain state.
	cs := new(chain.Chain_State)
	cs_err := chain.chain_state_init(cs, cfg.data_dir, params, cfg.db_cache_mb, script_threads, cfg.prune_mb * 1024 * 1024, dc_mode, prevout_fetch_threads)
	if cs_err != .None {
		log.errorf("Failed to initialize chain state: %v", cs_err)
		return
	}
	defer chain.chain_state_destroy(cs)

	// Open BIP 158 filter index if enabled.
	if bool(cfg.block_filter_index) {
		fdb := new(storage.Filter_DB)
		fdb_result, fdb_err := storage.filter_db_open(cfg.data_dir)
		if fdb_err != .None {
			log.errorf("Failed to open filter index: %v", fdb_err)
			free(fdb)
		} else {
			fdb^ = fdb_result
			cs.filter_db = fdb
			log.infof("BIP 158 compact block filter index enabled")
		}
	}

	// Open the transaction index if enabled (Core parity: refuse with pruning).
	if cfg.txindex {
		if cfg.prune_mb > 0 {
			log.error("--txindex is incompatible with --prune (the index reads txs from full block files)")
			return
		}
		tdb := new(storage.Tx_Index_DB)
		tdb_result, tdb_err := storage.tx_index_db_open(cfg.data_dir)
		if tdb_err != .None {
			log.errorf("Failed to open tx index: %v", tdb_err)
			free(tdb)
			return
		}
		tdb^ = tdb_result
		cs.tx_index = tdb
		chain.Boot_Stage = "Building transaction index"
		if !chain.tx_index_catchup(cs) {
			log.error("Transaction index could not be built (missing block data)")
			return
		}
		chain.Boot_Stage = ""
	}

	tip_hash, tip_height := chain.chain_tip(cs)
	log.infof("Chain loaded: height=%d tip=%s", tip_height, rpc._hash_to_hex(tip_hash))

	// Maintenance mode: sweep stale UTXO entries from local block data,
	// report, and exit (no RPC, no P2P).
	if cfg.repair_utxo {
		chain.repair_utxo_sweep(cs)
		return
	}

	// Verification mode: reconcile the UTXO set against its invariants and exit.
	if cfg.check_utxo {
		ok := chain.check_utxo_consistency(cs)
		os.exit(ok ? 0 : 1)
	}

	// Initialize mempool with config from CLI/config file.
	mp_config := mempool.Mempool_Config{
		max_mempool_mb          = cfg.max_mempool_mb,
		mempool_expiry_hours    = cfg.mempool_expiry_hours,
		limit_ancestor_count    = cfg.limit_ancestor_count,
		limit_ancestor_size_kb  = cfg.limit_ancestor_size_kb,
		limit_descendant_count  = cfg.limit_descendant_count,
		limit_descendant_size_kb= cfg.limit_descendant_size_kb,
		min_relay_tx_fee        = i64(cfg.min_relay_tx_fee),
		incremental_relay_fee   = i64(cfg.incremental_relay_fee),
		dust_relay_fee          = i64(cfg.dust_relay_fee),
		datacarrier             = cfg.datacarrier,
		datacarrier_size        = cfg.datacarrier_size,
		permit_bare_multisig    = cfg.permit_bare_multisig,
		fullrbf                 = cfg.mempool_fullrbf,
		max_rbf_evictions       = 100,
		persist_mempool         = cfg.persist_mempool,
		blocks_only             = cfg.blocks_only,
	}
	mp := new(mempool.Mempool)
	mempool.mempool_init(mp, cs, params, mp_config)
	// Defers run LIFO: destroy must be registered FIRST so it runs AFTER the
	// save. With the previous order, destroy freed every entry and the save
	// then serialized dangling tx structs — every shutdown-written
	// mempool.dat was garbage (empty 10-byte txs) and the loader skipped
	// 100% of entries on the next start.
	defer mempool.mempool_destroy(mp)
	defer {
		if mp.config.persist_mempool {
			mempool.mempool_save(mp, cfg.data_dir)
		}
		mempool.estimator_save(&mp.estimator, cfg.data_dir)
	}

	// Fee-estimate history first (cheap), then the mempool itself — loaded
	// entries re-enter through mempool_add and register with the estimator.
	mempool.estimator_load(&mp.estimator, cfg.data_dir)
	if mp.config.persist_mempool {
		mempool.mempool_load(mp, cfg.data_dir)
	}

	// Start RPC server (cm wired below after P2P init).
	srv: ^rpc.RPC_Server
	rpc_thread: ^thread.Thread

	if cfg.server {
		srv = new(rpc.RPC_Server)
		rpc.rpc_server_init(srv, cs, mp, params, rpc_port, data_dir = cfg.data_dir, rpc_user = cfg.rpc_user, rpc_password = cfg.rpc_password)

		if !rpc.rpc_server_configure_network(srv, cfg.rpc_bind, cfg.rpc_allow_ips[:]) {
			return
		}
		if !rpc.rpc_server_start(srv) {
			log.errorf("Failed to start RPC server on port %d", rpc_port)
			return
		}

		log.infof("RPC listening on %s:%d", cfg.rpc_bind != "" ? cfg.rpc_bind : "127.0.0.1", rpc_port)

		// Set global pointer for signal handler.
		_g_rpc_server = srv

		// Run RPC server on a background thread.
		rpc_data := new(_Rpc_Thread_Data)
		rpc_data.srv = srv
		rpc_data.log_level = log_level
		rpc_thread = thread.create_and_start_with_data(
			rawptr(rpc_data),
			proc(data: rawptr) {
				td := cast(^_Rpc_Thread_Data)data
				context.logger = _make_logger(td.log_level)
				rpc.rpc_server_run(td.srv)
				free(td)
			},
		)
	} else {
		log.info("RPC server disabled (--server=0)")
	}
	defer {
		if srv != nil {
			rpc.rpc_server_stop(srv)
		}
	}

	// Initialize P2P connection manager (unless --no-p2p).
	cm: ^p2p.Conn_Manager
	p2p_thread: ^thread.Thread

	if !cfg.no_p2p {
		cm = new(p2p.Conn_Manager)
		cm_err := p2p.conn_manager_init(cm, cs, params, mp)
		if cm_err != .None {
			log.errorf("Failed to initialize connection manager: %v", cm_err)
			// Continue without P2P — RPC still works.
		} else {
			cm.log_level = log_level
			cm.data_dir = cfg.data_dir
			cm.max_upload_target = i64(cfg.max_upload_target_mb) * 1024 * 1024
			cm.blocks_only = cfg.blocks_only
			cm.max_outbound = p2p.MAX_OUTBOUND_FULL_RELAY
			cm.v2_transport_enabled = cfg.v2_transport
			if cfg.proxy != "" {
				if !p2p.conn_manager_set_proxy(cm, cfg.proxy) {
					return
				}
				if cfg.listen {
					// Inbound + proxy would advertise/serve our real address.
					log.info("Proxy configured — disabling inbound P2P connections")
					cfg.listen = false
				}
			}
			cm.local_services = p2p.LOCAL_SERVICES
			if cfg.prune_mb > 0 {
				// Pruned: can serve only recent blocks — NODE_NETWORK_LIMITED
				// stays, full NODE_NETWORK must not be advertised.
				cm.local_services &~= p2p.NODE_NETWORK
			}
			if bool(cfg.block_filter_index) {
				cm.local_services |= p2p.NODE_COMPACT_FILTERS
			}
			if cfg.v2_transport {
				cm.local_services |= p2p.NODE_P2P_V2
			}
			if cfg.peer_bloom_filters {
				cm.peer_bloom_filters = true
				cm.local_services |= p2p.NODE_BLOOM
			}

			// Compute inbound connection budget.
			// When --listen=0, --connect is used, or --maxconnections=0: no inbound.
			p2p_port := cfg.p2p_port if cfg.p2p_port != 0 else cm.default_port
			if cfg.listen && len(cfg.connect) == 0 && cfg.max_connections > 0 {
				cm.max_inbound = max(cfg.max_connections - cm.max_outbound - 1, 0)
				cm.listen_port = p2p_port
			} else {
				cm.max_inbound = 0
			}

			if cm.max_inbound > 0 {
				log.infof("Connection budget: %d outbound, %d inbound (max %d total)",
					cm.max_outbound, cm.max_inbound, cfg.max_connections)
			}

			// If --connect was specified, store address for event loop to connect.
			if len(cfg.connect) > 0 {
				addr, port, connect_ok := _parse_connect(cfg.connect)
				if !connect_ok {
					log.error("Invalid --connect format, expected ip:port")
				} else {
					cm.connect_address = addr
					cm.connect_port = port
				}
			}

			// Set global pointer for signal handler.
			_g_conn_manager = cm

			// ZMQ publishers (Bitcoin Core zmqpub* parity), if configured.
			{
				topics := make([dynamic]string, 0, 5, context.temp_allocator)
				eps := make([dynamic]string, 0, 5, context.temp_allocator)
				if cfg.zmq_hashblock != "" { append(&topics, zmqpkg.TOPIC_HASHBLOCK); append(&eps, cfg.zmq_hashblock) }
				if cfg.zmq_hashtx    != "" { append(&topics, zmqpkg.TOPIC_HASHTX);    append(&eps, cfg.zmq_hashtx) }
				if cfg.zmq_rawblock  != "" { append(&topics, zmqpkg.TOPIC_RAWBLOCK);  append(&eps, cfg.zmq_rawblock) }
				if cfg.zmq_rawtx     != "" { append(&topics, zmqpkg.TOPIC_RAWTX);     append(&eps, cfg.zmq_rawtx) }
				if cfg.zmq_sequence  != "" { append(&topics, zmqpkg.TOPIC_SEQUENCE);  append(&eps, cfg.zmq_sequence) }
				if len(topics) > 0 {
					cm.zmq = zmqpkg.setup(topics[:], eps[:])
					cm.sync_mgr.zmq = cm.zmq
				}
			}

			// Publish the 1 Hz status snapshot always: the in-process GUI/TUI read
			// it, AND the getnodestatus RPC serves it to remote dashboards
			// (forseti-gui, --tui over RPC). Gating on cfg.gui left headless/daemon
			// nodes reporting an all-zero status. The map walk is cheap.
			cm.status_enabled = true

			// Wire connection manager into RPC server.
			if srv != nil {
				srv.cm = cm
			}

			// Run P2P on a background thread.
			p2p_thread = thread.create_and_start_with_data(
				rawptr(cm),
				proc(data: rawptr) {
					c := cast(^p2p.Conn_Manager)data
					p2p.conn_manager_run(c)
				},
			)
		}
	}
	defer {
		if cm != nil {
			p2p.conn_manager_destroy(cm)
			free(cm)
		}
	}

	// Register signal handlers for graceful shutdown.
	posix.signal(.SIGINT, _signal_handler)
	posix.signal(.SIGTERM, _signal_handler)

	if !cfg.server && cfg.no_p2p {
		log.info("Node ready (no RPC, no P2P). Nothing to do.")
		return
	} else if !cfg.server {
		log.info("Node ready (RPC disabled, P2P running).")
	} else if cfg.no_p2p {
		log.info("Node ready (RPC-only mode, P2P disabled).")
	} else if cm != nil {
		log.info("Node ready. RPC and P2P running.")
	} else {
		log.info("Node ready. RPC running (P2P init failed).")
	}
	if cfg.server {
		log.infof("Use bitcoin-cli -rpcport=%d to interact.", rpc_port)
	}

	// GUI mode: the main thread (which otherwise just blocks in thread.join)
	// runs the dashboard render loop. Closing the window triggers the same
	// graceful shutdown path as SIGINT. Without --gui nothing here runs and
	// the node stays fully headless.
	if cfg.tui && cm != nil {
		tui_fetch :: proc(ud: rawptr) -> (p2p.Node_Status, bool) {
			c := cast(^p2p.Conn_Manager)ud
			if c.shutdown { return {}, false }
			return p2p.conn_manager_get_status(c), true
		}
		if tui.run_with_source(tui.Static_Info{network = cfg.network, rpc_port = rpc_port, dbcache_mb = cfg.db_cache_mb, prune_mb = cfg.prune_mb, data_dir = cfg.data_dir}, tui_fetch, cm, local = true) {
			if srv != nil {
				rpc.rpc_server_stop(srv)
			}
			p2p.conn_manager_shutdown(cm)
		}
	}

	// GUI mode: the window is already open on the main thread (gui.run_boot);
	// publish cm/cs so it can switch from the loading screen to the dashboard.
	if boot != nil {
		boot.info = gui.Static_Info{network = cfg.network, rpc_port = rpc_port, dbcache_mb = cfg.db_cache_mb, prune_mb = cfg.prune_mb, data_dir = cfg.data_dir}
		boot.cm = cm
		boot.cs = cs
		boot.ready = true
	}

	// Wait for threads to finish.
	// If P2P is running, wait for it first (signal handler will stop both).
	if p2p_thread != nil {
		thread.join(p2p_thread)
		// P2P done — also stop RPC.
		if srv != nil {
			rpc.rpc_server_stop(srv)
		}
	}

	if rpc_thread != nil {
		thread.join(rpc_thread)
	}

	if cm != nil && cm.zmq != nil {
		zmqpkg.shutdown(cm.zmq)
	}
	log.info("Shutting down...")
}

