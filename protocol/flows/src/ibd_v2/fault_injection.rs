//! Explicit, opt-in crash injection for Phase 3 recovery testing.
//!
//! This is intentionally inert unless IBD v2 itself is enabled AND the dedicated
//! fault-injection switch is truthy. Production users therefore cannot trigger a
//! crash merely by setting a point name accidentally.

pub const ENABLE_ENV: &str = "KERYX_IBD_V2_FAULT_INJECTION";
pub const POINT_ENV: &str = "KERYX_IBD_V2_FAULT_POINT";

fn truthy(value: &str) -> bool {
    matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on")
}

pub fn requested(point: &str) -> bool {
    if !super::enabled_from_env() {
        return false;
    }
    let enabled = std::env::var(ENABLE_ENV).map(|value| truthy(&value)).unwrap_or(false);
    if !enabled {
        return false;
    }
    std::env::var(POINT_ENV).map(|value| value.trim().eq_ignore_ascii_case(point)).unwrap_or(false)
}

/// Abort the whole process at an exact durability boundary when explicitly requested.
/// `abort()` is deliberate: Phase 3 needs to prove recovery after a hard process loss,
/// without graceful shutdown handlers being given a chance to repair state.
pub fn crash_if_requested(point: &'static str) {
    if requested(point) {
        keryx_core::warn!("IBD v2 fault injection: aborting at {}", point);
        std::process::abort();
    }
}

#[cfg(test)]
mod tests {
    use super::truthy;

    #[test]
    fn truthy_parser_is_strict_and_case_insensitive() {
        for value in ["1", "true", "TRUE", " yes ", "On"] {
            assert!(truthy(value));
        }
        for value in ["", "0", "false", "enabled", "2"] {
            assert!(!truthy(value));
        }
    }
}
