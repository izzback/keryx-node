//! Keryx IBD v2.
//!
//! This module is intentionally isolated from the legacy `ibd` implementation.
//! During the early project phases it must not change consensus validity rules or
//! replace legacy IBD by default.

pub mod checkpoint;
pub mod compat;
pub mod fault_injection;
pub mod metrics;
pub mod service_state;
pub mod service_state_recovery;
pub mod service_state_spool;
pub mod state;

/// Runtime opt-in used while IBD v2 is experimental.
pub const ENABLE_ENV: &str = "KERYX_IBD_V2";

/// Returns whether the experimental IBD v2 path was explicitly requested.
///
/// Keeping this opt-in separate from legacy IBD allows the project to evolve on
/// a frozen Keryx baseline while upstream releases continue independently.
pub fn enabled_from_env() -> bool {
    std::env::var(ENABLE_ENV)
        .map(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}
