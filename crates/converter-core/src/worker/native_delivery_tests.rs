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
            assert!(text.chars().count() <= if spoken.is_empty() { 180 } else { 800 });
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
            crate::pcm::validate_mp3(bytes).unwrap();
            received.lock().unwrap().push(index);
            true
        }));
    let text = "Uma frase para preservar todo o conteúdo sem repetição. ".repeat(24);
    synthesize_native_fixture(&worker, "system", &text, &temp.path().join("audio.mp3")).unwrap();
    let spoken = spoken.lock().unwrap();
    assert_eq!(spoken.join(" "), text.trim());
    assert!(spoken.len() >= 2);
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
        assert!(crate::pcm::encode_wav_mp3(&wav).is_err());
    }
    let encoded = crate::pcm::encode_wav_mp3(&test_system_wav()).unwrap();
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
    assert!(crate::pcm::encode_wav_mp3(&wav).is_ok());
    wav.pop();
    assert!(crate::pcm::encode_wav_mp3(&wav).is_err());
}
