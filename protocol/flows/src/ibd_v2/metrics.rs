//! IBD v2 measurement primitives.
//!
//! Phase 0 starts with measurement. These counters are intentionally transport
//! and consensus agnostic so they remain stable even if upstream APIs change.

use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct StageMetrics {
    started_at: Instant,
    pub items: u64,
    pub bytes: u64,
    pub validation_time: Duration,
    pub storage_time: Duration,
    pub peer_wait_time: Duration,
}

impl Default for StageMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl StageMetrics {
    pub fn new() -> Self {
        Self {
            started_at: Instant::now(),
            items: 0,
            bytes: 0,
            validation_time: Duration::ZERO,
            storage_time: Duration::ZERO,
            peer_wait_time: Duration::ZERO,
        }
    }

    pub fn elapsed(&self) -> Duration {
        self.started_at.elapsed()
    }

    pub fn record_transfer(&mut self, items: u64, bytes: u64) {
        self.items = self.items.saturating_add(items);
        self.bytes = self.bytes.saturating_add(bytes);
    }

    pub fn record_validation_time(&mut self, elapsed: Duration) {
        self.validation_time = self.validation_time.saturating_add(elapsed);
    }

    pub fn record_storage_time(&mut self, elapsed: Duration) {
        self.storage_time = self.storage_time.saturating_add(elapsed);
    }

    pub fn record_peer_wait_time(&mut self, elapsed: Duration) {
        self.peer_wait_time = self.peer_wait_time.saturating_add(elapsed);
    }

    pub fn items_per_second(&self) -> f64 {
        let seconds = self.elapsed().as_secs_f64();
        if seconds == 0.0 { 0.0 } else { self.items as f64 / seconds }
    }

    pub fn megabytes_per_second(&self) -> f64 {
        let seconds = self.elapsed().as_secs_f64();
        if seconds == 0.0 { 0.0 } else { (self.bytes as f64 / 1_000_000.0) / seconds }
    }
}
