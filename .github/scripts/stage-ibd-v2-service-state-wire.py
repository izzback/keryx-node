from pathlib import Path

proto_path = Path("protocol/p2p/proto/p2p.proto")
flow_path = Path("protocol/flows/src/ibd/flow.rs")
server_path = Path("protocol/flows/src/v7/request_service_state.rs")

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

server_path.write_text(
    '''use crate::{flow_context::FlowContext, flow_trait::Flow};
use keryx_core::debug;
use keryx_hashes::{Hash, Hasher, MuHashElementHash};
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
            let actual = MuHashElementHash::hash(&rows[start - 1]).as_bytes();
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
