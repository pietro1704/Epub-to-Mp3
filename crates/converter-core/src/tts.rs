//! Deterministic Edge-TTS WebSocket client.
//!
//! The protocol is intentionally kept in this crate rather than delegated to a
//! platform bridge: it makes framing, SSML, cancellation, and retry behavior
//! identical on every conversion surface. `EdgeTransport` is injectable so
//! protocol tests can use a local deterministic server without network calls.

use std::{fmt, sync::Arc, time::Duration};

use futures_util::{SinkExt, StreamExt};
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

pub const DEFAULT_ENDPOINT: &str =
    "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1";
pub const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
pub const DEFAULT_OUTPUT_FORMAT: &str = "audio-24khz-48kbitrate-mono-mp3";
pub const DEFAULT_CHUNK_CHARS: usize = 12_000;
pub const DEFAULT_CONCURRENCY: usize = 8;
const EDGE_BROWSER_VERSION: &str = "1-143.0.3650.75";

pub type Telemetry = Arc<dyn Fn(TelemetryEvent) + Send + Sync>;
pub type EdgeSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

pub async fn synthesize_with_reference_client(
    text: &str,
    voice: &str,
) -> Result<Vec<u8>, EdgeError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut config = EdgeConfig::new(voice)?;
    config.chunk_chars = if cfg!(target_os = "android") {
        4096
    } else {
        12000
    };
    config.concurrency = 1;
    config.timeout = Duration::from_secs(if cfg!(target_os = "android") { 60 } else { 30 });
    let client = EdgeTtsClient::new(config);
    let result = timeout(
        Duration::from_secs(if cfg!(target_os = "android") { 120 } else { 45 }),
        client.synthesize(text),
    )
    .await
    .map_err(|_| EdgeError::Timeout)?
    .map_err(|error| EdgeError::Transport(error.to_string()))?;
    Ok(result)
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

#[derive(Clone, Debug, PartialEq, Eq)]
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
}

#[derive(Debug, PartialEq, Eq)]
pub enum EdgeError {
    InvalidInput(String),
    Url(String),
    Transport(String),
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
            max_retries: 1,
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
            .map_err(|e| EdgeError::Transport(e.to_string()))?;
            Ok(socket)
        })
    }
}

pub struct EdgeTtsClient<T = WebSocketTransport> {
    config: EdgeConfig,
    transport: Arc<T>,
    limiter: Arc<Semaphore>,
    telemetry: Option<Telemetry>,
}

impl EdgeTtsClient<WebSocketTransport> {
    pub fn new(config: EdgeConfig) -> Self {
        let permits = config.concurrency.max(1);
        Self::with_transport(config, Arc::new(WebSocketTransport), permits, None)
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
        }
    }

    pub fn config(&self) -> &EdgeConfig {
        &self.config
    }

    pub async fn synthesize(&self, text: &str) -> Result<Vec<u8>, EdgeError> {
        if text.trim().is_empty() {
            return Err(EdgeError::InvalidInput("text is empty".into()));
        }
        let _permit = self
            .limiter
            .acquire()
            .await
            .map_err(|_| EdgeError::Cancelled)?;
        let chunks = split_protocol_chunks(text, self.config.chunk_chars);
        let mut output = Vec::new();
        for chunk in chunks {
            let ssml = make_ssml_escaped(
                &chunk,
                &self.config.voice,
                &self.config.rate,
                &self.config.volume,
                &self.config.pitch,
                false,
            );
            output.extend(self.synthesize_request(&ssml, chunk.len()).await?);
        }
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
        let _permit = self
            .limiter
            .acquire()
            .await
            .map_err(|_| EdgeError::Cancelled)?;
        self.synthesize_request(ssml, ssml.len()).await
    }

    async fn synthesize_request(&self, ssml: &str, chars: usize) -> Result<Vec<u8>, EdgeError> {
        let request_id = random_id();
        let mut retries = 0;
        loop {
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
            match self.run_request(request.clone(), &request_id, ssml).await {
                Ok(audio) => {
                    self.emit(TelemetryEvent::RequestFinished {
                        request_id: request_id.clone(),
                        bytes: audio.len(),
                        retries,
                    });
                    return Ok(audio);
                }
                Err(error)
                    if error.retry_category().retryable() && retries < self.config.max_retries =>
                {
                    let category = error.retry_category();
                    retries += 1;
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category,
                        retries,
                    });
                    tokio::time::sleep(Duration::from_secs(2u64.saturating_pow(retries as u32)))
                        .await;
                }
                Err(error) => {
                    self.emit(TelemetryEvent::RequestFailed {
                        request_id: request_id.clone(),
                        category: error.retry_category(),
                        retries,
                    });
                    return Err(error);
                }
            }
        }
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
        match timeout(self.config.timeout, receive).await {
            Ok(result) => result,
            Err(_) => {
                self.emit(TelemetryEvent::Cancelled {
                    request_id: request_id.into(),
                });
                Err(EdgeError::Timeout)
            }
        }
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
    format!("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='{}'><prosody pitch='{}' rate='{}' volume='{}'>{}</prosody></voice></speak>", xml_escape(voice), xml_escape(rate), xml_escape(volume), xml_escape(pitch), text)
}

pub fn split_protocol_chunks(text: &str, limit: usize) -> Vec<String> {
    let limit = limit.max(1);
    let escaped = xml_escape(text);
    let mut bytes = escaped.as_bytes();
    let mut chunks = Vec::new();

    while bytes.len() > limit {
        let mut split_at = bytes[..limit]
            .iter()
            .rposition(|byte| *byte == b'\n' || *byte == b' ')
            .unwrap_or(limit);

        while std::str::from_utf8(&bytes[..split_at]).is_err() && split_at > 0 {
            split_at -= 1;
        }

        while split_at > 0 {
            let Some(amp_index) = bytes[..split_at].iter().rposition(|byte| *byte == b'&') else {
                break;
            };
            if bytes[amp_index..split_at].contains(&b';') {
                break;
            }
            split_at = amp_index;
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
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='en-US-GuyNeural'><prosody pitch='+0%' rate='+0%' volume='+0Hz'>A &amp; &lt;B&gt; &apos;quoted&apos;</prosody></voice></speak>"
        );
        assert!(!ssml.contains("xmlns:mstts"));
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
