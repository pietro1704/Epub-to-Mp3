    #[test]
    fn fallback_resumes_failed_segment_without_replaying_and_retries_edge() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let requests = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&requests);
        let audio = platform_tts::encode_wav(&test_system_wav_at_rate(24000)).unwrap();
        worker.test_edge = Some(Arc::new(move |_| {
            if !matches!(count.fetch_add(1, Ordering::AcqRel), 1 | 3) {
                Ok(audio.clone())
            } else {
                Err(WorkerError::Edge(EdgeError::Timeout))
            }
        }));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::clone(&delivered);
        worker = worker.with_streaming_chunks(Arc::new(move |_, index, bytes| {
            assert!(platform_tts::validate_mp3(bytes).is_ok());
            received.lock().unwrap().push(index);
            true
        }));
        let text = "A sentence to preserve every word. ".repeat(70);
        let pieces = platform_tts::segments(&text).unwrap();
        let native = std::sync::atomic::AtomicBool::new(false);
        worker
            .synthesize_platform_policy(
                "edge",
                &text,
                &temp.path().join("audio.mp3"),
                0,
                None,
                Some("en-US"),
                &std::sync::atomic::AtomicBool::new(false),
                &native,
                "job",
                1,
                0,
            )
            .unwrap();
        assert_eq!(requests.load(Ordering::Acquire), pieces.len());
        let native_texts = spoken.lock().unwrap();
        assert_eq!(
            native_texts.join(" "),
            [pieces[1].as_str(), pieces[3].as_str()].join(" ")
        );
        assert!(native_texts[0].chars().count() <= 60);
        assert!(native_texts
            .iter()
            .skip(1)
            .all(|text| text.chars().count() <= 240));
        let expected_chunk_count = pieces.len() - 2 + native_texts.len();
        drop(native_texts);
        assert_eq!(
            *delivered.lock().unwrap(),
            (0..expected_chunk_count).collect::<Vec<_>>()
        );
        assert!(native.load(Ordering::Acquire));
        let artifact = temp.path().join("audio.mp3");
        audio::validate_audio(&artifact, 100).unwrap();
        assert_eq!(audio::probe_sample_rate(&artifact).unwrap(), 24000);
        assert_eq!(
            fs::read_to_string(temp.path().join("audio.provider")).unwrap(),
            "edge+system"
        );
    }
    #[test]
    fn forced_system_delivers_bounded_utterances_before_synthesizing_next_chunk() {
        struct BoundedSystem {
            spoken: Arc<Mutex<Vec<String>>>,
            delivered: Arc<Mutex<Vec<usize>>>,
        }
        impl PlatformTts for BoundedSystem {
            fn synthesize_wav(
                &self,
                text: &str,
                _: &str,
                output: &Path,
                cancelled: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                assert!(!cancelled());
                let mut spoken = self.spoken.lock().unwrap();
                assert!(text.chars().count() <= if spoken.is_empty() { 60 } else { 240 });
                assert_eq!(
                    self.delivered.lock().unwrap().len(),
                    spoken.len(),
                    "Previous native audio must play before the next synthesis starts"
                );
                spoken.push(text.into());
                fs::write(output, test_system_wav()).map_err(|error| error.to_string())
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::clone(&delivered);
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(BoundedSystem {
                spoken: Arc::clone(&spoken),
                delivered: Arc::clone(&delivered),
            }))
            .with_streaming_chunks(Arc::new(move |_, index, bytes| {
                platform_tts::validate_mp3(bytes).unwrap();
                received.lock().unwrap().push(index);
                true
            }));
        let text = "Uma frase para preservar todo o conteúdo sem repetição. ".repeat(24);
        worker
            .synthesize_platform_policy(
                "system",
                &text,
                &temp.path().join("audio.mp3"),
                0,
                None,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0,
            )
            .unwrap();
        let spoken = spoken.lock().unwrap();
        assert_eq!(spoken.join(" "), text.trim());
        assert!(spoken.len() >= 6);
        assert_eq!(
            *delivered.lock().unwrap(),
            (0..spoken.len()).collect::<Vec<_>>()
        );
        audio::validate_audio(temp.path().join("audio.mp3"), 100).unwrap();
    }

    #[test]
    fn system_pcm_normalization_rejects_unsupported_sample_rates() {
        for rate in [1u32, 192000] {
            let mut wav = test_system_wav();
            wav[24..28].copy_from_slice(&rate.to_le_bytes());
            assert!(platform_tts::encode_wav(&wav).is_err());
        }
        let encoded = platform_tts::encode_wav(&test_system_wav()).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let artifact = temp.path().join("normalized.mp3");
        fs::write(&artifact, encoded).unwrap();
        assert_eq!(audio::probe_sample_rate(&artifact).unwrap(), 24000);
    }

    #[test]
    fn system_wav_with_extra_riff_chunks_is_encoded_and_truncation_rejected() {
        let mut wav = test_system_wav();
        let mut extra = b"JUNK".to_vec();
        extra.extend_from_slice(&4u32.to_le_bytes());
        extra.extend_from_slice(b"test");
        wav.splice(12..12, extra);
        let size = (wav.len() - 8) as u32;
        wav[4..8].copy_from_slice(&size.to_le_bytes());
        assert!(platform_tts::encode_wav(&wav).is_ok());
        wav.pop();
        assert!(platform_tts::encode_wav(&wav).is_err());
    }
    #[test]
    fn edge_success_after_previous_native_notice_is_delivered() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let sticky = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let selected = Arc::clone(&sticky);
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let edge_bytes = platform_tts::encode_wav(&test_system_wav()).unwrap();
        worker.test_edge = Some(Arc::new(move |_| {
            selected.store(true, Ordering::Release);
            Ok(edge_bytes.clone())
        }));
        worker
            .synthesize_platform_policy(
                "edge",
                "Pending Edge segment",
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &sticky,
                "job",
                1,
                0,
            )
            .unwrap();
        assert!(spoken.lock().unwrap().is_empty());
        assert_eq!(
            fs::read_to_string(temp.path().join("audio.provider")).unwrap(),
            "edge"
        );
    }
