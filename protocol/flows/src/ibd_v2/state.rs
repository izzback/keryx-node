//! Independent IBD v2 stage state.
//!
//! Stages are deliberately tracked separately so a restart does not force the
//! node to repeat work that was already verified or committed.

use keryx_hashes::Hash;

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

/// Durable progress required to resume a service-state transfer safely.
///
/// `next_cursor` is the canonical row index the next peer must start serving
/// from. `last_row_fingerprint` anchors that cursor to actual content so a
/// resumed transfer can detect a peer whose row sequence differs before it
/// trusts the requested offset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServiceStateResumeMetadata {
    pub pruning_point: Hash,
    pub next_cursor: u64,
    pub chunk_count: u64,
    pub row_count: u64,
    pub last_row_fingerprint: Option<[u8; 32]>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceStateResumeError {
    EmptyChunk,
    NonAdvancingCursor { current: u64, next: u64 },
    CursorRowMismatch { expected: u64, next: u64 },
}

impl ServiceStateResumeMetadata {
    pub const fn new(pruning_point: Hash) -> Self {
        Self { pruning_point, next_cursor: 0, chunk_count: 0, row_count: 0, last_row_fingerprint: None }
    }

    pub fn can_resume_from(&self, pruning_point: Hash) -> bool {
        self.pruning_point == pruning_point && self.next_cursor > 0 && self.last_row_fingerprint.is_some()
    }

    /// Records a fully accepted chunk. Callers must persist the rows first and
    /// update this metadata only afterwards, so a crash can never advertise a
    /// cursor beyond durable data.
    pub fn record_chunk(
        &mut self,
        next_cursor: u64,
        rows_in_chunk: u64,
        last_row_fingerprint: [u8; 32],
    ) -> Result<(), ServiceStateResumeError> {
        if rows_in_chunk == 0 {
            return Err(ServiceStateResumeError::EmptyChunk);
        }
        if next_cursor <= self.next_cursor {
            return Err(ServiceStateResumeError::NonAdvancingCursor { current: self.next_cursor, next: next_cursor });
        }

        let expected = self.next_cursor.saturating_add(rows_in_chunk);
        if next_cursor != expected {
            return Err(ServiceStateResumeError::CursorRowMismatch { expected, next: next_cursor });
        }

        self.next_cursor = next_cursor;
        self.chunk_count = self.chunk_count.saturating_add(1);
        self.row_count = self.row_count.saturating_add(rows_in_chunk);
        self.last_row_fingerprint = Some(last_row_fingerprint);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{ServiceStateResumeError, ServiceStateResumeMetadata};
    use keryx_hashes::Hash;

    fn pruning_point(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    #[test]
    fn service_state_resume_metadata_advances_only_after_complete_chunks() {
        let pp = pruning_point(1);
        let mut metadata = ServiceStateResumeMetadata::new(pp);
        assert!(!metadata.can_resume_from(pp));

        metadata.record_chunk(10_000, 10_000, [7; 32]).unwrap();
        assert!(metadata.can_resume_from(pp));
        assert!(!metadata.can_resume_from(pruning_point(2)));
        assert_eq!(metadata.next_cursor, 10_000);
        assert_eq!(metadata.chunk_count, 1);
        assert_eq!(metadata.row_count, 10_000);
        assert_eq!(metadata.last_row_fingerprint, Some([7; 32]));

        metadata.record_chunk(10_123, 123, [8; 32]).unwrap();
        assert_eq!(metadata.next_cursor, 10_123);
        assert_eq!(metadata.chunk_count, 2);
        assert_eq!(metadata.row_count, 10_123);
        assert_eq!(metadata.last_row_fingerprint, Some([8; 32]));
    }

    #[test]
    fn service_state_resume_metadata_rejects_invalid_cursor_progress() {
        let mut metadata = ServiceStateResumeMetadata::new(pruning_point(1));

        assert_eq!(metadata.record_chunk(0, 0, [1; 32]), Err(ServiceStateResumeError::EmptyChunk));
        assert_eq!(metadata.record_chunk(9, 10, [1; 32]), Err(ServiceStateResumeError::CursorRowMismatch { expected: 10, next: 9 }));

        metadata.record_chunk(10, 10, [1; 32]).unwrap();
        assert_eq!(metadata.record_chunk(10, 1, [2; 32]), Err(ServiceStateResumeError::NonAdvancingCursor { current: 10, next: 10 }));
        assert_eq!(metadata.next_cursor, 10);
        assert_eq!(metadata.row_count, 10);
    }
}
