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

#[path = "support/edge_pending_fixtures.rs"]
mod edge_pending_fixtures;
use edge_pending_fixtures::*;

#[tokio::test]
async fn binary_audio_without_path_is_rejected_through_the_transport() {
    let server = EchoServer::start(Behavior::MissingAudioPath).await;
    let client = EdgeTtsClient::with_adaptive_transport(
        server.config(),
        Arc::new(LocalTransport),
        controller(128),
        None,
    );
    let result = tokio::time::timeout(Duration::from_secs(5), client.synthesize("hello"))
        .await
        .expect("malformed local response must finish with a protocol error");
    assert!(matches!(
        result,
        Err(EdgeError::Protocol(message))
            if message == "Edge returned unexpected binary frame path <missing>"
    ));
    assert_eq!(*server.received.lock().unwrap(), vec!["hello".to_owned()]);
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
async fn playback_chunk_callback_delivers_in_order_and_can_stop_dispatch() {
    let server = EchoServer::start(Behavior::Echo).await;
    let mut config = server.config();
    config.concurrency = 1;
    let client = EdgeTtsClient::with_adaptive_transport(
        config,
        Arc::new(LocalTransport),
        controller(4),
        None,
    );
    let received = Arc::new(Mutex::new(Vec::new()));
    let callback_chunks = Arc::clone(&received);
    let audio = client
        .synthesize_with_chunks("abcdefghijkl", move |index, bytes| {
            callback_chunks
                .lock()
                .unwrap()
                .push((index, bytes.to_vec()));
            true
        })
        .await
        .unwrap();
    let chunks = received.lock().unwrap();
    assert_eq!(
        chunks.iter().map(|(index, _)| *index).collect::<Vec<_>>(),
        [0, 1, 2]
    );
    assert_eq!(
        chunks
            .iter()
            .flat_map(|(_, bytes)| bytes.clone())
            .collect::<Vec<_>>(),
        audio
    );
    drop(chunks);

    let server = EchoServer::start(Behavior::Echo).await;
    let mut config = server.config();
    config.concurrency = 1;
    let client = EdgeTtsClient::with_adaptive_transport(
        config,
        Arc::new(LocalTransport),
        controller(4),
        None,
    );
    let streamed_chunks = Arc::new(Mutex::new(Vec::new()));
    let callback_chunks = Arc::clone(&streamed_chunks);
    client
        .stream_with_chunks("abcdefghijkl", move |index, bytes| {
            callback_chunks
                .lock()
                .unwrap()
                .push((index, bytes.to_vec()));
            true
        })
        .await
        .unwrap();
    let streamed_chunks = streamed_chunks.lock().unwrap();
    assert_eq!(
        streamed_chunks
            .iter()
            .map(|(index, _)| *index)
            .collect::<Vec<_>>(),
        [0, 1, 2]
    );
    assert_eq!(
        streamed_chunks
            .iter()
            .flat_map(|(_, bytes)| bytes.clone())
            .collect::<Vec<_>>(),
        b"abcdefghijkl"
    );
    drop(streamed_chunks);

    let server = EchoServer::start(Behavior::Echo).await;
    let mut config = server.config();
    config.concurrency = 1;
    let client = EdgeTtsClient::with_adaptive_transport(
        config,
        Arc::new(LocalTransport),
        controller(4),
        None,
    );
    let error = client
        .synthesize_with_chunks("abcdefghijkl", |_, _| false)
        .await
        .unwrap_err();
    assert_eq!(error, EdgeError::Cancelled);
    assert_eq!(server.received.lock().unwrap().len(), 1);
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
