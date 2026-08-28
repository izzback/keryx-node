/// RocksDB store of service-bond first sightings. Append-once, written only for finality-deep
/// sightings (reorg-immune): the daa of an identity's first certified block, never overwritten.
/// The standing/probation clock reads it at a lagged anchor (`SERVICE_STANDING_LAG_DAA`).
use std::sync::Arc;

use keryx_database::prelude::{BatchDbWriter, CachePolicy, CachedDbAccess, DB, DirectDbWriter, StoreError};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
use rocksdb::WriteBatch;

#[derive(Clone)]
pub struct DbServiceFirstSeenStore {
    db: Arc<DB>,
    access: CachedDbAccess<Hash, u64>,
}

impl DbServiceFirstSeenStore {
    pub fn new(db: Arc<DB>, cache_policy: CachePolicy) -> Self {
        Self { db: Arc::clone(&db), access: CachedDbAccess::new(db, cache_policy, DatabaseStorePrefixes::ServiceFirstSeen.into()) }
    }

    pub fn set(&self, miner: Hash, daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), miner, daa)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, miner: Hash, daa: u64) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), miner, daa)
    }

    /// All sightings, for the boot load and the refold baseline.
    pub fn iterator(&self) -> impl Iterator<Item = Result<(Box<[u8]>, u64), Box<dyn std::error::Error>>> + '_ {
        self.access.iterator()
    }
}
