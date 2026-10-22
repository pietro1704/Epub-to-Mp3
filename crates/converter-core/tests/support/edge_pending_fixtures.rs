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

pub(super) fn binary_frame(header: &[u8], payload: &[u8]) -> Message {
    let mut frame = Vec::new();
    frame.extend_from_slice(&u16::try_from(header.len()).unwrap().to_be_bytes());
    frame.extend_from_slice(header);
    frame.extend_from_slice(payload);
    Message::Binary(frame.into())
}

pub(super) fn audio_frame(payload: &[u8]) -> Message {
    binary_frame(b"Path:audio\r\nContent-Type:audio/mpeg", payload)
}

pub(super) struct LocalTransport;

pub(super) struct FailFirstTransport(pub(super) AtomicUsize);

pub(super) struct FailTwiceTransport(pub(super) AtomicUsize);

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

pub(super) fn controller(initial: usize) -> Arc<AdaptiveThroughputController> {
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
pub(super) enum Behavior {
    Echo,
    SpeechOnly,
    MissingAudioPath,
    Reverse,
    Stall,
}

pub(super) struct EchoServer {
    pub(super) endpoint: String,
    pub(super) received: Arc<Mutex<Vec<String>>>,
    pub(super) completed: Arc<Mutex<Vec<String>>>,
    pub(super) two_received: Arc<Notify>,
    pub(super) task: JoinHandle<()>,
}

impl Drop for EchoServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl EchoServer {
    pub(super) async fn start(behavior: Behavior) -> Self {
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
                                let audio = if matches!(behavior, Behavior::MissingAudioPath) {
                                    binary_frame(b"Content-Type:audio/mpeg", text.as_bytes())
                                } else {
                                    audio_frame(text.as_bytes())
                                };
                                socket.send(audio).await.unwrap();
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

    pub(super) fn config(&self) -> EdgeConfig {
        let mut config = EdgeConfig::new("en-US-GuyNeural").unwrap();
        config.endpoint = self.endpoint.parse().unwrap();
        config.concurrency = 1;
        config.max_retries = 0;
        config.timeout = Duration::from_secs(2);
        config
    }
}
