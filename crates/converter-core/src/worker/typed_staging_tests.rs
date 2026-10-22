    #[test]
    fn typed_policy_staging_stays_in_job_output_and_is_cleaned_on_every_exit() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        struct RecordingSystem {
            paths: Arc<Mutex<Vec<PathBuf>>>,
            cancel: CancellationToken,
            outcome: &'static str,
        }
        impl PlatformTts for RecordingSystem {
            fn synthesize_wav(
                &self,
                _: &str,
                _: &str,
                output: &Path,
                _: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                self.paths.lock().unwrap().push(output.to_path_buf());
                fs::write(output, test_system_wav()).map_err(|e| e.to_string())?;
                match self.outcome {
                    "failure" => Err("fixture speech failed".into()),
                    "cancelled" => {
                        self.cancel.cancel();
                        Ok(())
                    }
                    _ => Ok(()),
                }
            }
        }
        for outcome in ["success", "failure", "cancelled"] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("book.epub");
            platform_test_book_with_text(&input, "Uma frase curta.");
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let job_output = config.paths.output_dir.join(outcome);
            let paths = Arc::new(Mutex::new(Vec::new()));
            let cancel = CancellationToken::default();
            let worker = ConversionWorker::new(config)
                .unwrap()
                .with_cancellation(cancel.clone())
                .with_platform_tts(Arc::new(RecordingSystem {
                    paths: Arc::clone(&paths),
                    cancel,
                    outcome,
                }));
            let mut request = preference_test_request();
            request.input = input;
            request.job_id = outcome.into();
            request.tts_preferences = Some(TtsPreferences {
                policy_version: None,
                primary: TtsSelection {
                    engine: "system".into(),
                    model_id: None,
                    voice: None,
                },
                secondary: None,
                allow_online_fallback: false,
            });
            let result = worker.run(request);
            if outcome == "success" {
                let manifest = result.unwrap();
                let audio = job_output.join(&manifest.chapters[0].filename);
                assert!(platform_tts::validate_mp3(&fs::read(audio).unwrap()).is_ok());
                assert_eq!(manifest.used_selections[0].engine, "system");
            } else {
                if outcome == "cancelled" {
                    assert!(matches!(result, Err(WorkerError::Cancelled)));
                } else {
                    assert!(result
                        .unwrap_err()
                        .to_string()
                        .contains("fixture speech failed"));
                }
                assert!(!job_output.join("manifest.json").exists());
            }
            let paths = paths.lock().unwrap();
            assert!(!paths.is_empty(), "the real worker must invoke speech");
            for path in paths.iter() {
                assert!(
                    path.starts_with(&job_output),
                    "speech staging must use app-owned job output: {path:?}"
                );
                assert!(!path.parent().unwrap().exists(), "staging must be removed");
            }
        }
    }
