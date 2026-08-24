use super::{checkpoint::ServiceStateCheckpointStore, service_state::ServiceStateWireTracker};
use keryx_hashes::Hash;
use std::{fs, path::PathBuf, time::{SystemTime, UNIX_EPOCH}};

fn temp_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("keryx-ibd-v2-recovery-{label}-{}-{nonce}", std::process::id()))
}

fn hash(byte: u8) -> Hash {
    Hash::from_bytes([byte; 32])
}

#[test]
fn service_state_resumes_after_crash_from_a_different_peer() {
    let root = temp_root("peer-switch");
    let pruning_point = hash(7);

    // Peer A serves the first durable chunk.
    let first = vec![b"row-a".to_vec(), b"row-b".to_vec()];
    let (mut store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
    assert!(loaded.is_none());
    let mut peer_a = ServiceStateWireTracker::new(pruning_point);
    peer_a.accept_chunk(Some(pruning_point), Some(0), Some(2), &first).unwrap();
    store.append_chunk(&first, peer_a.metadata()).unwrap();

    // Simulate process loss: all RAM state disappears.
    drop(peer_a);
    drop(store);

    // A new process and peer B must recover exclusively from durable state.
    let (mut store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
    let loaded = loaded.expect("peer A chunk must survive the crash");
    assert_eq!(loaded.rows, first);
    assert_eq!(loaded.metadata.next_cursor, 2);

    let mut peer_b = ServiceStateWireTracker::from_metadata(loaded.metadata);
    let second = vec![b"row-c".to_vec(), b"row-d".to_vec(), b"row-e".to_vec()];
    peer_b.accept_chunk(Some(pruning_point), Some(2), Some(5), &second).unwrap();
    store.append_chunk(&second, peer_b.metadata()).unwrap();
    peer_b.accept_done(Some(pruning_point), Some(5)).unwrap();
    drop(store);

    let (_store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
    let loaded = loaded.unwrap();
    let expected = first.into_iter().chain(second).collect::<Vec<_>>();
    assert_eq!(loaded.rows, expected);
    assert_eq!(loaded.metadata.next_cursor, 5);
    assert_eq!(loaded.metadata.row_count, 5);
    assert_eq!(loaded.metadata.chunk_count, 2);

    fs::remove_dir_all(root).unwrap();
}
