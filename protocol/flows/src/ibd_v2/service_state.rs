use keryx_hashes::Hash;

use super::state::{ServiceStateResumeError, ServiceStateResumeMetadata, service_state_row_fingerprint};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceStateWireMode {
    Unknown,
    Legacy,
    Resumable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceStateWireError {
    IncompleteChunkMetadata,
    IncompleteDoneMetadata,
    MixedWireModes,
    WrongPruningPoint { expected: Hash, received: Hash },
    StartCursorMismatch { expected: u64, received: u64 },
    NextCursorMismatch { expected: u64, received: u64 },
    CursorOverflow,
    ResumeMetadata(ServiceStateResumeError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServiceStateWireTracker {
    metadata: ServiceStateResumeMetadata,
    mode: ServiceStateWireMode,
}

impl ServiceStateWireTracker {
    pub const fn new(pruning_point: Hash) -> Self {
        Self { metadata: ServiceStateResumeMetadata::new(pruning_point), mode: ServiceStateWireMode::Unknown }
    }

    pub const fn from_metadata(metadata: ServiceStateResumeMetadata) -> Self {
        Self { metadata, mode: ServiceStateWireMode::Unknown }
    }

    pub const fn metadata(&self) -> ServiceStateResumeMetadata {
        self.metadata
    }

    pub const fn mode(&self) -> ServiceStateWireMode {
        self.mode
    }

    pub fn accept_chunk(
        &mut self,
        pruning_point: Option<Hash>,
        start_cursor: Option<u64>,
        next_cursor: Option<u64>,
        rows: &[Vec<u8>],
    ) -> Result<(), ServiceStateWireError> {
        let metadata_count = pruning_point.is_some() as u8 + start_cursor.is_some() as u8 + next_cursor.is_some() as u8;

        if metadata_count == 0 {
            if self.mode == ServiceStateWireMode::Resumable {
                return Err(ServiceStateWireError::MixedWireModes);
            }
            self.mode = ServiceStateWireMode::Legacy;
            return Ok(());
        }
        if metadata_count != 3 {
            return Err(ServiceStateWireError::IncompleteChunkMetadata);
        }
        if self.mode == ServiceStateWireMode::Legacy {
            return Err(ServiceStateWireError::MixedWireModes);
        }

        let pruning_point = pruning_point.expect("metadata_count guarantees pruning point");
        if pruning_point != self.metadata.pruning_point {
            return Err(ServiceStateWireError::WrongPruningPoint {
                expected: self.metadata.pruning_point,
                received: pruning_point,
            });
        }

        let start_cursor = start_cursor.expect("metadata_count guarantees start cursor");
        if start_cursor != self.metadata.next_cursor {
            return Err(ServiceStateWireError::StartCursorMismatch { expected: self.metadata.next_cursor, received: start_cursor });
        }

        let rows_in_chunk = rows.len() as u64;
        let expected_next = start_cursor.checked_add(rows_in_chunk).ok_or(ServiceStateWireError::CursorOverflow)?;
        let next_cursor = next_cursor.expect("metadata_count guarantees next cursor");
        if next_cursor != expected_next {
            return Err(ServiceStateWireError::NextCursorMismatch { expected: expected_next, received: next_cursor });
        }

        let last_row = rows.last().ok_or(ServiceStateWireError::ResumeMetadata(ServiceStateResumeError::EmptyChunk))?;
        self.metadata
            .record_chunk(next_cursor, rows_in_chunk, service_state_row_fingerprint(last_row))
            .map_err(ServiceStateWireError::ResumeMetadata)?;
        self.mode = ServiceStateWireMode::Resumable;
        Ok(())
    }

    pub fn accept_done(
        &mut self,
        pruning_point: Option<Hash>,
        next_cursor: Option<u64>,
    ) -> Result<(), ServiceStateWireError> {
        match (pruning_point, next_cursor) {
            (None, None) => {
                if self.mode == ServiceStateWireMode::Resumable {
                    return Err(ServiceStateWireError::MixedWireModes);
                }
                self.mode = ServiceStateWireMode::Legacy;
                Ok(())
            }
            (Some(pruning_point), Some(next_cursor)) => {
                if self.mode == ServiceStateWireMode::Legacy {
                    return Err(ServiceStateWireError::MixedWireModes);
                }
                if pruning_point != self.metadata.pruning_point {
                    return Err(ServiceStateWireError::WrongPruningPoint {
                        expected: self.metadata.pruning_point,
                        received: pruning_point,
                    });
                }
                if next_cursor != self.metadata.next_cursor {
                    return Err(ServiceStateWireError::NextCursorMismatch {
                        expected: self.metadata.next_cursor,
                        received: next_cursor,
                    });
                }
                self.mode = ServiceStateWireMode::Resumable;
                Ok(())
            }
            _ => Err(ServiceStateWireError::IncompleteDoneMetadata),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ServiceStateWireError, ServiceStateWireMode, ServiceStateWireTracker};
    use keryx_hashes::Hash;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    #[test]
    fn resumable_chunks_advance_exactly() {
        let pp = hash(1);
        let mut tracker = ServiceStateWireTracker::new(pp);
        let first = vec![b"a".to_vec(), b"b".to_vec()];
        tracker.accept_chunk(Some(pp), Some(0), Some(2), &first).unwrap();
        let second = vec![b"c".to_vec()];
        tracker.accept_chunk(Some(pp), Some(2), Some(3), &second).unwrap();
        tracker.accept_done(Some(pp), Some(3)).unwrap();

        assert_eq!(tracker.mode(), ServiceStateWireMode::Resumable);
        assert_eq!(tracker.metadata().next_cursor, 3);
        assert_eq!(tracker.metadata().row_count, 3);
        assert_eq!(tracker.metadata().chunk_count, 2);
    }

    #[test]
    fn legacy_stream_remains_accepted() {
        let mut tracker = ServiceStateWireTracker::new(hash(1));
        tracker.accept_chunk(None, None, None, &[b"row".to_vec()]).unwrap();
        tracker.accept_done(None, None).unwrap();
        assert_eq!(tracker.mode(), ServiceStateWireMode::Legacy);
        assert_eq!(tracker.metadata().next_cursor, 0);
    }

    #[test]
    fn rejects_mixed_or_inconsistent_resumable_metadata() {
        let pp = hash(1);
        let mut tracker = ServiceStateWireTracker::new(pp);
        let rows = vec![b"a".to_vec()];

        assert_eq!(
            tracker.accept_chunk(Some(hash(2)), Some(0), Some(1), &rows),
            Err(ServiceStateWireError::WrongPruningPoint { expected: pp, received: hash(2) })
        );
        assert_eq!(
            tracker.accept_chunk(Some(pp), Some(1), Some(2), &rows),
            Err(ServiceStateWireError::StartCursorMismatch { expected: 0, received: 1 })
        );
        assert_eq!(
            tracker.accept_chunk(Some(pp), Some(0), Some(2), &rows),
            Err(ServiceStateWireError::NextCursorMismatch { expected: 1, received: 2 })
        );

        tracker.accept_chunk(Some(pp), Some(0), Some(1), &rows).unwrap();
        assert_eq!(tracker.accept_done(None, None), Err(ServiceStateWireError::MixedWireModes));
    }
}
