#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
neqo_root="$(cd -- "${script_dir}/../.." && pwd)"
quiche_root="${QUICHE_ROOT:-/Users/mfranke/Devtools/Multicast/quiche}"
quiche_crate="${QUICHE_CRATE:-${quiche_root}/quiche}"

if [[ ! -f "${quiche_crate}/Cargo.toml" ]]; then
    echo "quiche crate not found at ${quiche_crate}" >&2
    echo "set QUICHE_ROOT or QUICHE_CRATE to the local quiche fork" >&2
    exit 1
fi

if [[ -d "${neqo_root}/.venv-gyp/bin" ]]; then
    export PATH="${neqo_root}/.venv-gyp/bin:${PATH}"
elif [[ -d /private/tmp/neqo-gyp-venv/bin ]]; then
    export PATH="/private/tmp/neqo-gyp-venv/bin:${PATH}"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/neqo-mcquic-interop.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/src"
cat >"${tmp}/Cargo.toml" <<CARGO
[package]
name = "mcquic-quiche-vectors"
version = "0.1.0"
edition = "2021"

[dependencies]
quiche = { path = "${quiche_crate}" }
CARGO

cat >"${tmp}/src/main.rs" <<'RUST'
use std::net::{IpAddr, Ipv4Addr};

use quiche::multicast::{
    Ack, Announce, ChannelFrame, ChannelSendState, ChannelState, ClientLimits,
    ClientTransportParams, Frame, Integrity, Join, Key, State, StateReasonScope,
    STATE_REASON_REQUESTED_BY_SERVER,
};

fn main() {
    let channel_id = b"demo-channel".to_vec();
    let params = ClientTransportParams {
        limits: ClientLimits {
            ipv4_channels_allowed: true,
            ipv6_channels_allowed: false,
            max_aggregate_rate_kibps: 100_000,
            max_channel_ids: 32,
        },
        hash_algorithms: vec![1],
        encryption_algorithms: vec![0x1301],
    };

    let announce_payload = Announce {
        channel_id: channel_id.clone(),
        source: IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
        group: IpAddr::V4(Ipv4Addr::new(233, 252, 0, 1)),
        udp_port: 4433,
        header_protection_algorithm: 0x1301,
        header_secret: vec![0x11; 32],
        aead_algorithm: 0x1301,
        integrity_hash_algorithm: 1,
        max_rate_kibps: 10_000,
        max_ack_delay_ms: 25,
    };
    let key_payload = Key {
        channel_id: channel_id.clone(),
        key_sequence: 1,
        from_packet_number: 0,
        secret: vec![0x22; 32],
    };
    let announce = Frame::Announce(announce_payload.clone());
    let key = Frame::Key(key_payload.clone());
    let integrity = Frame::Integrity(Integrity {
        channel_id: channel_id.clone(),
        packet_number_start: 0,
        packet_hash_count: Some(1),
        packet_hashes: vec![0x33; 32],
    });
    let join = Frame::Join(Join {
        channel_id: channel_id.clone(),
        mc_limits_sequence: 1,
        mc_state_sequence: 0,
        mc_key_sequence: 1,
    });
    let state = Frame::State(State {
        channel_id: channel_id.clone(),
        sequence: 1,
        state: ChannelState::Joined,
        reason_scope: StateReasonScope::Transport,
        reason_code: STATE_REASON_REQUESTED_BY_SERVER,
        reason_phrase: b"joined".to_vec(),
    });
    let ack = Frame::Ack(Ack {
        channel_id,
        largest_acknowledged: 10,
        ack_delay: 0,
        first_ack_range: 0,
        ack_ranges: vec![],
        ecn_counts: None,
    });

    println!("client_transport_params={}", hex(&encode_params(&params)));
    for (name, frame) in [
        ("mc_announce", announce),
        ("mc_key", key),
        ("mc_integrity", integrity),
        ("mc_join", join),
        ("mc_state", state),
        ("mc_ack", ack),
    ] {
        println!("{name}={}", hex(&encode_frame(&frame)));
    }

    let mut sender =
        ChannelSendState::new(announce_payload, key_payload).expect("channel send state");
    let mut out = vec![0; 1200];
    let sent = sender
        .write_packet(
            &[ChannelFrame::Datagram {
                data: b"payload".to_vec(),
            }],
            &mut out,
        )
        .expect("channel packet");
    println!("mc_channel_packet={}", hex(&out[..sent.packet_len]));
    println!(
        "mc_channel_integrity={}",
        hex(&encode_frame(&Frame::Integrity(sent.integrity)))
    );
}

fn encode_params(params: &ClientTransportParams) -> Vec<u8> {
    let mut out = vec![0; params.wire_len()];
    let written = params.to_bytes(&mut out).expect("encode params");
    out.truncate(written);
    out
}

fn encode_frame(frame: &Frame) -> Vec<u8> {
    let mut out = vec![0; 4096];
    let written = frame.to_bytes(&mut out).expect("encode frame");
    out.truncate(written);
    out
}

fn hex(data: &[u8]) -> String {
    const CHARS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(data.len() * 2);
    for byte in data {
        out.push(char::from(CHARS[usize::from(byte >> 4)]));
        out.push(char::from(CHARS[usize::from(byte & 0x0f)]));
    }
    out
}
RUST

(
    cd "${tmp}"
    cargo generate-lockfile --quiet
    cargo run --locked --quiet >quiche.hex
)

(
    cd "${neqo_root}"
    cargo run --locked --quiet -p neqo-transport --features mcquic \
        --example mcquic_hex --no-default-features >"${tmp}/neqo.hex"
)

diff -u "${tmp}/quiche.hex" "${tmp}/neqo.hex"
cat "${tmp}/neqo.hex"
echo "MCQUIC vector interop: quiche and Neqo match."
