// Preserve tts::protocol_tests identity and its existing behavioral assertions.
use super::edge_audio_stream::*;
use super::edge_protocol::*;
use super::edge_transport::*;
use http::Request;
use std::{
    sync::{atomic::Ordering, Arc},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use url::Url;

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
    assert_eq!(endpoint.path(), "/tts/cognitiveservices/websocket/v1");

    let request = request_url(&endpoint, "connection-id", TRUSTED_CLIENT_TOKEN).unwrap();
    let query = request.query_pairs().collect::<Vec<_>>();
    assert!(query.iter().any(|(key, value)| {
        key == "Ocp-Apim-Subscription-Key" && value == TRUSTED_CLIENT_TOKEN
    }));
    assert!(query
        .iter()
        .any(|(key, value)| { key == "ConnectionId" && value == "connection-id" }));
    assert!(query.iter().any(|(key, _)| key == "Sec-MS-GEC"));
    assert!(query
        .iter()
        .any(|(key, value)| { key == "Sec-MS-GEC-Version" && value == EDGE_BROWSER_VERSION }));
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
    let client = EdgeTtsClient::with_transport(config, Arc::new(StalledConnectTransport), 1, None);

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
