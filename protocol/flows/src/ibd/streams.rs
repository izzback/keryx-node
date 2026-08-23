//!
//! Logical stream abstractions used throughout the IBD negotiation protocols
//!

use crate::ibd_v2::metrics::{StageMetrics, metrics_enabled};
use keryx_consensus_core::{
    errors::consensus::ConsensusError,
    header::Header,
    tx::{TransactionOutpoint, UtxoEntry},
};
use keryx_core::{debug, info};
use keryx_p2p_lib::{
    IncomingRoute, Router,
    common::{DEFAULT_TIMEOUT, ProtocolError},
    convert::{header::HeaderFormat, header::Versioned, model::trusted::TrustedDataEntry},
    make_message,
    pb::{
        RequestNextHeadersMessage, RequestNextPruningPointAndItsAnticoneBlocksMessage, RequestNextPruningPointUtxoSetChunkMessage,
        kaspad_message::Payload,
    },
};
use std::{sync::Arc, time::Instant};
use tokio::time::timeout;

pub const IBD_BATCH_SIZE: usize = 99;

pub struct TrustedEntryStream<'a, 'b> {
    router: &'a Router,
    incoming_route: &'b mut IncomingRoute,
    header_format: HeaderFormat,
    i: usize,
    metrics: StageMetrics,
}

impl<'a, 'b> TrustedEntryStream<'a, 'b> {
    pub fn new(router: &'a Router, incoming_route: &'b mut IncomingRoute, header_format: HeaderFormat) -> Self {
        Self { router, incoming_route, header_format, i: 0, metrics: StageMetrics::new() }
    }

    pub async fn next(&mut self) -> Result<Option<TrustedDataEntry>, ProtocolError> {
        let wait_started = Instant::now();
        let received = timeout(DEFAULT_TIMEOUT, self.incoming_route.recv()).await;
        self.metrics.record_peer_wait_time(wait_started.elapsed());

        let res = match received {
            Ok(op) => {
                if let Some(msg) = op {
                    match msg.payload {
                        Some(Payload::BlockWithTrustedDataV4(payload)) => {
                            let entry: TrustedDataEntry = Versioned(self.header_format, payload).try_into()?;
                            if entry.block.is_header_only() {
                                Err(ProtocolError::OtherOwned(format!("trusted entry block {} is header only", entry.block.hash())))
                            } else {
                                Ok(Some(entry))
                            }
                        }
                        Some(Payload::DoneBlocksWithTrustedData(_)) => {
                            debug!("trusted entry stream completed after {} items", self.i);
                            if metrics_enabled() {
                                info!(
                                    "IBD-V2-METRICS: stage=trusted-anticone complete=true items={} elapsed={:.3}s rate={:.2} items/s peer_wait={:.3}s peer_wait_pct={:.1}%",
                                    self.metrics.items,
                                    self.metrics.elapsed_seconds(),
                                    self.metrics.items_per_second(),
                                    self.metrics.peer_wait_time.as_secs_f64(),
                                    self.metrics.peer_wait_ratio() * 100.0
                                );
                            }
                            Ok(None)
                        }
                        _ => Err(ProtocolError::UnexpectedMessage(
                            stringify!(Payload::BlockWithTrustedDataV4 | Payload::DoneBlocksWithTrustedData),
                            msg.payload.as_ref().map(|v| v.into()),
                        )),
                    }
                } else {
                    Err(ProtocolError::ConnectionClosed)
                }
            }
            Err(_) => Err(ProtocolError::Timeout(DEFAULT_TIMEOUT)),
        };

        if matches!(res, Ok(Some(_))) {
            self.metrics.record_transfer(1, 0);
        }

        // Request the next batch only if the stream is still live
        if let Ok(Some(_)) = res {
            self.i += 1;
            if self.i.is_multiple_of(IBD_BATCH_SIZE) {
                info!("Downloaded {} blocks from the pruning point anticone", self.i - 1);
                if metrics_enabled() {
                    info!(
                        "IBD-V2-METRICS: stage=trusted-anticone items={} elapsed={:.3}s rate={:.2} items/s peer_wait={:.3}s peer_wait_pct={:.1}%",
                        self.metrics.items,
                        self.metrics.elapsed_seconds(),
                        self.metrics.items_per_second(),
                        self.metrics.peer_wait_time.as_secs_f64(),
                        self.metrics.peer_wait_ratio() * 100.0
                    );
                }
                self.router
                    .enqueue(make_message!(
                        Payload::RequestNextPruningPointAndItsAnticoneBlocks,
                        RequestNextPruningPointAndItsAnticoneBlocksMessage {}
                    ))
                    .await?;
            }
        }

        res
    }
}

/// A chunk of headers
pub type HeadersChunk = Vec<Arc<Header>>;

pub struct HeadersChunkStream<'a, 'b> {
    router: &'a Router,
    incoming_route: &'b mut IncomingRoute,
    header_format: HeaderFormat,
    i: usize,
    metrics: StageMetrics,
}

impl<'a, 'b> HeadersChunkStream<'a, 'b> {
    pub fn new(router: &'a Router, incoming_route: &'b mut IncomingRoute, header_format: HeaderFormat) -> Self {
        Self { router, incoming_route, header_format, i: 0, metrics: StageMetrics::new() }
    }

    pub async fn next(&mut self) -> Result<Option<HeadersChunk>, ProtocolError> {
        let wait_started = Instant::now();
        let received = timeout(DEFAULT_TIMEOUT, self.incoming_route.recv()).await;
        self.metrics.record_peer_wait_time(wait_started.elapsed());

        let res = match received {
            Ok(op) => {
                if let Some(msg) = op {
                    match msg.payload {
                        Some(Payload::BlockHeaders(payload)) => {
                            if payload.block_headers.is_empty() {
                                // The syncer should have sent a done message if the search completed, and not an empty list
                                Err(ProtocolError::Other("Received an empty headers message"))
                            } else {
                                Ok(Some(Versioned(self.header_format, payload).try_into()?))
                            }
                        }
                        Some(Payload::DoneHeaders(_)) => {
                            debug!("headers chunk stream completed after {} chunks", self.i);
                            if metrics_enabled() {
                                info!(
                                    "IBD-V2-METRICS: stage=headers-stream complete=true chunks={} headers={} elapsed={:.3}s rate={:.2} headers/s peer_wait={:.3}s peer_wait_pct={:.1}%",
                                    self.i,
                                    self.metrics.items,
                                    self.metrics.elapsed_seconds(),
                                    self.metrics.items_per_second(),
                                    self.metrics.peer_wait_time.as_secs_f64(),
                                    self.metrics.peer_wait_ratio() * 100.0
                                );
                            }
                            Ok(None)
                        }
                        _ => Err(ProtocolError::UnexpectedMessage(
                            stringify!(Payload::BlockHeaders | Payload::DoneHeaders),
                            msg.payload.as_ref().map(|v| v.into()),
                        )),
                    }
                } else {
                    Err(ProtocolError::ConnectionClosed)
                }
            }
            Err(_) => Err(ProtocolError::Timeout(DEFAULT_TIMEOUT)),
        };

        if let Ok(Some(chunk)) = &res {
            self.metrics.record_transfer(chunk.len() as u64, 0);
        }

        // Request the next batch only if the stream is still live
        if let Ok(Some(_)) = res {
            self.i += 1;
            self.router.enqueue(make_message!(Payload::RequestNextHeaders, RequestNextHeadersMessage {})).await?;
        }

        res
    }
}

/// A chunk of UTXOs
pub type UtxosetChunk = Vec<(TransactionOutpoint, UtxoEntry)>;

pub struct PruningPointUtxosetChunkStream<'a, 'b> {
    router: &'a Router,
    incoming_route: &'b mut IncomingRoute,
    i: usize, // Chunk index
    utxo_count: usize,
    metrics: StageMetrics,
}

impl<'a, 'b> PruningPointUtxosetChunkStream<'a, 'b> {
    pub fn new(router: &'a Router, incoming_route: &'b mut IncomingRoute) -> Self {
        Self { router, incoming_route, i: 0, utxo_count: 0, metrics: StageMetrics::new() }
    }

    pub async fn next(&mut self) -> Result<Option<UtxosetChunk>, ProtocolError> {
        let wait_started = Instant::now();
        let received = timeout(DEFAULT_TIMEOUT, self.incoming_route.recv()).await;
        self.metrics.record_peer_wait_time(wait_started.elapsed());

        let res: Result<Option<UtxosetChunk>, ProtocolError> = match received {
            Ok(op) => {
                if let Some(msg) = op {
                    match msg.payload {
                        Some(Payload::PruningPointUtxoSetChunk(payload)) => Ok(Some(payload.try_into()?)),
                        Some(Payload::DonePruningPointUtxoSetChunks(_)) => {
                            info!("Finished receiving the UTXO set. Total UTXOs: {}", self.utxo_count);
                            if metrics_enabled() {
                                info!(
                                    "IBD-V2-METRICS: stage=utxo-stream complete=true chunks={} utxos={} elapsed={:.3}s rate={:.2} utxos/s peer_wait={:.3}s peer_wait_pct={:.1}%",
                                    self.i,
                                    self.metrics.items,
                                    self.metrics.elapsed_seconds(),
                                    self.metrics.items_per_second(),
                                    self.metrics.peer_wait_time.as_secs_f64(),
                                    self.metrics.peer_wait_ratio() * 100.0
                                );
                            }
                            Ok(None)
                        }
                        Some(Payload::UnexpectedPruningPoint(_)) => {
                            // Although this can happen also to an honest syncer (if his pruning point moves during the sync),
                            // we prefer erring and disconnecting to avoid possible exploits by a syncer repeating this failure
                            Err(ProtocolError::ConsensusError(ConsensusError::UnexpectedPruningPoint))
                        }
                        _ => Err(ProtocolError::UnexpectedMessage(
                            stringify!(
                                Payload::PruningPointUtxoSetChunk
                                    | Payload::DonePruningPointUtxoSetChunks
                                    | Payload::UnexpectedPruningPoint
                            ),
                            msg.payload.as_ref().map(|v| v.into()),
                        )),
                    }
                } else {
                    Err(ProtocolError::ConnectionClosed)
                }
            }
            Err(_) => Err(ProtocolError::Timeout(DEFAULT_TIMEOUT)),
        };

        // Request the next batch only if the stream is still live
        if let Ok(Some(chunk)) = res {
            self.i += 1;
            self.utxo_count += chunk.len();
            self.metrics.record_transfer(chunk.len() as u64, 0);
            if self.i.is_multiple_of(IBD_BATCH_SIZE) {
                info!("Received {} UTXO set chunks so far, totaling in {} UTXOs", self.i, self.utxo_count);
                if metrics_enabled() {
                    info!(
                        "IBD-V2-METRICS: stage=utxo-stream chunks={} utxos={} elapsed={:.3}s rate={:.2} utxos/s peer_wait={:.3}s peer_wait_pct={:.1}%",
                        self.i,
                        self.metrics.items,
                        self.metrics.elapsed_seconds(),
                        self.metrics.items_per_second(),
                        self.metrics.peer_wait_time.as_secs_f64(),
                        self.metrics.peer_wait_ratio() * 100.0
                    );
                }
                self.router
                    .enqueue(make_message!(
                        Payload::RequestNextPruningPointUtxoSetChunk,
                        RequestNextPruningPointUtxoSetChunkMessage {}
                    ))
                    .await?;
            }
            Ok(Some(chunk))
        } else {
            res
        }
    }
}
