//! Deterministic Edge-TTS WebSocket client.
//!
//! The protocol is intentionally kept in this crate rather than delegated to a
//! platform bridge: it makes framing, SSML, cancellation, and retry behavior
//! identical on every conversion surface. `EdgeTransport` is injectable so
//! protocol tests can use a local deterministic server without network calls.

use std::{
    fmt,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
    time::Instant,
};

use futures_util::{stream::FuturesUnordered, SinkExt, StreamExt};
use http::{header::HeaderValue, Request};
use rand::Rng;
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::timeout,
};
use tokio_tungstenite::{
    client_async_tls_with_config,
    tungstenite::{client::IntoClientRequest, Message},
    Connector, MaybeTlsStream, WebSocketStream,
};
use url::Url;

use crate::adaptive::{AdaptiveRequestPermit, AdaptiveThroughputController, ProviderFailure};

pub const DEFAULT_ENDPOINT: &str =
    "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1";
pub const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
pub const DEFAULT_OUTPUT_FORMAT: &str = "audio-24khz-48kbitrate-mono-mp3";
pub const DEFAULT_CHUNK_CHARS: usize = 12_000;
pub const DEFAULT_CONCURRENCY: usize = 8;
const EDGE_BROWSER_VERSION: &str = "1-143.0.3650.75";
const REFERENCE_MAX_RETRIES: usize = 3;
const REFERENCE_MAX_DEADLINE: Duration = Duration::from_secs(3_600);
static EDGE_CLOCK_SKEW_SECONDS: AtomicI64 = AtomicI64::new(0);

pub type Telemetry = Arc<dyn Fn(TelemetryEvent) + Send + Sync>;
pub type EdgeSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

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

fn map_reference_synthesis_error(error: EdgeError) -> EdgeError {
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
    Forbidden {
        edge_reference: Option<String>,
        server_date: Option<String>,
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
            Self::Forbidden { edge_reference, .. } => {
                f.write_str("Edge denied the speech request (HTTP 403)")?;
                if let Some(edge_reference) = edge_reference {
                    write!(f, "; reference: {edge_reference}")?;
                }
                Ok(())
            }
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
            Self::Forbidden { .. } => RetryCategory::Permanent,
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
            let request = websocket_upgrade_request(request)?;
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
            let host = request
                .uri()
                .host()
                .ok_or_else(|| EdgeError::Url("Edge WebSocket URL has no host".into()))?;
            let port = request.uri().port_u16().unwrap_or(443);
            let stream =
                connect_tcp_for_websocket(host, port, configured_edge_proxy(host)?).await?;
            let (socket, _) =
                client_async_tls_with_config(request, stream, None, Some(tls_connector))
                    .await
                    .map_err(map_websocket_error)?;
            Ok(socket)
        })
    }
}

fn configured_edge_proxy(host: &str) -> Result<Option<Url>, EdgeError> {
    let no_proxy = std::env::var("NO_PROXY")
        .or_else(|_| std::env::var("no_proxy"))
        .unwrap_or_default();
    if proxy_bypass_matches(host, &no_proxy) {
        return Ok(None);
    }

    let configured = [
        "EDGE_PROXY",
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
    ]
    .iter()
    .find_map(|name| {
        std::env::var(name)
            .ok()
            .filter(|value| !value.trim().is_empty())
    });
    let Some(configured) = configured else {
        return Ok(None);
    };
    let proxy = Url::parse(&configured)
        .map_err(|_| EdgeError::Transport("invalid Edge proxy URL".into()))?;
    if proxy.scheme() != "http"
        || proxy.host_str().is_none()
        || proxy.username() != ""
        || proxy.password().is_some()
    {
        return Err(EdgeError::Transport(
            "Edge proxy must be an unauthenticated http:// URL".into(),
        ));
    }
    Ok(Some(proxy))
}

fn proxy_bypass_matches(host: &str, entries: &str) -> bool {
    entries.split(',').map(str::trim).any(|entry| {
        if entry.is_empty() {
            return false;
        }
        if entry == "*" {
            return true;
        }
        let domain = entry.trim_start_matches('.');
        host.eq_ignore_ascii_case(domain)
            || host
                .to_ascii_lowercase()
                .ends_with(&format!(".{}", domain.to_ascii_lowercase()))
    })
}

async fn connect_tcp_for_websocket(
    host: &str,
    port: u16,
    proxy: Option<Url>,
) -> Result<TcpStream, EdgeError> {
    let Some(proxy) = proxy else {
        return TcpStream::connect((host, port))
            .await
            .map_err(|error| EdgeError::Transport(error.to_string()));
    };
    if proxy.path() != "/" || proxy.query().is_some() || proxy.fragment().is_some() {
        return Err(EdgeError::Transport(
            "Edge proxy URL cannot contain a path, query, or fragment".into(),
        ));
    }
    let proxy_host = proxy
        .host_str()
        .ok_or_else(|| EdgeError::Transport("Edge proxy URL has no host".into()))?;
    let proxy_port = proxy.port().unwrap_or(80);
    let mut stream = TcpStream::connect((proxy_host, proxy_port))
        .await
        .map_err(|error| EdgeError::Transport(format!("Edge proxy connection failed: {error}")))?;
    let authority_host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let authority = format!("{authority_host}:{port}");
    let connect_request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n\r\n"
    );
    stream
        .write_all(connect_request.as_bytes())
        .await
        .map_err(|error| EdgeError::Transport(format!("Edge proxy CONNECT failed: {error}")))?;
    let mut response = Vec::with_capacity(256);
    while response.len() < 16 * 1024 && !response.ends_with(b"\r\n\r\n") {
        let mut byte = [0u8; 1];
        stream
            .read_exact(&mut byte)
            .await
            .map_err(|error| EdgeError::Transport(format!("Edge proxy CONNECT failed: {error}")))?;
        response.push(byte[0]);
    }
    if !response.ends_with(b"\r\n\r\n") {
        return Err(EdgeError::Transport(
            "Edge proxy returned oversized CONNECT headers".into(),
        ));
    }
    let status = std::str::from_utf8(&response)
        .ok()
        .and_then(|headers| headers.lines().next())
        .and_then(|line| line.split_ascii_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok());
    if status != Some(200) {
        return Err(EdgeError::Transport(format!(
            "Edge proxy CONNECT returned HTTP {}",
            status.map_or_else(|| "invalid response".into(), |status| status.to_string())
        )));
    }
    Ok(stream)
}

fn websocket_upgrade_request(request: Request<()>) -> Result<Request<()>, EdgeError> {
    let mut websocket_request = request
        .uri()
        .to_string()
        .into_client_request()
        .map_err(|error| EdgeError::Transport(error.to_string()))?;
    for (name, value) in request.headers() {
        websocket_request
            .headers_mut()
            .insert(name.clone(), value.clone());
    }
    Ok(websocket_request)
}

fn map_websocket_error(error: tokio_tungstenite::tungstenite::Error) -> EdgeError {
    use tokio_tungstenite::tungstenite::Error as WebSocketError;

    match error {
        WebSocketError::Http(response) if response.status().as_u16() == 403 => {
            let edge_reference = response
                .headers()
                .get("x-msedge-ref")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let server_date = response
                .headers()
                .get(http::header::DATE)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            EdgeError::Forbidden {
                edge_reference,
                server_date,
            }
        }
        WebSocketError::Http(response) if matches!(response.status().as_u16(), 429 | 503) => {
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

struct RequestPermits {
    local: OwnedSemaphorePermit,
    adaptive: Option<AdaptiveRequestPermit>,
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
        Self::with_adaptive_transport(config, Arc::new(WebSocketTransport), adaptive, telemetry)
    }
}

impl<T: EdgeTransport + 'static> EdgeTtsClient<T> {
    /// Use the same adaptive request policy with a supplied protocol transport.
    pub fn with_adaptive_transport(
        config: EdgeConfig,
        transport: Arc<T>,
        adaptive: Arc<AdaptiveThroughputController>,
        telemetry: Option<Telemetry>,
    ) -> Self {
        // The shared controller owns the live concurrency ceiling. A semaphore
        // fixed at its initial snapshot would prevent subsequent capacity growth.
        let mut client = Self::with_transport(config, transport, Semaphore::MAX_PERMITS, telemetry);
        client.adaptive = Some(adaptive);
        client
    }

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

    async fn synthesize_with_chunks_mode<F>(
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

    async fn synthesize_text_chunk(
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
            Ok(audio) => Ok(audio),
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

    async fn synthesize_request(
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

    async fn acquire_request_permits(&self) -> Result<RequestPermits, EdgeError> {
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

// Consume a nonempty prefix without trimming text or splitting a UTF-8 scalar.
// A scalar wider than the configured byte limit is sent whole to make progress.
fn next_protocol_chunk(text: &str, limit: usize) -> (&str, &str) {
    let mut end = text.len().min(limit.max(1));
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    if end == 0 {
        end = text.chars().next().unwrap().len_utf8();
    }
    if end < text.len() {
        if let Some(boundary) = text.as_bytes()[..end]
            .iter()
            .rposition(|byte| *byte == b'\n' || *byte == b' ')
        {
            end = boundary + 1;
        }
    }
    text.split_at(end)
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
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair("Ocp-Apim-Subscription-Key", token)
            .append_pair("ConnectionId", connection_id)
            .append_pair("Sec-MS-GEC", &sec_ms_gec_now())
            .append_pair("Sec-MS-GEC-Version", EDGE_BROWSER_VERSION);
    }
    Ok(url)
}

fn sec_ms_gec_now() -> String {
    const WINDOWS_EPOCH_SECONDS: u64 = 11_644_473_600;
    let seconds = adjusted_unix_seconds().max(0) as u64;
    let rounded_seconds = seconds + WINDOWS_EPOCH_SECONDS;
    let rounded_seconds = rounded_seconds - rounded_seconds % 300;
    let ticks = rounded_seconds * 10_000_000;
    let payload = format!("{ticks}{TRUSTED_CLIENT_TOKEN}");
    hex::encode(Sha256::digest(payload.as_bytes())).to_uppercase()
}

fn adjusted_unix_seconds() -> i64 {
    time::OffsetDateTime::now_utc()
        .unix_timestamp()
        .saturating_add(EDGE_CLOCK_SKEW_SECONDS.load(Ordering::Relaxed))
}

fn adjust_edge_clock_skew(server_date: &str) -> Result<i64, String> {
    let format = time::format_description::well_known::Rfc2822;
    let server_time = time::OffsetDateTime::parse(server_date, &format)
        .map_err(|error| format!("invalid Edge Date header: {error}"))?;
    let skew = server_time
        .unix_timestamp()
        .saturating_sub(time::OffsetDateTime::now_utc().unix_timestamp());
    if skew.unsigned_abs() > 24 * 60 * 60 {
        return Err("Edge Date header differs from local time by more than 24 hours".into());
    }
    EDGE_CLOCK_SKEW_SECONDS.store(skew, Ordering::Relaxed);
    Ok(skew)
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
    time::OffsetDateTime::from_unix_timestamp(adjusted_unix_seconds())
        .unwrap_or_else(|_| time::OffsetDateTime::now_utc())
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
                        "sentenceBoundaryEnabled": "false",
                        "wordBoundaryEnabled": "true",
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
    let header = std::str::from_utf8(&frame[2..header_len + 2])
        .map_err(|error| EdgeError::Protocol(format!("invalid binary frame header: {error}")))?;
    let path = frame_path(header);
    if path.as_deref() != Some("audio") {
        return Err(EdgeError::Protocol(format!(
            "Edge returned unexpected binary frame path {}",
            path.as_deref().unwrap_or("<missing>")
        )));
    }
    let content_type = header
        .split("\r\n")
        .find_map(|line| line.strip_prefix("Content-Type:"));
    if !matches!(content_type, Some("audio/mpeg") | None) {
        return Err(EdgeError::Protocol(format!(
            "Edge returned unexpected binary content type {}",
            content_type.unwrap_or("<missing>")
        )));
    }
    let payload = frame[header_len + 2..].to_vec();
    if payload.is_empty() && content_type.is_some() {
        return Err(EdgeError::Protocol(
            "Edge returned an empty audio frame".into(),
        ));
    }
    Ok(payload)
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

    struct ForbiddenConnectTransport {
        attempts: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl EdgeTransport for ForbiddenConnectTransport {
        fn connect<'a>(&'a self, _request: Request<()>) -> TransportFuture<'a> {
            self.attempts
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async {
                Err(EdgeError::Forbidden {
                    edge_reference: Some("edge-ref-test".into()),
                    server_date: None,
                })
            })
        }
    }

    struct ClockSkewCorrectionTransport {
        attempts: Arc<std::sync::atomic::AtomicUsize>,
        server_date: String,
    }

    impl EdgeTransport for ClockSkewCorrectionTransport {
        fn connect<'a>(&'a self, _request: Request<()>) -> TransportFuture<'a> {
            let attempt = self
                .attempts
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let server_date = (attempt == 0).then(|| self.server_date.clone());
            Box::pin(async move {
                Err(EdgeError::Forbidden {
                    edge_reference: Some("edge-ref-clock-test".into()),
                    server_date,
                })
            })
        }
    }

    #[test]
    fn websocket_upgrade_preserves_only_the_edge_websocket_headers() {
        let url = Url::parse(DEFAULT_ENDPOINT).unwrap();
        let request = protocol_request(url).unwrap();
        let request = websocket_upgrade_request(request).unwrap();
        let headers = request.headers();

        assert_eq!(headers["origin"], EDGE_ORIGIN);
        assert_eq!(headers["pragma"], "no-cache");
        assert_eq!(headers["cache-control"], "no-cache");
        assert_eq!(headers["sec-websocket-version"], "13");
        assert_eq!(headers["accept-encoding"], "gzip, deflate, br, zstd");
        assert_eq!(headers["accept-language"], "en-US,en;q=0.9");
        assert!(headers["cookie"].to_str().unwrap().starts_with("muid="));
        assert!(headers["user-agent"]
            .to_str()
            .unwrap()
            .contains("Edg/143.0.0.0"));
        assert!(headers.contains_key("sec-websocket-key"));
        assert!(!headers.contains_key("sec-ch-ua"));
        assert!(!headers.contains_key("sec-fetch-site"));
        assert!(!headers.contains_key("accept"));
    }

    #[test]
    fn default_endpoint_uses_current_edge_read_aloud_host_and_subscription_query_key() {
        let endpoint = Url::parse(DEFAULT_ENDPOINT).unwrap();
        assert_eq!(endpoint.host_str(), Some("api.msedgeservices.com"));
        assert_eq!(
            endpoint.path(),
            "/tts/cognitiveservices/websocket/v1"
        );

        let request = request_url(&endpoint, "connection-id", TRUSTED_CLIENT_TOKEN).unwrap();
        let query = request.query_pairs().collect::<Vec<_>>();
        assert!(query.iter().any(|(key, value)| {
            key == "Ocp-Apim-Subscription-Key" && value == TRUSTED_CLIENT_TOKEN
        }));
        assert!(query.iter().any(|(key, value)| {
            key == "ConnectionId" && value == "connection-id"
        }));
        assert!(query.iter().any(|(key, _)| key == "Sec-MS-GEC"));
        assert!(query.iter().any(|(key, value)| {
            key == "Sec-MS-GEC-Version" && value == EDGE_BROWSER_VERSION
        }));
        assert!(!query.iter().any(|(key, _)| key == "TrustedClientToken"));
    }

    #[test]
    fn proxy_bypass_matches_exact_hosts_and_domain_suffixes() {
        assert!(proxy_bypass_matches(
            "speech.platform.bing.com",
            "localhost, .bing.com"
        ));
        assert!(proxy_bypass_matches("localhost", "localhost, .bing.com"));
        assert!(!proxy_bypass_matches("notbing.com", ".bing.com"));
        assert!(proxy_bypass_matches("anything.example", "*"));
    }

    #[tokio::test]
    async fn http_proxy_connect_tunnels_the_edge_websocket_target() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0u8; 1];
                stream.read_exact(&mut byte).await.unwrap();
                request.push(byte[0]);
            }
            stream
                .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                .await
                .unwrap();
            String::from_utf8(request).unwrap()
        });

        let proxy = Url::parse(&format!("http://{address}")).unwrap();
        let stream = connect_tcp_for_websocket("speech.platform.bing.com", 443, Some(proxy))
            .await
            .unwrap();
        drop(stream);

        let request = server.await.unwrap();
        assert!(request.starts_with(
            "CONNECT speech.platform.bing.com:443 HTTP/1.1\r\nHost: speech.platform.bing.com:443\r\n"
        ));
    }

    #[tokio::test]
    async fn http_proxy_connect_rejects_non_success_responses() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0u8; 1];
                stream.read_exact(&mut byte).await.unwrap();
                request.push(byte[0]);
            }
            stream
                .write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
                .await
                .unwrap();
        });

        let proxy = Url::parse(&format!("http://{address}")).unwrap();
        let error = connect_tcp_for_websocket("speech.platform.bing.com", 443, Some(proxy))
            .await
            .unwrap_err();
        server.await.unwrap();
        assert_eq!(
            error,
            EdgeError::Transport("Edge proxy CONNECT returned HTTP 407".into())
        );
    }

    #[test]
    fn speech_config_uses_edge_string_valued_metadata_flags() {
        let frame = speech_config(
            "Mon Oct 12 2026 20:00:00 GMT+0000 (Coordinated Universal Time)",
            "audio-24khz-48kbitrate-mono-mp3",
        );
        let payload = frame.split_once("\r\n\r\n").unwrap().1.trim();
        let payload: serde_json::Value = serde_json::from_str(payload).unwrap();

        assert_eq!(
            payload["context"]["synthesis"]["audio"]["metadataoptions"]["sentenceBoundaryEnabled"],
            "false"
        );
        assert_eq!(
            payload["context"]["synthesis"]["audio"]["metadataoptions"]["wordBoundaryEnabled"],
            "true"
        );
        assert_eq!(
            payload["context"]["synthesis"]["audio"]["outputFormat"],
            "audio-24khz-48kbitrate-mono-mp3"
        );
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
    fn edge_http_403_is_a_permanent_rejection_with_server_reference() {
        let response = http::Response::builder()
            .status(403)
            .header("x-msedge-ref", "region-reference")
            .header("date", "Tue, 13 Oct 2026 12:05:00 GMT")
            .body(Some(Vec::new()))
            .unwrap();
        let error = map_websocket_error(tokio_tungstenite::tungstenite::Error::Http(response));

        assert_eq!(
            error,
            EdgeError::Forbidden {
                edge_reference: Some("region-reference".into()),
                server_date: Some("Tue, 13 Oct 2026 12:05:00 GMT".into()),
            }
        );
        assert_eq!(error.retry_category(), RetryCategory::Permanent);
        assert!(error.to_string().contains("region-reference"));
    }

    #[tokio::test]
    async fn edge_http_403_without_server_date_does_not_retry() {
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut config = EdgeConfig::new("pt-BR-FranciscaNeural").unwrap();
        config.max_retries = 3;
        let client = EdgeTtsClient::with_transport(
            config,
            Arc::new(ForbiddenConnectTransport {
                attempts: Arc::clone(&attempts),
            }),
            1,
            None,
        );

        let error = client.synthesize("hello").await.unwrap_err();

        assert_eq!(attempts.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(
            error,
            EdgeError::Forbidden {
                edge_reference: Some("edge-ref-test".into()),
                server_date: None,
            }
        );
    }

    #[tokio::test]
    async fn edge_http_403_with_server_date_adjusts_clock_and_retries_once() {
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let old_skew = EDGE_CLOCK_SKEW_SECONDS.load(Ordering::Relaxed);
        let server_date = (time::OffsetDateTime::now_utc() + time::Duration::seconds(300))
            .format(&time::format_description::well_known::Rfc2822)
            .unwrap();
        let mut config = EdgeConfig::new("pt-BR-FranciscaNeural").unwrap();
        config.max_retries = 3;
        let client = EdgeTtsClient::with_transport(
            config,
            Arc::new(ClockSkewCorrectionTransport {
                attempts: Arc::clone(&attempts),
                server_date,
            }),
            1,
            None,
        );

        let error = client.synthesize("hello").await.unwrap_err();

        assert_eq!(attempts.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert_eq!(
            error,
            EdgeError::Forbidden {
                edge_reference: Some("edge-ref-clock-test".into()),
                server_date: None,
            }
        );
        EDGE_CLOCK_SKEW_SECONDS.store(old_skew, Ordering::Relaxed);
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
            reference_synthesis_timeout(
                2_000,
                2_048,
                Duration::from_secs(25),
                3,
                Duration::from_secs(3_600)
            ),
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
        let header = b"Path:audio\r\nContent-Type:audio/mpeg";
        let mut frame = Vec::new();
        frame.extend_from_slice(&(header.len() as u16).to_be_bytes());
        frame.extend_from_slice(header);
        frame.extend_from_slice(&[1, 2]);
        assert_eq!(parse_audio_frame(&frame).unwrap(), vec![1, 2]);
    }

    #[test]
    fn binary_frame_rejects_non_audio_control_frames() {
        let header = b"Path:metadata\r\nContent-Type:application/json";
        let mut frame = Vec::new();
        frame.extend_from_slice(&(header.len() as u16).to_be_bytes());
        frame.extend_from_slice(header);
        frame.extend_from_slice(b"{}");

        assert!(matches!(
            parse_audio_frame(&frame),
            Err(EdgeError::Protocol(message)) if message.contains("unexpected binary frame path metadata")
        ));
    }
}
