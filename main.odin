package main

import "base:runtime"
import "core:fmt"
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

CLI_Config :: struct {
	network:   string,
	data_dir:  string,
	rpc_port:  int,
	connect:   string, // ip:port of manual peer
	p2p_port:  int,
	no_p2p:    bool,
}

_parse_cli :: proc() -> (cfg: CLI_Config, ok: bool) {
	cfg.network = "regtest"
	cfg.data_dir = DEFAULT_DATA_DIR
	cfg.rpc_port = 0  // 0 = use network default
	cfg.p2p_port = 0  // 0 = use network default
	cfg.no_p2p = false

	for arg in os.args[1:] {
		if arg == "--help" || arg == "-h" {
			_print_usage()
			return cfg, false
		} else if strings.has_prefix(arg, "--network=") {
			cfg.network = arg[len("--network="):]
		} else if strings.has_prefix(arg, "--datadir=") {
			cfg.data_dir = arg[len("--datadir="):]
		} else if strings.has_prefix(arg, "--rpcport=") {
			val, parse_ok := strconv.parse_int(arg[len("--rpcport="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --rpcport value")
				return cfg, false
			}
			cfg.rpc_port = val
		} else if strings.has_prefix(arg, "--connect=") {
			cfg.connect = arg[len("--connect="):]
		} else if strings.has_prefix(arg, "--p2p-port=") {
			val, parse_ok := strconv.parse_int(arg[len("--p2p-port="):])
			if !parse_ok {
				fmt.eprintln("Error: invalid --p2p-port value")
				return cfg, false
			}
			cfg.p2p_port = val
		} else if arg == "--no-p2p" {
			cfg.no_p2p = true
		} else {
			fmt.eprintln("Error: unknown flag:", arg)
			_print_usage()
			return cfg, false
		}
	}

	return cfg, true
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
	fmt.println("  --help, -h            Show this help message")
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

	fmt.eprintln("Error: unknown network:", network)
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
	// Parse CLI flags.
	cfg, cli_ok := _parse_cli()
	if !cli_ok {
		return
	}

	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	fmt.println("bitcoin-node-odin starting...")

	// Select network params.
	params, default_rpc_port, params_ok := _select_params(cfg.network)
	if !params_ok {
		return
	}

	rpc_port := default_rpc_port
	if cfg.rpc_port != 0 {
		rpc_port = cfg.rpc_port
	}

	fmt.printf("[init] Network: %s\n", params.name)
	fmt.printf("[init] Data directory: %s\n", cfg.data_dir)

	// Initialize chain state.
	cs := new(chain.Chain_State)
	cs_err := chain.chain_state_init(cs, cfg.data_dir, params)
	if cs_err != .None {
		fmt.eprintln("[init] Failed to initialize chain state:", cs_err)
		return
	}
	defer chain.chain_state_destroy(cs)

	tip_hash, tip_height := chain.chain_tip(cs)
	fmt.printf("[init] Chain loaded: height=%d tip=%s\n", tip_height, rpc._hash_to_hex(tip_hash))

	// Initialize mempool.
	mp := new(mempool.Mempool)
	mempool.mempool_init(mp, cs, params)
	defer mempool.mempool_destroy(mp)

	// Start RPC server (cm wired below after P2P init).
	srv := new(rpc.RPC_Server)
	rpc.rpc_server_init(srv, cs, mp, params, rpc_port)

	if !rpc.rpc_server_start(srv) {
		fmt.eprintln("[init] Failed to start RPC server on port", rpc_port)
		return
	}
	defer rpc.rpc_server_stop(srv)

	fmt.printf("[rpc] Listening on 127.0.0.1:%d\n", rpc_port)

	// Set global pointer for signal handler.
	_g_rpc_server = srv

	// Run RPC server on a background thread.
	rpc_thread := thread.create_and_start_with_data(
		rawptr(srv),
		proc(data: rawptr) {
			s := cast(^rpc.RPC_Server)data
			rpc.rpc_server_run(s)
		},
	)

	// Initialize P2P connection manager (unless --no-p2p).
	cm: ^p2p.Conn_Manager
	p2p_thread: ^thread.Thread

	if !cfg.no_p2p {
		cm = new(p2p.Conn_Manager)
		cm_err := p2p.conn_manager_init(cm, cs, params)
		if cm_err != .None {
			fmt.eprintln("[init] Failed to initialize connection manager:", cm_err)
			// Continue without P2P — RPC still works.
		} else {
			// If --connect was specified, add the peer before starting the run loop.
			if len(cfg.connect) > 0 {
				addr, port, connect_ok := _parse_connect(cfg.connect)
				if !connect_ok {
					fmt.eprintln("[init] Invalid --connect format, expected ip:port")
				} else {
					peer_err := p2p.conn_manager_add_peer(cm, addr, port)
					if peer_err != .None {
						fmt.printf("[init] Failed to connect to %s:%d: %v\n", addr, port, peer_err)
					} else {
						fmt.printf("[init] Connected to manual peer %s:%d\n", addr, port)
					}
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
		fmt.println("[init] Node ready (RPC-only mode, P2P disabled).")
	} else if cm != nil {
		fmt.println("[init] Node ready. RPC and P2P running.")
	} else {
		fmt.println("[init] Node ready. RPC running (P2P init failed).")
	}
	fmt.printf("[init] Use bitcoin-cli -rpcport=%d to interact.\n", rpc_port)

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

	fmt.println("[init] Shutting down...")
}
