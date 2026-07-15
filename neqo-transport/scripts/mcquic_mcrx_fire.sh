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

if [[ -z "${NSS_DIR:-}" && -d "${neqo_root}/target/debug/build" ]]; then
    existing_nss_dir="$(
        find "${neqo_root}/target/debug/build" -path '*/out/nss' -type d -print -quit 2>/dev/null || true
    )"
    if [[ -n "${existing_nss_dir}" && -d "$(dirname "${existing_nss_dir}")/dist/Release/lib" ]]; then
        export NSS_DIR="${existing_nss_dir}"
        export NSS_PREBUILT="${NSS_PREBUILT:-1}"
        nss_lib_dir="$(dirname "${existing_nss_dir}")/dist/Release/lib"
        export DYLD_LIBRARY_PATH="${nss_lib_dir}:${DYLD_LIBRARY_PATH:-}"
        export LD_LIBRARY_PATH="${nss_lib_dir}:${LD_LIBRARY_PATH:-}"
    fi
fi

nss_rs_path="${NSS_RS_PATH:-}"
if [[ -z "${nss_rs_path}" ]]; then
    nss_checkout_root="${CARGO_HOME:-${HOME}/.cargo}/git/checkouts/nss-rs-71e20fe79ef91440"
    if [[ -d "${nss_checkout_root}" ]]; then
        nss_rs_path="$(find "${nss_checkout_root}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    fi
fi

if [[ "${MCQUIC_USE_LOCAL_NSS_RS:-0}" == "1" && -n "${nss_rs_path}" && -f "${nss_rs_path}/Cargo.toml" ]]; then
    nss_dependency="nss = { path = \"${nss_rs_path}\", package = \"nss-rs\" }"
    nss_patch="[patch.\"git+https://github.com/mozilla/nss-rs?rev=0.12.2\"]
nss = { path = \"${nss_rs_path}\", package = \"nss-rs\" }
nss-test-fixture = { path = \"${nss_rs_path}/test-fixture\", package = \"test-fixture\" }"
else
    nss_dependency="nss = { rev = \"0.12.2\", package = \"nss-rs\", git = \"https://github.com/mozilla/nss-rs\" }"
    nss_patch=""
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'USAGE'
MCQUIC mcrx fire interop harness.

This creates a temporary Rust harness that:
  1. asks quiche multicast to encode one protected channel DATAGRAM,
  2. sends that UDP payload with mctx-core,
  3. receives multicast with mcrx-core,
  4. feeds the received bytes into Neqo MCQUIC channel validation.

Optional:
  MCQUIC_SOURCE       local source IP used for SSM (default: 127.0.0.1)
  MCQUIC_INTERFACE    local multicast interface IP (defaults to MCQUIC_SOURCE)
  MCQUIC_GROUP        multicast group (default: 232.1.1.1)
  MCQUIC_PORT         UDP port (default: 5004)
  MCQUIC_PAYLOAD      DATAGRAM payload text (default: neqo-mcquic-fire)
  MCQUIC_TIMEOUT_MS   receive timeout (default: 3000)
  MCQUIC_TTL          multicast TTL/hop-limit (default: 1)
  MCQUIC_BIND_SOURCE  bind sender to MCQUIC_SOURCE (default: 0)
  MCQUIC_BUILD_ONLY   set to 1 to only compile the temporary harness
  MCQUIC_CARGO_OFFLINE set to 1 to force Cargo offline mode (default: 0)
  MCQUIC_TARGET_DIR   Cargo target dir for the temp harness
                      (default: /private/tmp/neqo-mcquic-fire-target)
  MCQUIC_USE_LOCAL_NSS_RS set to 1 to force local nss-rs path dependencies
  QUICHE_ROOT         local quiche fork root
  QUICHE_CRATE        local quiche crate path

Example:
  neqo-transport/scripts/mcquic_mcrx_fire.sh

Real interface example:
  MCQUIC_SOURCE=192.0.2.10 MCQUIC_INTERFACE=192.0.2.10 \
    neqo-transport/scripts/mcquic_mcrx_fire.sh
USAGE
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/neqo-mcquic-mcrx-fire.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/src/bin" "${tmp}/.cargo"
if [[ -x /private/tmp/neqo-gyp-venv/bin/python && -f /private/tmp/neqo-gyp-venv/bin/gyp ]]; then
    mkdir -p "${tmp}/bin"
    cat >"${tmp}/bin/gyp" <<'GYP_WRAPPER'
#!/usr/bin/env sh
exec /private/tmp/neqo-gyp-venv/bin/python /private/tmp/neqo-gyp-venv/bin/gyp "$@"
GYP_WRAPPER
    chmod +x "${tmp}/bin/gyp"
    export PATH="${tmp}/bin:/private/tmp/neqo-gyp-venv/bin:${PATH}"
fi

if [[ "${MCQUIC_USE_LOCAL_NSS_RS:-0}" == "1" && -n "${nss_rs_path}" && -f "${nss_rs_path}/Cargo.toml" ]]; then
    cat >"${tmp}/.cargo/config.toml" <<CARGO_CONFIG
paths = ["${nss_rs_path}", "${nss_rs_path}/test-fixture"]
CARGO_CONFIG
fi
export CARGO_TARGET_DIR="${MCQUIC_TARGET_DIR:-/private/tmp/neqo-mcquic-fire-target}"

cat >"${tmp}/Cargo.toml" <<CARGO
[package]
name = "mcquic-mcrx-fire"
version = "0.1.0"
edition = "2021"

[dependencies]
mcrx-core = { version = "0.2.6", default-features = false }
mctx-core = { version = "0.2.4", default-features = false }
neqo-transport = { path = "${neqo_root}/neqo-transport", default-features = false, features = ["mcquic"] }
${nss_dependency}
quiche = { path = "${quiche_crate}" }

${nss_patch}
CARGO
cp "${neqo_root}/Cargo.lock" "${tmp}/Cargo.lock"

cat >"${tmp}/src/bin/mcquic-quiche-send.rs" <<'RUST'
use std::{
    env,
    error::Error,
    net::IpAddr,
};

use mctx_core::{OutgoingInterface, Publication, PublicationConfig, PublicationId};
use quiche::multicast as quiche_mc;

fn main() -> Result<(), Box<dyn Error>> {
    let source = source_ip()?;
    let interface = optional_ip("MCQUIC_INTERFACE")?.unwrap_or(source);
    let group = optional_ip("MCQUIC_GROUP")?
        .unwrap_or_else(|| "232.1.1.1".parse().expect("default group parses"));
    let port = optional_u16("MCQUIC_PORT")?.unwrap_or(5004);
    let ttl = optional_u64("MCQUIC_TTL")?.unwrap_or(1) as u32;
    let payload = env::var("MCQUIC_PAYLOAD").unwrap_or_else(|_| "neqo-mcquic-fire".into());
    let integrity_file = env::var("MCQUIC_INTEGRITY_FILE")
        .map_err(|_| "MCQUIC_INTEGRITY_FILE is required")?;
    let channel_id = b"neqo-fire-channel".to_vec();

    if !group.is_multicast() {
        return Err(format!("{group} is not a multicast group").into());
    }
    if !same_family(source, group) || !same_family(interface, group) {
        return Err("MCQUIC_SOURCE, MCQUIC_INTERFACE, and MCQUIC_GROUP must use one IP family".into());
    }

    let announce = quiche_mc::Announce {
        channel_id: channel_id.clone(),
        source,
        group,
        udp_port: port,
        header_protection_algorithm: 0x1301,
        header_secret: vec![0x11; 32],
        aead_algorithm: 0x1301,
        integrity_hash_algorithm: 1,
        max_rate_kibps: 10_000,
        max_ack_delay_ms: 25,
    };
    let key = quiche_mc::Key {
        channel_id: channel_id.clone(),
        key_sequence: 1,
        from_packet_number: 0,
        secret: vec![0x22; 32],
    };

    let mut quiche_sender =
        quiche_mc::ChannelSendState::new(announce.clone(), key.clone())?;
    let mut protected = vec![0; 1500];
    let sent = quiche_sender.write_packet(
        &[quiche_mc::ChannelFrame::Datagram {
            data: payload.as_bytes().to_vec(),
        }],
        &mut protected,
    )?;
    protected.truncate(sent.packet_len);

    std::fs::write(
        integrity_file,
        format!(
            "{} {} {}\n",
            sent.integrity.packet_number_start,
            sent.integrity.packet_hash_count.unwrap_or(1),
            hex(&sent.integrity.packet_hashes)
        ),
    )?;

    let mut publication_config = PublicationConfig::new(group, port)
        .with_outgoing_interface(outgoing_interface(interface))
        .with_ttl(ttl)
        .with_loopback(true);
    if env::var("MCQUIC_BIND_SOURCE").is_ok_and(|value| value != "0") {
        publication_config = publication_config.with_source_addr(source);
    }
    let publication = Publication::new(PublicationId(1), publication_config)?;
    let report = publication.send(&protected)?;

    println!(
        "quiche sender fired bytes={} packet_number={} payload={}",
        report.bytes_sent,
        sent.packet_number,
        payload
    );

    Ok(())
}

fn source_ip() -> Result<IpAddr, Box<dyn Error>> {
    env::var("MCQUIC_SOURCE")
        .unwrap_or_else(|_| "127.0.0.1".into())
        .parse()
        .map_err(|err| format!("MCQUIC_SOURCE is not an IP address: {err}").into())
}

fn optional_ip(name: &str) -> Result<Option<IpAddr>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not an IP address: {err}").into())
        })
        .transpose()
}

fn optional_u16(name: &str) -> Result<Option<u16>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not a u16: {err}").into())
        })
        .transpose()
}

fn optional_u64(name: &str) -> Result<Option<u64>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not a u64: {err}").into())
        })
        .transpose()
}

fn same_family(a: IpAddr, b: IpAddr) -> bool {
    matches!(
        (a, b),
        (IpAddr::V4(_), IpAddr::V4(_)) | (IpAddr::V6(_), IpAddr::V6(_))
    )
}

fn outgoing_interface(interface: IpAddr) -> OutgoingInterface {
    match interface {
        IpAddr::V4(interface) => OutgoingInterface::Ipv4Addr(interface),
        IpAddr::V6(interface) => OutgoingInterface::Ipv6Addr(interface),
    }
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

cat >"${tmp}/src/bin/mcquic-mcrx-recv.rs" <<'RUST'
use std::{
    env,
    error::Error,
    net::IpAddr,
    thread,
    time::{Duration, Instant},
};

use mcrx_core::{Context as McrxContext, SubscriptionConfig};
use neqo_transport::mcquic as neqo_mc;

fn main() -> Result<(), Box<dyn Error>> {
    nss::init()?;

    let source = source_ip()?;
    let interface = optional_ip("MCQUIC_INTERFACE")?.unwrap_or(source);
    let group = optional_ip("MCQUIC_GROUP")?
        .unwrap_or_else(|| "232.1.1.1".parse().expect("default group parses"));
    let port = optional_u16("MCQUIC_PORT")?.unwrap_or(5004);
    let timeout = Duration::from_millis(optional_u64("MCQUIC_TIMEOUT_MS")?.unwrap_or(3000));
    let payload = env::var("MCQUIC_PAYLOAD").unwrap_or_else(|_| "neqo-mcquic-fire".into());
    let integrity_file = env::var("MCQUIC_INTEGRITY_FILE")
        .map_err(|_| "MCQUIC_INTEGRITY_FILE is required")?;
    let channel_id = b"neqo-fire-channel".to_vec();

    if !group.is_multicast() {
        return Err(format!("{group} is not a multicast group").into());
    }
    if !same_family(source, group) || !same_family(interface, group) {
        return Err("MCQUIC_SOURCE, MCQUIC_INTERFACE, and MCQUIC_GROUP must use one IP family".into());
    }

    let neqo_announce = neqo_mc::Announce {
        channel_id: channel_id.clone(),
        source,
        group,
        udp_port: port,
        header_protection_algorithm: 0x1301,
        header_secret: vec![0x11; 32],
        aead_algorithm: 0x1301,
        integrity_hash_algorithm: 1,
        max_rate_kibps: 10_000,
        max_ack_delay_ms: 25,
    };
    let neqo_key = neqo_mc::Key {
        channel_id: channel_id.clone(),
        key_sequence: 1,
        from_packet_number: 0,
        secret: vec![0x22; 32],
    };

    let mut rx_config = SubscriptionConfig::ssm_ip(group, source, port);
    rx_config.interface = Some(interface);
    let mut rx = McrxContext::new();
    let subscription_id = rx.add_subscription(rx_config)?;
    rx.join_subscription(subscription_id)?;

    let received = recv_one(&mut rx, timeout)?;
    let received_payload = received.packet.payload();

    let mut neqo_receiver = neqo_mc::ChannelReceiveState::new(neqo_announce)?;
    assert!(neqo_receiver.insert_key(neqo_key)?.is_empty());
    assert!(neqo_receiver
        .process_protected_packet(received_payload)?
        .is_empty());

    let (packet_number_start, packet_hash_count, packet_hashes) =
        wait_integrity(&integrity_file, timeout)?;
    let released = neqo_receiver.insert_integrity(neqo_mc::Integrity {
        channel_id,
        packet_number_start,
        packet_hash_count: Some(packet_hash_count),
        packet_hashes,
    })?;
    let datagram = released
        .first()
        .ok_or("Neqo did not release a DATAGRAM after MC_INTEGRITY")?;

    if datagram.data != payload.as_bytes() {
        return Err(format!(
            "Neqo released {:?}, expected {:?}",
            String::from_utf8_lossy(&datagram.data),
            payload
        )
        .into());
    }

    println!("MCQUIC mcrx fire interop succeeded");
    println!("group={group} source={source} interface={interface} port={port}");
    println!(
        "received_bytes={} packet_number={} payload={}",
        received_payload.len(),
        datagram.packet_number,
        String::from_utf8_lossy(&datagram.data)
    );
    println!("remote_source={}", received.packet.source);

    Ok(())
}

fn recv_one(
    rx: &mut McrxContext,
    timeout: Duration,
) -> Result<mcrx_core::PacketWithMetadata, Box<dyn Error>> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(packet) = rx.try_recv_any_with_metadata()? {
            return Ok(packet);
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out after {} ms waiting for mcrx packet", timeout.as_millis()).into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn wait_integrity(path: &str, timeout: Duration) -> Result<(u64, u64, Vec<u8>), Box<dyn Error>> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(contents) = std::fs::read_to_string(path) {
            let fields = contents.split_whitespace().collect::<Vec<_>>();
            if fields.len() == 3 {
                return Ok((fields[0].parse()?, fields[1].parse()?, decode_hex(fields[2])?));
            }
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out after {} ms waiting for MC_INTEGRITY", timeout.as_millis()).into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn source_ip() -> Result<IpAddr, Box<dyn Error>> {
    env::var("MCQUIC_SOURCE")
        .unwrap_or_else(|_| "127.0.0.1".into())
        .parse()
        .map_err(|err| format!("MCQUIC_SOURCE is not an IP address: {err}").into())
}

fn optional_ip(name: &str) -> Result<Option<IpAddr>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not an IP address: {err}").into())
        })
        .transpose()
}

fn optional_u16(name: &str) -> Result<Option<u16>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not a u16: {err}").into())
        })
        .transpose()
}

fn optional_u64(name: &str) -> Result<Option<u64>, Box<dyn Error>> {
    env::var(name)
        .ok()
        .map(|value| {
            value
                .parse()
                .map_err(|err| format!("{name} is not a u64: {err}").into())
        })
        .transpose()
}

fn same_family(a: IpAddr, b: IpAddr) -> bool {
    matches!(
        (a, b),
        (IpAddr::V4(_), IpAddr::V4(_)) | (IpAddr::V6(_), IpAddr::V6(_))
    )
}

fn decode_hex(hex: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    if hex.len() % 2 != 0 {
        return Err("odd-length hex".into());
    }
    let mut out = Vec::with_capacity(hex.len() / 2);
    for idx in (0..hex.len()).step_by(2) {
        out.push(u8::from_str_radix(&hex[idx..idx + 2], 16)?);
    }
    Ok(out)
}
RUST

(
    cd "${tmp}"
    if [[ "${MCQUIC_CARGO_OFFLINE:-0}" == "1" ]]; then
        cargo generate-lockfile --offline --quiet
    else
        cargo generate-lockfile --quiet
    fi
)

if [[ "${MCQUIC_BUILD_ONLY:-0}" == "1" ]]; then
    (
        cd "${tmp}"
        if [[ "${MCQUIC_CARGO_OFFLINE:-0}" == "1" ]]; then
            cargo build --locked --offline --quiet \
                --bin mcquic-mcrx-recv --bin mcquic-quiche-send
        else
            cargo build --locked --quiet \
                --bin mcquic-mcrx-recv --bin mcquic-quiche-send
        fi
    )
    echo "MCQUIC mcrx fire harness builds."
    exit 0
fi

integrity_file="${tmp}/mcquic-integrity.txt"
rm -f "${integrity_file}"

(
    cd "${tmp}"
    if [[ "${MCQUIC_CARGO_OFFLINE:-0}" == "1" ]]; then
        MCQUIC_INTEGRITY_FILE="${integrity_file}" \
            cargo run --locked --offline --quiet --bin mcquic-mcrx-recv
    else
        MCQUIC_INTEGRITY_FILE="${integrity_file}" \
            cargo run --locked --quiet --bin mcquic-mcrx-recv
    fi
) &
receiver_pid=$!

sleep "${MCQUIC_RX_STARTUP_SLEEP:-0.25}"

sender_status=0
(
    cd "${tmp}"
    if [[ "${MCQUIC_CARGO_OFFLINE:-0}" == "1" ]]; then
        MCQUIC_INTEGRITY_FILE="${integrity_file}" \
            cargo run --locked --offline --quiet --bin mcquic-quiche-send
    else
        MCQUIC_INTEGRITY_FILE="${integrity_file}" \
            cargo run --locked --quiet --bin mcquic-quiche-send
    fi
) || sender_status=$?

receiver_status=0
wait "${receiver_pid}" || receiver_status=$?

if [[ "${sender_status}" -ne 0 ]]; then
    exit "${sender_status}"
fi
if [[ "${receiver_status}" -ne 0 ]]; then
    exit "${receiver_status}"
fi
