package rpc

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import tcp "core:net"

import "../chain"
import "../consensus"
import "../mempool"
import "../p2p"

RPC_Server :: struct {
	listener:     tcp.TCP_Socket,
	chain:        ^chain.Chain_State,
	mp:           ^mempool.Mempool,
	params:       ^consensus.Chain_Params,
	cm:           ^p2p.Conn_Manager,
	running:      bool,
	port:         int,
	start_time:   i64,
	data_dir:     string,
	rpc_user:     string,
	rpc_password: string,
	_current_id:  json.Value, // tracks request id for current dispatch (per-connection copy)
	logger:       log.Logger, // captured at init; connection threads adopt it
	conn_mutex:   sync.Mutex,
	conns:        map[tcp.TCP_Socket]bool, // open client sockets, force-closed on stop
	shared:       ^RPC_Server, // per-connection copies point back at the real server
}

// Loopback-only server, but bound so a misbehaving client can't exhaust fds.
MAX_RPC_CONNECTIONS :: 32

// Initialize the RPC server with references to chain state and mempool.
rpc_server_init :: proc(srv: ^RPC_Server, cs: ^chain.Chain_State, mp: ^mempool.Mempool, params: ^consensus.Chain_Params, port: int, cm: ^p2p.Conn_Manager = nil, data_dir: string = "", rpc_user: string = "", rpc_password: string = "") {
	srv.chain = cs
	srv.mp = mp
	srv.params = params
	srv.port = port
	srv.cm = cm
	srv.data_dir = data_dir
	srv.rpc_user = rpc_user
	srv.rpc_password = rpc_password
	srv.running = false
	srv.start_time = time.to_unix_seconds(time.now())
	srv.logger = context.logger
	srv.conns = make(map[tcp.TCP_Socket]bool)
	srv.shared = nil
}

// Bind the TCP socket and start listening.
rpc_server_start :: proc(srv: ^RPC_Server) -> bool {
	endpoint := tcp.Endpoint {
		address = tcp.IP4_Loopback,
		port    = srv.port,
	}

	socket, err := tcp.listen_tcp(endpoint)
	if err != nil {
		log.errorf("Failed to listen on port %d: %v", srv.port, err)
		return false
	}

	srv.listener = socket
	srv.running = true
	return true
}

// Stop the RPC server and close the listener socket. Callable from a
// per-connection server copy (the `stop` handler) — acts on the real server.
rpc_server_stop :: proc(srv: ^RPC_Server) {
	target := srv.shared != nil ? srv.shared : srv
	target.running = false
	tcp.close(target.listener)
}

// Accept loop: each connection gets its own thread serving keep-alive
// requests until the client disconnects (Bitcoin Core behavior — electrs
// and bitcoin-cli hold persistent connections; a single-threaded loop would
// let one client starve all others, including the GUI's getnodestatus poll).
rpc_server_run :: proc(srv: ^RPC_Server) {
	for srv.running {
		client, _, accept_err := tcp.accept_tcp(srv.listener)
		if accept_err != nil {
			if !srv.running {
				break
			}
			continue
		}

		sync.mutex_lock(&srv.conn_mutex)
		too_many := len(srv.conns) >= MAX_RPC_CONNECTIONS
		if !too_many {
			srv.conns[client] = true
		}
		sync.mutex_unlock(&srv.conn_mutex)
		if too_many {
			tcp.close(client)
			continue
		}

		arg := new(_Conn_Arg)
		arg.srv = srv
		arg.client = client
		thread.create_and_start_with_data(rawptr(arg), _serve_connection, self_cleanup = true)
	}

	// Force-close remaining client sockets so their threads unblock, then
	// DRAIN: node teardown follows right after this returns, and a handler
	// still reading LevelDB when the DB closes is a use-after-free inside
	// leveldb (chainstate corruption risk). Threads deregister themselves;
	// bound the wait so a wedged handler can't hold shutdown hostage.
	sync.mutex_lock(&srv.conn_mutex)
	for s in srv.conns {
		tcp.close(s)
	}
	sync.mutex_unlock(&srv.conn_mutex)
	for _ in 0 ..< 500 {
		sync.mutex_lock(&srv.conn_mutex)
		remaining := len(srv.conns)
		sync.mutex_unlock(&srv.conn_mutex)
		if remaining == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
}

_Conn_Arg :: struct {
	srv:    ^RPC_Server,
	client: tcp.TCP_Socket,
}

// Serve one client connection: keep-alive request loop, one request at a
// time. Runs on its own thread with a shallow per-connection copy of the
// server so _current_id is private (everything else is shared pointers).
_serve_connection :: proc(data: rawptr) {
	arg := cast(^_Conn_Arg)data
	shared := arg.srv
	client := arg.client
	free(arg)

	context.logger = shared.logger
	local := shared^
	local.shared = shared

	defer {
		sync.mutex_lock(&shared.conn_mutex)
		delete_key(&shared.conns, client)
		sync.mutex_unlock(&shared.conn_mutex)
		tcp.close(client)
	}

	for shared.running {
		// Each connection thread has its own default temp allocator; requests
		// (JSON parse + response build) live entirely in it.
		free_all(context.temp_allocator)

		body, auth_header, want_close, ok := _read_http_request(client)
		if !ok {
			return // client closed (normal keep-alive end) or read error
		}
		if len(shared.rpc_user) > 0 && !_check_auth(&local, auth_header) {
			_send_http_401(client)
			return
		}
		resp_bytes := _handle_body(&local, body)
		if !_send_http_response(client, resp_bytes, want_close) {
			return
		}
		if want_close {
			return // client asked for Connection: close — honor it
		}
	}
}

// Parse and dispatch one HTTP body: either a single JSON-RPC request or a
// batch (JSON array of requests → JSON array of responses, same order), as
// sent by bitcoincore-rpc batch clients like electrs.
_handle_body :: proc(srv: ^RPC_Server, body: []byte) -> []byte {
	parsed, parse_err := json.parse(body, parse_integers = true, allocator = context.temp_allocator)
	if parse_err != nil {
		resp := _make_error(.Parse_Error, "Parse error", json.Value(nil))
		return _format_response(resp, context.temp_allocator)
	}

	if arr, is_batch := parsed.(json.Array); is_batch {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for elem, i in arr {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			resp: RPC_Response
			req, req_err := _request_from_value(elem)
			if req_err != nil {
				resp = _make_error(req_err, "Invalid request", json.Value(nil))
			} else {
				srv._current_id = req.id
				resp = _dispatch(srv, req)
			}
			strings.write_bytes(&b, _format_response(resp, context.temp_allocator))
		}
		strings.write_byte(&b, ']')
		return transmute([]byte)strings.to_string(b)
	}

	req, req_err := _request_from_value(parsed)
	if req_err != nil {
		resp := _make_error(req_err, "Invalid request", json.Value(nil))
		return _format_response(resp, context.temp_allocator)
	}
	srv._current_id = req.id
	resp := _dispatch(srv, req)
	return _format_response(resp, context.temp_allocator)
}

// Read an HTTP POST request body. Parses Content-Length and Authorization header.
_read_http_request :: proc(socket: tcp.TCP_Socket) -> (body: []byte, auth_header: string, want_close: bool, ok: bool) {
	buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	recv_buf: [4096]byte

	// Read until we have the full header (\r\n\r\n)
	header_end := -1
	for {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return nil, "", want_close, false
		}
		append(&buf, ..recv_buf[:n])

		// Search for header terminator
		if len(buf) >= 4 {
			for i in 0 ..< len(buf) - 3 {
				if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
					header_end = i
					break
				}
			}
		}
		if header_end >= 0 {
			break
		}
	}

	if header_end < 0 {
		return nil, "", want_close, false
	}

	// Parse Content-Length and Authorization from headers
	header_str := string(buf[:header_end])
	content_length := _parse_content_length(header_str)
	auth_header = _parse_authorization(header_str)
	want_close = _parse_connection_close(header_str)
	if content_length < 0 {
		return nil, "", want_close, false
	}

	// Body starts after \r\n\r\n
	body_start := header_end + 4
	body_have := len(buf) - body_start

	// Read remaining body bytes if needed
	for body_have < content_length {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return nil, "", want_close, false
		}
		append(&buf, ..recv_buf[:n])
		body_have = len(buf) - body_start
	}

	return buf[body_start:body_start + content_length], auth_header, want_close, true
}

// Did the client request Connection: close? (until-EOF readers and one-shot
// clients depend on it being honored — a keep-alive-only server hangs them.)
_parse_connection_close :: proc(headers: string) -> bool {
	lines := strings.split(headers, "\r\n", context.temp_allocator)
	for line in lines {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "connection:") {
			return strings.contains(lower, "close")
		}
	}
	return false
}

// Extract Content-Length value from HTTP headers.
_parse_content_length :: proc(headers: string) -> int {
	lines := strings.split(headers, "\r\n", context.temp_allocator)
	for line in lines {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "content-length:") {
			val_str := strings.trim_space(line[len("content-length:"):])
			val, ok := strconv.parse_int(val_str)
			if ok {
				return val
			}
		}
	}
	return -1
}

// Extract Authorization header value from HTTP headers.
_parse_authorization :: proc(headers: string) -> string {
	lines := strings.split(headers, "\r\n", context.temp_allocator)
	for line in lines {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "authorization:") {
			return strings.trim_space(line[len("authorization:"):])
		}
	}
	return ""
}

// Validate HTTP Basic Auth against server credentials.
_check_auth :: proc(srv: ^RPC_Server, auth_header: string) -> bool {
	if !strings.has_prefix(auth_header, "Basic ") {
		return false
	}
	encoded := auth_header[len("Basic "):]

	decoded_bytes, decode_err := base64.decode(encoded, allocator = context.temp_allocator)
	if decode_err != nil {
		return false
	}
	decoded := string(decoded_bytes)

	// Split on first ':' — password may contain colons.
	colon_idx := strings.index_byte(decoded, ':')
	if colon_idx < 0 {
		return false
	}

	user := decoded[:colon_idx]
	pass := decoded[colon_idx + 1:]

	return user == srv.rpc_user && pass == srv.rpc_password
}

// Send an HTTP 401 Unauthorized response.
_send_http_401 :: proc(socket: tcp.TCP_Socket) {
	body := `{"result":null,"error":{"code":-32600,"message":"Unauthorized"},"id":null}`
	header := fmt.tprintf(
		"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"jsonrpc\"\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		len(body))
	tcp.send_tcp(socket, transmute([]byte)header)
	tcp.send_tcp(socket, transmute([]byte)body)
}

// Send an HTTP 200 response with JSON body. Connection stays open
// (keep-alive) — the per-connection loop serves the next request.
_send_http_response :: proc(socket: tcp.TCP_Socket, body: []byte, want_close := false) -> bool {
	conn := want_close ? "close" : "keep-alive"
	header := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n", len(body), conn)
	if _, err := tcp.send_tcp(socket, transmute([]byte)header); err != nil {
		return false
	}
	if _, err := tcp.send_tcp(socket, body); err != nil {
		return false
	}
	return true
}

// Route a request to the appropriate handler.
_dispatch :: proc(srv: ^RPC_Server, req: RPC_Request) -> RPC_Response {
	switch req.method {
	case "getblockchaininfo":
		return _handle_getblockchaininfo(srv, req.params)
	case "getblockcount":
		return _handle_getblockcount(srv, req.params)
	case "getblockhash":
		return _handle_getblockhash(srv, req.params)
	case "getbestblockhash":
		return _handle_getbestblockhash(srv, req.params)
	case "getblock":
		return _handle_getblock(srv, req.params)
	case "getrawtransaction":
		return _handle_getrawtransaction(srv, req.params)
	case "sendrawtransaction":
		return _handle_sendrawtransaction(srv, req.params)
	case "getmempoolinfo":
		return _handle_getmempoolinfo(srv, req.params)
	case "estimatesmartfee":
		return _handle_estimatesmartfee(srv, req.params)
	case "createmultisig":
		return _handle_createmultisig(srv, req.params)
	case "getindexinfo":
		return _handle_getindexinfo(srv, req.params)
	case "pruneblockchain":
		return _handle_pruneblockchain(srv, req.params)
	case "preciousblock":
		return _handle_preciousblock(srv, req.params)
	case "addnode":
		return _handle_addnode(srv, req.params)
	case "getaddednodeinfo":
		return _handle_getaddednodeinfo(srv, req.params)
	case "disconnectnode":
		return _handle_disconnectnode(srv, req.params)
	case "setban":
		return _handle_setban(srv, req.params)
	case "listbanned":
		return _handle_listbanned(srv, req.params)
	case "clearbanned":
		return _handle_clearbanned(srv, req.params)
	case "setnetworkactive":
		return _handle_setnetworkactive(srv, req.params)
	case "getnodeaddresses":
		return _handle_getnodeaddresses(srv, req.params)
	case "generatetoaddress":
		return _handle_generatetoaddress(srv, req.params)
	case "getrawmempool":
		return _handle_getrawmempool(srv, req.params)
	case "gettxout":
		return _handle_gettxout(srv, req.params)
	case "getblockheader":
		return _handle_getblockheader(srv, req.params)
	case "getdifficulty":
		return _handle_getdifficulty(srv, req.params)
	case "getconnectioncount":
		return _handle_getconnectioncount(srv, req.params)
	case "getpeerinfo":
		return _handle_getpeerinfo(srv, req.params)
	case "getnetworkinfo":
		return _handle_getnetworkinfo(srv, req.params)
	case "stop":
		return _handle_stop(srv, req.params)
	case "uptime":
		return _handle_uptime(srv, req.params)
	case "decoderawtransaction":
		return _handle_decoderawtransaction(srv, req.params)
	case "decodescript":
		return _handle_decodescript(srv, req.params)
	case "getmempoolancestors":
		return _handle_getmempoolancestors(srv, req.params)
	case "getmempooldescendants":
		return _handle_getmempooldescendants(srv, req.params)
	case "getmempoolentry":
		return _handle_getmempoolentry(srv, req.params)
	case "testmempoolaccept":
		return _handle_testmempoolaccept(srv, req.params)
	case "getchaintips":
		return _handle_getchaintips(srv, req.params)
	case "getchaintxstats":
		return _handle_getchaintxstats(srv, req.params)
	case "getblockstats":
		return _handle_getblockstats(srv, req.params)
	case "help":
		return _handle_help(srv, req.params)
	case "getmininginfo":
		return _handle_getmininginfo(srv, req.params)
	case "getnodestatus":
		return _handle_getnodestatus(srv, req.params)
	case "listsidechains":
		return _handle_listsidechains(srv, req.params)
	case "getsidechaininfo":
		return _handle_getsidechaininfo(srv, req.params)
	case "listwithdrawalstatus":
		return _handle_listwithdrawalstatus(srv, req.params)
	case "getnetworkhashps":
		return _handle_getnetworkhashps(srv, req.params)
	case "getnettotals":
		return _handle_getnettotals(srv, req.params)
	case "validateaddress":
		return _handle_validateaddress(srv, req.params)
	case "savemempool":
		return _handle_savemempool(srv, req.params)
	case "ping":
		return _handle_ping(srv, req.params)
	case "getmemoryinfo":
		return _handle_getmemoryinfo(srv, req.params)
	case "getrpcinfo":
		return _handle_getrpcinfo(srv, req.params)
	case "logging":
		return _handle_logging(srv, req.params)
	case "createrawtransaction":
		return _handle_createrawtransaction(srv, req.params)
	case "combinerawtransaction":
		return _handle_combinerawtransaction(srv, req.params)
	case "signrawtransactionwithkey":
		return _handle_signrawtransactionwithkey(srv, req.params)
	case "gettxoutsetinfo":
		return _handle_gettxoutsetinfo(srv, req.params)
	case "gettxoutproof":
		return _handle_gettxoutproof(srv, req.params)
	case "verifytxoutproof":
		return _handle_verifytxoutproof(srv, req.params)
	case "getblockfilter":
		return _handle_getblockfilter(srv, req.params)
	case "signmessagewithprivkey":
		return _handle_signmessagewithprivkey(srv, req.params)
	case "verifymessage":
		return _handle_verifymessage(srv, req.params)
	}

	return _make_error(.Method_Not_Found, fmt.tprintf("Method not found: %s", req.method), srv._current_id)
}
