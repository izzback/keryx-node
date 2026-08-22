use std::sync::Arc;

use keryx_consensus_core::BlockHasher;
use keryx_consensus_core::pom::{PomProof, PomProofPreH4, PomProofPreV3, PomProofPreV4};
use keryx_database::prelude::CachePolicy;
use keryx_database::prelude::DB;
use keryx_database::prelude::StoreError;
use keryx_database::prelude::{BatchDbWriter, CachedDbAccess};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
use rocksdb::WriteBatch;

/// Read access to the full PoM possession proof of each block, persisted at body-commit time.
/// Required so a block can be re-served to peers (relay / IBD) with its proof attached:
/// `get_block` reconstructs the block from storage, and without this store `pom_proof` would be
/// `None`, causing peers to reject the served block with `PoM possession proof missing`. Only
/// blocks at/after `pom_activation` carry a proof; pre-fork blocks have no entry here.
pub trait PomProofStoreReader {
    fn get(&self, hash: Hash) -> Result<PomProof, StoreError>;
    fn has(&self, hash: Hash) -> Result<bool, StoreError>;
}

/// A DB + cache implementation of `PomProofStoreReader`, with concurrency support.
#[derive(Clone)]
pub struct DbPomProofStore {
    db: Arc<DB>,
    access: CachedDbAccess<Hash, PomProof, BlockHasher>,
}

impl DbPomProofStore {
    pub fn new(db: Arc<DB>, cache_policy: CachePolicy) -> Self {
        Self { db: Arc::clone(&db), access: CachedDbAccess::new(db, cache_policy, DatabaseStorePrefixes::PomProof.into()) }
    }

    pub fn clone_with_new_cache(&self, cache_policy: CachePolicy) -> Self {
        Self::new(Arc::clone(&self.db), cache_policy)
    }

    // Append-only, but retry-safe for the same immutable proof. `CachedDbAccess::write` publishes
    // the value to the cache before the surrounding RocksDB WriteBatch is flushed, so body commit
    // can race with PoM re-proof adoption and observe the hash as present while the first writer is
    // still finishing. Treat that exact duplicate as an idempotent success. A different proof for
    // the same hash remains a hard data-consistency error rather than being silently overwritten.
    pub fn insert_batch(&self, batch: &mut WriteBatch, hash: Hash, proof: &PomProof) -> Result<(), StoreError> {
        if self.access.has(hash)? {
            let existing = self.get(hash)?;
            if existing.wire_digest() == proof.wire_digest() {
                return Ok(());
            }
            return Err(StoreError::DataInconsistency(format!("conflicting PoM possession proofs for block {hash}")));
        }
        self.access.write(BatchDbWriter::new(batch), hash, proof.clone())?;
        Ok(())
    }

    pub fn delete_batch(&self, batch: &mut WriteBatch, hash: Hash) -> Result<(), StoreError> {
        self.access.delete(BatchDbWriter::new(batch), hash)
    }
}

impl PomProofStoreReader for DbPomProofStore {
    fn get(&self, hash: Hash) -> Result<PomProof, StoreError> {
        // Records written before the H6 `v3` field existed are the pre-V3 positional layout;
        // before the H4 `steps_v2` field, the pre-H4 one. The grown `PomProof` under-flows on
        // their bytes, so decode falls back down the era chain (same mechanism as the utxoset
        // store, one more era deep). KeyNotFound short-circuits — only decode shapes chain.
        match self.access.read_with_decode_fallback::<PomProofPreV4>(hash) {
            Err(e @ StoreError::KeyNotFound(_)) => Err(e),
            Err(_) => match self.access.read_with_decode_fallback::<PomProofPreV3>(hash) {
                Err(_) => self.access.read_with_decode_fallback::<PomProofPreH4>(hash),
                ok => ok,
            },
            ok => ok,
        }
    }

    fn has(&self, hash: Hash) -> Result<bool, StoreError> {
        self.access.has(hash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keryx_database::{create_temp_db, prelude::ConnBuilder};

    fn dummy_proof(final_state: u64) -> PomProof {
        PomProof {
            tier: 0,
            trace_root: [1; 32],
            pow_value: [2; 32],
            final_state,
            initial_trace_path: vec![],
            final_trace_path: vec![],
            openings: vec![],
            steps_v2: None,
            v3: None,
            v4: None,
        }
    }

    #[test]
    fn concurrent_same_proof_insert_is_idempotent_before_batch_flush() {
        let (_lifetime, db) = create_temp_db!(ConnBuilder::default().with_files_limit(10));
        let store = DbPomProofStore::new(db.clone(), CachePolicy::Count(16));
        let hash: Hash = 42.into();
        let proof = dummy_proof(7);

        // First writer publishes to CachedDbAccess immediately but deliberately does not flush its
        // RocksDB batch yet. This is the window hit when body commit races re-proof adoption.
        let mut first_batch = WriteBatch::default();
        store.insert_batch(&mut first_batch, hash, &proof).unwrap();

        // Before the fix this returned HashAlreadyExists, and commit_body().unwrap() panicked.
        let mut racing_batch = WriteBatch::default();
        store.insert_batch(&mut racing_batch, hash, &proof).unwrap();

        // The first writer still owns persistence; the duplicate must not replace it.
        db.write(first_batch).unwrap();
        assert_eq!(store.get(hash).unwrap().wire_digest(), proof.wire_digest());
    }

    #[test]
    fn conflicting_proof_for_same_hash_is_not_silently_accepted() {
        let (_lifetime, db) = create_temp_db!(ConnBuilder::default().with_files_limit(10));
        let store = DbPomProofStore::new(db, CachePolicy::Count(16));
        let hash: Hash = 43.into();

        let mut first_batch = WriteBatch::default();
        store.insert_batch(&mut first_batch, hash, &dummy_proof(7)).unwrap();

        let mut conflicting_batch = WriteBatch::default();
        let err = store.insert_batch(&mut conflicting_batch, hash, &dummy_proof(8)).unwrap_err();
        assert!(matches!(err, StoreError::DataInconsistency(_)));
    }
}
