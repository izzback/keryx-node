//! Narrow compatibility boundary between IBD v2 and Keryx upstream APIs.
//!
//! Upstream-facing consensus, storage and P2P calls should be concentrated in
//! this module whenever practical. This keeps future Keryx updates from leaking
//! API churn throughout the IBD v2 implementation.

/// Keryx release used as the original IBD v2 development baseline.
pub const BASELINE_RELEASE: &str = "v1.5.4";

/// Exact upstream commit used by `ibd-v2-base-v1.5.4`.
pub const BASELINE_COMMIT: &str = "e97dc268b2f7eb16ae761a37c79080a5c5c46ddc";

/// Compatibility metadata exposed for diagnostics and future IBD v2 metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompatibilityBaseline {
    pub release: &'static str,
    pub commit: &'static str,
}

pub const fn baseline() -> CompatibilityBaseline {
    CompatibilityBaseline { release: BASELINE_RELEASE, commit: BASELINE_COMMIT }
}
