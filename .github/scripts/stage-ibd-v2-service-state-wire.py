from pathlib import Path

proto_path = Path("protocol/p2p/proto/p2p.proto")
flow_path = Path("protocol/flows/src/ibd/flow.rs")
server_path = Path("protocol/flows/src/v7/request_service_state.rs")
state_path = Path("protocol/flows/src/ibd_v2/state.rs")

proto = proto_path.read_text(encoding="utf-8")
old_proto = """message RequestServiceStateMessage {
  Hash pruningPointHash = 1;
}

message ServiceStateChunkMessage {
  repeated bytes rows = 1;
}

message DoneServiceStateChunksMessage {
}
"""
new_proto = """message RequestServiceStateMessage {
  Hash pruningPointHash = 1;
  optional uint64 startCursor = 2;
  optional bytes previousRowFingerprint = 3;
}

message ServiceStateChunkMessage {
  repeated bytes rows = 1;
  optional uint64 startCursor = 2;
  optional uint64 nextCursor = 3;
  Hash pruningPointHash = 4;
}

message DoneServiceStateChunksMessage {
  optional uint64 nextCursor = 1;
  Hash pruningPointHash = 2;
}
"""
if proto.count(old_proto) != 1:
    raise SystemExit("service-state proto anchor mismatch")
proto_path.write_text(proto.replace(old_proto, new_proto), encoding="utf-8")

flow = flow_path.read_text(encoding="utf-8")
old_request = "RequestServiceStateMessage { pruning_point_hash: Some(pruning_point.into()) }"
new_request = (
    "RequestServiceStateMessage { pruning_point_hash: Some(pruning_point.into()), "
    "start_cursor: None, previous_row_fingerprint: None }"
)
if flow.count(old_request) != 1:
    raise SystemExit("service-state requester anchor mismatch")
flow_path.write_text(flow.replace(old_request, new_request), encoding="utf-8")

state = state_path.read_text(encoding="utf-8")
old_import = "use keryx_hashes::Hash;"
new_import = "use keryx_hashes::{Hash, Hasher, MuHashElementHash};"
if state.count(old_import) != 1:
    raise SystemExit("service-state fingerprint import anchor mismatch")
state = state.replace(old_import, new_import)

error_anchor = """pub enum ServiceStateResumeError {
    EmptyChunk,
    NonAdvancingCursor { current: u64, next: u64 },
    CursorRowMismatch { expected: u64, next: u64 },
}

"""
helper = """pub enum ServiceStateResumeError {
    EmptyChunk,
    NonAdvancingCursor { current: u64, next: u64 },
    CursorRowMismatch { expected: u64, next: u64 },
}

/// Content anchor used when a service-state transfer resumes from another peer.
/// This deliberately reuses Keryx's MuHash element domain so both peers derive
/// the same 32-byte fingerprint from the exact canonical row bytes.
pub fn service_state_row_fingerprint(row: &[u8]) -> [u8; 32] {
    MuHashElementHash::hash(row).as_bytes()
}

"""
if state.count(error_anchor) != 1:
    raise SystemExit("service-state fingerprint helper anchor mismatch")
state = state.replace(error_anchor, helper)

mod_anchor = """mod tests {
    use super::{ServiceStateResumeError, ServiceStateResumeMetadata};
"""
mod_replacement = """mod tests {
    use super::{service_state_row_fingerprint, ServiceStateResumeError, ServiceStateResumeMetadata};
"""
if state.count(mod_anchor) != 1:
    raise SystemExit("service-state fingerprint test import anchor mismatch")
state = state.replace(mod_anchor, mod_replacement)

test_anchor = """    #[test]
    fn service_state_resume_metadata_advances_only_after_complete_chunks() {
"""
test_replacement = """    #[test]
    fn service_state_row_fingerprint_is_content_bound() {
        assert_eq!(service_state_row_fingerprint(b"row-a"), service_state_row_fingerprint(b"row-a"));
        assert_ne!(service_state_row_fingerprint(b"row-a"), service_state_row_fingerprint(b"row-b"));
    }

    #[test]
    fn service_state_resume_metadata_advances_only_after_complete_chunks() {
"""
if state.count(test_anchor) != 1:
    raise SystemExit("service-state fingerprint test anchor mismatch")
state_path.write_text(state.replace(test_anchor, test_replacement), encoding="utf-8")

server_path.write_text(
    '''use crate::{
    flow_context::FlowContext,
    flow_trait::Flow,
    ibd_v2::state::service_state_row_fingerprint,
};
use keryx_core::debug;
use keryx_hashes::Hash;
use keryx_p2p_lib::{
    IncomingRoute, Router,
    common::ProtocolError,
    dequeue, make_message,
    pb::{DoneServiceStateChunksMessage, ServiceStateChunkMessage, kaspad_message::Payload},
};
use std::sync::Arc;

/// Rows per chunk: canonical rows are small, so a chunk stays well under the
/// message size limit while avoiding excessive per-message overhead.
const SERVICE_STATE_CHUNK_ROWS: usize = 10_000;

pub struct RequestServiceStateFlow {
    ctx: FlowContext,
    router: Arc<Router>,
    incoming_route: IncomingRoute,
}

#[async_trait::async_trait]
impl Flow for RequestServiceStateFlow {
    fn router(&self) -> Option<Arc<Router>> {
        Some(self.router.clone())
    }

    async fn start(&mut self) -> Result<(), ProtocolError> {
        self.start_impl().await
    }
}

impl RequestServiceStateFlow {
    pub fn new(ctx: FlowContext, router: Arc<Router>, incoming_route: IncomingRoute) -> Self {
        Self { ctx, router, incoming_route }
    }

    async fn start_impl(&mut self) -> Result<(), ProtocolError> {
        loop {
            let request = dequeue!(self.incoming_route, Payload::RequestServiceState)?;
            let pruning_point: Hash = request.clone().try_into()?;
            let start_cursor = request.start_cursor.unwrap_or(0);
            self.handle_request(pruning_point, start_cursor, request.previous_row_fingerprint).await?
        }
    }

    async fn handle_request(
        &mut self,
        pruning_point: Hash,
        start_cursor: u64,
        previous_row_fingerprint: Option<Vec<u8>>,
    ) -> Result<(), ProtocolError> {
        let consensus = self.ctx.consensus();
        let session = consensus.session().await;
        let rows = session.async_get_service_state_rows(pruning_point).await?;
        drop(session);

        let start = usize::try_from(start_cursor).map_err(|_| ProtocolError::Other("service-state cursor does not fit usize"))?;
        if start > rows.len() {
            return Err(ProtocolError::Other("service-state cursor beyond available rows"));
        }

        if start == 0 {
            if previous_row_fingerprint.is_some() {
                return Err(ProtocolError::Other("service-state cursor zero must not include a previous-row fingerprint"));
            }
        } else {
            let expected = previous_row_fingerprint
                .ok_or(ProtocolError::Other("resumed service-state request missing previous-row fingerprint"))?;
            if expected.len() != 32 {
                return Err(ProtocolError::Other("invalid service-state previous-row fingerprint length"));
            }
            let actual = service_state_row_fingerprint(&rows[start - 1]);
            if expected.as_slice() != actual.as_slice() {
                return Err(ProtocolError::Other("service-state resume anchor mismatch"));
            }
        }

        debug!(
            "Serving {} service-state rows for pruning point {} from cursor {}",
            rows.len().saturating_sub(start),
            pruning_point,
            start_cursor
        );

        let mut cursor = start_cursor;
        for chunk in rows[start..].chunks(SERVICE_STATE_CHUNK_ROWS) {
            let chunk_start = cursor;
            cursor = cursor.saturating_add(chunk.len() as u64);
            self.router
                .enqueue(make_message!(
                    Payload::ServiceStateChunk,
                    ServiceStateChunkMessage {
                        rows: chunk.to_vec(),
                        start_cursor: Some(chunk_start),
                        next_cursor: Some(cursor),
                        pruning_point_hash: Some(pruning_point.into()),
                    }
                ))
                .await?;
        }
        self.router
            .enqueue(make_message!(
                Payload::DoneServiceStateChunks,
                DoneServiceStateChunksMessage {
                    next_cursor: Some(cursor),
                    pruning_point_hash: Some(pruning_point.into()),
                }
            ))
            .await?;
        Ok(())
    }
}
''',
    encoding="utf-8",
)
