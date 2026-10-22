    #[test]
    fn preference_edge_allows_first_audio_after_five_seconds() {
        let bytes = run_preference_edge_synthesis(
            async {
                tokio::time::sleep(std::time::Duration::from_millis(5_100)).await;
                Ok(vec![1, 2, 3])
            },
            &CancellationToken::default(),
            20,
        )
        .expect("Configured Edge must retain the reference client's connection/retry budget");
        assert_eq!(bytes, vec![1, 2, 3]);
    }

    #[test]
    fn preference_edge_keeps_cancellation_and_provider_error_identity() {
        let cancelled = CancellationToken::default();
        cancelled.cancel();
        assert!(matches!(
            run_preference_edge_synthesis::<Vec<u8>, _>(
                async { panic!("Cancelled jobs must not contact Edge") },
                &cancelled,
                20,
            ),
            Err(WorkerError::Cancelled)
        ));
        assert!(matches!(
            run_preference_edge_synthesis::<Vec<u8>, _>(
                async { Err(EdgeError::NoAudio) },
                &CancellationToken::default(),
                20,
            ),
            Err(WorkerError::Edge(EdgeError::NoAudio))
        ));
    }

    #[test]
    fn edge_synthesis_panic_remains_a_typed_worker_error() {
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async { panic!("simulated synthesis panic") },
            &CancellationToken::default(),
            std::time::Duration::from_secs(1),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(message)))
                if message == "synthesis thread panicked"
        ));
    }

    #[test]
    fn edge_timeout_returns_before_the_pending_synthesis_finishes() {
        let started = std::time::Instant::now();
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                Ok(vec![1, 2, 3])
            },
            &CancellationToken::default(),
            std::time::Duration::from_millis(20),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(_)))
        ));
        assert!(
            started.elapsed() < std::time::Duration::from_millis(250),
            "timeout waited for synthesis: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn edge_timeout_does_not_wait_for_blocking_runtime_cleanup() {
        let started = std::time::Instant::now();
        let result = run_edge_synthesis(
            async {
                tokio::task::spawn_blocking(|| {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                });
                std::future::pending::<Result<Vec<u8>, EdgeError>>().await
            },
            &CancellationToken::default(),
            std::time::Duration::from_millis(20),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(_)))
        ));
        assert!(
            started.elapsed() < std::time::Duration::from_millis(250),
            "timeout waited for blocking cleanup: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn edge_cancellation_drops_active_synthesis_without_waiting_for_it() {
        struct DropSignal(Arc<std::sync::atomic::AtomicBool>);
        impl Drop for DropSignal {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let signal = DropSignal(dropped.clone());
        let cancel = CancellationToken::default();
        let started = std::time::Instant::now();
        let result = std::thread::scope(|scope| {
            let token = cancel.clone();
            scope.spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(20));
                token.cancel();
            });
            run_edge_synthesis(
                async move {
                    let _signal = signal;
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    Ok(vec![1])
                },
                &cancel,
                std::time::Duration::from_secs(1),
            )
        });
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(started.elapsed() < std::time::Duration::from_millis(250));
        assert!(dropped.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn edge_cancelled_request_does_not_poll_synthesis() {
        let cancel = CancellationToken::default();
        cancel.cancel();
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async { panic!("cancelled requests must not start synthesis") },
            &cancel,
            std::time::Duration::from_secs(1),
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
    }

    #[test]
    fn edge_deadline_preserves_success_and_original_engine_error() {
        let cancel = CancellationToken::default();
        let timeout = std::time::Duration::from_secs(1);
        assert_eq!(
            run_edge_synthesis(async { Ok(vec![1, 2]) }, &cancel, timeout).unwrap(),
            vec![1, 2]
        );
        assert!(matches!(
            run_edge_synthesis::<Vec<u8>, _>(async { Err(EdgeError::NoAudio) }, &cancel, timeout),
            Err(WorkerError::Edge(EdgeError::NoAudio))
        ));
    }
