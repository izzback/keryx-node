//! IBD v2 measurement primitives.
//!
//! Phase 0 starts with measurement. These counters are intentionally transport
//! and consensus agnostic so they remain stable even if upstream APIs change.

use std::{
    sync::OnceLock,
    time::{Duration, Instant},
};

/// Enables the Phase 0 instrumentation without enabling the experimental IBD v2
/// synchronization path itself.
pub const METRICS_ENV: &str = "KERYX_IBD_V2_METRICS";

static METRICS_ENABLED: OnceLock<bool> = OnceLock::new();

/// Returns whether the opt-in Phase 0 metrics are enabled for this process.
///
/// The value is read once so hot IBD paths never repeatedly query the process
/// environment.
pub fn metrics_enabled() -> bool {
    *METRICS_ENABLED.get_or_init(|| {
        std::env::var(METRICS_ENV)
            .map(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
            .unwrap_or(false)
    })
}

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

    pub fn elapsed_seconds(&self) -> f64 {
        self.elapsed().as_secs_f64()
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
        let seconds = self.elapsed_seconds();
        if seconds == 0.0 { 0.0 } else { self.items as f64 / seconds }
    }

    pub fn megabytes_per_second(&self) -> f64 {
        let seconds = self.elapsed_seconds();
        if seconds == 0.0 { 0.0 } else { (self.bytes as f64 / 1_000_000.0) / seconds }
    }

    pub fn peer_wait_ratio(&self) -> f64 {
        let elapsed = self.elapsed_seconds();
        if elapsed == 0.0 { 0.0 } else { (self.peer_wait_time.as_secs_f64() / elapsed).clamp(0.0, 1.0) }
    }
}
