// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

#[cfg(feature = "mcquic")]
fn main() {
    use std::net::{IpAddr, Ipv4Addr};

    use neqo_transport::mcquic::{
        Ack, Announce, ChannelFrame, ChannelSendState, ChannelState, ClientLimits,
        ClientTransportParams, Frame, Integrity, Join, Key, STATE_REASON_REQUESTED_BY_SERVER,
        State, StateReasonScope,
    };

    nss::init().expect("initialize NSS");

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

    println!("client_transport_params={}", hex(&params.to_vec()));
    for (name, frame) in [
        ("mc_announce", announce),
        ("mc_key", key),
        ("mc_integrity", integrity),
        ("mc_join", join),
        ("mc_state", state),
        ("mc_ack", ack),
    ] {
        println!("{name}={}", hex(&frame.to_vec().expect("valid frame")));
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
        hex(&Frame::Integrity(sent.integrity)
            .to_vec()
            .expect("valid frame"))
    );
}

#[cfg(not(feature = "mcquic"))]
fn main() {
    eprintln!("enable the mcquic feature to print MCQUIC interop hex");
}

#[cfg(feature = "mcquic")]
fn hex(data: &[u8]) -> String {
    const CHARS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(data.len() * 2);
    for byte in data {
        out.push(char::from(CHARS[usize::from(byte >> 4)]));
        out.push(char::from(CHARS[usize::from(byte & 0x0f)]));
    }
    out
}
