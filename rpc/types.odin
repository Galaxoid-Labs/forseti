package rpc

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../crypto"
import "../wire"

Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

RPC_Error_Code :: enum i32 {
	Parse_Error      = -32700,
	Invalid_Request  = -32600,
	Method_Not_Found = -32601,
	Invalid_Params   = -32602,
	Internal_Error   = -32603,
	// Bitcoin-specific
	Misc_Error       = -1,
	Block_Not_Found  = -5,
	Tx_Deser_Error   = -22,
	Verify_Error     = -25,
	Mempool_Error    = -26,
}

RPC_Request :: struct {
	method: string,
	params: json.Value,
	id:     json.Value,
}

RPC_Response :: struct {
	result: json.Value,
	error:  Maybe(RPC_Error),
	id:     json.Value,
}

RPC_Error :: struct {
	code:    RPC_Error_Code,
	message: string,
}

// Parse a JSON-RPC request body into an RPC_Request.
_parse_request :: proc(body: []byte) -> (req: RPC_Request, err: RPC_Error_Code) {
	parsed, parse_err := json.parse(body, parse_integers = true)
	if parse_err != nil {
		return {}, .Parse_Error
	}

	obj, ok := parsed.(json.Object)
	if !ok {
		json.destroy_value(parsed)
		return {}, .Invalid_Request
	}

	method_val, has_method := obj["method"]
	if !has_method {
		json.destroy_value(parsed)
		return {}, .Invalid_Request
	}
	method_str, is_str := method_val.(json.String)
	if !is_str {
		json.destroy_value(parsed)
		return {}, .Invalid_Request
	}

	req.method = method_str
	req.params = obj["params"] if "params" in obj else json.Value(nil)
	req.id = obj["id"] if "id" in obj else json.Value(nil)

	return req, nil
}

// Format an RPC_Response as a JSON string.
_format_response :: proc(resp: RPC_Response, allocator := context.allocator) -> []byte {
	b := strings.builder_make(0, 256, allocator)

	strings.write_string(&b, `{"result":`)

	// Write result
	err_val, has_err := resp.error.?
	if has_err {
		strings.write_string(&b, "null")
	} else {
		_write_json_value(&b, resp.result)
	}

	strings.write_string(&b, `,"error":`)
	if has_err {
		strings.write_byte(&b, '{')
		strings.write_string(&b, fmt.tprintf(`"code":%d,"message":"%s"`, i32(err_val.code), _json_escape(err_val.message)))
		strings.write_byte(&b, '}')
	} else {
		strings.write_string(&b, "null")
	}

	strings.write_string(&b, `,"id":`)
	_write_json_value(&b, resp.id)
	strings.write_string(&b, "}")

	return transmute([]byte)strings.to_string(b)
}

// Write a json.Value to a string builder.
_write_json_value :: proc(b: ^strings.Builder, val: json.Value) {
	switch v in val {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, "true" if v else "false")
	case json.Integer:
		strings.write_string(b, fmt.tprintf("%d", v))
	case json.Float:
		strings.write_string(b, fmt.tprintf("%.8f", v))
	case json.String:
		strings.write_string(b, fmt.tprintf(`"%s"`, _json_escape(v)))
	case json.Array:
		strings.write_byte(b, '[')
		for i in 0 ..< len(v) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			_write_json_value(b, v[i])
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		first := true
		for key, value in v {
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			strings.write_string(b, fmt.tprintf(`"%s":`, _json_escape(key)))
			_write_json_value(b, value)
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

// Escape special characters for JSON strings.
_json_escape :: proc(s: string) -> string {
	// Fast path: no escaping needed for most strings
	needs_escape := false
	for c in s {
		if c == '"' || c == '\\' || c == '\n' || c == '\r' || c == '\t' {
			needs_escape = true
			break
		}
	}
	if !needs_escape {
		return s
	}

	b := strings.builder_make(0, len(s) + 8, context.temp_allocator)
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\r':
			strings.write_string(&b, `\r`)
		case '\t':
			strings.write_string(&b, `\t`)
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

// Reverse a hash (internal LE -> display BE) and hex-encode.
_hash_to_hex :: proc(hash: Hash256) -> string {
	reversed: [32]byte
	for i in 0 ..< 32 {
		reversed[i] = hash[31 - i]
	}
	return fmt.tprintf("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
		reversed[0], reversed[1], reversed[2], reversed[3],
		reversed[4], reversed[5], reversed[6], reversed[7],
		reversed[8], reversed[9], reversed[10], reversed[11],
		reversed[12], reversed[13], reversed[14], reversed[15],
		reversed[16], reversed[17], reversed[18], reversed[19],
		reversed[20], reversed[21], reversed[22], reversed[23],
		reversed[24], reversed[25], reversed[26], reversed[27],
		reversed[28], reversed[29], reversed[30], reversed[31])
}

// Decode a hex string and reverse bytes to internal hash format.
_hex_to_hash :: proc(hex_str: string) -> (Hash256, bool) {
	if len(hex_str) != 64 {
		return {}, false
	}

	// Decode hex to bytes
	decoded: [32]byte
	for i in 0 ..< 32 {
		hi, hi_ok := _hex_digit(hex_str[i * 2])
		if !hi_ok { return {}, false }
		lo, lo_ok := _hex_digit(hex_str[i * 2 + 1])
		if !lo_ok { return {}, false }
		decoded[i] = (hi << 4) | lo
	}

	// Reverse for internal byte order
	hash: Hash256
	for i in 0 ..< 32 {
		hash[i] = decoded[31 - i]
	}
	return hash, true
}

_hex_digit :: proc(c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// Hex-encode a byte slice (no reversal).
_bytes_to_hex :: proc(data: []byte) -> string {
	if len(data) == 0 {
		return ""
	}
	hex_chars := [16]byte{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}
	buf := make([]byte, len(data) * 2, context.temp_allocator)
	for i in 0 ..< len(data) {
		buf[i * 2] = hex_chars[data[i] >> 4]
		buf[i * 2 + 1] = hex_chars[data[i] & 0x0f]
	}
	return string(buf)
}

// Decode hex string to bytes.
_hex_decode :: proc(hex_str: string) -> ([]byte, bool) {
	if len(hex_str) % 2 != 0 {
		return nil, false
	}
	result := make([]byte, len(hex_str) / 2, context.temp_allocator)
	for i in 0 ..< len(result) {
		hi, hi_ok := _hex_digit(hex_str[i * 2])
		if !hi_ok { return nil, false }
		lo, lo_ok := _hex_digit(hex_str[i * 2 + 1])
		if !lo_ok { return nil, false }
		result[i] = (hi << 4) | lo
	}
	return result, true
}

// Make an error response.
_make_error :: proc(code: RPC_Error_Code, message: string, id: json.Value) -> RPC_Response {
	return RPC_Response {
		error = RPC_Error{code = code, message = message},
		id    = id,
	}
}

// Make a success response.
_make_result :: proc(result: json.Value, id: json.Value) -> RPC_Response {
	return RPC_Response {
		result = result,
		id     = id,
	}
}

// Get a parameter from a JSON array at a given index.
_get_param :: proc(params: json.Value, idx: int) -> (json.Value, bool) {
	arr, ok := params.(json.Array)
	if !ok || idx >= len(arr) {
		return nil, false
	}
	return arr[idx], true
}

// Get an integer parameter.
_get_int_param :: proc(params: json.Value, idx: int) -> (int, bool) {
	val, ok := _get_param(params, idx)
	if !ok {
		return 0, false
	}
	#partial switch v in val {
	case json.Integer:
		return int(v), true
	case json.Float:
		return int(v), true
	}
	return 0, false
}

// Get a string parameter.
_get_string_param :: proc(params: json.Value, idx: int) -> (string, bool) {
	val, ok := _get_param(params, idx)
	if !ok {
		return "", false
	}
	s, is_str := val.(json.String)
	return s, is_str
}

// Get a bool parameter with default value.
_get_bool_param :: proc(params: json.Value, idx: int, default_val: bool) -> bool {
	val, ok := _get_param(params, idx)
	if !ok {
		return default_val
	}
	b, is_bool := val.(json.Boolean)
	if !is_bool {
		// Also accept integers (0=false, 1=true)
		i, is_int := val.(json.Integer)
		if is_int {
			return i != 0
		}
		return default_val
	}
	return b
}
