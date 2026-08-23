//! Independent IBD v2 stage state.
//!
//! Stages are deliberately tracked separately so a restart does not force the
//! node to repeat work that was already verified or committed.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stage {
    Headers,
    Pruning,
    Utxo,
    ServiceState,
    Pom,
    Bodies,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StageStatus {
    NotStarted,
    Downloading,
    Verified,
    Committed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StageProgress {
    pub stage: Stage,
    pub status: StageStatus,
    pub completed_units: u64,
    pub total_units: Option<u64>,
}

impl StageProgress {
    pub const fn new(stage: Stage) -> Self {
        Self { stage, status: StageStatus::NotStarted, completed_units: 0, total_units: None }
    }

    pub const fn with_status(mut self, status: StageStatus) -> Self {
        self.status = status;
        self
    }

    pub const fn with_progress(mut self, completed_units: u64, total_units: Option<u64>) -> Self {
        self.completed_units = completed_units;
        self.total_units = total_units;
        self
    }
}
