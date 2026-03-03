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

DEFAULT_DATA_DIR :: "/tmp/btcnode-data"

// Global pointers for signal handler (C-calling-convention, no closures).
_g_rpc_server: ^rpc.RPC_Server
_g_conn_manager: ^p2p.Conn_Manager

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
}
CLI_Flags_Set :: bit_set[CLI_Flag]

CLI_Config :: struct {
	network:         string,
	data_dir:        string,
	rpc_port:        int,
	connect:         string, // ip:port of manual peer
	p2p_port:        int,
	no_p2p:          bool,
	mempool_fullrbf: bool,
	db_cache_mb:     int,
	par_threads:     int, // 0 = auto, 1 = serial, >= 2 = N threads
	assumevalid:     int, // -1 = use default, 0 = disable, >0 = override height
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
	fmt.println("  --connect=<ip:port>   Connect to specific peer instead of DNS discovery")
	fmt.println("  --p2p-port=<port>     P2P listen port (default: network-appropriate)")
	fmt.println("  --no-p2p              Disable P2P networking (RPC-only mode)")
	fmt.println("  --mempoolfullrbf=<0|1> Allow full RBF replacement (default: 1)")
	fmt.println("  --dbcache=<MB>        Database cache size in MiB (default: 450, min: 4)")
	fmt.println("  --par=<N>             Script verification threads (0=auto, 1=serial, 2+=parallel; default: 0)")
	fmt.println("  --assumevalid=<height> Skip script verification below height (0=disable; default: network-specific)")
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
	context.logger = log.create_console_logger(.Debug, {.Level, .Time, .Terminal_Color})

	// Parse CLI flags.
	cfg, flags_set, cli_ok := _parse_cli()
	if !cli_ok {
		return
	}

	// Load config file (CLI flags take precedence).
	_load_config_file(fmt.tprintf("%s/btcnode.conf", cfg.data_dir), &cfg, flags_set)

	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	log.info("bitcoin-node-odin starting...")

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

	tip_hash, tip_height := chain.chain_tip(cs)
	log.infof("Chain loaded: height=%d tip=%s", tip_height, rpc._hash_to_hex(tip_hash))

	// Initialize mempool.
	mp := new(mempool.Mempool)
	mempool.mempool_init(mp, cs, params)
	mp.fullrbf = cfg.mempool_fullrbf
	defer mempool.mempool_save(mp, cfg.data_dir)
	defer mempool.mempool_destroy(mp)

	mempool.mempool_load(mp, cfg.data_dir)

	// Start RPC server (cm wired below after P2P init).
	srv := new(rpc.RPC_Server)
	rpc.rpc_server_init(srv, cs, mp, params, rpc_port, data_dir = cfg.data_dir)

	if !rpc.rpc_server_start(srv) {
		log.errorf("Failed to start RPC server on port %d", rpc_port)
		return
	}
	defer rpc.rpc_server_stop(srv)

	log.infof("RPC listening on 127.0.0.1:%d", rpc_port)

	// Set global pointer for signal handler.
	_g_rpc_server = srv

	// Run RPC server on a background thread.
	rpc_thread := thread.create_and_start_with_data(
		rawptr(srv),
		proc(data: rawptr) {
			context.logger = log.create_console_logger(.Debug, {.Level, .Time, .Terminal_Color})
			s := cast(^rpc.RPC_Server)data
			rpc.rpc_server_run(s)
		},
	)

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
			srv.cm = cm

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

	if cfg.no_p2p {
		log.info("Node ready (RPC-only mode, P2P disabled).")
	} else if cm != nil {
		log.info("Node ready. RPC and P2P running.")
	} else {
		log.info("Node ready. RPC running (P2P init failed).")
	}
	log.infof("Use bitcoin-cli -rpcport=%d to interact.", rpc_port)

	// Wait for threads to finish.
	// If P2P is running, wait for it first (signal handler will stop both).
	if p2p_thread != nil {
		thread.join(p2p_thread)
		// P2P done — also stop RPC.
		rpc.rpc_server_stop(srv)
	}

	if rpc_thread != nil {
		thread.join(rpc_thread)
	}

	log.info("Shutting down...")
}
