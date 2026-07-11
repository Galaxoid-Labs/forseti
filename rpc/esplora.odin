package rpc

// Esplora REST server (Phase 1 of the in-node wallet backend). Serves the
// Blockstream Esplora HTTP API subset that BDK's `esplora` backend calls, so a
// BDK wallet syncs directly against forseti — no electrs sidecar. Requires
// --index-addresses (the scripthash index). Runs on its own listener/port
// (default 127.0.0.1:3000), separate from the JSON-RPC server.
//
// Reuses the JSON-RPC server's HTTP helpers (_parse_content_length,
// _parse_connection_close, _write_json_value) and the tx/script/address
// decoders in handlers.odin.
//
// Scripthash convention: Esplora (and esplora-client) key on sha256(scriptPubKey)
// in FORWARD hex — exactly the raw bytes the address index stores. (Electrum's
// reversed convention is a Phase-2 concern.)

import "base:intrinsics"
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
import crypto "../crypto"
import "../mempool"
import "../p2p"
import "../script"
import "../storage"
import "../wire"

// Esplora returns confirmed history 25 txs per page (mempool.space / electrs parity).
ESPLORA_PAGE :: 25
MAX_ESPLORA_CONNECTIONS :: 32

Esplora_Server :: struct {
	listener:   tcp.TCP_Socket,
	chain:      ^chain.Chain_State,
	mp:         ^mempool.Mempool,
	params:     ^consensus.Chain_Params,
	cm:         ^p2p.Conn_Manager,
	running:    bool,
	port:       int,
	bind_addr:  tcp.IP4_Address,
	bind_set:   bool,
	logger:     log.Logger,
	conn_mutex: sync.Mutex,
	conns:      map[tcp.TCP_Socket]bool,
	shared:     ^Esplora_Server,
}

esplora_server_init :: proc(srv: ^Esplora_Server, cs: ^chain.Chain_State, mp: ^mempool.Mempool, params: ^consensus.Chain_Params, cm: ^p2p.Conn_Manager, bind: string, port: int) {
	srv.chain = cs
	srv.mp = mp
	srv.params = params
	srv.cm = cm
	srv.port = port
	srv.running = false
	srv.logger = context.logger
	srv.conns = make(map[tcp.TCP_Socket]bool)
	srv.shared = nil
	if bind != "" {
		if addr, ok := tcp.parse_ip4_address(bind); ok {
			srv.bind_addr = addr
			srv.bind_set = true
		}
	}
}

esplora_server_start :: proc(srv: ^Esplora_Server) -> bool {
	bind := srv.bind_set ? srv.bind_addr : tcp.IP4_Loopback
	socket, err := tcp.listen_tcp(tcp.Endpoint{address = bind, port = srv.port})
	if err != nil {
		log.errorf("Esplora: failed to listen on %v:%d: %v", bind, srv.port, err)
		return false
	}
	srv.listener = socket
	srv.running = true
	if bind != tcp.IP4_Loopback {
		log.warnf("Esplora REST listening on %v:%d (non-loopback — no auth; restrict via firewall)", bind, srv.port)
	} else {
		log.infof("Esplora REST listening on 127.0.0.1:%d", srv.port)
	}
	return true
}

esplora_server_stop :: proc(srv: ^Esplora_Server) {
	target := srv.shared != nil ? srv.shared : srv
	target.running = false
	addr := target.bind_set && target.bind_addr != (tcp.IP4_Address{0, 0, 0, 0}) ? target.bind_addr : tcp.IP4_Loopback
	if dummy, derr := tcp.dial_tcp(tcp.Endpoint{address = addr, port = target.port}); derr == nil {
		tcp.close(dummy)
	}
	tcp.close(target.listener)
}

esplora_server_run :: proc(srv: ^Esplora_Server) {
	for srv.running {
		client, _, accept_err := tcp.accept_tcp(srv.listener)
		if accept_err != nil {
			if !srv.running { break }
			continue
		}
		if !srv.running {
			tcp.close(client)
			break
		}
		sync.mutex_lock(&srv.conn_mutex)
		too_many := len(srv.conns) >= MAX_ESPLORA_CONNECTIONS
		if !too_many { srv.conns[client] = true }
		sync.mutex_unlock(&srv.conn_mutex)
		if too_many {
			tcp.close(client)
			continue
		}
		arg := new(_Esplora_Conn_Arg)
		arg.srv = srv
		arg.client = client
		thread.create_and_start_with_data(rawptr(arg), _esplora_serve_connection, self_cleanup = true)
	}

	// Drain: teardown follows, so a handler mid-LevelDB-read when the DB closes
	// is a use-after-free (same rationale as rpc_server_run).
	sync.mutex_lock(&srv.conn_mutex)
	for s in srv.conns { tcp.close(s) }
	sync.mutex_unlock(&srv.conn_mutex)
	for _ in 0 ..< 500 {
		sync.mutex_lock(&srv.conn_mutex)
		remaining := len(srv.conns)
		sync.mutex_unlock(&srv.conn_mutex)
		if remaining == 0 { break }
		time.sleep(10 * time.Millisecond)
	}
}

_Esplora_Conn_Arg :: struct {
	srv:    ^Esplora_Server,
	client: tcp.TCP_Socket,
}

_esplora_serve_connection :: proc(data: rawptr) {
	arg := cast(^_Esplora_Conn_Arg)data
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
		free_all(context.temp_allocator)
		method, path, body, want_close, ok := _read_http_rest(client)
		if !ok { return }
		status, ctype, resp := _esplora_route(&local, method, path, body)
		if !_esplora_send(client, status, ctype, resp, want_close) { return }
		if want_close { return }
	}
}

// Read one HTTP request: method, path (query stripped), body. Reuses the
// JSON-RPC server's lenient header parsing (CRLF or bare-LF).
_read_http_rest :: proc(socket: tcp.TCP_Socket) -> (method: string, path: string, body: []byte, want_close: bool, ok: bool) {
	buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	recv_buf: [4096]byte

	header_end := -1
	term_len := 0
	for {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return "", "", nil, want_close, false
		}
		append(&buf, ..recv_buf[:n])
		for i in 0 ..< len(buf) - 1 {
			if buf[i] == '\n' && buf[i + 1] == '\n' {
				header_end = i; term_len = 2; break
			}
			if i + 3 < len(buf) && buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
				header_end = i; term_len = 4; break
			}
		}
		if header_end >= 0 { break }
	}

	header_str := string(buf[:header_end])
	want_close = _parse_connection_close(header_str)
	content_length := _parse_content_length(header_str)
	if content_length < 0 { content_length = 0 } // GETs carry no Content-Length

	// Request line: "METHOD /path?query HTTP/1.1"
	nl := strings.index_byte(header_str, '\n')
	if nl < 0 { return "", "", nil, want_close, false }
	req_line := strings.trim_space(header_str[:nl])
	parts := strings.split(req_line, " ", context.temp_allocator)
	if len(parts) < 2 { return "", "", nil, want_close, false }
	method = parts[0]
	raw_path := parts[1]
	if q := strings.index_byte(raw_path, '?'); q >= 0 {
		raw_path = raw_path[:q]
	}
	path = raw_path

	body_start := header_end + term_len
	body_have := len(buf) - body_start
	for body_have < content_length {
		n, err := tcp.recv_tcp(socket, recv_buf[:])
		if err != nil || n == 0 {
			return "", "", nil, want_close, false
		}
		append(&buf, ..recv_buf[:n])
		body_have = len(buf) - body_start
	}
	body = buf[body_start:body_start + content_length]
	return method, path, body, want_close, true
}

_esplora_send :: proc(client: tcp.TCP_Socket, status: int, content_type: string, body: []byte, want_close: bool) -> bool {
	reason := "OK"
	switch status {
	case 400: reason = "Bad Request"
	case 404: reason = "Not Found"
	case 500: reason = "Internal Server Error"
	}
	conn := want_close ? "close" : "keep-alive"
	head := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: %s\r\n\r\n",
		status, reason, content_type, len(body), conn,
	)
	if !_esplora_send_all(client, transmute([]byte)head) { return false }
	if len(body) > 0 && !_esplora_send_all(client, body) { return false }
	return true
}

_esplora_send_all :: proc(client: tcp.TCP_Socket, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := tcp.send_tcp(client, data[sent:])
		if err != nil { return false }
		sent += n
	}
	return true
}

// --- routing ---

_esplora_route :: proc(srv: ^Esplora_Server, method: string, path: string, body: []byte) -> (status: int, content_type: string, resp: []byte) {
	if srv.chain.addr_index == nil {
		return 500, "text/plain", transmute([]byte)string("address index not enabled (start with --index-addresses)")
	}
	intrinsics.atomic_add(&srv.chain.esplora_requests, 1) // liveness counter for the dashboard

	segs := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in strings.split(path, "/", context.temp_allocator) {
		if part != "" { append(&segs, part) }
	}

	if method == "POST" {
		if len(segs) == 1 && segs[0] == "tx" {
			return _esplora_broadcast(srv, body)
		}
		return _not_found()
	}
	if method != "GET" {
		return _not_found()
	}

	switch {
	case len(segs) == 3 && segs[0] == "blocks" && segs[1] == "tip" && segs[2] == "height":
		return _txt(_itoa(chain.chain_height(srv.chain)))
	case len(segs) == 3 && segs[0] == "blocks" && segs[1] == "tip" && segs[2] == "hash":
		h := chain.chain_height(srv.chain)
		if h < 0 { return 404, "text/plain", transmute([]byte)string("no tip") }
		return _txt(_hash_to_hex(srv.chain.active_chain[h]))
	case len(segs) == 1 && segs[0] == "blocks":
		return _esplora_blocks(srv, -1)
	case len(segs) == 2 && segs[0] == "blocks" && segs[1] != "tip":
		if start, ok := strconv.parse_int(segs[1]); ok {
			return _esplora_blocks(srv, start)
		}
		return _not_found()
	case len(segs) == 2 && segs[0] == "block-height":
		return _esplora_block_height(srv, segs[1])
	case len(segs) == 3 && segs[0] == "block" && segs[2] == "header":
		return _esplora_block_header(srv, segs[1])
	case len(segs) == 1 && segs[0] == "fee-estimates":
		return _esplora_fee_estimates(srv)
	case len(segs) >= 2 && segs[0] == "tx":
		return _esplora_tx_route(srv, segs[:])
	case len(segs) >= 2 && segs[0] == "scripthash":
		return _esplora_scripthash_route(srv, segs[:])
	}
	return _not_found()
}

_not_found :: proc() -> (int, string, []byte) {
	return 404, "text/plain", transmute([]byte)string("not found")
}
_txt :: proc(s: string) -> (int, string, []byte) {
	return 200, "text/plain", transmute([]byte)s
}
_json_ok :: proc(s: string) -> (int, string, []byte) {
	return 200, "application/json", transmute([]byte)s
}
_itoa :: proc(v: int) -> string {
	return fmt.tprintf("%d", v)
}

// small json.Value constructors
_ei :: proc(v: i64) -> json.Value    { return json.Value(json.Integer(v)) }
_es :: proc(v: string) -> json.Value { return json.Value(json.String(v)) }
_eb :: proc(v: bool) -> json.Value   { return json.Value(json.Boolean(v)) }
_ef :: proc(v: f64) -> json.Value    { return json.Value(json.Float(v)) }

_json_bytes :: proc(v: json.Value) -> []byte {
	b := strings.builder_make(context.temp_allocator)
	_write_json_value(&b, v)
	return transmute([]byte)strings.to_string(b)
}

// --- block endpoints ---

// GET /blocks[/:start_height] — up to 10 block summaries, newest-first. Used by
// bdk_esplora to seed its checkpoint tip.
_esplora_blocks :: proc(srv: ^Esplora_Server, start_height: int) -> (int, string, []byte) {
	tip := chain.chain_height(srv.chain)
	if tip < 0 { return _json_ok("[]") }
	top := start_height >= 0 ? min(start_height, tip) : tip
	arr := make(json.Array, 0, 10, context.temp_allocator)
	h := top
	for h >= 0 && len(arr) < 10 {
		if h < len(srv.chain.active_chain) {
			if summary, ok := _esplora_block_summary(srv, h); ok {
				append(&arr, summary)
			}
		}
		h -= 1
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

_esplora_block_summary :: proc(srv: ^Esplora_Server, height: int) -> (json.Value, bool) {
	bh := srv.chain.active_chain[height]
	entry, found := srv.chain.block_index.entries[bh]
	if !found { return nil, false }

	merkle: Hash256
	tx_count := int(entry.num_tx)
	size := 0
	weight := 0
	if .Has_Data in entry.status {
		loc := storage.Block_Location{file_num = entry.file_num, data_offset = entry.data_offset, data_size = entry.data_size}
		if block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator); berr == .None {
			merkle = block.header.merkle_root
			tx_count = len(block.txs)
			size = int(entry.data_size)
			w := 0
			for i in 0 ..< len(block.txs) {
				w += consensus.get_tx_weight(&block.txs[i])
			}
			weight = w
		}
	} else if height == 0 {
		merkle = srv.chain.params.genesis_header.merkle_root
		tx_count = 1
	}

	o := make(json.Object, 13, context.temp_allocator)
	o["id"] = _es(_hash_to_hex(bh))
	o["height"] = _ei(i64(height))
	o["version"] = _ei(i64(entry.version))
	o["timestamp"] = _ei(i64(entry.timestamp))
	o["tx_count"] = _ei(i64(tx_count))
	o["size"] = _ei(i64(size))
	o["weight"] = _ei(i64(weight))
	o["merkle_root"] = _es(_hash_to_hex(merkle))
	if height > 0 {
		o["previousblockhash"] = _es(_hash_to_hex(entry.prev_hash))
	}
	o["mediantime"] = _ei(i64(chain.get_median_time_past(entry)))
	o["nonce"] = _ei(i64(entry.nonce))
	o["bits"] = _ei(i64(entry.bits))
	o["difficulty"] = _ef(1.0)
	return json.Value(o), true
}

_esplora_block_height :: proc(srv: ^Esplora_Server, height_str: string) -> (int, string, []byte) {
	h, ok := strconv.parse_int(height_str)
	if !ok || h < 0 || h > chain.chain_height(srv.chain) {
		return 404, "text/plain", transmute([]byte)string("block not found")
	}
	return _txt(_hash_to_hex(srv.chain.active_chain[h]))
}

_esplora_block_header :: proc(srv: ^Esplora_Server, hash_hex: string) -> (int, string, []byte) {
	hash, ok := _hex_to_hash(hash_hex)
	if !ok { return 400, "text/plain", transmute([]byte)string("invalid block hash") }
	entry, found := srv.chain.block_index.entries[hash]
	if !found { return 404, "text/plain", transmute([]byte)string("block not found") }

	merkle: Hash256
	if .Has_Data in entry.status {
		loc := storage.Block_Location{file_num = entry.file_num, data_offset = entry.data_offset, data_size = entry.data_size}
		block, berr := storage.block_db_read(&srv.chain.block_db, loc, context.temp_allocator)
		if berr != .None { return 500, "text/plain", transmute([]byte)string("read failed") }
		merkle = block.header.merkle_root
	} else if entry.height == 0 {
		merkle = srv.chain.params.genesis_header.merkle_root
	} else {
		return 404, "text/plain", transmute([]byte)string("block data not available")
	}
	hdr := wire.Block_Header{
		version = entry.version, prev_hash = entry.prev_hash, merkle_root = merkle,
		timestamp = entry.timestamp, bits = entry.bits, nonce = entry.nonce,
	}
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_block_header(&w, &hdr)
	return _txt(_bytes_to_hex(wire.writer_bytes(&w)))
}

// --- tx endpoints ---

_esplora_tx_route :: proc(srv: ^Esplora_Server, segs: []string) -> (int, string, []byte) {
	txid, ok := _hex_to_hash(segs[1])
	if !ok { return 400, "text/plain", transmute([]byte)string("invalid txid") }

	tx, meta, found := _esplora_resolve_tx(srv, txid)
	if !found { return 404, "text/plain", transmute([]byte)string("Transaction not found") }

	if len(segs) == 2 {
		return _json_ok(string(_json_bytes(_esplora_tx_json(srv, &tx, txid, meta))))
	}
	switch segs[2] {
	case "hex":
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &tx)
		return _txt(_bytes_to_hex(wire.writer_bytes(&w)))
	case "raw":
		w := wire.writer_init(context.temp_allocator)
		wire.serialize_tx(&w, &tx)
		return 200, "application/octet-stream", wire.writer_bytes(&w)
	case "status":
		return _json_ok(string(_json_bytes(_esplora_status_json(srv, meta))))
	}
	return _not_found()
}

// Metadata about where a resolved tx lives.
_Esplora_Tx_Meta :: struct {
	confirmed:  bool,
	height:     int,
	block_hash: Hash256,
	block_time: u32,
	position:   int,
}

_esplora_resolve_tx :: proc(srv: ^Esplora_Server, txid: Hash256) -> (tx: wire.Tx, meta: _Esplora_Tx_Meta, found: bool) {
	if entry, mfound := mempool.mempool_get(srv.mp, txid); mfound {
		return entry.tx, _Esplora_Tx_Meta{confirmed = false}, true
	}
	ctx, block_hash, height, position, cfound := chain.addr_index_lookup_tx(srv.chain, txid)
	if !cfound { return {}, {}, false }
	block_time: u32 = 0
	if e, ok := srv.chain.block_index.entries[block_hash]; ok {
		block_time = e.timestamp
	}
	return ctx, _Esplora_Tx_Meta{
		confirmed = true, height = height, block_hash = block_hash,
		block_time = block_time, position = position,
	}, true
}

_esplora_status_json :: proc(srv: ^Esplora_Server, meta: _Esplora_Tx_Meta) -> json.Value {
	obj := make(json.Object, 4, context.temp_allocator)
	obj["confirmed"] = _eb(meta.confirmed)
	if meta.confirmed {
		obj["block_height"] = _ei(i64(meta.height))
		obj["block_hash"] = _es(_hash_to_hex(meta.block_hash))
		obj["block_time"] = _ei(i64(meta.block_time))
	}
	return json.Value(obj)
}

// Full Esplora Tx JSON (schema BDK's esplora-client deserializes). Values are
// integer satoshis (NOT BTC floats).
_esplora_tx_json :: proc(srv: ^Esplora_Server, tx: ^wire.Tx, txid: Hash256, meta: _Esplora_Tx_Meta) -> json.Value {
	obj := make(json.Object, 12, context.temp_allocator)
	obj["txid"] = _es(_hash_to_hex(txid))
	obj["version"] = _ei(i64(tx.version))
	obj["locktime"] = _ei(i64(tx.locktime))

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, tx)
	obj["size"] = _ei(i64(wire.writer_len(&w)))
	obj["weight"] = _ei(i64(consensus.get_tx_weight(tx)))

	is_cb := consensus.is_coinbase_tx(tx)

	vin := make(json.Array, len(tx.inputs), context.temp_allocator)
	input_sum: i64 = 0
	have_all_prevouts := true
	for i in 0 ..< len(tx.inputs) {
		inp := make(json.Object, 8, context.temp_allocator)
		po := tx.inputs[i].previous_output
		inp["txid"] = _es(_hash_to_hex(po.hash))
		inp["vout"] = _ei(i64(po.index))
		inp["is_coinbase"] = _eb(is_cb)
		inp["sequence"] = _ei(i64(tx.inputs[i].sequence))
		inp["scriptsig"] = _es(_bytes_to_hex(tx.inputs[i].script_sig))
		inp["scriptsig_asm"] = _es(script.script_to_asm(tx.inputs[i].script_sig))
		if len(tx.witness) > i && len(tx.witness[i]) > 0 {
			wit := make(json.Array, len(tx.witness[i]), context.temp_allocator)
			for j in 0 ..< len(tx.witness[i]) {
				wit[j] = _es(_bytes_to_hex(tx.witness[i][j]))
			}
			inp["witness"] = json.Value(wit)
		}
		if !is_cb {
			if spk, value, ok := _esplora_resolve_prevout(srv, po.hash, int(po.index)); ok {
				inp["prevout"] = _esplora_spk_json(srv, spk, value)
				input_sum += value
			} else {
				have_all_prevouts = false
				inp["prevout"] = json.Value(nil)
			}
		} else {
			inp["prevout"] = json.Value(nil)
		}
		vin[i] = json.Value(inp)
	}
	obj["vin"] = json.Value(vin)

	vout := make(json.Array, len(tx.outputs), context.temp_allocator)
	output_sum: i64 = 0
	for i in 0 ..< len(tx.outputs) {
		vout[i] = _esplora_spk_json(srv, tx.outputs[i].script_pubkey, tx.outputs[i].value)
		output_sum += tx.outputs[i].value
	}
	obj["vout"] = json.Value(vout)

	fee: i64 = 0
	if !is_cb && have_all_prevouts {
		fee = input_sum - output_sum
		if fee < 0 { fee = 0 }
	}
	obj["fee"] = _ei(fee)
	obj["status"] = _esplora_status_json(srv, meta)
	return json.Value(obj)
}

// scriptpubkey object: {scriptpubkey, scriptpubkey_asm, scriptpubkey_type,
// scriptpubkey_address?, value}
_esplora_spk_json :: proc(srv: ^Esplora_Server, spk: []byte, value: i64) -> json.Value {
	o := make(json.Object, 6, context.temp_allocator)
	o["value"] = _ei(value)
	o["scriptpubkey"] = _es(_bytes_to_hex(spk))
	o["scriptpubkey_asm"] = _es(script.script_to_asm(spk))
	o["scriptpubkey_type"] = _es(_esplora_script_type(spk))
	if addr, ok := _script_to_address(spk, srv.params); ok {
		o["scriptpubkey_address"] = _es(addr)
	}
	return json.Value(o)
}

// Map forseti's script classification to Esplora's type strings.
_esplora_script_type :: proc(spk: []byte) -> string {
	#partial switch script.classify_script(spk) {
	case .P2PK:            return "p2pk"
	case .P2PKH:           return "p2pkh"
	case .P2SH:            return "p2sh"
	case .P2WPKH:          return "v0_p2wpkh"
	case .P2WSH:           return "v0_p2wsh"
	case .P2TR:            return "v1_p2tr"
	case .Null_Data:       return "op_return"
	case .Witness_Unknown: return "unknown"
	}
	return "unknown"
}

_esplora_resolve_prevout :: proc(srv: ^Esplora_Server, txid: Hash256, vout: int) -> (spk: []byte, value: i64, ok: bool) {
	if entry, mfound := mempool.mempool_get(srv.mp, txid); mfound {
		if vout >= 0 && vout < len(entry.tx.outputs) {
			return entry.tx.outputs[vout].script_pubkey, entry.tx.outputs[vout].value, true
		}
		return nil, 0, false
	}
	tx, _, _, _, cfound := chain.addr_index_lookup_tx(srv.chain, txid)
	if !cfound || vout < 0 || vout >= len(tx.outputs) {
		return nil, 0, false
	}
	return tx.outputs[vout].script_pubkey, tx.outputs[vout].value, true
}

// --- scripthash endpoints ---

_esplora_scripthash_route :: proc(srv: ^Esplora_Server, segs: []string) -> (int, string, []byte) {
	sh, ok := _hex_to_scripthash(segs[1])
	if !ok { return 400, "text/plain", transmute([]byte)string("invalid scripthash") }

	if len(segs) == 3 && segs[2] == "utxo" {
		return _esplora_scripthash_utxo(srv, sh)
	}
	if len(segs) >= 3 && segs[2] == "txs" {
		mode := ""
		last_seen := ""
		if len(segs) >= 4 {
			mode = segs[3] // "mempool" or "chain"
			if len(segs) >= 5 { last_seen = segs[4] }
		}
		return _esplora_scripthash_txs(srv, sh, mode, last_seen)
	}
	return _not_found()
}

_esplora_scripthash_utxo :: proc(srv: ^Esplora_Server, sh: Hash256) -> (int, string, []byte) {
	utxos := storage.addr_index_get_utxos(srv.chain.addr_index, sh, context.temp_allocator)
	arr := make(json.Array, 0, len(utxos), context.temp_allocator)
	tip := chain.chain_height(srv.chain)
	for u in utxos {
		o := make(json.Object, 4, context.temp_allocator)
		o["txid"] = _es(_hash_to_hex(u.txid))
		o["vout"] = _ei(i64(u.vout))
		o["value"] = _ei(u.value)
		st := make(json.Object, 4, context.temp_allocator)
		st["confirmed"] = _eb(true)
		st["block_height"] = _ei(i64(u.height))
		if int(u.height) <= tip && int(u.height) < len(srv.chain.active_chain) {
			bh := srv.chain.active_chain[u.height]
			st["block_hash"] = _es(_hash_to_hex(bh))
			if e, ok := srv.chain.block_index.entries[bh]; ok {
				st["block_time"] = _ei(i64(e.timestamp))
			}
		}
		o["status"] = json.Value(st)
		append(&arr, json.Value(o))
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

_esplora_scripthash_txs :: proc(srv: ^Esplora_Server, sh: Hash256, mode: string, last_seen: string) -> (int, string, []byte) {
	// Confirmed history: unique txids in height order, then newest-first.
	hist := storage.addr_index_get_history(srv.chain.addr_index, sh, context.temp_allocator)
	seen := make(map[Hash256]bool, len(hist), context.temp_allocator)
	confirmed := make([dynamic]Hash256, 0, len(hist), context.temp_allocator)
	for i := len(hist) - 1; i >= 0; i -= 1 { // reverse → newest-first
		if !seen[hist[i].txid] {
			seen[hist[i].txid] = true
			append(&confirmed, hist[i].txid)
		}
	}

	arr := make(json.Array, 0, ESPLORA_PAGE, context.temp_allocator)

	// First page (mode=="") leads with mempool matches; mode=="mempool" is only those.
	if mode == "" || mode == "mempool" {
		for txid in _esplora_mempool_matches(srv, sh) {
			tx, meta, ok := _esplora_resolve_tx(srv, txid)
			if ok { append(&arr, _esplora_tx_json(srv, &tx, txid, meta)) }
		}
		if mode == "mempool" {
			return _json_ok(string(_json_bytes(json.Value(arr))))
		}
	}

	// Confirmed page. mode=="chain" with a last_seen txid paginates from AFTER it.
	start := 0
	if mode == "chain" && last_seen != "" {
		if ls, ok := _hex_to_hash(last_seen); ok {
			for i in 0 ..< len(confirmed) {
				if confirmed[i] == ls { start = i + 1; break }
			}
		}
	}
	added := 0
	for i in start ..< len(confirmed) {
		if added >= ESPLORA_PAGE { break }
		txid := confirmed[i]
		tx, meta, ok := _esplora_resolve_tx(srv, txid)
		if ok {
			append(&arr, _esplora_tx_json(srv, &tx, txid, meta))
			added += 1
		}
	}
	return _json_ok(string(_json_bytes(json.Value(arr))))
}

// Mempool txids that fund or spend `sh` (linear scan — mempool is small).
_esplora_mempool_matches :: proc(srv: ^Esplora_Server, sh: Hash256) -> []Hash256 {
	out := make([dynamic]Hash256, 0, 8, context.temp_allocator)
	for txid, entry in srv.mp.entries {
		hit := false
		for o in entry.tx.outputs {
			if crypto.sha256_hash(o.script_pubkey) == sh { hit = true; break }
		}
		if !hit {
			for in_ in entry.tx.inputs {
				if spk, _, ok := _esplora_resolve_prevout(srv, in_.previous_output.hash, int(in_.previous_output.index)); ok {
					if crypto.sha256_hash(spk) == sh { hit = true; break }
				}
			}
		}
		if hit { append(&out, txid) }
	}
	return out[:]
}

// --- broadcast ---

_esplora_broadcast :: proc(srv: ^Esplora_Server, body: []byte) -> (int, string, []byte) {
	hex_str := strings.trim_space(string(body))
	raw, ok := _hex_decode(hex_str)
	if !ok { return 400, "text/plain", transmute([]byte)string("invalid hex") }
	reader := wire.reader_init(raw)
	tx, werr := wire.deserialize_tx(&reader, context.temp_allocator)
	if werr != nil { return 400, "text/plain", transmute([]byte)string("invalid transaction") }
	if mp_err := mempool.mempool_add(srv.mp, &tx); mp_err != .None {
		msg := fmt.tprintf("sendrawtransaction: %v", mp_err)
		return 400, "text/plain", transmute([]byte)msg
	}
	txid := wire.tx_id(&tx)
	// Relay to peers with wtxid + fee rate for BIP133/339 (same path as sendrawtransaction).
	if srv.cm != nil {
		entry, _ := mempool.mempool_get(srv.mp, txid)
		wtxid := entry.wtxid if entry != nil else txid
		fee_rate_kvb := mempool.fee_rate_per_kvb(entry.fee_rate) if entry != nil else i64(0)
		p2p.conn_manager_relay_tx(srv.cm, txid, wtxid, fee_rate_kvb)
	}
	return _txt(_hash_to_hex(txid))
}

// --- fee estimates ---

_esplora_fee_estimates :: proc(srv: ^Esplora_Server) -> (int, string, []byte) {
	// Esplora: { "<target_blocks>": <sat/vB float>, ... }
	targets := []int{1, 2, 3, 4, 5, 6, 10, 20, 144, 504, 1008}
	floor_sat := max(srv.mp.min_fee, srv.mp.config.min_relay_tx_fee) // sat/kvB
	obj := make(json.Object, len(targets), context.temp_allocator)
	for target in targets {
		rate := floor_sat
		if est, found := mempool.estimator_smart_fee(&srv.mp.estimator, target, false); found {
			rate = max(est, floor_sat)
		}
		obj[_itoa(target)] = _ef(f64(rate) / 1000.0) // sat/kvB → sat/vB
	}
	return _json_ok(string(_json_bytes(json.Value(obj))))
}

// --- helpers ---

// Parse a FORWARD (non-reversed) 32-byte hex scripthash. Esplora keys on
// sha256(script) in natural byte order — unlike txid/blockhash which reverse.
_hex_to_scripthash :: proc(hex_str: string) -> (Hash256, bool) {
	if len(hex_str) != 64 { return {}, false }
	out: Hash256
	for i in 0 ..< 32 {
		hi, hi_ok := _hex_digit(hex_str[i * 2])
		lo, lo_ok := _hex_digit(hex_str[i * 2 + 1])
		if !hi_ok || !lo_ok { return {}, false }
		out[i] = (hi << 4) | lo
	}
	return out, true
}
