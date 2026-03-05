package main

import "base:runtime"
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
import "mempool"
import "p2p"
import "rpc"
import "storage"
import "wire"

DEFAULT_DATA_DIR :: "/tmp/btcnode-data"

// Global pointers for signal handler (C-calling-convention, no closures).
_g_rpc_server: ^rpc.RPC_Server
_g_conn_manager: ^p2p.Conn_Manager

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

CLI_Flag :: enum {
	Network,
	Data_Dir,
	Rpc_Port,
	Connect,
	P2P_Port,
	No_P2P,
	Mempool_Full_RBF,
	DbCache,
	Par,
	Assume_Valid,
	Max_Mempool,
	Mempool_Expiry,
	Limit_Ancestor_Count,
	Limit_Ancestor_Size,
	Limit_Descendant_Count,
	Limit_Descendant_Size,
	Min_Relay_Tx_Fee,
	Incremental_Relay_Fee,
	Dust_Relay_Fee,
	Datacarrier,
	Datacarrier_Size,
	Permit_Bare_Multisig,
	Blocks_Only,
	Persist_Mempool,
	Rpc_User,
	Rpc_Password,
	Server,
	Max_Connections,
	V2_Transport,
	Block_Filter_Index,
	Listen,
}
CLI_Flags_Set :: bit_set[CLI_Flag]

CLI_Config :: struct {
	network:                string,
	data_dir:               string,
	rpc_port:               int,
	connect:                string, // ip:port of manual peer
	p2p_port:               int,
	no_p2p:                 bool,
	mempool_fullrbf:        bool,
	db_cache_mb:            int,
	par_threads:            int, // 0 = auto, 1 = serial, >= 2 = N threads
	assumevalid:            int, // -1 = use default, 0 = disable, >0 = override height
	max_mempool_mb:         int,
	mempool_expiry_hours:   int,
	limit_ancestor_count:   int,
	limit_ancestor_size_kb: int,
	limit_descendant_count: int,
	limit_descendant_size_kb: int,
	min_relay_tx_fee:       i64,
	incremental_relay_fee:  i64,
	dust_relay_fee:         i64,
	datacarrier:            bool,
	datacarrier_size:       int,
	permit_bare_multisig:   bool,
	blocks_only:            bool,
	persist_mempool:        bool,
	rpc_user:               string,
	rpc_password:           string,
	server:                 bool,   // default true
	max_connections:        int,    // total peer connections (default: 125)
	v2_transport:           bool,   // BIP324 v2 encrypted transport
	block_filter_index:     bool,   // BIP158 compact block filter index
	listen:                 bool,   // accept inbound connections (default: true)
	debug:                  bool,   // enable debug logging (default: false)
}

_parse_cli :: proc() -> (cfg: CLI_Config, flags_set: CLI_Flags_Set, ok: bool) {
	cfg.network = "regtest"
	cfg.data_dir = DEFAULT_DATA_DIR
	cfg.rpc_port = 0  // 0 = use network default
	cfg.p2p_port = 0  // 0 = use network default
	cfg.no_p2p = false
	cfg.mempool_fullrbf = true
	cfg.db_cache_mb = 450
	cfg.par_threads = 0  // auto-detect
	cfg.assumevalid = -1 // use network default
	cfg.max_mempool_mb = 300
	cfg.mempool_expiry_hours = 336
	cfg.limit_ancestor_count = 25
	cfg.limit_ancestor_size_kb = 101
	cfg.limit_descendant_count = 25
	cfg.limit_descendant_size_kb = 101
	cfg.min_relay_tx_fee = 1000
	cfg.incremental_relay_fee = 1000
	cfg.dust_relay_fee = 3000
	cfg.datacarrier = true
	cfg.datacarrier_size = 83
	cfg.permit_bare_multisig = true
	cfg.blocks_only = false
	cfg.persist_mempool = true
	cfg.server = true
	cfg.max_connections = 125
	cfg.v2_transport = true
	cfg.block_filter_index = false
	cfg.listen = true

	for arg in os.args[1:] {
		if arg == "--help" || arg == "-h" {
			_print_usage()
			return cfg, flags_set, false
		} else if strings.has_prefix(arg, "--network=") {
			cfg.network = arg[len("--network="):]
			flags_set += {.Network}
		} else if strings.has_prefix(arg, "--datadir=") {
			cfg.data_dir = arg[len("--datadir="):]
			flags_set += {.Data_Dir}
		} else if strings.has_prefix(arg, "--rpcport=") {
			val, parse_ok := strconv.parse_int(arg[len("--rpcport="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --rpcport value")
				return cfg, flags_set, false
			}
			cfg.rpc_port = val
			flags_set += {.Rpc_Port}
		} else if strings.has_prefix(arg, "--connect=") {
			cfg.connect = arg[len("--connect="):]
			flags_set += {.Connect}
		} else if strings.has_prefix(arg, "--p2p-port=") {
			val, parse_ok := strconv.parse_int(arg[len("--p2p-port="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --p2p-port value")
				return cfg, flags_set, false
			}
			cfg.p2p_port = val
			flags_set += {.P2P_Port}
		} else if arg == "--no-p2p" {
			cfg.no_p2p = true
			flags_set += {.No_P2P}
		} else if strings.has_prefix(arg, "--mempoolfullrbf=") {
			val := arg[len("--mempoolfullrbf="):]
			cfg.mempool_fullrbf = val == "1" || val == "true"
			flags_set += {.Mempool_Full_RBF}
		} else if strings.has_prefix(arg, "--dbcache=") {
			val, parse_ok := strconv.parse_int(arg[len("--dbcache="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --dbcache value")
				return cfg, flags_set, false
			}
			cfg.db_cache_mb = max(val, 4)
			flags_set += {.DbCache}
		} else if strings.has_prefix(arg, "--par=") {
			val, parse_ok := strconv.parse_int(arg[len("--par="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --par value")
				return cfg, flags_set, false
			}
			cfg.par_threads = max(val, 0)
			flags_set += {.Par}
		} else if strings.has_prefix(arg, "--assumevalid=") {
			val, parse_ok := strconv.parse_int(arg[len("--assumevalid="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --assumevalid value")
				return cfg, flags_set, false
			}
			cfg.assumevalid = max(val, 0)
			flags_set += {.Assume_Valid}
		} else if strings.has_prefix(arg, "--maxmempool=") {
			val, parse_ok := strconv.parse_int(arg[len("--maxmempool="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --maxmempool value")
				return cfg, flags_set, false
			}
			cfg.max_mempool_mb = max(val, 1)
			flags_set += {.Max_Mempool}
		} else if strings.has_prefix(arg, "--mempoolexpiry=") {
			val, parse_ok := strconv.parse_int(arg[len("--mempoolexpiry="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --mempoolexpiry value")
				return cfg, flags_set, false
			}
			cfg.mempool_expiry_hours = max(val, 1)
			flags_set += {.Mempool_Expiry}
		} else if strings.has_prefix(arg, "--limitancestorcount=") {
			val, parse_ok := strconv.parse_int(arg[len("--limitancestorcount="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --limitancestorcount value")
				return cfg, flags_set, false
			}
			cfg.limit_ancestor_count = max(val, 1)
			flags_set += {.Limit_Ancestor_Count}
		} else if strings.has_prefix(arg, "--limitancestorsize=") {
			val, parse_ok := strconv.parse_int(arg[len("--limitancestorsize="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --limitancestorsize value")
				return cfg, flags_set, false
			}
			cfg.limit_ancestor_size_kb = max(val, 1)
			flags_set += {.Limit_Ancestor_Size}
		} else if strings.has_prefix(arg, "--limitdescendantcount=") {
			val, parse_ok := strconv.parse_int(arg[len("--limitdescendantcount="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --limitdescendantcount value")
				return cfg, flags_set, false
			}
			cfg.limit_descendant_count = max(val, 1)
			flags_set += {.Limit_Descendant_Count}
		} else if strings.has_prefix(arg, "--limitdescendantsize=") {
			val, parse_ok := strconv.parse_int(arg[len("--limitdescendantsize="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --limitdescendantsize value")
				return cfg, flags_set, false
			}
			cfg.limit_descendant_size_kb = max(val, 1)
			flags_set += {.Limit_Descendant_Size}
		} else if strings.has_prefix(arg, "--minrelaytxfee=") {
			val, parse_ok := strconv.parse_f64(arg[len("--minrelaytxfee="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --minrelaytxfee value")
				return cfg, flags_set, false
			}
			cfg.min_relay_tx_fee = i64(val * 100_000_000)
			flags_set += {.Min_Relay_Tx_Fee}
		} else if strings.has_prefix(arg, "--incrementalrelayfee=") {
			val, parse_ok := strconv.parse_f64(arg[len("--incrementalrelayfee="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --incrementalrelayfee value")
				return cfg, flags_set, false
			}
			cfg.incremental_relay_fee = i64(val * 100_000_000)
			flags_set += {.Incremental_Relay_Fee}
		} else if strings.has_prefix(arg, "--dustrelayfee=") {
			val, parse_ok := strconv.parse_f64(arg[len("--dustrelayfee="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --dustrelayfee value")
				return cfg, flags_set, false
			}
			cfg.dust_relay_fee = i64(val * 100_000_000)
			flags_set += {.Dust_Relay_Fee}
		} else if strings.has_prefix(arg, "--datacarrier=") {
			val := arg[len("--datacarrier="):]
			cfg.datacarrier = val == "1" || val == "true"
			flags_set += {.Datacarrier}
		} else if strings.has_prefix(arg, "--datacarriersize=") {
			val, parse_ok := strconv.parse_int(arg[len("--datacarriersize="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --datacarriersize value")
				return cfg, flags_set, false
			}
			cfg.datacarrier_size = max(val, 0)
			flags_set += {.Datacarrier_Size}
		} else if strings.has_prefix(arg, "--permitbaremultisig=") {
			val := arg[len("--permitbaremultisig="):]
			cfg.permit_bare_multisig = val == "1" || val == "true"
			flags_set += {.Permit_Bare_Multisig}
		} else if arg == "--blocksonly" || strings.has_prefix(arg, "--blocksonly=") {
			if strings.has_prefix(arg, "--blocksonly=") {
				val := arg[len("--blocksonly="):]
				cfg.blocks_only = val == "1" || val == "true"
			} else {
				cfg.blocks_only = true
			}
			flags_set += {.Blocks_Only}
		} else if strings.has_prefix(arg, "--persistmempool=") {
			val := arg[len("--persistmempool="):]
			cfg.persist_mempool = val == "1" || val == "true"
			flags_set += {.Persist_Mempool}
		} else if strings.has_prefix(arg, "--rpcuser=") {
			cfg.rpc_user = arg[len("--rpcuser="):]
			flags_set += {.Rpc_User}
		} else if strings.has_prefix(arg, "--rpcpassword=") {
			cfg.rpc_password = arg[len("--rpcpassword="):]
			flags_set += {.Rpc_Password}
		} else if strings.has_prefix(arg, "--server=") {
			val := arg[len("--server="):]
			cfg.server = val == "1" || val == "true"
			flags_set += {.Server}
		} else if strings.has_prefix(arg, "--maxconnections=") {
			val, parse_ok := strconv.parse_int(arg[len("--maxconnections="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --maxconnections value")
				return cfg, flags_set, false
			}
			cfg.max_connections = max(val, 0)
			flags_set += {.Max_Connections}
		} else if arg == "--v2transport" || arg == "--v2transport=1" {
			cfg.v2_transport = true
			flags_set += {.V2_Transport}
		} else if arg == "--v2transport=0" {
			cfg.v2_transport = false
			flags_set += {.V2_Transport}
		} else if arg == "--blockfilterindex" || arg == "--blockfilterindex=1" || arg == "--blockfilterindex=basic" {
			cfg.block_filter_index = true
			flags_set += {.Block_Filter_Index}
		} else if arg == "--blockfilterindex=0" {
			cfg.block_filter_index = false
			flags_set += {.Block_Filter_Index}
		} else if arg == "--listen" || arg == "--listen=1" {
			cfg.listen = true
			flags_set += {.Listen}
		} else if arg == "--listen=0" {
			cfg.listen = false
			flags_set += {.Listen}
		} else if arg == "--debug" {
			cfg.debug = true
		} else {
			fmt.eprintln("Error: unknown flag:", arg)
			_print_usage()
			return cfg, flags_set, false
		}
	}

	return cfg, flags_set, true
}

_print_usage :: proc() {
	fmt.println("Usage: btcnode [options]")
	fmt.println()
	fmt.println("Options:")
	fmt.println("  --network=<network>   Network: mainnet, testnet3, testnet4, signet, regtest (default: regtest)")
	fmt.println("  --datadir=<path>      Data directory (default: /tmp/btcnode-data)")
	fmt.println("  --rpcport=<port>      RPC port (default: network-appropriate)")
	fmt.println("  --rpcuser=<user>      RPC auth username (default: cookie auth)")
	fmt.println("  --rpcpassword=<pass>  RPC auth password (must set both user and password)")
	fmt.println("  --server=<0|1>        Enable/disable RPC server (default: 1)")
	fmt.println("  --connect=<ip:port>   Connect to specific peer instead of DNS discovery")
	fmt.println("  --p2p-port=<port>     P2P listen port (default: network-appropriate)")
	fmt.println("  --no-p2p              Disable P2P networking (RPC-only mode)")
	fmt.println("  --listen=<0|1>        Accept inbound P2P connections (default: 1)")
	fmt.println("  --maxconnections=<N>  Total peer connections (default: 125)")
	fmt.println("  --v2transport=<0|1>   Enable BIP 324 v2 encrypted P2P transport (default: 1)")
	fmt.println("  --blockfilterindex=<0|1|basic> Enable BIP 158 compact block filter index (default: 0)")
	fmt.println("  --dbcache=<MB>        Database cache size in MiB (default: 450, min: 4)")
	fmt.println("  --par=<N>             Script verification threads (0=auto, 1=serial, 2+=parallel; default: 0)")
	fmt.println("  --assumevalid=<height> Skip script verification below height (0=disable; default: network-specific)")
	fmt.println()
	fmt.println("Mempool options:")
	fmt.println("  --maxmempool=<MB>     Maximum mempool size in megabytes (default: 300)")
	fmt.println("  --mempoolexpiry=<hours> Evict txs older than N hours (default: 336)")
	fmt.println("  --mempoolfullrbf=<0|1> Allow full RBF replacement (default: 1)")
	fmt.println("  --limitancestorcount=<N> Max unconfirmed ancestor count (default: 25)")
	fmt.println("  --limitancestorsize=<kvB> Max ancestor chain size in kvB (default: 101)")
	fmt.println("  --limitdescendantcount=<N> Max unconfirmed descendant count (default: 25)")
	fmt.println("  --limitdescendantsize=<kvB> Max descendant chain size in kvB (default: 101)")
	fmt.println("  --minrelaytxfee=<BTC/kvB> Minimum relay fee rate (default: 0.00001000)")
	fmt.println("  --incrementalrelayfee=<BTC/kvB> Fee rate increment for RBF (default: 0.00001000)")
	fmt.println("  --dustrelayfee=<BTC/kvB> Dust threshold fee rate (default: 0.00003000)")
	fmt.println("  --datacarrier=<0|1>   Allow OP_RETURN outputs (default: 1)")
	fmt.println("  --datacarriersize=<bytes> Max OP_RETURN script size (default: 83)")
	fmt.println("  --permitbaremultisig=<0|1> Allow bare multisig outputs (default: 1)")
	fmt.println("  --blocksonly          Disable tx relay, only sync blocks (default: off)")
	fmt.println("  --persistmempool=<0|1> Save/load mempool on shutdown/startup (default: 1)")
	fmt.println()
	fmt.println("  --debug               Enable debug logging (default: off)")
	fmt.println("  --help, -h            Show this help message")
}

_load_config_file :: proc(path: string, cfg: ^CLI_Config, flags_set: CLI_Flags_Set) {
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
	if .Network not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "network"); found {
			cfg.network = val
		}
	}

	if .Data_Dir not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "datadir"); found {
			cfg.data_dir = val
		}
	}

	if .Rpc_Port not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "rpcport"); found {
			if port, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.rpc_port = port
			}
		}
	}

	if .Connect not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "connect"); found {
			cfg.connect = val
		}
	}

	if .P2P_Port not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "p2p-port"); found {
			if port, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.p2p_port = port
			}
		}
	}

	if .No_P2P not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "no-p2p"); found {
			cfg.no_p2p = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Mempool_Full_RBF not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "mempoolfullrbf"); found {
			cfg.mempool_fullrbf = val == "1" || val == "true" || val == "yes"
		}
	}

	if .DbCache not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "dbcache"); found {
			if mb, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.db_cache_mb = max(mb, 4)
			}
		}
	}

	if .Par not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "par"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.par_threads = max(n, 0)
			}
		}
	}

	if .Assume_Valid not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "assumevalid"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.assumevalid = max(n, 0)
			}
		}
	}

	if .Max_Mempool not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "maxmempool"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.max_mempool_mb = max(n, 1)
			}
		}
	}

	if .Mempool_Expiry not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "mempoolexpiry"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.mempool_expiry_hours = max(n, 1)
			}
		}
	}

	if .Limit_Ancestor_Count not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "limitancestorcount"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_ancestor_count = max(n, 1)
			}
		}
	}

	if .Limit_Ancestor_Size not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "limitancestorsize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_ancestor_size_kb = max(n, 1)
			}
		}
	}

	if .Limit_Descendant_Count not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "limitdescendantcount"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_descendant_count = max(n, 1)
			}
		}
	}

	if .Limit_Descendant_Size not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "limitdescendantsize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.limit_descendant_size_kb = max(n, 1)
			}
		}
	}

	if .Min_Relay_Tx_Fee not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "minrelaytxfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.min_relay_tx_fee = i64(f * 100_000_000)
			}
		}
	}

	if .Incremental_Relay_Fee not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "incrementalrelayfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.incremental_relay_fee = i64(f * 100_000_000)
			}
		}
	}

	if .Dust_Relay_Fee not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "dustrelayfee"); found {
			if f, parse_ok := strconv.parse_f64(val); parse_ok {
				cfg.dust_relay_fee = i64(f * 100_000_000)
			}
		}
	}

	if .Datacarrier not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "datacarrier"); found {
			cfg.datacarrier = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Datacarrier_Size not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "datacarriersize"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.datacarrier_size = max(n, 0)
			}
		}
	}

	if .Permit_Bare_Multisig not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "permitbaremultisig"); found {
			cfg.permit_bare_multisig = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Blocks_Only not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "blocksonly"); found {
			cfg.blocks_only = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Persist_Mempool not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "persistmempool"); found {
			cfg.persist_mempool = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Rpc_User not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "rpcuser"); found {
			cfg.rpc_user = val
		}
	}

	if .Rpc_Password not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "rpcpassword"); found {
			cfg.rpc_password = val
		}
	}

	if .Server not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "server"); found {
			cfg.server = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Max_Connections not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "maxconnections"); found {
			if n, parse_ok := strconv.parse_int(val); parse_ok {
				cfg.max_connections = max(n, 0)
			}
		}
	}

	if .V2_Transport not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "v2transport"); found {
			cfg.v2_transport = val == "1" || val == "true" || val == "yes"
		}
	}

	if .Block_Filter_Index not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "blockfilterindex"); found {
			cfg.block_filter_index = val == "1" || val == "basic" || val == "true"
		}
	}

	if .Listen not_in flags_set {
		if val, found := _ini_get(&m, cfg.network, "listen"); found {
			cfg.listen = val == "1" || val == "true" || val == "yes"
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
	n := os.processor_core_count()
	if n <= 0 {
		return 4 // fallback
	}
	result := max(n - 2, 1)
	if result < 2 {
		return 0 // serial on single/dual-core
	}
	return min(result, 15)
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
	cfg, flags_set, cli_ok := _parse_cli()
	if !cli_ok {
		return
	}

	// Apply debug log level if requested.
	log_level: log.Level = cfg.debug ? .Debug : .Info
	context.logger = log.create_console_logger(log_level, {.Level, .Time, .Terminal_Color})

	// Load config file (CLI flags take precedence).
	_load_config_file(fmt.tprintf("%s/btcnode.conf", cfg.data_dir), &cfg, flags_set)

	// Validate rpcuser/rpcpassword: must set both or neither.
	has_user := len(cfg.rpc_user) > 0
	has_pass := len(cfg.rpc_password) > 0
	if has_user != has_pass {
		fmt.eprintln("Error: must set both rpcuser and rpcpassword")
		return
	}

	// Generate cookie file if no explicit credentials and server is enabled.
	cookie_path := ""
	if !has_user && cfg.server {
		cookie_path = fmt.aprintf("%s/.cookie", cfg.data_dir)

		// Read 32 random bytes from /dev/urandom → 64 hex chars.
		random_bytes: [32]byte
		urandom_handle, urandom_err := os.open("/dev/urandom")
		if urandom_err != os.ERROR_NONE {
			fmt.eprintln("Error: failed to open /dev/urandom for cookie generation")
			return
		}
		_, read_err := os.read(urandom_handle, random_bytes[:])
		os.close(urandom_handle)
		if read_err != os.ERROR_NONE {
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

		cookie_content := fmt.aprintf("__cookie__:%s\n", cookie_hex)
		defer delete(cookie_content)

		if !os.write_entire_file(cookie_path, transmute([]byte)cookie_content) {
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

	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	log.infof("bitcoin-node-odin v%s starting...", wire.NODE_VERSION)

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

	// Resolve parallel script verification threads.
	script_threads := _resolve_par_threads(cfg.par_threads)

	log.infof("Network: %s", params.name)
	log.infof("Data directory: %s", cfg.data_dir)
	log.infof("DB cache: %d MiB", cfg.db_cache_mb)
	if script_threads >= 2 {
		log.infof("Script verification: %d threads", script_threads)
	} else {
		log.info("Script verification: serial")
	}
	if params.assumevalid_height > 0 {
		log.infof("Assumevalid: skip script verification below height %d", params.assumevalid_height)
	} else {
		log.info("Assumevalid: disabled (verifying all scripts)")
	}

	// Initialize chain state.
	cs := new(chain.Chain_State)
	cs_err := chain.chain_state_init(cs, cfg.data_dir, params, cfg.db_cache_mb, script_threads)
	if cs_err != .None {
		log.errorf("Failed to initialize chain state: %v", cs_err)
		return
	}
	defer chain.chain_state_destroy(cs)

	// Open BIP 158 filter index if enabled.
	if cfg.block_filter_index {
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

	tip_hash, tip_height := chain.chain_tip(cs)
	log.infof("Chain loaded: height=%d tip=%s", tip_height, rpc._hash_to_hex(tip_hash))

	// Initialize mempool with config from CLI/config file.
	mp_config := mempool.Mempool_Config{
		max_mempool_mb          = cfg.max_mempool_mb,
		mempool_expiry_hours    = cfg.mempool_expiry_hours,
		limit_ancestor_count    = cfg.limit_ancestor_count,
		limit_ancestor_size_kb  = cfg.limit_ancestor_size_kb,
		limit_descendant_count  = cfg.limit_descendant_count,
		limit_descendant_size_kb= cfg.limit_descendant_size_kb,
		min_relay_tx_fee        = cfg.min_relay_tx_fee,
		incremental_relay_fee   = cfg.incremental_relay_fee,
		dust_relay_fee          = cfg.dust_relay_fee,
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
	defer {
		if mp.config.persist_mempool {
			mempool.mempool_save(mp, cfg.data_dir)
		}
	}
	defer mempool.mempool_destroy(mp)

	if mp.config.persist_mempool {
		mempool.mempool_load(mp, cfg.data_dir)
	}

	// Start RPC server (cm wired below after P2P init).
	srv: ^rpc.RPC_Server
	rpc_thread: ^thread.Thread

	if cfg.server {
		srv = new(rpc.RPC_Server)
		rpc.rpc_server_init(srv, cs, mp, params, rpc_port, data_dir = cfg.data_dir, rpc_user = cfg.rpc_user, rpc_password = cfg.rpc_password)

		if !rpc.rpc_server_start(srv) {
			log.errorf("Failed to start RPC server on port %d", rpc_port)
			return
		}

		log.infof("RPC listening on 127.0.0.1:%d", rpc_port)

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
				context.logger = log.create_console_logger(td.log_level, {.Level, .Time, .Terminal_Color})
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
			cm.blocks_only = cfg.blocks_only
			cm.max_outbound = p2p.MAX_OUTBOUND_FULL_RELAY
			cm.v2_transport_enabled = cfg.v2_transport
			cm.local_services = p2p.LOCAL_SERVICES
			if cfg.block_filter_index {
				cm.local_services |= p2p.NODE_COMPACT_FILTERS
			}
			if cfg.v2_transport {
				cm.local_services |= p2p.NODE_P2P_V2
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

	log.info("Shutting down...")
}
