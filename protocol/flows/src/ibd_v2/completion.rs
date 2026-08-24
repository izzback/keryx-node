//! Durable completion marker for the IBD v2 Service State stage.
//!
//! The progress journal answers "how far did the download get?". This marker
//! answers a different question: "was the verified state imported into
//! consensus successfully?". Keeping the two concepts separate lets a restart
//! resume an interrupted transfer even when the pruning UTXO set is already
//! marked stable.

use keryx_hashes::Hash;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

const MAGIC: &[u8; 8] = b"KIBDSC01";
const VERSION: u32 = 1;
const RECORD_LEN: usize = 8 + 4 + 32 + 32;
const MARKER_FILE: &str = "complete.bin";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServiceStateCompletion {
    pub pruning_point: Hash,
    pub service_state_hash: Hash,
}

#[derive(Debug, Clone)]
pub struct ServiceStateCompletionStore {
    path: PathBuf,
}

impl ServiceStateCompletionStore {
    pub fn open(root: impl AsRef<Path>) -> io::Result<Self> {
        let dir = root.as_ref().join("service-state");
        fs::create_dir_all(&dir)?;
        Ok(Self { path: dir.join(MARKER_FILE) })
    }

    /// Returns the durable completion marker when it is structurally valid.
    ///
    /// A missing, truncated, future-version or otherwise malformed marker is
    /// treated as incomplete. That may cause a safe re-import, but can never
    /// cause an unverified Service State to be trusted after a crash.
    pub fn load(&self) -> io::Result<Option<ServiceStateCompletion>> {
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(err),
        };
        if file.metadata()?.len() != RECORD_LEN as u64 {
            return Ok(None);
        }

        let mut bytes = [0u8; RECORD_LEN];
        file.read_exact(&mut bytes)?;
        decode(&bytes)
    }

    pub fn is_complete(&self, pruning_point: Hash, service_state_hash: Hash) -> io::Result<bool> {
        Ok(self
            .load()?
            .is_some_and(|marker| marker.pruning_point == pruning_point && marker.service_state_hash == service_state_hash))
    }

    /// Persist completion only after both the commitment check and consensus
    /// import have succeeded. A torn marker is deliberately interpreted as
    /// incomplete on the next boot, making the failure mode a safe re-import.
    pub fn mark_complete(&self, pruning_point: Hash, service_state_hash: Hash) -> io::Result<()> {
        let marker = ServiceStateCompletion { pruning_point, service_state_hash };
        let bytes = encode(marker);
        let mut file = OpenOptions::new().create(true).write(true).truncate(true).open(&self.path)?;
        file.write_all(&bytes)?;
        file.sync_all()
    }

    pub fn clear(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err),
        }
    }
}

fn encode(marker: ServiceStateCompletion) -> [u8; RECORD_LEN] {
    let mut out = [0u8; RECORD_LEN];
    out[..8].copy_from_slice(MAGIC);
    out[8..12].copy_from_slice(&VERSION.to_le_bytes());
    out[12..44].copy_from_slice(&marker.pruning_point.as_bytes());
    out[44..76].copy_from_slice(&marker.service_state_hash.as_bytes());
    out
}

fn decode(bytes: &[u8; RECORD_LEN]) -> io::Result<Option<ServiceStateCompletion>> {
    if &bytes[..8] != MAGIC {
        return Ok(None);
    }
    let version = u32::from_le_bytes(bytes[8..12].try_into().expect("fixed marker range"));
    if version != VERSION {
        return Ok(None);
    }

    let mut pruning_point = [0u8; 32];
    pruning_point.copy_from_slice(&bytes[12..44]);
    let mut service_state_hash = [0u8; 32];
    service_state_hash.copy_from_slice(&bytes[44..76]);
    Ok(Some(ServiceStateCompletion {
        pruning_point: Hash::from_bytes(pruning_point),
        service_state_hash: Hash::from_bytes(service_state_hash),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ibd_v2::{checkpoint::ServiceStateCheckpointStore, state::ServiceStateResumeMetadata};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("keryx-ibd-v2-completion-{label}-{}-{nonce}", std::process::id()))
    }

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    #[test]
    fn completion_survives_reopen() {
        let root = temp_root("reopen");
        let store = ServiceStateCompletionStore::open(&root).unwrap();
        store.mark_complete(hash(1), hash(2)).unwrap();
        drop(store);

        let store = ServiceStateCompletionStore::open(&root).unwrap();
        assert!(store.is_complete(hash(1), hash(2)).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn wrong_pruning_point_or_commitment_is_not_complete() {
        let root = temp_root("mismatch");
        let store = ServiceStateCompletionStore::open(&root).unwrap();
        store.mark_complete(hash(1), hash(2)).unwrap();

        assert!(!store.is_complete(hash(3), hash(2)).unwrap());
        assert!(!store.is_complete(hash(1), hash(4)).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn truncated_marker_is_safely_incomplete() {
        let root = temp_root("truncated");
        let store = ServiceStateCompletionStore::open(&root).unwrap();
        store.mark_complete(hash(1), hash(2)).unwrap();
        let marker_path = root.join("service-state").join(MARKER_FILE);
        OpenOptions::new().write(true).open(marker_path).unwrap().set_len(17).unwrap();

        assert!(store.load().unwrap().is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn clearing_staging_does_not_clear_completion() {
        let root = temp_root("independent");
        let pruning_point = hash(1);
        let completion = ServiceStateCompletionStore::open(&root).unwrap();
        completion.mark_complete(pruning_point, hash(2)).unwrap();

        let (mut checkpoint, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
        assert!(loaded.is_none());
        let rows = vec![b"row".to_vec()];
        let mut metadata = ServiceStateResumeMetadata::new(pruning_point);
        metadata
            .record_chunk(1, 1, crate::ibd_v2::state::service_state_row_fingerprint(&rows[0]))
            .unwrap();
        checkpoint.append_chunk(&rows, metadata).unwrap();
        checkpoint.reset().unwrap();

        assert!(completion.is_complete(pruning_point, hash(2)).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
