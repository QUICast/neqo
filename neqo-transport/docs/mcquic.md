# Experimental MCQUIC Transport Support

This crate has an off-by-default `mcquic` feature for experimental
draft-jholland-quic-multicast-08 style QUIC multicast support.

This is a transport extension. It is not WebTransport, not MoQT, not QVF1, and
not a media pipeline. It must not be exposed to ordinary web content by default.

The unicast QUIC connection negotiates multicast capability, carries MCQUIC
control frames, and authenticates multicast channel packets in connection
context. Neqo does not join multicast sockets itself. A future Gecko/Necko
integration should own socket joins, receive UDP multicast packets, and pass
channel packet bytes and metadata into Neqo.

MCQUIC packet numbers are transport telemetry and control state. Application
protocols must not treat them as media identity. A higher layer such as MoQT
needs its own object identity and continuity model.

Current first-slice support includes:

- client and server multicast transport parameter codecs
- multicast control frame codecs
- connection-level control-frame send and receive queues
- sender-direction and negotiation checks for control frames
- ACK range tracking
- NSS-backed multicast packet header protection and AEAD encode/decode
- receive-side primitives for keys, integrity state, protected channel packet
  buffering, integrity validation, and authenticated frame release
- connection-owned channel receive state that applies authenticated STREAM and
  RESET_STREAM frames through Neqo's ordinary QUIC receive-stream machinery
- ordinary stream limits, flow control, final-size handling, reset events,
  out-of-order reassembly, and unicast/multicast overlap checks for channel data
- an `examples/mcquic_hex.rs` helper for comparing wire encodings against other
  QUICast implementations
- a `scripts/mcquic_interop_vectors.sh` helper that diffs those encodings
  against the adjacent local quiche fork
- a `scripts/mcquic_mcrx_fire.sh` helper for live socket interop: quiche
  encodes one protected multicast channel packet, `mctx-core` sends it,
  `mcrx-core` receives it, and Neqo validates and releases the DATAGRAM

Review-facing Neqo API surface:

- configure client capability with
  `ConnectionParameters::mcquic_client_params(Some(...))`
- configure server advertisement with
  `ConnectionParameters::mcquic_server_support(true)`
- inspect negotiated peer transport parameters with
  `Connection::peer_mcquic_server_support()` and
  `Connection::peer_mcquic_client_params()`
- queue and receive unicast MCQUIC control frames with
  `Connection::mcquic_send()`, `Connection::mcquic_readable()`, and
  `Connection::mcquic_recv()`
- validate caller-supplied multicast UDP payloads in connection context with
  `Connection::mcquic_process_channel_packet()`
- queue generated acknowledgements with
  `Connection::mcquic_send_pending_acks()`
- retain the prototype DATAGRAM bridge with
  `Connection::mcquic_pop_channel_datagram()` or the standalone
  `ChannelReceiveState` API

Current intentional limits:

- the send-side channel packet helper always emits four-byte packet numbers,
  while the receive path accepts the packet number length encoded in the short
  header
- the current draft has not assigned a wire code for `MC_EXTENSION_ERROR`, so
  conflicting overlapping stream bytes currently close with QUIC
  `PROTOCOL_VIOLATION`
- the HTTP/3 raw DATAGRAM bridge used by Firefox glue is a bounded internal
  queue for native prototype work, not a long-term web-exposed API
- socket joins, interface selection, channel join/leave policy, rate policy,
  and fallback policy remain caller-owned

Neqo still does not own multicast sockets. The fire-test helper is intentionally
outside the crate dependency graph so Gecko/Necko can remain the future owner of
socket joins and packet delivery.

The fire-test helper uses separate sender and receiver processes so the quiche
sender and Neqo receiver do not link their crypto stacks into one binary. A
local loopback smoke test can be run with:

```sh
neqo-transport/scripts/mcquic_mcrx_fire.sh
```

For real interface testing, set `MCQUIC_SOURCE` and `MCQUIC_INTERFACE` to the
source and local interface addresses that the OS accepts for the SSM join.
On macOS, leaving `MCQUIC_BIND_SOURCE` at its default of `0` avoids a multicast
send `BrokenPipe` seen when the sender socket is also bound to the source
address. Set `MCQUIC_BIND_SOURCE=1` only on platforms or networks that need an
explicit sender bind.
