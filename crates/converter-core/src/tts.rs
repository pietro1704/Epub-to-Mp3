//! Deterministic Edge-TTS WebSocket client.
//!
//! The protocol is intentionally kept in this crate rather than delegated to a
//! platform bridge: it makes framing, SSML, cancellation, and retry behavior
//! identical on every conversion surface. `EdgeTransport` is injectable so
//! protocol tests can use a local deterministic server without network calls.

use crate::adaptive::{AdaptiveRequestPermit, AdaptiveThroughputController};
use http::Request;
use std::{fmt, sync::Arc, time::Duration};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use url::Url;

mod edge_audio_stream;
mod edge_protocol;
mod edge_request_execution;
mod edge_transport;
pub(crate) use edge_audio_stream::reference_synthesis_timeout_for_text;
pub use edge_audio_stream::{
    synthesize_with_reference_client, synthesize_with_reference_client_chunks,
    synthesize_with_reference_client_stream,
};
pub use edge_protocol::{make_ssml, sec_ms_gec, split_protocol_chunks, xml_escape};
pub use edge_transport::WebSocketTransport;

pub const DEFAULT_ENDPOINT: &str =
    "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1";
pub const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
pub const DEFAULT_OUTPUT_FORMAT: &str = "audio-24khz-48kbitrate-mono-mp3";
pub const DEFAULT_CHUNK_CHARS: usize = 12_000;
pub const DEFAULT_CONCURRENCY: usize = 8;
const REFERENCE_MAX_RETRIES: usize = 3;
pub type Telemetry = Arc<dyn Fn(TelemetryEvent) + Send + Sync>;
pub type EdgeSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

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
}

#[cfg(test)]
#[path = "tts/edge_protocol_tests.rs"]
mod protocol_tests;
