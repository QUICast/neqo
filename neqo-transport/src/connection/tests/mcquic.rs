use std::collections::VecDeque;

use crate::{
    connection::queue_mcquic_frame,
    mcquic::{Ack, Frame},
};

fn ack(channel_id: &[u8], largest_acknowledged: u64) -> Frame {
    Frame::Ack(Ack {
        channel_id: channel_id.to_vec(),
        largest_acknowledged,
        ack_delay: 0,
        first_ack_range: 0,
        ack_ranges: Vec::new(),
        ecn_counts: None,
    })
}

#[test]
fn queued_ack_replaces_stale_snapshot_for_same_channel() {
    let mut queue = VecDeque::new();
    queue_mcquic_frame(&mut queue, ack(b"one", 1));
    queue_mcquic_frame(&mut queue, ack(b"two", 4));
    queue_mcquic_frame(&mut queue, ack(b"one", 7));

    assert_eq!(queue.len(), 2);
    assert_eq!(queue.pop_front(), Some(ack(b"one", 7)));
    assert_eq!(queue.pop_front(), Some(ack(b"two", 4)));
}
