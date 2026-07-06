// btcnode-gui: standalone dashboard for a (possibly remote) btcnode.
//
// Polls the node's getnodestatus RPC once a second over HTTP JSON-RPC and
// renders the same dashboard the in-process --gui shows. The node's RPC binds
// localhost only — reach a remote node with an SSH tunnel:
//
//   ssh -L 8332:localhost:8332 myserver
//   btcnode-gui --connect=127.0.0.1:8332 --cookie=~/btcnode-mainnet/.cookie
//
// Auth: --rpcuser/--rpcpassword, or --cookie=<path to .cookie file>.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "../gui"
import "../p2p"
import "../tui"

Client :: struct {
	endpoint: net.Endpoint,
	auth_b64: string, // base64("user:pass")
	// Filled from the first successful response.
	info:     gui.Static_Info,
	have_info: bool,
}

main :: proc() {
	address := "127.0.0.1:8332"
	user, pass, cookie_path: string
	probe := false
	use_tui := false

	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--connect=") {
			address = arg[len("--connect="):]
		} else if strings.has_prefix(arg, "--rpcuser=") {
			user = arg[len("--rpcuser="):]
		} else if strings.has_prefix(arg, "--rpcpassword=") {
			pass = arg[len("--rpcpassword="):]
		} else if strings.has_prefix(arg, "--cookie=") {
			cookie_path = arg[len("--cookie="):]
		} else if arg == "--probe" {
			probe = true
		} else if arg == "--tui" {
			use_tui = true
		} else if arg == "--help" || arg == "-h" {
			fmt.println("btcnode-gui — remote dashboard for btcnode")
			fmt.println("  --connect=<ip:port>    Node RPC address (default: 127.0.0.1:8332)")
			fmt.println("  --rpcuser=<u> --rpcpassword=<p>   RPC credentials")
			fmt.println("  --cookie=<path>        Read credentials from a .cookie file")
			fmt.println("  --probe                Fetch one status snapshot, print it, exit (no window)")
			fmt.println("  --tui                  Terminal dashboard instead of a window (SSH-friendly)")
			fmt.println("Remote nodes: tunnel first — ssh -L 8332:localhost:8332 <server>")
			return
		}
	}

	if cookie_path != "" {
		data, rerr := os.read_entire_file(cookie_path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("Failed to read cookie file %s", cookie_path)
			return
		}
		cookie := strings.trim_space(string(data))
		idx := strings.index_byte(cookie, ':')
		if idx < 0 {
			fmt.eprintln("Cookie file is not user:pass")
			return
		}
		user = cookie[:idx]
		pass = cookie[idx + 1:]
	}
	if user == "" {
		fmt.eprintln("No credentials: pass --rpcuser/--rpcpassword or --cookie=<path>")
		return
	}

	ep, ep_ok := net.parse_endpoint(address)
	if !ep_ok {
		fmt.eprintfln("Invalid --connect address %q (use ip:port)", address)
		return
	}

	client := Client{
		endpoint = ep,
		auth_b64 = base64.encode(transmute([]byte)fmt.tprintf("%s:%s", user, pass), allocator = context.allocator),
	}
	client.info = gui.Static_Info{network = "connecting...", rpc_port = ep.port, data_dir = address}

	if probe {
		st, fetch_ok := _fetch_status(&client)
		if !fetch_ok {
			fmt.eprintln("probe: FAILED to fetch status")
			os.exit(1)
		}
		fmt.printfln("probe: network=%s height=%d headers=%d state=%v peers=%d mempool=%d disk=%dMB uptime=%ds",
			client.info.network, st.chain_height, st.best_header, st.sync_state,
			st.peer_count, st.mempool_count, st.disk_usage / 1_048_576, st.uptime_secs)
		return
	}

	fetch :: proc(ud: rawptr) -> (p2p.Node_Status, bool) {
		c := cast(^Client)ud
		return _fetch_status(c)
	}

	// Prime the static info (network/datadir/prune/dbcache) with one fetch —
	// the renderers take Static_Info by value, so it must be correct up front.
	_, _ = _fetch_status(&client)

	if use_tui {
		tinfo := tui.Static_Info{
			network    = client.info.network,
			rpc_port   = client.info.rpc_port,
			dbcache_mb = client.info.dbcache_mb,
			prune_mb   = client.info.prune_mb,
			data_dir   = client.info.data_dir,
		}
		tui.run_with_source(tinfo, fetch, &client)
		return
	}
	title := fmt.ctprintf("btcnode-gui — %s", address)
	gui.run_with_source(title, client.info, fetch, &client)
}

// One JSON-RPC roundtrip: connect, POST getnodestatus, parse into Node_Status.
_fetch_status :: proc(c: ^Client) -> (st: p2p.Node_Status, ok: bool) {
	sock, derr := net.dial_tcp(c.endpoint)
	if derr != nil { return {}, false }
	defer net.close(sock)

	body :: `{"jsonrpc":"1.0","id":"gui","method":"getnodestatus","params":[]}`
	req := fmt.tprintf(
		"POST / HTTP/1.1\r\nHost: btcnode\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		c.auth_b64, len(body), body)

	sent := 0
	req_bytes := transmute([]byte)req
	for sent < len(req_bytes) {
		n, serr := net.send_tcp(sock, req_bytes[sent:])
		if serr != nil { return {}, false }
		sent += n
	}

	// Read until connection close.
	resp := make([dynamic]byte, 0, 8192, context.temp_allocator)
	buf: [8192]byte
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 { append(&resp, ..buf[:n]) }
		if rerr != nil || n == 0 { break }
	}

	// Split HTTP header from body.
	text := string(resp[:])
	sep := strings.index(text, "\r\n\r\n")
	if sep < 0 { return {}, false }
	if !strings.contains(text[:sep], "200") { return {}, false }
	payload := text[sep + 4:]

	parsed, perr := json.parse(transmute([]byte)payload, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil { return {}, false }
	root, root_ok := parsed.(json.Object)
	if !root_ok { return {}, false }
	result, res_ok := root["result"].(json.Object)
	if !res_ok { return {}, false }

	// Static info from the node itself (first response wins).
	if !c.have_info {
		c.info.network = strings.clone(_jstr(result, "network"))
		c.info.data_dir = strings.clone(_jstr(result, "data_dir"))
		c.info.dbcache_mb = int(_jint(result, "dbcache_mb"))
		c.info.prune_mb = int(_jint(result, "prune_mb"))
		c.have_info = true
	}

	st.chain_height = int(_jint(result, "chain_height"))
	st.best_header = int(_jint(result, "best_header"))
	st.sync_state = p2p.Sync_State(_jint(result, "sync_state"))
	st.blocks_remaining = int(_jint(result, "blocks_remaining"))
	st.blocks_in_flight = int(_jint(result, "blocks_in_flight"))
	st.verification_pct = _jfloat(result, "verification_pct")
	st.eta_secs = _jint(result, "eta_secs")
	st.mempool_count = int(_jint(result, "mempool_count"))
	st.mempool_vbytes = int(_jint(result, "mempool_vbytes"))
	st.utxo_cache_count = int(_jint(result, "utxo_cache_count"))
	st.utxo_cache_bytes = int(_jint(result, "utxo_cache_bytes"))
	st.utxo_cache_budget = int(_jint(result, "utxo_cache_budget"))
	st.prof_blocks = int(_jint(result, "prof_blocks"))
	st.prof_ms_per_block = _jfloat(result, "prof_ms_per_block")
	st.prof_read_pct = _jfloat(result, "prof_read_pct")
	st.prof_prefetch_pct = _jfloat(result, "prof_prefetch_pct")
	st.prof_valid_pct = _jfloat(result, "prof_valid_pct")
	st.prof_utxo_pct = _jfloat(result, "prof_utxo_pct")
	st.prof_scripts_pct = _jfloat(result, "prof_scripts_pct")
	st.prof_undo_pct = _jfloat(result, "prof_undo_pct")
	st.uptime_secs = _jint(result, "uptime_secs")
	st.disk_usage = _jint(result, "disk_usage")
	st.total_bytes_sent = _jint(result, "total_bytes_sent")
	st.total_bytes_recv = _jint(result, "total_bytes_recv")
	st.flushing = _jbool(result, "flushing")
	st.flush_total = int(_jint(result, "flush_total"))
	st.flush_progress = int(_jint(result, "flush_progress"))

	if peers, peers_ok := result["peers"].(json.Array); peers_ok {
		for pv, i in peers {
			if i >= p2p.STATUS_MAX_PEERS { break }
			po, po_ok := pv.(json.Object)
			if !po_ok { continue }
			ps := &st.peers[st.peer_count]
			ps.id = p2p.Peer_Id(_jint(po, "id"))
			addr := _jstr(po, "address")
			ps.addr_len = min(len(addr), len(ps.address))
			copy(ps.address[:ps.addr_len], addr[:ps.addr_len])
			agent := _jstr(po, "agent")
			ps.agent_len = min(len(agent), len(ps.user_agent))
			copy(ps.user_agent[:ps.agent_len], agent[:ps.agent_len])
			ps.inbound = _jbool(po, "inbound")
			ps.start_height = i32(_jint(po, "start_height"))
			ps.bytes_sent = _jint(po, "bytes_sent")
			ps.bytes_recv = _jint(po, "bytes_recv")
			ps.blocks_delivered = int(_jint(po, "blocks_delivered"))
			ps.blocks_in_flight = int(_jint(po, "blocks_in_flight"))
			ps.throughput = _jfloat(po, "throughput")
			ps.last_recv_secs = _jint(po, "last_recv_secs")
			st.peer_count += 1
		}
	}

	return st, true
}

_jint :: proc(obj: json.Object, key: string) -> i64 {
	#partial switch v in obj[key] {
	case json.Integer: return i64(v)
	case json.Float:   return i64(v)
	}
	return 0
}

_jfloat :: proc(obj: json.Object, key: string) -> f64 {
	#partial switch v in obj[key] {
	case json.Float:   return f64(v)
	case json.Integer: return f64(v)
	}
	return 0
}

_jstr :: proc(obj: json.Object, key: string) -> string {
	if v, v_ok := obj[key].(json.String); v_ok { return string(v) }
	return ""
}

_jbool :: proc(obj: json.Object, key: string) -> bool {
	if v, v_ok := obj[key].(json.Boolean); v_ok { return bool(v) }
	return false
}
