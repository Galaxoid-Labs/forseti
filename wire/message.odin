package wire

import "../crypto"

// P2P message header: 24 bytes
// [magic:4][command:12][payload_size:4][checksum:4]
Message_Header :: struct {
	magic:        u32,
	command:      [COMMAND_SIZE]byte,
	payload_size: u32,
	checksum:     [4]byte,
}

// Known command strings.
CMD_VERSION     :: "version"
CMD_VERACK      :: "verack"
CMD_PING        :: "ping"
CMD_PONG        :: "pong"
CMD_INV         :: "inv"
CMD_GETDATA     :: "getdata"
CMD_GETBLOCKS   :: "getblocks"
CMD_GETHEADERS  :: "getheaders"
CMD_HEADERS     :: "headers"
CMD_BLOCK       :: "block"
CMD_TX          :: "tx"
CMD_ADDR        :: "addr"
CMD_GETADDR     :: "getaddr"
CMD_SENDHEADERS :: "sendheaders"
CMD_SENDCMPCT   :: "sendcmpct"
CMD_CMPCTBLOCK  :: "cmpctblock"
CMD_GETBLOCKTXN :: "getblocktxn"
CMD_BLOCKTXN    :: "blocktxn"
CMD_FEEFILTER   :: "feefilter"
CMD_REJECT      :: "reject"
CMD_WTXIDRELAY  :: "wtxidrelay"
CMD_ADDRV2      :: "addrv2"
CMD_UNKNOWN     :: "unknown"

// Computes the 4-byte checksum (first 4 bytes of SHA256d of payload).
compute_checksum :: proc(payload: []byte) -> [4]byte {
	hash := crypto.sha256d(payload)
	result: [4]byte
	copy(result[:], hash[:4])
	return result
}

// Converts a command string to the 12-byte null-padded wire format.
command_to_bytes :: proc(cmd: string) -> [COMMAND_SIZE]byte {
	result: [COMMAND_SIZE]byte
	n := min(len(cmd), COMMAND_SIZE)
	for i in 0 ..< n {
		result[i] = cmd[i]
	}
	return result
}

// Extracts the command name from a 12-byte field (strips null padding).
// Returns one of the known CMD_ constants when possible, otherwise allocates via temp_allocator.
command_from_bytes :: proc(cmd: [COMMAND_SIZE]byte) -> string {
	n := 0
	for i in 0 ..< COMMAND_SIZE {
		if cmd[i] == 0 {
			break
		}
		n = i + 1
	}

	// Match against known commands to return static strings.
	cmd := cmd
	s := string(cmd[:n])
	switch s {
	case CMD_VERSION:     return CMD_VERSION
	case CMD_VERACK:      return CMD_VERACK
	case CMD_PING:        return CMD_PING
	case CMD_PONG:        return CMD_PONG
	case CMD_INV:         return CMD_INV
	case CMD_GETDATA:     return CMD_GETDATA
	case CMD_GETBLOCKS:   return CMD_GETBLOCKS
	case CMD_GETHEADERS:  return CMD_GETHEADERS
	case CMD_HEADERS:     return CMD_HEADERS
	case CMD_BLOCK:       return CMD_BLOCK
	case CMD_TX:          return CMD_TX
	case CMD_ADDR:        return CMD_ADDR
	case CMD_GETADDR:     return CMD_GETADDR
	case CMD_SENDHEADERS: return CMD_SENDHEADERS
	case CMD_SENDCMPCT:   return CMD_SENDCMPCT
	case CMD_CMPCTBLOCK:  return CMD_CMPCTBLOCK
	case CMD_GETBLOCKTXN: return CMD_GETBLOCKTXN
	case CMD_BLOCKTXN:    return CMD_BLOCKTXN
	case CMD_FEEFILTER:   return CMD_FEEFILTER
	case CMD_REJECT:      return CMD_REJECT
	case CMD_WTXIDRELAY:  return CMD_WTXIDRELAY
	case CMD_ADDRV2:      return CMD_ADDRV2
	}

	// Unknown command — return static string (must not use temp_allocator;
	// reader thread's temp allocator is freed on disconnect, but messages
	// referencing this string may still be in the channel).
	return CMD_UNKNOWN
}

// Serializes a message header.
serialize_message_header :: proc(w: ^Wire_Writer, hdr: ^Message_Header) {
	write_u32le(w, hdr.magic)
	write_bytes(w, hdr.command[:])
	write_u32le(w, hdr.payload_size)
	write_bytes(w, hdr.checksum[:])
}

// Deserializes a message header.
deserialize_message_header :: proc(r: ^Wire_Reader) -> (hdr: Message_Header, err: Wire_Error) {
	hdr.magic = read_u32le(r) or_return

	cmd_bytes := read_bytes_no_copy(r, COMMAND_SIZE) or_return
	copy(hdr.command[:], cmd_bytes)

	hdr.payload_size = read_u32le(r) or_return

	checksum_bytes := read_bytes_no_copy(r, 4) or_return
	copy(hdr.checksum[:], checksum_bytes)

	return hdr, nil
}

// Creates a complete message (header + payload) ready to send on the wire.
build_message :: proc(magic: u32, command: string, payload: []byte, allocator := context.allocator) -> []byte {
	w := writer_init(allocator)

	hdr := Message_Header {
		magic        = magic,
		command      = command_to_bytes(command),
		payload_size = u32(len(payload)),
		checksum     = compute_checksum(payload),
	}

	serialize_message_header(&w, &hdr)
	write_bytes(&w, payload)

	// Transfer ownership of the buffer.
	result := make([]byte, len(w.buf), allocator)
	copy(result, w.buf[:])
	delete(w.buf)
	return result
}

// Validates a message header checksum against its payload.
validate_checksum :: proc(hdr: ^Message_Header, payload: []byte) -> bool {
	expected := compute_checksum(payload)
	return hdr.checksum == expected
}
