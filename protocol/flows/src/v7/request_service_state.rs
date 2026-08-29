use crate::{flow_context::FlowContext, flow_trait::Flow, ibd_v2::state::service_state_row_fingerprint};
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
    protocol_version: u32,
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
    pub fn new(ctx: FlowContext, router: Arc<Router>, incoming_route: IncomingRoute, protocol_version: u32) -> Self {
        Self { ctx, router, incoming_route, protocol_version }
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
        let handoff_daa = service_state_handoff_daa(self.protocol_version);
        let rows = session.async_get_service_state_rows(pruning_point, handoff_daa).await?;
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
                DoneServiceStateChunksMessage { next_cursor: Some(cursor), pruning_point_hash: Some(pruning_point.into()) }
            ))
            .await?;
        Ok(())
    }
}
/// Event-daa span above the pruning point a peer of `protocol_version` ships and accepts as
/// service-state handoff rows. Protocol v11+ transfers every flushed row; older peers retain the
/// bounded legacy handoff window.
pub fn service_state_handoff_daa(protocol_version: u32) -> u64 {
    if protocol_version >= 11 { u64::MAX } else { keryx_consensus_core::collateral::SERVICE_STATE_HANDOFF_DAA }
}

#[cfg(test)]
mod tests {
    use super::service_state_handoff_daa;

    #[test]
    fn v11_and_newer_take_the_full_flushed_service_state() {
        assert_eq!(service_state_handoff_daa(11), u64::MAX);
        assert_eq!(service_state_handoff_daa(12), u64::MAX);
    }

    #[test]
    fn pre_v11_keeps_the_legacy_handoff_window() {
        assert_eq!(service_state_handoff_daa(10), keryx_consensus_core::collateral::SERVICE_STATE_HANDOFF_DAA);
    }
}
