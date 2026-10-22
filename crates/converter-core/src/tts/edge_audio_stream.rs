//! Ordered text dispatch, adaptive pending capacity and playback chunk delivery.
use super::edge_protocol::{make_ssml_escaped, next_protocol_chunk};
use super::REFERENCE_MAX_RETRIES;
use super::{
    EdgeConfig, EdgeError, EdgeTransport, EdgeTtsClient, RequestPermits, RetryCategory, Telemetry,
};
use crate::adaptive::AdaptiveThroughputController;
use futures_util::{stream::FuturesUnordered, StreamExt};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::time::timeout;

pub(super) const REFERENCE_MAX_DEADLINE: Duration = Duration::from_secs(3_600);
pub async fn synthesize_with_reference_client(
    text: &str,
    voice: &str,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
) -> Result<Vec<u8>, EdgeError> {
    synthesize_with_reference_client_chunks(text, voice, adaptive, telemetry, |_, _| true).await
}

pub async fn synthesize_with_reference_client_chunks<F>(
    text: &str,
    voice: &str,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
    on_chunk: F,
) -> Result<Vec<u8>, EdgeError>
where
    F: FnMut(usize, &[u8]) -> bool,
{
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut config = EdgeConfig::new(voice)?;
    config.chunk_chars = adaptive.snapshot().chunk_chars;
    config.concurrency = adaptive.snapshot().max_in_flight;
    config.timeout = Duration::from_secs(if cfg!(target_os = "android") { 60 } else { 25 });
    let total_timeout = reference_synthesis_timeout_for_text(text.len());
    let client = EdgeTtsClient::with_adaptive_controller(config, adaptive, telemetry);
    let result = timeout(total_timeout, client.synthesize_with_chunks(text, on_chunk))
        .await
        .map_err(|_| EdgeError::Timeout)?
        .map_err(map_reference_synthesis_error)?;
    Ok(result)
}

pub async fn synthesize_with_reference_client_stream<F>(
    text: &str,
    voice: &str,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
    on_chunk: F,
) -> Result<(), EdgeError>
where
    F: FnMut(usize, &[u8]) -> bool,
{
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut config = EdgeConfig::new(voice)?;
    config.chunk_chars = adaptive.snapshot().chunk_chars;
    config.concurrency = adaptive.snapshot().max_in_flight;
    config.timeout = Duration::from_secs(if cfg!(target_os = "android") { 60 } else { 25 });
    let total_timeout = reference_synthesis_timeout_for_text(text.len());
    let client = EdgeTtsClient::with_adaptive_controller(config, adaptive, telemetry);
    timeout(total_timeout, client.stream_with_chunks(text, on_chunk))
        .await
        .map_err(|_| EdgeError::Timeout)?
        .map_err(map_reference_synthesis_error)
}

pub(super) fn map_reference_synthesis_error(error: EdgeError) -> EdgeError {
    match error {
        EdgeError::Timeout | EdgeError::RateLimited { .. } | EdgeError::Forbidden { .. } => error,
        EdgeError::Cancelled => EdgeError::Cancelled,
        other => EdgeError::Transport(other.to_string()),
    }
}

pub(crate) fn reference_synthesis_timeout_for_text(text_bytes: usize) -> Duration {
    reference_synthesis_timeout(
        text_bytes,
        crate::adaptive::MIN_CHUNK_CHARS,
        Duration::from_secs(if cfg!(target_os = "android") { 60 } else { 25 }),
        REFERENCE_MAX_RETRIES,
        REFERENCE_MAX_DEADLINE,
    )
}

pub(super) fn reference_synthesis_timeout(
    text_bytes: usize,
    chunk_bytes: usize,
    request_timeout: Duration,
    max_retries: usize,
    maximum: Duration,
) -> Duration {
    let chunks = text_bytes.div_ceil(chunk_bytes.max(1)).max(1) as u64;
    let attempts = max_retries as u64 + 1;
    let retry_backoff = (1..=max_retries)
        .map(|retry| 2u64.saturating_pow(retry.min(10) as u32))
        .sum::<u64>();
    // A request can spend its entire timeout in DNS/TLS negotiation on Apple
    // hosts before audio starts. Budget each chunk independently, with enough
    // room for a successful response after a failed attempt and backoff.
    let per_chunk = request_timeout
        .as_secs()
        .saturating_mul(attempts)
        .saturating_add(retry_backoff)
        .saturating_add(30);
    let budget = per_chunk.saturating_mul(chunks).saturating_add(10);
    Duration::from_secs(budget.min(maximum.as_secs()))
}
impl<T: EdgeTransport + 'static> EdgeTtsClient<T> {
    pub async fn synthesize(&self, text: &str) -> Result<Vec<u8>, EdgeError> {
        self.synthesize_with_chunks(text, |_, _| true).await
    }

    /// Synthesize ordered protocol chunks and let a playback consumer take
    /// ownership before the complete chapter buffer is assembled.
    pub async fn synthesize_with_chunks<F>(
        &self,
        text: &str,
        on_chunk: F,
    ) -> Result<Vec<u8>, EdgeError>
    where
        F: FnMut(usize, &[u8]) -> bool,
    {
        self.synthesize_with_chunks_mode(text, true, on_chunk)
            .await?
            .ok_or(EdgeError::NoAudio)
    }

    pub async fn stream_with_chunks<F>(&self, text: &str, on_chunk: F) -> Result<(), EdgeError>
    where
        F: FnMut(usize, &[u8]) -> bool,
    {
        self.synthesize_with_chunks_mode(text, false, on_chunk)
            .await
            .map(|_| ())
    }

    pub(super) async fn synthesize_with_chunks_mode<F>(
        &self,
        text: &str,
        collect_audio: bool,
        mut on_chunk: F,
    ) -> Result<Option<Vec<u8>>, EdgeError>
    where
        F: FnMut(usize, &[u8]) -> bool,
    {
        if text.trim().is_empty() {
            return Err(EdgeError::InvalidInput("text is empty".into()));
        }
        let cursor = Mutex::new((text, 0usize));
        let mut pending = FuturesUnordered::new();
        let mut ordered_audio = Vec::<Option<Vec<u8>>>::new();
        let mut next_delivery = 0;
        let mut delivered_any = false;
        loop {
            let capacity = self
                .adaptive
                .as_ref()
                .map(|controller| controller.snapshot().max_in_flight)
                .unwrap_or(self.config.concurrency)
                .max(1);
            while pending.len() < capacity && !cursor.lock().unwrap().0.is_empty() {
                let cursor = &cursor;
                pending.push(async move {
                    // Do not freeze a chunk while it waits for another chapter's
                    // requests or provider cooldown. Reserve text only at dispatch.
                    let permits = self.acquire_request_permits().await?;
                    let chunk_limit = self
                        .adaptive
                        .as_ref()
                        .map(|controller| controller.snapshot().chunk_chars)
                        .unwrap_or(self.config.chunk_chars)
                        .max(1);
                    let (chunk, chunk_index, estimated_total) = {
                        let mut cursor = cursor.lock().unwrap();
                        let (chunk, remaining) = loop {
                            if cursor.0.is_empty() {
                                return Ok::<_, EdgeError>(None);
                            }
                            let (chunk, remaining) = next_protocol_chunk(cursor.0, chunk_limit);
                            cursor.0 = remaining;
                            // A speech provider may finish a blank SSML request
                            // without audio. Consume it without reserving an index.
                            if !chunk.trim().is_empty() {
                                break (chunk, remaining);
                            }
                        };
                        let index = cursor.1;
                        *cursor = (remaining, index + 1);
                        (
                            chunk,
                            index,
                            index + 1 + remaining.len().div_ceil(chunk_limit),
                        )
                    };
                    // The remaining total is an estimate: later dispatches may
                    // use a different size. Audio indexing never uses this total.
                    eprintln!(
                        "[Rust][Edge] dispatching chunk {} (~{} total, {} bytes)",
                        chunk_index + 1,
                        estimated_total,
                        chunk.len()
                    );
                    let audio = self
                        .synthesize_text_chunk(
                            chunk,
                            chunk_index + 1,
                            estimated_total,
                            Some(permits),
                        )
                        .await?;
                    Ok(Some((chunk_index, audio)))
                });
            }
            let Some(result) = pending.next().await else {
                break;
            };
            let Some((chunk_index, audio)) = result? else {
                continue;
            };
            if ordered_audio.len() <= chunk_index {
                ordered_audio.resize_with(chunk_index + 1, || None);
            }
            ordered_audio[chunk_index] = Some(audio);
            while next_delivery < ordered_audio.len() {
                let Some(audio) = ordered_audio[next_delivery].take() else {
                    break;
                };
                if !on_chunk(next_delivery, &audio) {
                    return Err(EdgeError::Cancelled);
                }
                delivered_any = true;
                if collect_audio {
                    ordered_audio[next_delivery] = Some(audio);
                }
                next_delivery += 1;
            }
        }
        if !delivered_any {
            return Err(EdgeError::NoAudio);
        }
        if !collect_audio {
            return Ok(None);
        }
        let output = ordered_audio
            .into_iter()
            .flatten()
            .flatten()
            .collect::<Vec<_>>();
        if output.is_empty() {
            Err(EdgeError::NoAudio)
        } else {
            Ok(Some(output))
        }
    }

    pub async fn synthesize_ssml(&self, ssml: &str) -> Result<Vec<u8>, EdgeError> {
        if ssml.trim().is_empty() {
            return Err(EdgeError::InvalidInput("SSML is empty".into()));
        }
        self.synthesize_request(ssml, ssml.len(), 1, 1, None).await
    }

    pub(super) async fn synthesize_text_chunk(
        &self,
        text: &str,
        chunk_index: usize,
        total_chunks: usize,
        initial_permits: Option<RequestPermits>,
    ) -> Result<Vec<u8>, EdgeError> {
        let ssml = make_ssml_escaped(
            text,
            &self.config.voice,
            &self.config.rate,
            &self.config.volume,
            &self.config.pitch,
            true,
        );
        match self
            .synthesize_request(
                &ssml,
                text.len(),
                chunk_index,
                total_chunks,
                initial_permits,
            )
            .await
        {
            Ok(mut audio) => {
                crate::pcm::trim_edge_trailing_silence(&mut audio);
                Ok(audio)
            }
            Err(error)
                if matches!(
                    error.retry_category(),
                    RetryCategory::RateLimit | RetryCategory::Timeout
                ) && text.len() > crate::adaptive::MIN_CHUNK_CHARS =>
            {
                let reduced_limit = (text.len() / 2).max(crate::adaptive::MIN_CHUNK_CHARS);
                let mut remaining = text;
                eprintln!(
                    "[Rust][TTS] provider=edge pressure=retry-smaller-chunks previous_chars={} next_limit={reduced_limit}",
                    text.len()
                );
                let mut output = Vec::new();
                let mut sub_index = 0;
                while !remaining.is_empty() {
                    let permits = self.acquire_request_permits().await?;
                    let limit = self
                        .adaptive
                        .as_ref()
                        .map(|controller| controller.snapshot().chunk_chars.min(reduced_limit))
                        .unwrap_or(reduced_limit)
                        .max(1);
                    let (chunk, tail) = next_protocol_chunk(remaining, limit);
                    remaining = tail;
                    if chunk.trim().is_empty() {
                        continue;
                    }
                    // Every recursive recovery must make strict progress, even
                    // if the provider limit grows again while this parent waits.
                    if chunk.len() >= text.len() {
                        return Err(error);
                    }
                    sub_index += 1;
                    let estimated_total = sub_index + remaining.len().div_ceil(limit);
                    output.extend(
                        Box::pin(self.synthesize_text_chunk(
                            chunk,
                            sub_index,
                            estimated_total,
                            Some(permits),
                        ))
                        .await?,
                    );
                }
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }
}
