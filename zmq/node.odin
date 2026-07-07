// Node-facing API: group Core-style --zmqpub<topic>=tcp://... options into
// one Publisher per distinct endpoint and expose typed notify helpers with
// Bitcoin Core's exact payload formats.
package zmq

import "core:sync"

TOPIC_HASHBLOCK :: "hashblock"
TOPIC_HASHTX    :: "hashtx"
TOPIC_RAWBLOCK  :: "rawblock"
TOPIC_RAWTX     :: "rawtx"
TOPIC_SEQUENCE  :: "sequence"

Node :: struct {
	pubs:        [dynamic]^Publisher,
	by_topic:    map[string]^Publisher,
	mempool_seq: u64, // global mempool event counter for the sequence topic
	seq_mutex:   sync.Mutex,
}

// topics/endpoints: parallel slices (topic name, endpoint string).
setup :: proc(topics: []string, endpoints: []string) -> ^Node {
	if len(topics) == 0 {
		return nil
	}
	z := new(Node)
	z.pubs = make([dynamic]^Publisher, 0, len(topics))
	z.by_topic = make(map[string]^Publisher)

	// One publisher per distinct endpoint, carrying all its topics.
	for t, i in topics {
		ep := endpoints[i]
		shared: ^Publisher
		for p, j in z.pubs {
			if endpoints_equal(p, ep) {
				shared = z.pubs[j]
				break
			}
		}
		if shared != nil {
			shared.topics[t] = true
		} else {
			np := publisher_start(ep, []string{t})
			if np != nil {
				append(&z.pubs, np)
			} else {
				continue
			}
			shared = np
		}
		z.by_topic[t] = shared
	}
	if len(z.pubs) == 0 {
		delete(z.pubs)
		delete(z.by_topic)
		free(z)
		return nil
	}
	return z
}

endpoints_equal :: proc(p: ^Publisher, endpoint_str: string) -> bool {
	ep, ok := parse_endpoint(endpoint_str)
	return ok && ep == p.endpoint
}

shutdown :: proc(z: ^Node) {
	if z == nil {
		return
	}
	for p in z.pubs {
		publisher_stop(p)
	}
	delete(z.pubs)
	delete(z.by_topic)
	free(z)
}

// Block connected at the tip. hash = internal byte order (Core parity).
notify_block :: proc(z: ^Node, hash: [32]byte, raw_block: []byte) {
	if z == nil {
		return
	}
	h := hash
	notify(z.by_topic[TOPIC_HASHBLOCK], TOPIC_HASHBLOCK, h[:])
	if len(raw_block) > 0 {
		notify(z.by_topic[TOPIC_RAWBLOCK], TOPIC_RAWBLOCK, raw_block)
	}
	seq_payload: [33]byte
	copy(seq_payload[:32], h[:])
	seq_payload[32] = 'C'
	notify(z.by_topic[TOPIC_SEQUENCE], TOPIC_SEQUENCE, seq_payload[:])
}

notify_block_disconnect :: proc(z: ^Node, hash: [32]byte) {
	if z == nil {
		return
	}
	h := hash
	seq_payload: [33]byte
	copy(seq_payload[:32], h[:])
	seq_payload[32] = 'D'
	notify(z.by_topic[TOPIC_SEQUENCE], TOPIC_SEQUENCE, seq_payload[:])
}

// Transaction accepted to the mempool.
notify_tx :: proc(z: ^Node, txid: [32]byte, raw_tx: []byte) {
	if z == nil {
		return
	}
	t := txid
	notify(z.by_topic[TOPIC_HASHTX], TOPIC_HASHTX, t[:])
	if len(raw_tx) > 0 {
		notify(z.by_topic[TOPIC_RAWTX], TOPIC_RAWTX, raw_tx)
	}
	sync.mutex_lock(&z.seq_mutex)
	z.mempool_seq += 1
	ms := z.mempool_seq
	sync.mutex_unlock(&z.seq_mutex)
	seq_payload: [41]byte
	copy(seq_payload[:32], t[:])
	seq_payload[32] = 'A'
	for i in 0 ..< 8 {
		seq_payload[33 + i] = byte(ms >> (uint(i) * 8))
	}
	notify(z.by_topic[TOPIC_SEQUENCE], TOPIC_SEQUENCE, seq_payload[:])
}
