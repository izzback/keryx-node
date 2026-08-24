//! Keryx-native GHOSTDAG self-reference validation fixtures.
//!
//! This module is test-only. It deliberately calls the production `GhostdagManager`
//! rather than reimplementing selected-parent or blue/red rules. The surrounding
//! stores are in-memory test stores so fixtures stay deterministic and cheap.

use std::sync::Arc;

use keryx_consensus_core::{
    BlockHashMap,
    blockhash::{BlockHashes, ORIGIN},
    header::Header,
};
use keryx_database::prelude::StoreError;
use keryx_hashes::Hash;
use parking_lot::RwLock;

use crate::{
    model::{
        services::reachability::MTReachabilityService,
        stores::{
            ghostdag::{GhostdagData, GhostdagStore, GhostdagStoreReader, KType, MemoryGhostdagStore},
            headers::{CompactHeaderData, HeaderStoreReader, HeaderWithBlockLevel},
            reachability::MemoryReachabilityStore,
            relations::MemoryRelationsStore,
        },
    },
    processes::{
        ghostdag::protocol::GhostdagManager,
        reachability::inquirer::{add_block as reachability_add_block, init as reachability_init},
        relations::{RelationsStoreExtensions, init as relations_init},
    },
};

const TEST_K: KType = 124;
const TEST_BITS: u32 = 0x1e7fffff;

/// Minimal in-memory header reader for GHOSTDAG tests.
///
/// GHOSTDAG level 0 only needs each blue block's compact target (`bits`) to
/// calculate work. The full reader implementation keeps this helper compatible
/// with the production manager interface without touching production code.
#[derive(Default)]
struct TestHeaderStore {
    headers: RwLock<BlockHashMap<Arc<Header>>>,
}

impl TestHeaderStore {
    fn insert(&self, hash: Hash, parents: &[Hash], daa_score: u64) {
        let mut header = Header::from_precomputed_hash(hash, parents.to_vec());
        header.bits = TEST_BITS;
        header.daa_score = daa_score;
        self.headers.write().insert(hash, Arc::new(header));
    }

    fn get(&self, hash: Hash) -> Result<Arc<Header>, StoreError> {
        self.headers
            .read()
            .get(&hash)
            .cloned()
            .ok_or_else(|| StoreError::DataInconsistency(format!("missing selfref test header {hash}")))
    }
}

impl HeaderStoreReader for TestHeaderStore {
    fn get_daa_score(&self, hash: Hash) -> Result<u64, StoreError> {
        Ok(self.get(hash)?.daa_score)
    }

    fn get_blue_score(&self, hash: Hash) -> Result<u64, StoreError> {
        Ok(self.get(hash)?.blue_score)
    }

    fn get_timestamp(&self, hash: Hash) -> Result<u64, StoreError> {
        Ok(self.get(hash)?.timestamp)
    }

    fn get_bits(&self, hash: Hash) -> Result<u32, StoreError> {
        Ok(self.get(hash)?.bits)
    }

    fn get_header(&self, hash: Hash) -> Result<Arc<Header>, StoreError> {
        self.get(hash)
    }

    fn get_header_with_block_level(&self, hash: Hash) -> Result<HeaderWithBlockLevel, StoreError> {
        Ok(HeaderWithBlockLevel { header: self.get(hash)?, block_level: 0 })
    }

    fn get_compact_header_data(&self, hash: Hash) -> Result<CompactHeaderData, StoreError> {
        Ok(self.get(hash)?.as_ref().into())
    }
}

struct GhostdagHarness {
    genesis: Hash,
    ghostdag_store: Arc<MemoryGhostdagStore>,
    relations_store: MemoryRelationsStore,
    headers_store: Arc<TestHeaderStore>,
    reachability_store: Arc<RwLock<MemoryReachabilityStore>>,
    next_daa_score: u64,
}

impl GhostdagHarness {
    fn new() -> Self {
        let genesis: Hash = 1u64.into();
        let ghostdag_store = Arc::new(MemoryGhostdagStore::new());
        let headers_store = Arc::new(TestHeaderStore::default());

        let mut relations_store = MemoryRelationsStore::new();
        relations_init(&mut relations_store);

        let mut reachability_store = MemoryReachabilityStore::new();
        reachability_init(&mut reachability_store).unwrap();
        let reachability_store = Arc::new(RwLock::new(reachability_store));

        let mut harness = Self {
            genesis,
            ghostdag_store,
            relations_store,
            headers_store,
            reachability_store,
            next_daa_score: 0,
        };

        // GHOSTDAG expects ORIGIN data to exist before processing genesis.
        let origin_data = harness.manager().origin_ghostdag_data();
        harness.ghostdag_store.insert(ORIGIN, origin_data).unwrap();

        let genesis_data = harness.add_block(genesis, &[ORIGIN]);
        assert_eq!(genesis_data.selected_parent, ORIGIN);
        harness
    }

    fn manager(
        &self,
    ) -> GhostdagManager<
        MemoryGhostdagStore,
        &MemoryRelationsStore,
        MTReachabilityService<MemoryReachabilityStore>,
        TestHeaderStore,
    > {
        GhostdagManager::new(
            self.genesis,
            TEST_K,
            Arc::clone(&self.ghostdag_store),
            &self.relations_store,
            Arc::clone(&self.headers_store),
            MTReachabilityService::new(Arc::clone(&self.reachability_store)),
        )
    }

    fn preview(&self, parents: &[Hash]) -> GhostdagData {
        self.manager().ghostdag(parents)
    }

    fn add_block(&mut self, hash: Hash, parents: &[Hash]) -> GhostdagData {
        self.headers_store.insert(hash, parents, self.next_daa_score);
        self.next_daa_score += 1;

        // This is the production GHOSTDAG calculation under test.
        let data = self.preview(parents);
        let selected_parent = data.selected_parent;
        let mergeset: Vec<Hash> = data.unordered_mergeset_without_selected_parent().collect();

        // Update Keryx's actual reachability structure with the GHOSTDAG-selected
        // parent and the exact mergeset returned above.
        let mut mergeset_iter = mergeset.into_iter();
        reachability_add_block(
            &mut *self.reachability_store.write(),
            hash,
            selected_parent,
            &mut mergeset_iter,
        )
        .unwrap();

        self.relations_store.insert(hash, BlockHashes::new(parents.to_vec())).unwrap();
        self.ghostdag_store.insert(hash, Arc::new(data.clone())).unwrap();
        data
    }
}

#[test]
fn linear_single_parent_chain_always_selects_the_only_parent() {
    let mut harness = GhostdagHarness::new();
    let mut parent = harness.genesis;

    for i in 0u64..32 {
        let hash: Hash = (100 + i).into();
        let data = harness.add_block(hash, &[parent]);
        assert_eq!(data.selected_parent, parent);
        parent = hash;
    }
}

#[test]
fn selected_parent_prefers_higher_blue_work() {
    let mut harness = GhostdagHarness::new();

    let a1: Hash = 101u64.into();
    let a2: Hash = 102u64.into();
    let a3: Hash = 103u64.into();
    harness.add_block(a1, &[harness.genesis]);
    harness.add_block(a2, &[a1]);
    harness.add_block(a3, &[a2]);

    let b1: Hash = 201u64.into();
    let b2: Hash = 202u64.into();
    harness.add_block(b1, &[harness.genesis]);
    harness.add_block(b2, &[b1]);

    assert!(
        harness.ghostdag_store.get_blue_work(a3).unwrap()
            > harness.ghostdag_store.get_blue_work(b2).unwrap()
    );

    let candidate = harness.preview(&[b2, a3]);
    assert_eq!(candidate.selected_parent, a3);
}

#[test]
fn selected_parent_tie_breaks_by_hash() {
    let mut harness = GhostdagHarness::new();
    let a: Hash = 301u64.into();
    let b: Hash = 302u64.into();
    harness.add_block(a, &[harness.genesis]);
    harness.add_block(b, &[harness.genesis]);

    assert_eq!(
        harness.ghostdag_store.get_blue_work(a).unwrap(),
        harness.ghostdag_store.get_blue_work(b).unwrap()
    );

    let candidate = harness.preview(&[a, b]);
    assert_eq!(candidate.selected_parent, std::cmp::max(a, b));
}

#[test]
fn simple_two_parent_mergeset_colors_both_siblings_blue() {
    let mut harness = GhostdagHarness::new();
    let a: Hash = 401u64.into();
    let b: Hash = 402u64.into();
    harness.add_block(a, &[harness.genesis]);
    harness.add_block(b, &[harness.genesis]);

    let candidate = harness.preview(&[a, b]);
    assert_eq!(candidate.selected_parent, std::cmp::max(a, b));
    assert_eq!(candidate.mergeset_blues.len(), 2);
    assert!(candidate.mergeset_blues.iter().any(|&hash| hash == a));
    assert!(candidate.mergeset_blues.iter().any(|&hash| hash == b));
    assert!(candidate.mergeset_reds.is_empty());
}

/// Deterministic counterexample fixture for the proposition
/// "98% selected-parent self-reference implies >20% raw share".
///
/// Model an exogenous partition with two independently extending tips. Per round,
/// the suspect produces one block while the rest of the network produces four.
/// The suspect therefore has exactly 20% of produced blocks. Because each side
/// only sees its own current tip during the partition, every suspect block after
/// its first has exactly one suspect parent.
///
/// This fixture tests GHOSTDAG mechanics only; it does not claim that a 50/200
/// split is a normal network condition. The reconnect assertion separately shows
/// which branch Keryx prefers once both tips are visible again.
#[test]
fn partition_fixture_allows_98_percent_selfref_at_exactly_20_percent_raw_share() {
    let mut harness = GhostdagHarness::new();
    let mut suspect_tip = harness.genesis;
    let mut honest_tip = harness.genesis;
    let mut suspect_selfrefs = 0usize;
    let mut suspect_blocks = 0usize;
    let mut honest_blocks = 0usize;

    for round in 0u64..50 {
        let suspect_hash: Hash = (1_000 + round).into();
        let suspect_data = harness.add_block(suspect_hash, &[suspect_tip]);
        if round > 0 {
            assert_eq!(suspect_data.selected_parent, suspect_tip);
            suspect_selfrefs += 1;
        } else {
            assert_eq!(suspect_data.selected_parent, harness.genesis);
        }
        suspect_tip = suspect_hash;
        suspect_blocks += 1;

        for j in 0u64..4 {
            let honest_hash: Hash = (10_000 + round * 4 + j).into();
            let honest_data = harness.add_block(honest_hash, &[honest_tip]);
            assert_eq!(honest_data.selected_parent, honest_tip);
            honest_tip = honest_hash;
            honest_blocks += 1;
        }
    }

    assert_eq!(suspect_blocks, 50);
    assert_eq!(honest_blocks, 200);
    assert_eq!(suspect_blocks * 4, honest_blocks); // 50 / 250 = 20%
    assert_eq!(suspect_selfrefs, 49); // 49 / 50 = 98%
    assert_eq!(suspect_selfrefs * 100, suspect_blocks * 98);

    // The four-times-longer honest branch has strictly more accumulated blue work.
    assert!(
        harness.ghostdag_store.get_blue_work(honest_tip).unwrap()
            > harness.ghostdag_store.get_blue_work(suspect_tip).unwrap()
    );

    // Once both partition tips are visible to one new block, the real Keryx
    // selected-parent rule chooses the higher-blue-work honest tip.
    let reconnect = harness.preview(&[suspect_tip, honest_tip]);
    assert_eq!(reconnect.selected_parent, honest_tip);
}
