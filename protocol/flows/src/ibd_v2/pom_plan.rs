//! PoM-aware IBD body planning.
//!
//! This module only classifies body targets. It deliberately performs no network requests,
//! persistence, proof decoding, or consensus validation so Phase 5 can introduce PoM-aware
//! planning without changing legacy IBD behaviour in the same micro-step.

use keryx_consensus_core::config::params::POM_PROOF_SERVE_DEPTH_DAA;

/// Proof material required for an IBD body target.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PomBodyPlan {
    /// The block predates PoM activation, so no PoM proof or tier is required.
    PrePom,
    /// The block is PoM-era but older than the proof-serving horizon.
    ///
    /// Full possession proofs are intentionally unavailable here; only the persisted tier metadata
    /// is relevant to later reward-routing reconstruction.
    HistoricalPomTierOnly,
    /// The block is PoM-era and still inside the proof-serving horizon.
    RecentPomProofRequired,
}

/// Classifies one body target without performing any I/O or mutating validation state.
///
/// `pom_active` must be evaluated for the target block's own DAA score by the caller. Historical
/// PoM starts strictly *beyond* [`POM_PROOF_SERVE_DEPTH_DAA`], matching the existing serving and
/// retention boundary: a delta exactly equal to the horizon is still recent and proof-required.
#[must_use]
pub fn classify_pom_body(pom_active: bool, block_daa: u64, high_daa: u64) -> PomBodyPlan {
    if !pom_active {
        PomBodyPlan::PrePom
    } else if high_daa.saturating_sub(block_daa) > POM_PROOF_SERVE_DEPTH_DAA {
        PomBodyPlan::HistoricalPomTierOnly
    } else {
        PomBodyPlan::RecentPomProofRequired
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_POM_ACTIVATION_DAA: u64 = 37_780_000;

    fn classify_at(block_daa: u64, high_daa: u64) -> PomBodyPlan {
        classify_pom_body(block_daa >= TEST_POM_ACTIVATION_DAA, block_daa, high_daa)
    }

    #[test]
    fn pre_pom_block_never_requires_a_proof() {
        let block_daa = TEST_POM_ACTIVATION_DAA - 1;
        let high_daa = block_daa + POM_PROOF_SERVE_DEPTH_DAA + 10_000;

        assert_eq!(classify_at(block_daa, high_daa), PomBodyPlan::PrePom);
    }

    #[test]
    fn pom_block_beyond_serve_depth_is_historical_tier_only() {
        let block_daa = TEST_POM_ACTIVATION_DAA;
        let high_daa = block_daa + POM_PROOF_SERVE_DEPTH_DAA + 1;

        assert_eq!(classify_at(block_daa, high_daa), PomBodyPlan::HistoricalPomTierOnly);
    }

    #[test]
    fn pom_block_exactly_at_serve_depth_stays_proof_required() {
        let block_daa = TEST_POM_ACTIVATION_DAA;
        let high_daa = block_daa + POM_PROOF_SERVE_DEPTH_DAA;

        assert_eq!(classify_at(block_daa, high_daa), PomBodyPlan::RecentPomProofRequired);
    }

    #[test]
    fn pom_block_inside_serve_depth_is_proof_required() {
        let block_daa = TEST_POM_ACTIVATION_DAA + 1;
        let high_daa = block_daa + POM_PROOF_SERVE_DEPTH_DAA - 1;

        assert_eq!(classify_at(block_daa, high_daa), PomBodyPlan::RecentPomProofRequired);
    }

    #[test]
    fn block_ahead_of_high_daa_saturates_to_recent() {
        let high_daa = TEST_POM_ACTIVATION_DAA;
        let block_daa = high_daa + 1;

        assert_eq!(classify_at(block_daa, high_daa), PomBodyPlan::RecentPomProofRequired);
    }
}
