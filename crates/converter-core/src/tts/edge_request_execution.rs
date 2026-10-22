//! One request attempt/retry owner retains permits, feedback and telemetry.
use super::edge_protocol::{
    adjust_edge_clock_skew, frame_path, parse_audio_frame, protocol_request, protocol_timestamp,
    random_id, request_url, speech_config, ssml_frame,
};
use super::{
    EdgeError, EdgeTransport, EdgeTtsClient, RequestPermits, RetryCategory, TelemetryEvent,
};
use crate::adaptive::ProviderFailure;
use futures_util::{SinkExt, StreamExt};
use http::Request;
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

impl<T: EdgeTransport + 'static> EdgeTtsClient<T> {
    pub(super) async fn synthesize_request(
        &self,
        ssml: &str,
        chars: usize,
        chunk_index: usize,
        total_chunks: usize,
        mut initial_permits: Option<RequestPermits>,
    ) -> Result<Vec<u8>, EdgeError> {
        let request_id = random_id();
        let mut retries = 0;
        loop {
            let RequestPermits {
                local: local_permit,
                adaptive: permit,
            } = match initial_permits.take() {
                Some(permits) => permits,
                None => self.acquire_request_permits().await?,
            };
            let connection_id = random_id();
            let url = request_url(
                &self.config.endpoint,
                &connection_id,
                &self.config.trusted_client_token,
            )?;
            let request = protocol_request(url)?;
            self.emit(TelemetryEvent::RequestStarted {
                request_id: request_id.clone(),
                chars,
            });
            // Measure provider service time only. Queueing behind local
            // concurrency or adaptive cooldown is not provider slowness.
            let request_started = Instant::now();
            match timeout(
                self.config.timeout,
                self.run_request(request.clone(), &request_id, ssml),
            )
            .await
            {
                Ok(Ok(audio)) => {
                    let elapsed = request_started.elapsed();
                    if let Some(controller) = &self.adaptive {
                        controller.observe_success(chars, elapsed, retries);
                        let snapshot = controller.snapshot();
                        self.emit(TelemetryEvent::ChunkMetrics {
                            provider: "edge".into(),
                            chunk_index,
                            total_chunks,
                            chars,
                            elapsed_ms: elapsed.as_millis().min(u64::MAX as u128) as u64,
                            chars_per_second: chars as f64 / elapsed.as_secs_f64().max(0.001),
                            retries,
                            chunk_limit: snapshot.chunk_chars,
                            max_in_flight: snapshot.max_in_flight,
                            cooldown_ms: snapshot.cooldown_remaining.as_millis() as u64,
                            result: "success".into(),
                        });
                    }
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFinished {
                        request_id: request_id.clone(),
                        bytes: audio.len(),
                        retries,
                    });
                    return Ok(audio);
                }
                Ok(Err(error))
                    if error.retry_category().retryable() && retries < self.config.max_retries =>
                {
                    let category = error.retry_category();
                    retries += 1;
                    self.observe_failure(
                        &error,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category,
                        retries,
                    });
                    if self.adaptive.is_none() {
                        tokio::time::sleep(Duration::from_secs(
                            2u64.saturating_pow(retries as u32),
                        ))
                        .await;
                    }
                }
                Ok(Err(error @ EdgeError::Forbidden { .. }))
                    if retries == 0 && retries < self.config.max_retries =>
                {
                    let corrected = match &error {
                        EdgeError::Forbidden { server_date, .. } => server_date
                            .as_deref()
                            .and_then(|date| adjust_edge_clock_skew(date).ok())
                            .is_some(),
                        _ => false,
                    };
                    if corrected {
                        retries = 1;
                        drop(local_permit);
                        drop(permit);
                        continue;
                    }
                    self.observe_failure(
                        &error,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: RetryCategory::Permanent,
                        retries,
                    });
                    return Err(error);
                }
                Ok(Err(error)) => {
                    self.observe_failure(
                        &error,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: error.retry_category(),
                        retries,
                    });
                    return Err(error);
                }
                Err(_) if retries < self.config.max_retries => {
                    retries += 1;
                    self.observe_failure(
                        &EdgeError::Timeout,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: RetryCategory::Timeout,
                        retries,
                    });
                    if self.adaptive.is_none() {
                        tokio::time::sleep(Duration::from_secs(
                            2u64.saturating_pow(retries as u32),
                        ))
                        .await;
                    }
                }
                Err(_) => {
                    self.observe_failure(
                        &EdgeError::Timeout,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    drop(local_permit);
                    drop(permit);
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: RetryCategory::Timeout,
                        retries,
                    });
                    self.emit(TelemetryEvent::Cancelled {
                        request_id: request_id.clone(),
                    });
                    return Err(EdgeError::Timeout);
                }
            }
        }
    }

    pub(super) async fn acquire_request_permits(&self) -> Result<RequestPermits, EdgeError> {
        let local = Arc::clone(&self.limiter)
            .acquire_owned()
            .await
            .map_err(|_| EdgeError::Cancelled)?;
        let adaptive = match &self.adaptive {
            Some(controller) => Some(controller.acquire_request().await),
            None => None,
        };
        Ok(RequestPermits { local, adaptive })
    }

    pub(super) fn observe_failure(
        &self,
        error: &EdgeError,
        chars: usize,
        chunk_index: usize,
        total_chunks: usize,
        retries: usize,
        elapsed: Duration,
    ) {
        let Some(controller) = &self.adaptive else {
            return;
        };
        if matches!(error, EdgeError::Forbidden { .. }) {
            return;
        }
        let failure = match error {
            EdgeError::RateLimited { retry_after, .. } => ProviderFailure::Throttled {
                retry_after: *retry_after,
            },
            EdgeError::Timeout => ProviderFailure::Timeout,
            _ => ProviderFailure::Transient,
        };
        controller.observe_failure(failure);
        let snapshot = controller.snapshot();
        self.emit(TelemetryEvent::ChunkMetrics {
            provider: "edge".into(),
            chunk_index,
            total_chunks,
            chars,
            elapsed_ms: elapsed.as_millis().min(u64::MAX as u128) as u64,
            chars_per_second: chars as f64 / elapsed.as_secs_f64().max(0.001),
            retries,
            chunk_limit: snapshot.chunk_chars,
            max_in_flight: snapshot.max_in_flight,
            cooldown_ms: snapshot.cooldown_remaining.as_millis() as u64,
            result: format!("pressure:{:?}", error.retry_category()),
        });
    }

    pub(super) async fn run_request(
        &self,
        request: Request<()>,
        request_id: &str,
        ssml: &str,
    ) -> Result<Vec<u8>, EdgeError> {
        let mut socket = self.transport.connect(request).await?;
        let speech_timestamp = protocol_timestamp();
        socket
            .send(Message::Text(
                speech_config(&speech_timestamp, &self.config.output_format).into(),
            ))
            .await
            .map_err(|e| EdgeError::Transport(e.to_string()))?;
        socket
            .send(Message::Text(
                ssml_frame(request_id, &protocol_timestamp(), ssml).into(),
            ))
            .await
            .map_err(|e| EdgeError::Transport(e.to_string()))?;
        let receive = async {
            let mut audio = Vec::new();
            while let Some(message) = socket.next().await {
                match message.map_err(|e| EdgeError::Transport(e.to_string()))? {
                    Message::Text(text) => match frame_path(&text).as_deref() {
                        Some("turn.end") => {
                            return if audio.is_empty() {
                                Err(EdgeError::NoAudio)
                            } else {
                                Ok(audio)
                            };
                        }
                        Some("turn.start") | Some("response") | Some("audio.metadata") => {}
                        Some(path) => {
                            return Err(EdgeError::Protocol(format!(
                                "Edge returned unexpected text frame {path}"
                            )));
                        }
                        None if {
                            let lower = text.to_ascii_lowercase();
                            lower.contains("429") || lower.contains("toomanyrequests")
                        } =>
                        {
                            return Err(EdgeError::RateLimited {
                                status: 429,
                                retry_after: None,
                            });
                        }
                        None if text.to_ascii_lowercase().contains("error") => {
                            return Err(EdgeError::Protocol(format!(
                                "Edge returned an error frame: {text}"
                            )));
                        }
                        None => {}
                    },
                    Message::Binary(frame) => {
                        let payload = parse_audio_frame(&frame)?;
                        if !payload.is_empty() {
                            self.emit(TelemetryEvent::AudioFrame {
                                request_id: request_id.into(),
                                bytes: payload.len(),
                            });
                            audio.extend_from_slice(&payload);
                        }
                    }
                    Message::Close(frame) => {
                        let reason = frame
                            .as_ref()
                            .map(|value| value.reason.to_string())
                            .filter(|value| !value.is_empty())
                            .unwrap_or_else(|| "no close reason".to_owned());
                        return Err(EdgeError::Transport(format!(
                            "Edge closed the WebSocket: {reason}"
                        )));
                    }
                    _ => {}
                }
            }
            Err(EdgeError::Transport("socket ended before turn.end".into()))
        };
        receive.await
    }

    pub(super) fn emit(&self, event: TelemetryEvent) {
        if let Some(callback) = &self.telemetry {
            callback(event);
        }
    }
}
