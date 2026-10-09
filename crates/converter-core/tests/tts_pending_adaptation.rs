#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    adaptive::{AdaptiveConfig, AdaptiveThroughputController, ProviderFailure},
    tts::{EdgeConfig, EdgeError, EdgeTransport, EdgeTtsClient, TelemetryEvent, TransportFuture},
};
use futures_util::{SinkExt, StreamExt};
use http::Request;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::{
    net::TcpListener,
    sync::Notify,
    task::{JoinHandle, JoinSet},
};
use tokio_tungstenite::{accept_async, client_async, tungstenite::Message, MaybeTlsStream};

struct LocalTransport;

struct FailFirstTransport(AtomicUsize);

struct FailTwiceTransport(AtomicUsize);

impl EdgeTransport for FailTwiceTransport {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a> {
        if self.0.fetch_add(1, Ordering::SeqCst) < 2 {
            Box::pin(async {
                Err(EdgeError::RateLimited {
                    status: 429,
                    retry_after: None,
                })
            })
        } else {
            LocalTransport.connect(request)
        }
    }
}

impl EdgeTransport for FailFirstTransport {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a> {
        if self.0.fetch_add(1, Ordering::SeqCst) == 0 {
            Box::pin(async {
                Err(EdgeError::RateLimited {
                    status: 429,
                    retry_after: None,
                })
            })
        } else {
            LocalTransport.connect(request)
        }
    }
}

impl EdgeTransport for LocalTransport {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a> {
        Box::pin(async move {
            let uri = request.uri().to_string();
            let authority = request.uri().authority().unwrap().as_str();
            let stream = tokio::net::TcpStream::connect(authority)
                .await
                .map_err(|error| EdgeError::Transport(error.to_string()))?;
            let (socket, _) = client_async(uri, MaybeTlsStream::Plain(stream))
                .await
                .map_err(|error| EdgeError::Transport(error.to_string()))?;
            Ok(socket)
        })
    }
}

fn controller(initial: usize) -> Arc<AdaptiveThroughputController> {
    Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
        initial_chunk_chars: initial,
        min_chunk_chars: 4,
        max_chunk_chars: 2048,
        initial_max_in_flight: 1,
        min_max_in_flight: 1,
        max_max_in_flight: 2,
        success_window: 1,
        fast_chars_per_second: f64::INFINITY,
        slow_chars_per_second: 0.0,
        throttle_cooldown: Duration::ZERO,
        timeout_cooldown: Duration::ZERO,
        max_cooldown: Duration::ZERO,
    }))
}

#[derive(Clone, Copy)]
enum Behavior {
    Echo,
    SpeechOnly,
    Reverse,
    Stall,
}

struct EchoServer {
    endpoint: String,
    received: Arc<Mutex<Vec<String>>>,
    completed: Arc<Mutex<Vec<String>>>,
    two_received: Arc<Notify>,
    task: JoinHandle<()>,
}

impl Drop for EchoServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl EchoServer {
    async fn start(behavior: Behavior) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let received = Arc::new(Mutex::new(Vec::<String>::new()));
        let completed = Arc::new(Mutex::new(Vec::<String>::new()));
        let two_received = Arc::new(Notify::new());
        let reverse = Arc::new(Notify::new());
        let server_received = Arc::clone(&received);
        let server_completed = Arc::clone(&completed);
        let server_two_received = Arc::clone(&two_received);
        let task = tokio::spawn(async move {
            let mut tasks = JoinSet::new();
            loop {
                tokio::select! {
                    result = listener.accept() => {
                        let (stream, _) = result.unwrap();
                        let received = Arc::clone(&server_received);
                        let completed = Arc::clone(&server_completed);
                        let two_received = Arc::clone(&server_two_received);
                        let reverse = Arc::clone(&reverse);
                        tasks.spawn(async move {
                            let mut socket = accept_async(stream).await.unwrap();
                            socket.next().await.unwrap().unwrap();
                            let message = socket.next().await.unwrap().unwrap().into_text().unwrap();
                            let escaped = message.split("</prosody>").next().unwrap().rsplit('>').next().unwrap();
                            let text = quick_xml::escape::unescape(escaped).unwrap().into_owned();
                            let index = {
                                let mut received = received.lock().unwrap();
                                let index = received.len();
                                received.push(text.clone());
                                index
                            };
                            if index == 1 { two_received.notify_one(); }
                            match behavior {
                                Behavior::Stall => std::future::pending::<()>().await,
                                Behavior::Reverse if index == 1 => reverse.notified().await,
                                _ => {},
                            }
                            if !matches!(behavior, Behavior::SpeechOnly) || !text.trim().is_empty() {
                                let mut audio = vec![0, 0];
                                audio.extend_from_slice(text.as_bytes());
                                socket.send(Message::Binary(audio.into())).await.unwrap();
                            }
                            socket.send(Message::Text("Path:turn.end\r\n\r\n".into())).await.unwrap();
                            completed.lock().unwrap().push(text);
                            if matches!(behavior, Behavior::Reverse) && index == 2 { reverse.notify_one(); }
                        });
                    },
                    result = tasks.join_next(), if !tasks.is_empty() => { result.unwrap().unwrap(); },
                }
            }
        });
        Self {
            endpoint,
            received,
            completed,
            two_received,
            task,
        }
    }

    fn config(&self) -> EdgeConfig {
        let mut config = EdgeConfig::new("en-US-GuyNeural").unwrap();
        config.endpoint = self.endpoint.parse().unwrap();
        config.concurrency = 1;
        config.max_retries = 0;
        config.timeout = Duration::from_secs(2);
        config
    }
}

#[tokio::test]
async fn nonempty_text_never_dispatches_whitespace_only_speech_requests() {
    let server = EchoServer::start(Behavior::SpeechOnly).await;
    let adaptive = controller(12);
    let client = EdgeTtsClient::with_adaptive_transport(
        server.config(),
        Arc::new(LocalTransport),
        adaptive,
        None,
    );
    let text = format!(
        "{}Olá😀 & mundo{}fim{}",
        " \n\t".repeat(10),
        " \n\t".repeat(10),
        " \n\t".repeat(10)
    );
    let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize(&text))
        .await
        .expect("local speech synthesis must finish")
        .expect("blank fragments must not make a nonempty chapter fail with NoAudio");
    let received = server.received.lock().unwrap();
    assert!(
        received.iter().all(|chunk| !chunk.trim().is_empty()),
        "blank speech request: {received:?}"
    );
    let spoken = |text: &str| {
        text.chars()
            .filter(|character| !character.is_whitespace())
            .collect::<String>()
    };
    assert_eq!(spoken(&received.concat()), spoken(&text));
    assert_eq!(audio, received.concat().as_bytes());
}

#[tokio::test]
async fn unsent_text_uses_latest_size_and_preserves_utf8_and_audio_order() {
    let adaptive = controller(12);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let received = Arc::new(Mutex::new(Vec::<String>::new()));
    let server_received = Arc::clone(&received);
    let server_adaptive = Arc::clone(&adaptive);
    let server = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let received = Arc::clone(&server_received);
            let adaptive = Arc::clone(&server_adaptive);
            tokio::spawn(async move {
                let mut socket = accept_async(stream).await.unwrap();
                socket.next().await.unwrap().unwrap(); // speech.config
                let message = socket.next().await.unwrap().unwrap().into_text().unwrap();
                let escaped = message
                    .split("</prosody>")
                    .next()
                    .unwrap()
                    .rsplit('>')
                    .next()
                    .unwrap();
                let text = quick_xml::escape::unescape(escaped).unwrap().into_owned();
                let index = {
                    let mut received = received.lock().unwrap();
                    let index = received.len();
                    received.push(text.clone());
                    index
                };
                if index == 0 {
                    adaptive.observe_failure(ProviderFailure::Throttled { retry_after: None });
                }
                let mut audio = vec![0, 0];
                audio.extend_from_slice(text.as_bytes());
                socket.send(Message::Binary(audio.into())).await.unwrap();
                socket
                    .send(Message::Text("Path:turn.end\r\n\r\n".into()))
                    .await
                    .unwrap();
            });
        }
    });
    let mut config = EdgeConfig::new("en-US-GuyNeural").unwrap();
    config.endpoint = endpoint.parse().unwrap();
    config.concurrency = 2;
    config.max_retries = 0;
    config.timeout = Duration::from_secs(2);
    let client =
        EdgeTtsClient::with_adaptive_transport(config, Arc::new(LocalTransport), adaptive, None);
    let text = "abcdefghijklmnopqrstuvé😀<& xy z\n0123456789  ";
    let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize(text))
        .await
        .expect("local synthesis must finish")
        .unwrap();
    server.abort();
    let received = received.lock().unwrap();
    assert_eq!(received[0], "abcdefghijkl");
    assert!(
        received[1..].iter().all(|chunk| chunk.len() <= 6),
        "unsent fragments must use the reduced byte limit: {received:?}"
    );
    assert_eq!(received.concat(), text);
    assert_eq!(audio, text.as_bytes());
}

#[tokio::test]
async fn growth_dispatches_larger_concurrent_chunks_and_orders_reverse_responses() {
    let server = EchoServer::start(Behavior::Reverse).await;
    let adaptive = Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
        initial_chunk_chars: 8,
        min_chunk_chars: 4,
        max_chunk_chars: 16,
        initial_max_in_flight: 1,
        min_max_in_flight: 1,
        max_max_in_flight: 2,
        success_window: 1,
        fast_chars_per_second: 0.0,
        slow_chars_per_second: 0.0,
        ..AdaptiveConfig::default()
    }));
    let client = EdgeTtsClient::with_adaptive_transport(
        server.config(),
        Arc::new(LocalTransport),
        adaptive,
        None,
    );
    let text = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL";
    let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize(text))
        .await
        .expect("growth must permit the second concurrent response")
        .unwrap();
    let received = server.received.lock().unwrap();
    assert_eq!(
        received.iter().map(String::len).collect::<Vec<_>>(),
        vec![8, 16, 16, 8]
    );
    assert_eq!(server.completed.lock().unwrap()[1], received[2]);
    assert_eq!(audio, text.as_bytes());
}

#[tokio::test]
async fn pressure_preserves_retry_and_smaller_fragment_recovery() {
    for max_retries in [0, 1] {
        let server = EchoServer::start(Behavior::Echo).await;
        let adaptive = Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
            initial_chunk_chars: 4096,
            min_chunk_chars: 2048,
            max_chunk_chars: 4096,
            initial_max_in_flight: 1,
            min_max_in_flight: 1,
            max_max_in_flight: 1,
            fast_chars_per_second: f64::INFINITY,
            slow_chars_per_second: 0.0,
            throttle_cooldown: Duration::ZERO,
            timeout_cooldown: Duration::ZERO,
            max_cooldown: Duration::ZERO,
            ..AdaptiveConfig::default()
        }));
        let mut config = server.config();
        config.max_retries = max_retries;
        let transport = Arc::new(FailFirstTransport(AtomicUsize::new(0)));
        let client =
            EdgeTtsClient::with_adaptive_transport(config, Arc::clone(&transport), adaptive, None);
        let text = format!("{} é😀 & < >\n{}  ", "a".repeat(5000), "b".repeat(3500));
        let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize(&text))
            .await
            .unwrap()
            .unwrap();
        let received = server.received.lock().unwrap();
        assert_eq!(
            received[0].len(),
            if max_retries == 1 { 4096 } else { 2048 }
        );
        assert!(received[1..].iter().all(|chunk| chunk.len() <= 2048));
        assert_eq!(transport.0.load(Ordering::SeqCst), received.len() + 1);
        assert_eq!(received.concat(), text);
        assert_eq!(audio, text.as_bytes());
    }
}

#[tokio::test]
async fn repeated_pressure_resizes_unsent_retry_fragments() {
    let server = EchoServer::start(Behavior::SpeechOnly).await;
    let adaptive = Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
        initial_chunk_chars: 6144,
        min_chunk_chars: 2048,
        max_chunk_chars: 6144,
        initial_max_in_flight: 1,
        min_max_in_flight: 1,
        max_max_in_flight: 1,
        fast_chars_per_second: f64::INFINITY,
        slow_chars_per_second: 0.0,
        throttle_cooldown: Duration::ZERO,
        timeout_cooldown: Duration::ZERO,
        max_cooldown: Duration::ZERO,
        ..AdaptiveConfig::default()
    }));
    let transport = Arc::new(FailTwiceTransport(AtomicUsize::new(0)));
    let client = EdgeTtsClient::with_adaptive_transport(
        server.config(),
        Arc::clone(&transport),
        Arc::clone(&adaptive),
        None,
    );
    let text = "abcdef".repeat(1024);
    let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize(&text))
        .await
        .expect("recursive recovery must terminate")
        .unwrap();
    let received = server.received.lock().unwrap();
    assert!(
        received.iter().all(|chunk| chunk.len() <= 2048),
        "all unsent retry fragments must reflect the second pressure signal: {:?}",
        received.iter().map(String::len).collect::<Vec<_>>()
    );
    assert_eq!(received.concat(), text);
    assert_eq!(audio, text.as_bytes());
    assert_eq!(transport.0.load(Ordering::SeqCst), received.len() + 2);
    assert_eq!(adaptive.snapshot().in_flight, 0);
}

#[tokio::test]
async fn failure_feedback_retains_the_active_permit() {
    let server = EchoServer::start(Behavior::SpeechOnly).await;
    let adaptive = controller(12);
    let observed = Arc::new(Mutex::new(Vec::new()));
    let callback_observed = Arc::clone(&observed);
    let callback_adaptive = Arc::clone(&adaptive);
    let telemetry = Arc::new(move |event| {
        if let TelemetryEvent::ChunkMetrics { result, .. } = event {
            if result.starts_with("pressure:") {
                let snapshot = callback_adaptive.snapshot();
                callback_observed
                    .lock()
                    .unwrap()
                    .push((snapshot.in_flight, snapshot.chunk_chars));
            }
        }
    });
    let mut config = server.config();
    config.max_retries = 1;
    let client = EdgeTtsClient::with_adaptive_transport(
        config,
        Arc::new(FailFirstTransport(AtomicUsize::new(0))),
        adaptive,
        Some(telemetry),
    );
    let audio = tokio::time::timeout(Duration::from_secs(5), client.synthesize("abcdefghijkl"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(audio, b"abcdefghijkl");
    assert_eq!(
        *observed.lock().unwrap(),
        vec![(1, 6)],
        "publish reduced capacity while the failed request still owns its permit"
    );
}

#[tokio::test]
async fn dropping_synthesis_releases_capacity_and_does_not_dispatch_the_tail() {
    let server = EchoServer::start(Behavior::Stall).await;
    let adaptive = Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
        initial_chunk_chars: 8,
        min_chunk_chars: 4,
        max_chunk_chars: 8,
        initial_max_in_flight: 2,
        min_max_in_flight: 1,
        max_max_in_flight: 2,
        ..AdaptiveConfig::default()
    }));
    let client = EdgeTtsClient::with_adaptive_transport(
        server.config(),
        Arc::new(LocalTransport),
        Arc::clone(&adaptive),
        None,
    );
    let job = tokio::spawn(async move {
        client
            .synthesize("abcdefghijklmnopqrstuvwxyz0123456789")
            .await
    });
    tokio::time::timeout(Duration::from_secs(1), server.two_received.notified())
        .await
        .unwrap();
    assert_eq!(adaptive.snapshot().in_flight, 2);
    job.abort();
    assert!(job.await.unwrap_err().is_cancelled());
    assert_eq!(adaptive.snapshot().in_flight, 0);
    assert_eq!(server.received.lock().unwrap().len(), 2);
}
