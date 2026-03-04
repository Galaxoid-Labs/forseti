package rpc

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
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
	_current_id:  json.Value, // tracks request id for current dispatch
}

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

// Stop the RPC server and close the listener socket.
rpc_server_stop :: proc(srv: ^RPC_Server) {
	srv.running = false
	tcp.close(srv.listener)
}

// Main accept loop: process one connection at a time.
rpc_server_run :: proc(srv: ^RPC_Server) {
	for srv.running {
		// Free temp allocations from previous request.
		free_all(context.temp_allocator)

		client, _, accept_err := tcp.accept_tcp(srv.listener)
		if accept_err != nil {
			if !srv.running {
				break
			}
			continue
		}

		// Read HTTP request body
		body, auth_header, ok := _read_http_request(client)
		if ok {
			// Check authentication if credentials are configured.
			if len(srv.rpc_user) > 0 && !_check_auth(srv, auth_header) {
				_send_http_401(client)
				tcp.close(client)
				continue
			}

			// Parse JSON-RPC request
			req, parse_err := _parse_request(body)
			if parse_err != nil {
				resp := _make_error(parse_err, "Parse error", json.Value(nil))
				resp_bytes := _format_response(resp, context.temp_allocator)
				_send_http_response(client, resp_bytes)
			} else {
				srv._current_id = req.id
				resp := _dispatch(srv, req)
				resp_bytes := _format_response(resp, context.temp_allocator)
				_send_http_response(client, resp_bytes)
			}
		}

		tcp.close(client)
	}
}

// Read an HTTP POST request body. Parses Content-Length and Authorization header.
_read_http_request :: proc(socket: tcp.TCP_Socket) -> (body: []byte, auth_header: string, ok: bool) {
	buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	recv_buf: [4096]byte

	// Read until we have the full header (\r\n\r\n)
	header_end := -1
	for {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return nil, "", false
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
		return nil, "", false
	}

	// Parse Content-Length and Authorization from headers
	header_str := string(buf[:header_end])
	content_length := _parse_content_length(header_str)
	auth_header = _parse_authorization(header_str)
	if content_length < 0 {
		return nil, "", false
	}

	// Body starts after \r\n\r\n
	body_start := header_end + 4
	body_have := len(buf) - body_start

	// Read remaining body bytes if needed
	for body_have < content_length {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return nil, "", false
		}
		append(&buf, ..recv_buf[:n])
		body_have = len(buf) - body_start
	}

	return buf[body_start:body_start + content_length], auth_header, true
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

// Send an HTTP 200 response with JSON body.
_send_http_response :: proc(socket: tcp.TCP_Socket, body: []byte) {
	header := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(body))
	tcp.send_tcp(socket, transmute([]byte)header)
	tcp.send_tcp(socket, body)
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
	}

	return _make_error(.Method_Not_Found, fmt.tprintf("Method not found: %s", req.method), srv._current_id)
}
