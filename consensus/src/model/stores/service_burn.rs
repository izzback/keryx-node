/// RocksDB store of service-bond burned escrow outpoints. Written only for finality-deep misses
/// (reorg-immune), so writes are monotone and idempotent and never rolled back. Read at boot to
/// rebuild the RAM burned-set consulted by transaction validation.
use std::sync::Arc;

use keryx_database::prelude::{BatchDbWriter, CachePolicy, CachedDbAccess, DB, DirectDbWriter, StoreError};
use keryx_database::registry::DatabaseStorePrefixes;
use rocksdb::WriteBatch;

use super::ai_slash::OutpointKey;

#[derive(Clone)]
pub struct DbServiceBurnStore {
    db: Arc<DB>,
    access: CachedDbAccess<OutpointKey, u64>,
}

impl DbServiceBurnStore {
    pub fn new(db: Arc<DB>, cache_policy: CachePolicy) -> Self {
        Self { db: Arc::clone(&db), access: CachedDbAccess::new(db, cache_policy, DatabaseStorePrefixes::ServiceBurn.into()) }
    }

    pub fn set(&self, key: OutpointKey, miss_daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), key, miss_daa)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, key: OutpointKey, miss_daa: u64) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), key, miss_daa)
    }

    /// All burned outpoints with their miss daa, for the boot load.
    pub fn iterator(&self) -> impl Iterator<Item = Result<(Box<[u8]>, u64), Box<dyn std::error::Error>>> + '_ {
        self.access.iterator()
    }
}
