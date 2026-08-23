use std::time::{Duration, Instant};

use crate::ibd_v2::metrics::{StageMetrics, metrics_enabled};
use chrono::{Local, LocalResult, TimeZone};
use keryx_core::info;

/// Minimum number of items to report
const REPORT_BATCH_GRANULARITY: usize = 500;
/// Maximum time to go without report
const REPORT_TIME_GRANULARITY: Duration = Duration::from_secs(2);

pub struct ProgressReporter {
    low_daa_score: u64,
    high_daa_score: u64,
    object_name: &'static str,
    last_reported_percent: i32,
    last_log_time: Instant,
    current_batch: usize,
    processed: usize,
    metrics: StageMetrics,
}

impl ProgressReporter {
    pub fn new(low_daa_score: u64, mut high_daa_score: u64, object_name: &'static str) -> Self {
        if high_daa_score <= low_daa_score {
            // Avoid a zero or negative diff
            high_daa_score = low_daa_score + 1;
        }
        Self {
            low_daa_score,
            high_daa_score,
            object_name,
            last_reported_percent: 0,
            last_log_time: Instant::now(),
            current_batch: 0,
            processed: 0,
            metrics: StageMetrics::new(),
        }
    }

    pub fn report(&mut self, processed_delta: usize, current_daa_score: u64, current_timestamp: u64) {
        self.metrics.record_transfer(processed_delta as u64, 0);
        self.current_batch += processed_delta;
        let now = Instant::now();
        if now - self.last_log_time < REPORT_TIME_GRANULARITY && self.current_batch < REPORT_BATCH_GRANULARITY && self.processed > 0 {
            return;
        }
        self.processed += self.current_batch;
        self.current_batch = 0;
        if current_daa_score > self.high_daa_score {
            self.high_daa_score = current_daa_score + 1; // + 1 for keeping it at 99%
        }
        let relative_daa_score = current_daa_score.saturating_sub(self.low_daa_score);
        let percent = ((relative_daa_score as f64 / (self.high_daa_score - self.low_daa_score) as f64) * 100.0) as i32;
        if percent > self.last_reported_percent {
            let date = match Local.timestamp_opt(current_timestamp as i64 / 1000, 1000 * (current_timestamp as u32 % 1000)) {
                LocalResult::None | LocalResult::Ambiguous(_, _) => "cannot parse date".into(),
                LocalResult::Single(date) => date.format("%Y-%m-%d %H:%M:%S.%3f:%z").to_string(),
            };
            info!("IBD: Processed {} {} ({}%) last block timestamp: {}", self.processed, self.object_name, percent, date);
            if metrics_enabled() {
                info!(
                    "IBD-V2-METRICS: stage={} items={} elapsed={:.3}s rate={:.2} items/s",
                    self.object_name,
                    self.metrics.items,
                    self.metrics.elapsed_seconds(),
                    self.metrics.items_per_second()
                );
            }
            self.last_reported_percent = percent;
        }
        self.last_log_time = now;
    }

    pub fn report_completion(mut self, processed_delta: usize) {
        self.metrics.record_transfer(processed_delta as u64, 0);
        self.processed += self.current_batch + processed_delta;
        info!("IBD: Processed {} {} (100%)", self.processed, self.object_name);
        if metrics_enabled() {
            info!(
                "IBD-V2-METRICS: stage={} complete=true items={} elapsed={:.3}s rate={:.2} items/s",
                self.object_name,
                self.metrics.items,
                self.metrics.elapsed_seconds(),
                self.metrics.items_per_second()
            );
        }
    }
}
