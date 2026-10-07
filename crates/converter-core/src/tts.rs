//! Deterministic Edge-TTS WebSocket client.
//!
//! The protocol is intentionally kept in this crate rather than delegated to a
//! platform bridge: it makes framing, SSML, cancellation, and retry behavior
//! identical on every conversion surface. `EdgeTransport` is injectable so
//! protocol tests can use a local deterministic server without network calls.

use std::{fmt, sync::Arc, time::Duration, time::Instant};

use futures_util::{stream::FuturesUnordered, SinkExt, StreamExt};
use http::{header::HeaderValue, Request};
use rand::Rng;
use sha2::{Digest, Sha256};
use tokio::{sync::Semaphore, time::timeout};
use tokio_tungstenite::{
    client_async_tls_with_config,
    tungstenite::{client::IntoClientRequest, Message},
    Connector, MaybeTlsStream, WebSocketStream,
};
use url::Url;

use crate::adaptive::{AdaptiveThroughputController, ProviderFailure};

pub const DEFAULT_ENDPOINT: &str =
    "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1";
pub const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
pub const DEFAULT_OUTPUT_FORMAT: &str = "audio-24khz-48kbitrate-mono-mp3";
pub const DEFAULT_CHUNK_CHARS: usize = 12_000;
pub const DEFAULT_CONCURRENCY: usize = 8;
const EDGE_BROWSER_VERSION: &str = "1-143.0.3650.75";
const REFERENCE_MAX_RETRIES: usize = 3;
const REFERENCE_MAX_DEADLINE: Duration = Duration::from_secs(3_600);

pub type Telemetry = Arc<dyn Fn(TelemetryEvent) + Send + Sync>;
pub type EdgeSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

pub async fn synthesize_with_reference_client(
    text: &str,
    voice: &str,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
) -> Result<Vec<u8>, EdgeError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut config = EdgeConfig::new(voice)?;
    config.chunk_chars = adaptive.snapshot().chunk_chars;
    config.concurrency = adaptive.snapshot().max_in_flight;
    config.timeout = Duration::from_secs(if cfg!(target_os = "android") { 60 } else { 25 });
    let total_timeout = reference_synthesis_timeout_for_text(text.len());
    let client = EdgeTtsClient::with_adaptive_controller(config, adaptive, telemetry);
    let result = timeout(total_timeout, client.synthesize(text))
        .await
        .map_err(|_| EdgeError::Timeout)?
        .map_err(map_reference_synthesis_error)?;
    Ok(result)
}

fn map_reference_synthesis_error(error: EdgeError) -> EdgeError {
    match error {
        EdgeError::Timeout | EdgeError::RateLimited { .. } => error,
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

fn reference_synthesis_timeout(
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
const EDGE_ORIGIN: &str = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RetryCategory {
    RateLimit,
    Timeout,
    Transport,
    NoAudio,
    Protocol,
    Cancelled,
    Permanent,
}

impl RetryCategory {
    pub fn retryable(&self) -> bool {
        matches!(
            self,
            Self::RateLimit | Self::Timeout | Self::Transport | Self::NoAudio
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TelemetryEvent {
    RequestStarted {
        request_id: String,
        chars: usize,
    },
    AudioFrame {
        request_id: String,
        bytes: usize,
    },
    RequestFinished {
        request_id: String,
        bytes: usize,
        retries: usize,
    },
    RequestFailed {
        request_id: String,
        category: RetryCategory,
        retries: usize,
    },
    Cancelled {
        request_id: String,
    },
    ChunkMetrics {
        provider: String,
        chunk_index: usize,
        total_chunks: usize,
        chars: usize,
        elapsed_ms: u64,
        chars_per_second: f64,
        retries: usize,
        chunk_limit: usize,
        max_in_flight: usize,
        cooldown_ms: u64,
        result: String,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum EdgeError {
    InvalidInput(String),
    Url(String),
    Transport(String),
    RateLimited {
        status: u16,
        retry_after: Option<Duration>,
    },
    Protocol(String),
    Timeout,
    NoAudio,
    Cancelled,
}

impl fmt::Display for EdgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(v) => write!(f, "invalid input: {v}"),
            Self::Url(v) => write!(f, "invalid Edge URL: {v}"),
            Self::Transport(v) => write!(f, "Edge transport: {v}"),
            Self::RateLimited { status, .. } => write!(f, "Edge request throttled (HTTP {status})"),
            Self::Protocol(v) => write!(f, "Edge protocol: {v}"),
            Self::Timeout => f.write_str("Edge synthesis timed out"),
            Self::NoAudio => f.write_str("Edge returned no audio"),
            Self::Cancelled => f.write_str("Edge synthesis cancelled"),
        }
    }
}

impl std::error::Error for EdgeError {}

impl EdgeError {
    pub fn retry_category(&self) -> RetryCategory {
        match self {
            Self::Timeout => RetryCategory::Timeout,
            Self::NoAudio => RetryCategory::NoAudio,
            Self::RateLimited { .. } => RetryCategory::RateLimit,
            Self::Transport(_) => RetryCategory::Transport,
            Self::Protocol(_) => RetryCategory::Protocol,
            Self::Cancelled => RetryCategory::Cancelled,
            Self::InvalidInput(_) | Self::Url(_) => RetryCategory::Permanent,
        }
    }
}

#[derive(Clone, Debug)]
pub struct EdgeConfig {
    pub endpoint: Url,
    pub voice: String,
    pub rate: String,
    pub volume: String,
    pub pitch: String,
    pub timeout: Duration,
    pub max_retries: usize,
    pub chunk_chars: usize,
    pub concurrency: usize,
    pub trusted_client_token: String,
    pub output_format: String,
}

impl EdgeConfig {
    pub fn new(voice: impl Into<String>) -> Result<Self, EdgeError> {
        let endpoint = Url::parse(DEFAULT_ENDPOINT).map_err(|e| EdgeError::Url(e.to_string()))?;
        Ok(Self {
            endpoint,
            voice: voice.into(),
            rate: "+0%".into(),
            volume: "+0%".into(),
            pitch: "+0Hz".into(),
            timeout: Duration::from_secs(60),
            max_retries: REFERENCE_MAX_RETRIES,
            chunk_chars: DEFAULT_CHUNK_CHARS,
            concurrency: DEFAULT_CONCURRENCY,
            trusted_client_token: TRUSTED_CLIENT_TOKEN.into(),
            output_format: DEFAULT_OUTPUT_FORMAT.into(),
        })
    }
}

pub trait EdgeTransport: Send + Sync {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a>;
}

pub type TransportFuture<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<EdgeSocket, EdgeError>> + Send + 'a>>;

#[derive(Default)]
pub struct WebSocketTransport;

impl EdgeTransport for WebSocketTransport {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a> {
        Box::pin(async move {
            let mut request = request
                .uri()
                .to_string()
                .into_client_request()
                .map_err(|error| EdgeError::Transport(error.to_string()))?;

            request
                .headers_mut()
                .insert("Origin", HeaderValue::from_static(EDGE_ORIGIN));
            request
                .headers_mut()
                .insert("Pragma", HeaderValue::from_static("no-cache"));
            request
                .headers_mut()
                .insert("Cache-Control", HeaderValue::from_static("no-cache"));
            request
                .headers_mut()
                .insert("Sec-WebSocket-Version", HeaderValue::from_static("13"));
            request.headers_mut().insert(
                "Accept-Encoding",
                HeaderValue::from_static("gzip, deflate, br, zstd"),
            );
            request.headers_mut().insert(
                "Accept-Language",
                HeaderValue::from_static("en-US,en;q=0.9"),
            );
            let mut muid_bytes = [0u8; 16];
            rand::rng().fill(&mut muid_bytes);
            let muid = hex::encode_upper(muid_bytes);
            let cookie = format!("muid={muid};");
            request.headers_mut().insert(
                "Cookie",
                HeaderValue::from_str(&cookie)
                    .map_err(|error| EdgeError::Transport(error.to_string()))?,
            );

            request.headers_mut().insert(
                "User-Agent",
                HeaderValue::from_static(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
                ),
            );
            request
                .headers_mut()
                .insert("Pragma", HeaderValue::from_static("no-cache"));
            request
                .headers_mut()
                .insert("Cache-Control", HeaderValue::from_static("no-cache"));
            request.headers_mut().insert(
                "Accept-Encoding",
                HeaderValue::from_static("gzip, deflate, br"),
            );
            request.headers_mut().insert(
                "Accept-Language",
                HeaderValue::from_static("en-US,en;q=0.9"),
            );
            request
                .headers_mut()
                .insert("Accept", HeaderValue::from_static("*/*"));
            request.headers_mut().insert(
                "Sec-CH-UA",
                HeaderValue::from_static(
                    "\" Not;A Brand\";v=\"99\", \"Microsoft Edge\";v=\"143\", \"Chromium\";v=\"143\"",
                ),
            );
            request
                .headers_mut()
                .insert("Sec-CH-UA-Mobile", HeaderValue::from_static("?0"));
            request
                .headers_mut()
                .insert("Sec-Fetch-Site", HeaderValue::from_static("none"));
            request
                .headers_mut()
                .insert("Sec-Fetch-Mode", HeaderValue::from_static("cors"));
            request
                .headers_mut()
                .insert("Sec-Fetch-Dest", HeaderValue::from_static("empty"));
            let mut roots = rustls::RootCertStore::empty();
            let certificate_result = rustls_native_certs::load_native_certs();
            for certificate in certificate_result.certs {
                roots
                    .add(certificate)
                    .map_err(|error| EdgeError::Transport(error.to_string()))?;
            }
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let mut tls_config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            tls_config.alpn_protocols = vec![b"http/1.1".to_vec()];
            let tls_connector = Connector::Rustls(std::sync::Arc::new(tls_config));
            let (socket, _) = client_async_tls_with_config(
                request,
                tokio::net::TcpStream::connect("speech.platform.bing.com:443")
                    .await
                    .map_err(|error| EdgeError::Transport(error.to_string()))?,
                None,
                Some(tls_connector),
            )
            .await
            .map_err(map_websocket_error)?;
            Ok(socket)
        })
    }
}

fn map_websocket_error(error: tokio_tungstenite::tungstenite::Error) -> EdgeError {
    use tokio_tungstenite::tungstenite::Error as WebSocketError;

    match error {
        WebSocketError::Http(response) if matches!(response.status().as_u16(), 403 | 429 | 503) => {
            let retry_after = response
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok())
                .map(Duration::from_secs);
            EdgeError::RateLimited {
                status: response.status().as_u16(),
                retry_after,
            }
        }
        other => EdgeError::Transport(other.to_string()),
    }
}

pub struct EdgeTtsClient<T = WebSocketTransport> {
    config: EdgeConfig,
    transport: Arc<T>,
    limiter: Arc<Semaphore>,
    telemetry: Option<Telemetry>,
    adaptive: Option<Arc<AdaptiveThroughputController>>,
}

impl EdgeTtsClient<WebSocketTransport> {
    pub fn new(config: EdgeConfig) -> Self {
        let permits = config.concurrency.max(1);
        Self::with_transport(config, Arc::new(WebSocketTransport), permits, None)
    }

    pub fn with_adaptive_controller(
        config: EdgeConfig,
        adaptive: Arc<AdaptiveThroughputController>,
        telemetry: Option<Telemetry>,
    ) -> Self {
        let permits = config.concurrency.max(1);
        let mut client =
            Self::with_transport(config, Arc::new(WebSocketTransport), permits, telemetry);
        client.adaptive = Some(adaptive);
        client
    }
}

impl<T: EdgeTransport + 'static> EdgeTtsClient<T> {
    pub fn with_transport(
        config: EdgeConfig,
        transport: Arc<T>,
        concurrency: usize,
        telemetry: Option<Telemetry>,
    ) -> Self {
        Self {
            config,
            transport,
            limiter: Arc::new(Semaphore::new(concurrency.max(1))),
            telemetry,
            adaptive: None,
        }
    }

    pub fn config(&self) -> &EdgeConfig {
        &self.config
    }

    pub async fn synthesize(&self, text: &str) -> Result<Vec<u8>, EdgeError> {
        if text.trim().is_empty() {
            return Err(EdgeError::InvalidInput("text is empty".into()));
        }
        let chunk_limit = self
            .adaptive
            .as_ref()
            .map(|controller| controller.snapshot().chunk_chars)
            .unwrap_or(self.config.chunk_chars);
        let chunks = split_protocol_chunks(text, chunk_limit);
        let total_chunks = chunks.len();
        let mut pending = FuturesUnordered::new();
        for (chunk_index, chunk) in chunks.into_iter().enumerate() {
            eprintln!(
                "[Rust][Edge] synthesizing chunk {}/{} ({} chars)",
                chunk_index + 1,
                total_chunks,
                chunk.len()
            );
            let client = self;
            pending.push(async move {
                let audio = client
                    .synthesize_text_chunk(&chunk, chunk_index + 1, total_chunks)
                    .await?;
                Ok::<_, EdgeError>((chunk_index, audio))
            });
        }
        let mut ordered_audio = (0..total_chunks).map(|_| None).collect::<Vec<_>>();
        while let Some(result) = pending.next().await {
            let (chunk_index, audio) = result?;
            ordered_audio[chunk_index] = Some(audio);
        }
        let output = ordered_audio
            .into_iter()
            .flatten()
            .flatten()
            .collect::<Vec<_>>();
        if output.is_empty() {
            Err(EdgeError::NoAudio)
        } else {
            Ok(output)
        }
    }

    pub async fn synthesize_ssml(&self, ssml: &str) -> Result<Vec<u8>, EdgeError> {
        if ssml.trim().is_empty() {
            return Err(EdgeError::InvalidInput("SSML is empty".into()));
        }
        self.synthesize_request(ssml, ssml.len(), 1, 1).await
    }

    async fn synthesize_text_chunk(
        &self,
        text: &str,
        chunk_index: usize,
        total_chunks: usize,
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
            .synthesize_request(&ssml, text.len(), chunk_index, total_chunks)
            .await
        {
            Ok(audio) => Ok(audio),
            Err(error)
                if matches!(
                    error.retry_category(),
                    RetryCategory::RateLimit | RetryCategory::Timeout
                ) && text.len() > crate::adaptive::MIN_CHUNK_CHARS =>
            {
                let reduced_limit = (text.len() / 2).max(crate::adaptive::MIN_CHUNK_CHARS);
                let smaller_chunks = split_protocol_chunks(text, reduced_limit);
                if smaller_chunks.len() < 2 {
                    return Err(error);
                }
                eprintln!(
                    "[Rust][TTS] provider=edge pressure=retry-smaller-chunks previous_chars={} next_limit={reduced_limit}",
                    text.len()
                );
                let mut output = Vec::new();
                for (sub_index, chunk) in smaller_chunks.iter().enumerate() {
                    output.extend(
                        Box::pin(self.synthesize_text_chunk(
                            chunk,
                            sub_index + 1,
                            smaller_chunks.len(),
                        ))
                        .await?,
                    );
                }
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }

    async fn synthesize_request(
        &self,
        ssml: &str,
        chars: usize,
        chunk_index: usize,
        total_chunks: usize,
    ) -> Result<Vec<u8>, EdgeError> {
        let request_id = random_id();
        let mut retries = 0;
        loop {
            let local_permit = self
                .limiter
                .acquire()
                .await
                .map_err(|_| EdgeError::Cancelled)?;
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
            let permit = match &self.adaptive {
                Some(controller) => Some(controller.acquire_request().await),
                None => None,
            };
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
                    drop(local_permit);
                    drop(permit);
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
                    drop(local_permit);
                    drop(permit);
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
                Ok(Err(error)) => {
                    drop(local_permit);
                    drop(permit);
                    self.observe_failure(
                        &error,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: error.retry_category(),
                        retries,
                    });
                    return Err(error);
                }
                Err(_) if retries < self.config.max_retries => {
                    drop(local_permit);
                    drop(permit);
                    retries += 1;
                    self.observe_failure(
                        &EdgeError::Timeout,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
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
                    drop(local_permit);
                    drop(permit);
                    self.observe_failure(
                        &EdgeError::Timeout,
                        chars,
                        chunk_index,
                        total_chunks,
                        retries,
                        request_started.elapsed(),
                    );
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

    fn observe_failure(
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

    async fn run_request(
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

    fn emit(&self, event: TelemetryEvent) {
        if let Some(callback) = &self.telemetry {
            callback(event);
        }
    }
}

pub fn xml_escape(value: &str) -> String {
    value
        .chars()
        .fold(String::with_capacity(value.len()), |mut out, ch| {
            if (ch < ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                || (('\u{7f}'..='\u{9f}').contains(&ch))
                || ch == '\u{fffe}'
                || ch == '\u{ffff}'
            {
                out.push(' ');
                return out;
            }
            match ch {
                '&' => out.push_str("&amp;"),
                '<' => out.push_str("&lt;"),
                '>' => out.push_str("&gt;"),
                '"' => out.push_str("&quot;"),
                '\'' => out.push_str("&apos;"),
                _ => out.push(ch),
            }
            out
        })
}

pub fn make_ssml(text: &str, voice: &str, rate: &str, volume: &str, pitch: &str) -> String {
    make_ssml_escaped(text, voice, rate, volume, pitch, true)
}

fn make_ssml_escaped(
    text: &str,
    voice: &str,
    rate: &str,
    volume: &str,
    pitch: &str,
    escape_text: bool,
) -> String {
    let text = if escape_text {
        xml_escape(text)
    } else {
        text.to_owned()
    };
    let voice = normalize_voice_for_ssml(voice);
    format!("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='{}'><prosody pitch='{}' rate='{}' volume='{}'>{}</prosody></voice></speak>", xml_escape(&voice), xml_escape(pitch), xml_escape(rate), xml_escape(volume), text)
}

fn normalize_voice_for_ssml(voice: &str) -> String {
    const SERVER_VOICE_PREFIX: &str = "Microsoft Server Speech Text to Speech Voice (";
    if voice.starts_with(SERVER_VOICE_PREFIX) {
        return voice.to_owned();
    }
    let mut parts = voice.splitn(3, '-');
    let (Some(language), Some(region), Some(name)) = (parts.next(), parts.next(), parts.next())
    else {
        return voice.to_owned();
    };
    format!("{SERVER_VOICE_PREFIX}{language}-{region}, {name})")
}

pub fn split_protocol_chunks(text: &str, limit: usize) -> Vec<String> {
    let limit = limit.max(1);
    let mut bytes = text.as_bytes();
    let mut chunks = Vec::new();

    while bytes.len() > limit {
        let mut split_at = bytes[..limit]
            .iter()
            .rposition(|byte| *byte == b'\n' || *byte == b' ')
            .unwrap_or(limit);

        while std::str::from_utf8(&bytes[..split_at]).is_err() && split_at > 0 {
            split_at -= 1;
        }

        if split_at == 0 {
            split_at = limit;
            while std::str::from_utf8(&bytes[..split_at]).is_err() && split_at > 0 {
                split_at -= 1;
            }
        }

        let chunk = std::str::from_utf8(&bytes[..split_at])
            .expect("split point must remain valid UTF-8")
            .trim();
        if !chunk.is_empty() {
            chunks.push(chunk.to_owned());
        }
        bytes = &bytes[split_at..];
    }

    let tail = std::str::from_utf8(bytes)
        .expect("remaining chunk must remain valid UTF-8")
        .trim();
    if !tail.is_empty() {
        chunks.push(tail.to_owned());
    }
    chunks
}

fn random_id() -> String {
    let bytes: [u8; 16] = rand::rng().random();
    hex::encode(bytes)
}

fn request_url(endpoint: &Url, connection_id: &str, token: &str) -> Result<Url, EdgeError> {
    let mut url = endpoint.clone();
    url.query_pairs_mut()
        .append_pair("ConnectionId", connection_id);
    if !url
        .query_pairs()
        .any(|(key, value)| key == "TrustedClientToken" && value == token)
    {
        url.query_pairs_mut()
            .append_pair("TrustedClientToken", token);
    }
    url.query_pairs_mut()
        .append_pair("Sec-MS-GEC", &sec_ms_gec_now())
        .append_pair("Sec-MS-GEC-Version", EDGE_BROWSER_VERSION);
    Ok(url)
}

fn sec_ms_gec_now() -> String {
    const WINDOWS_EPOCH_SECONDS: u64 = 11_644_473_600;
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let rounded_seconds = seconds + WINDOWS_EPOCH_SECONDS;
    let rounded_seconds = rounded_seconds - rounded_seconds % 300;
    let ticks = rounded_seconds * 10_000_000;
    let payload = format!("{ticks}{TRUSTED_CLIENT_TOKEN}");
    hex::encode(Sha256::digest(payload.as_bytes())).to_uppercase()
}

fn protocol_request(url: Url) -> Result<Request<()>, EdgeError> {
    let mut request = Request::builder()
        .method("GET")
        .uri(url.as_str())
        .body(())
        .map_err(|e| EdgeError::Url(e.to_string()))?;
    request
        .headers_mut()
        .insert("Pragma", HeaderValue::from_static("no-cache"));
    request
        .headers_mut()
        .insert("Cache-Control", HeaderValue::from_static("no-cache"));
    request
        .headers_mut()
        .insert("Sec-WebSocket-Version", HeaderValue::from_static("13"));
    request
        .headers_mut()
        .insert("Origin", HeaderValue::from_static(EDGE_ORIGIN));
    request.headers_mut().insert(
        "Accept-Encoding",
        HeaderValue::from_static("gzip, deflate, br, zstd"),
    );
    request.headers_mut().insert(
        "Accept-Language",
        HeaderValue::from_static("en-US,en;q=0.9"),
    );
    let muid = random_id().to_uppercase();
    request.headers_mut().insert(
        "Cookie",
        HeaderValue::from_str(&format!("muid={muid};"))
            .map_err(|e| EdgeError::Url(e.to_string()))?,
    );
    request.headers_mut().insert(
        "User-Agent",
        HeaderValue::from_static(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
        ),
    );
    Ok(request)
}

fn protocol_timestamp() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::macros::format_description!(
            "[weekday repr:short] [month repr:short] [day padding:zero] [year] [hour]:[minute]:[second] GMT+0000 (Coordinated Universal Time)"
        ))
        .expect("Edge timestamp format is static and valid")
}

fn speech_config(timestamp: &str, format: &str) -> String {
    let payload = serde_json::json!({
        "context": {
            "synthesis": {
                "audio": {
                    "metadataoptions": {
                        "sentenceBoundaryEnabled": false,
                        "wordBoundaryEnabled": true,
                    },
                    "outputFormat": format,
                },
            },
        },
    });
    format!("X-Timestamp:{timestamp}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{payload}\r\n")
}

fn ssml_frame(request_id: &str, timestamp: &str, ssml: &str) -> String {
    format!("X-RequestId:{request_id}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:{timestamp}Z\r\nPath:ssml\r\n\r\n{ssml}")
}

fn frame_path(text: &str) -> Option<String> {
    text.split("\r\n")
        .find_map(|line| line.strip_prefix("Path:").map(str::to_owned))
}

fn parse_audio_frame(frame: &[u8]) -> Result<Vec<u8>, EdgeError> {
    if frame.len() < 2 {
        return Err(EdgeError::Protocol(
            "binary frame is shorter than header length".into(),
        ));
    }
    let header_len = u16::from_be_bytes([frame[0], frame[1]]) as usize;
    if header_len + 2 > frame.len() {
        return Err(EdgeError::Protocol("binary header exceeds frame".into()));
    }
    Ok(frame[header_len + 2..].to_vec())
}

/// Stable helper for protocol fixtures: returns the Sec-MS-GEC token shape.
pub fn sec_ms_gec(filetime_ticks: u64, token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!(
        "{}{}",
        filetime_ticks - (filetime_ticks % 300_000_000_000),
        token
    ));
    hex::encode_upper(hasher.finalize())
}

#[cfg(test)]
mod protocol_tests {
    use super::*;

    struct StalledConnectTransport;

    impl EdgeTransport for StalledConnectTransport {
        fn connect<'a>(&'a self, _request: Request<()>) -> TransportFuture<'a> {
            Box::pin(async {
                std::future::pending::<()>().await;
                unreachable!("a stalled connection must be cancelled by its request timeout")
            })
        }
    }

    #[tokio::test]
    async fn request_timeout_covers_a_stalled_connection_handshake() {
        let mut config = EdgeConfig::new("en-US-GuyNeural").unwrap();
        config.timeout = Duration::from_millis(10);
        config.max_retries = 0;
        let client =
            EdgeTtsClient::with_transport(config, Arc::new(StalledConnectTransport), 1, None);

        let started = tokio::time::Instant::now();
        let error = client.synthesize("hello").await.unwrap_err();

        assert_eq!(error, EdgeError::Timeout);
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn provider_http_throttle_is_classified_and_honors_retry_after() {
        let response = http::Response::builder()
            .status(429)
            .header("retry-after", "17")
            .body(Some(Vec::new()))
            .unwrap();
        let error = map_websocket_error(tokio_tungstenite::tungstenite::Error::Http(response));

        assert_eq!(
            error,
            EdgeError::RateLimited {
                status: 429,
                retry_after: Some(Duration::from_secs(17)),
            }
        );
        assert_eq!(error.retry_category(), RetryCategory::RateLimit);
    }

    #[test]
    fn reference_client_preserves_timeout_classification() {
        let error = map_reference_synthesis_error(EdgeError::Timeout);

        assert_eq!(error, EdgeError::Timeout);
        assert_eq!(error.retry_category(), RetryCategory::Timeout);
    }

    #[test]
    fn reference_deadline_includes_three_request_retries() {
        assert_eq!(
            reference_synthesis_timeout(2_000, 2_048, Duration::from_secs(25), 3, Duration::from_secs(3_600)),
            Duration::from_secs(154)
        );
    }

    #[test]
    fn total_synthesis_deadline_scales_with_chunk_count_and_stays_bounded() {
        let one_chunk = reference_synthesis_timeout(
            2_000,
            2_048,
            Duration::from_secs(25),
            1,
            Duration::from_secs(150),
        );
        let two_chunks = reference_synthesis_timeout(
            8_000,
            2_048,
            Duration::from_secs(25),
            1,
            Duration::from_secs(1_500),
        );
        let huge_chapter = reference_synthesis_timeout(
            200_000,
            2_048,
            Duration::from_secs(25),
            1,
            Duration::from_secs(1_500),
        );

        assert_eq!(one_chunk, Duration::from_secs(92));
        assert_eq!(two_chunks, Duration::from_secs(338));
        assert_eq!(
            reference_synthesis_timeout(
                53_852,
                2_048,
                Duration::from_secs(25),
                1,
                Duration::from_secs(1_500),
            ),
            Duration::from_secs(1_500)
        );
        assert_eq!(huge_chapter, Duration::from_secs(1_500));
    }

    #[test]
    fn ssml_escapes_xml_content_and_attributes() {
        let ssml = make_ssml("A & <B>", "en-US-GuyNeural", "+0%", "+0%", "+0Hz");
        assert!(ssml.contains("A &amp; &lt;B&gt;"));
        assert!(!ssml.contains("A & <B>"));
    }

    #[test]
    fn chunks_are_deterministic_and_respect_limit() {
        let chunks = split_protocol_chunks("one two three four", 8);
        assert_eq!(chunks, vec!["one two", "three", "four"]);
        assert!(chunks.iter().all(|chunk| chunk.len() <= 8));
    }

    #[test]
    fn ssml_matches_reference_shape_and_escapes_text_once() {
        let ssml = make_ssml("A & <B> 'quoted'", "en-US-GuyNeural", "+0%", "+0%", "+0Hz");
        assert_eq!(
            ssml,
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>A &amp; &lt;B&gt; &apos;quoted&apos;</prosody></voice></speak>"
        );
        assert!(!ssml.contains("xmlns:mstts"));
    }

    #[test]
    fn ssml_keeps_an_already_qualified_server_voice_unchanged() {
        let voice = "Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)";
        assert_eq!(normalize_voice_for_ssml(voice), voice);
    }

    #[test]
    fn chunking_raw_text_keeps_xml_entities_intact_after_escaping() {
        let text = format!("{} & value", "x".repeat(7));
        for chunk in split_protocol_chunks(&text, 8) {
            let ssml = make_ssml(&chunk, "en-US-GuyNeural", "+0%", "+0%", "+0Hz");
            let mut reader = quick_xml::Reader::from_str(&ssml);
            let mut depth = 0usize;
            loop {
                match reader.read_event() {
                    Ok(quick_xml::events::Event::Start(_)) => depth += 1,
                    Ok(quick_xml::events::Event::End(_)) => depth -= 1,
                    Ok(quick_xml::events::Event::Eof) => break,
                    Ok(_) => {}
                    Err(error) => panic!("invalid SSML chunk: {error}"),
                }
            }
            assert_eq!(depth, 0);
        }
    }

    #[test]
    fn binary_frame_discards_protocol_header() {
        assert_eq!(
            parse_audio_frame(&[0, 3, b'a', b'b', b'c', 1, 2]).unwrap(),
            vec![1, 2]
        );
    }
}
