use super::*;

struct ScopedRuntime {
    active: std::sync::Mutex<Option<(PathBuf, PathBuf)>>,
    calls: std::sync::Mutex<Vec<(PathBuf, PathBuf, String)>>,
    ready: bool,
    reject_init: bool,
}
impl PiperRuntime for ScopedRuntime {
    fn supports_explicit_model_paths(&self) -> bool {
        true
    }
    fn status(&self) -> PiperRuntimeStatus {
        PiperRuntimeStatus {
            runtime_loaded: true,
            model_available: self.ready,
            abi_compatible: true,
            engine_ready: self.ready,
        }
    }
    fn init(&self, model: &Path, config: &Path) -> Result<(), PiperError> {
        if self.reject_init {
            return Err(PiperError::Synthesis(
                "controlled initialization failure".into(),
            ));
        }
        *self.active.lock().unwrap() = Some((model.to_owned(), config.to_owned()));
        Ok(())
    }
    fn synthesize(&self, text: &str, output: &Path) -> Result<(), PiperError> {
        // Give another request an opportunity to initialize this shared runtime.
        std::thread::sleep(std::time::Duration::from_millis(10));
        let (model, config) = self.active.lock().unwrap().clone().unwrap();
        self.calls
            .lock()
            .unwrap()
            .push((model, config, text.into()));
        write_test_wav(output);
        Ok(())
    }
    fn shutdown(&self) {}
}
fn scoped_runtime(ready: bool, reject_init: bool) -> Arc<ScopedRuntime> {
    Arc::new(ScopedRuntime {
        active: std::sync::Mutex::new(None),
        calls: std::sync::Mutex::new(Vec::new()),
        ready,
        reject_init,
    })
}
fn installed_fixture(root: &Path, id: &str) {
    fs::create_dir(root.join(id)).unwrap();
    fs::write(root.join(id).join("voice.onnx"), b"synthetic model").unwrap();
    fs::write(root.join(id).join("voice.config.json"), b"{}").unwrap();
}

#[test]
fn explicit_model_preflight_requires_actual_initialization_and_ready_runtime() {
    let fixture = tempfile::tempdir().unwrap();
    installed_fixture(fixture.path(), "selected");
    for runtime in [scoped_runtime(false, false), scoped_runtime(true, true)] {
        assert!(PreparedPiperModel::prepare(
            fixture.path(),
            "selected",
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            runtime
        )
        .is_err());
    }
    let ignored_paths = Arc::new(RegisteredPiperRuntime::new(|_, _| Ok(())));
    assert!(PreparedPiperModel::prepare(
        fixture.path(),
        "selected",
        Path::new("voice.onnx"),
        Path::new("voice.config.json"),
        ignored_paths
    )
    .is_err());
    assert_eq!(
        fs::read(fixture.path().join("selected/voice.onnx")).unwrap(),
        b"synthetic model"
    );
}

#[tokio::test]
async fn prepared_model_refuses_removal_until_every_captured_session_is_released() {
    let root = tempfile::tempdir().unwrap();
    installed_fixture(root.path(), "selected");
    installed_fixture(root.path(), "unrelated");
    let runtime = scoped_runtime(true, false);
    let prepare = || {
        PreparedPiperModel::prepare(
            root.path(),
            "selected",
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            runtime.clone(),
        )
        .unwrap()
    };
    let first = prepare();
    let second = prepare();
    let store = crate::model_store::ModelStore::new(root.path());

    assert!(matches!(
        store.remove("selected").await,
        Err(crate::model_store::ModelStoreError::ModelInUse(_))
    ));
    drop(first);
    assert!(matches!(
        store.remove("selected").await,
        Err(crate::model_store::ModelStoreError::ModelInUse(_))
    ));
    assert_eq!(
        fs::read(root.path().join("selected/voice.onnx")).unwrap(),
        b"synthetic model"
    );
    drop(second);
    store.remove("selected").await.unwrap();
    assert!(!root.path().join("selected").exists());
    assert_eq!(
        fs::read(root.path().join("unrelated/voice.onnx")).unwrap(),
        b"synthetic model"
    );
}

#[test]
fn explicit_models_are_pinned_and_init_plus_synthesis_is_atomic_between_requests() {
    let fixture = tempfile::tempdir().unwrap();
    for id in ["one", "two"] {
        installed_fixture(fixture.path(), id);
    }
    let runtime = scoped_runtime(true, false);
    let mut requests = Vec::new();
    for id in ["one", "two"] {
        let prepared = PreparedPiperModel::prepare(
            fixture.path(),
            id,
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            runtime.clone(),
        )
        .unwrap();
        requests.push((id, prepared, fixture.path().join(format!("{id}.wav"))));
    }
    std::thread::scope(|scope| {
        for (id, prepared, output) in requests {
            scope.spawn(move || {
                prepared
                    .synthesize(id, &output, &CancellationToken::default())
                    .unwrap()
            });
        }
    });
    let calls = runtime.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    for (model, config, text) in calls.iter() {
        assert_eq!(
            model
                .parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap(),
            text
        );
        assert_eq!(config, &model.with_file_name("voice.config.json"));
    }
}

#[test]
fn explicit_model_paths_reject_traversal_missing_files_and_namespace_escape() {
    let fixture = tempfile::tempdir().unwrap();
    installed_fixture(fixture.path(), "selected");
    for (id, model, config) in [
        ("../selected", "voice.onnx", "voice.config.json"),
        ("selected", "../voice.onnx", "voice.config.json"),
        ("selected", "/outside.onnx", "voice.config.json"),
        ("selected", "missing.onnx", "voice.config.json"),
        ("selected", "voice.onnx", "missing.json"),
    ] {
        assert!(PreparedPiperModel::prepare(
            fixture.path(),
            id,
            Path::new(model),
            Path::new(config),
            scoped_runtime(true, false)
        )
        .is_err());
    }
    #[cfg(unix)]
    {
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("external.onnx"), b"preserve").unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("external.onnx"),
            fixture.path().join("selected/escape.onnx"),
        )
        .unwrap();
        assert!(PreparedPiperModel::prepare(
            fixture.path(),
            "selected",
            Path::new("escape.onnx"),
            Path::new("voice.config.json"),
            scoped_runtime(true, false)
        )
        .is_err());
        assert_eq!(
            fs::read(outside.path().join("external.onnx")).unwrap(),
            b"preserve"
        );
    }
}

#[test]
fn cancelled_explicit_model_preserves_existing_audio_and_model_identity_is_distinct() {
    let fixture = tempfile::tempdir().unwrap();
    for id in ["one", "two"] {
        installed_fixture(fixture.path(), id);
    }
    let runtime = scoped_runtime(true, false);
    let prepare = |id| {
        PreparedPiperModel::prepare(
            fixture.path(),
            id,
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            runtime.clone(),
        )
        .unwrap()
    };
    let first = prepare("one");
    let second = prepare("two");
    assert_ne!(first.cache_identity(), second.cache_identity());
    let output = fixture.path().join("previous.mp3");
    fs::write(&output, b"previous audio").unwrap();
    let cancel = CancellationToken::default();
    cancel.cancel();
    assert_eq!(
        first.synthesize("cancelled", &output, &cancel),
        Err(PiperError::Cancelled)
    );
    assert_eq!(fs::read(output).unwrap(), b"previous audio");
    assert!(runtime.calls.lock().unwrap().is_empty());
}

#[test]
fn replacing_model_or_config_at_same_paths_changes_prepared_cache_identity() {
    let fixture = tempfile::tempdir().unwrap();
    installed_fixture(fixture.path(), "selected");
    let runtime = scoped_runtime(true, false);
    let prepare = || {
        PreparedPiperModel::prepare(
            fixture.path(),
            "selected",
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            runtime.clone(),
        )
        .unwrap()
    };
    let original = prepare();
    fs::write(
        fixture.path().join("selected/voice.onnx"),
        b"replacement model",
    )
    .unwrap();
    let changed_model = prepare();
    assert_ne!(original.cache_identity(), changed_model.cache_identity());
    fs::write(
        fixture.path().join("selected/voice.config.json"),
        b"{\"new\":true}",
    )
    .unwrap();
    let changed_config = prepare();
    assert_ne!(
        changed_model.cache_identity(),
        changed_config.cache_identity()
    );
}

fn write_test_wav(path: &Path) {
    let sample_rate = 22_050_u32;
    let sample_count = sample_rate / 4;
    let data_length = sample_count * 2;
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_length).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16_u32.to_le_bytes());
    bytes.extend_from_slice(&1_u16.to_le_bytes());
    bytes.extend_from_slice(&1_u16.to_le_bytes());
    bytes.extend_from_slice(&sample_rate.to_le_bytes());
    bytes.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    bytes.extend_from_slice(&2_u16.to_le_bytes());
    bytes.extend_from_slice(&16_u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_length.to_le_bytes());
    for index in 0..sample_count {
        let sample = ((index as f32 * 440.0 * std::f32::consts::TAU / sample_rate as f32).sin()
            * i16::MAX as f32
            * 0.4) as i16;
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    fs::write(path, bytes).unwrap();
}

#[test]
fn mp3_destination_contains_decodable_audio_without_external_tools() {
    let root = tempfile::Builder::new()
        .prefix("piper codec's fixture ")
        .tempdir()
        .unwrap();
    let wav = root.path().join("native.wav");
    let output = root.path().join("chapter.mp3");
    write_test_wav(&wav);
    publish_piper_audio(&wav, &output).unwrap();
    let encoded = fs::read(&output).unwrap();
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(&encoded);
    decoder.flush();
    let mut decoded_samples = Vec::new();
    while let Ok(decoded) = decoder.next_frame() {
        decoded_samples.extend(decoded.samples);
    }
    assert!(!decoded_samples.is_empty());
    assert!(decoded_samples.iter().any(|sample| sample.abs() > 0.01));

    if std::process::Command::new("ffprobe")
        .arg("-version")
        .output()
        .is_ok()
    {
        let probe = std::process::Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=codec_name,sample_rate,channels",
                "-of",
                "csv=p=0",
            ])
            .arg(&output)
            .output()
            .expect("ffprobe availability was checked");
        assert!(probe.status.success());
        assert_eq!(String::from_utf8_lossy(&probe.stdout).trim(), "mp3,22050,1");
    }
    if std::process::Command::new("ffmpeg")
        .arg("-version")
        .output()
        .is_ok()
    {
        let decode = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-i"])
            .arg(&output)
            .args(["-f", "null", "-"])
            .output()
            .expect("ffmpeg availability was checked");
        assert!(
            decode.status.success(),
            "ffmpeg could not decode MP3: {}",
            String::from_utf8_lossy(&decode.stderr)
        );
    }
}

#[test]
fn wav_destination_preserves_the_native_payload() {
    let root = tempfile::tempdir().unwrap();
    let wav = root.path().join("native.wav");
    let output = root.path().join("chapter.wav");
    write_test_wav(&wav);
    let expected = fs::read(&wav).unwrap();
    assert_eq!(publish_piper_audio(&wav, &output).unwrap(), output);
    assert_eq!(fs::read(&output).unwrap(), expected);
    validate_wav(&output).unwrap();
}

#[test]
fn invalid_wave_does_not_replace_previous_audio() {
    let root = tempfile::tempdir().unwrap();
    let wav = root.path().join("invalid.wav");
    let output = root.path().join("chapter.mp3");
    fs::write(&wav, b"invalid wave input").unwrap();
    fs::write(&output, b"previous audio").unwrap();
    assert!(matches!(
        publish_piper_audio(&wav, &output),
        Err(PiperError::InvalidWav(_))
    ));
    assert_eq!(fs::read(output).unwrap(), b"previous audio");
}

#[test]
fn invalid_mp3_sample_rate_preserves_previous_audio() {
    let root = tempfile::tempdir().unwrap();
    let wav = root.path().join("native.wav");
    let output = root.path().join("chapter.mp3");
    write_test_wav(&wav);
    let mut bytes = fs::read(&wav).unwrap();
    bytes[24..28].copy_from_slice(&12_345_u32.to_le_bytes());
    fs::write(&wav, bytes).unwrap();
    fs::write(&output, b"previous audio").unwrap();
    assert!(publish_piper_audio(&wav, &output).is_err());
    assert_eq!(fs::read(output).unwrap(), b"previous audio");
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
}

#[test]
fn cancellation_token_can_be_shared_with_active_worker() {
    let token = CancellationToken::default();
    let worker_token = token.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(10));
        worker_token.cancel();
    })
    .join()
    .unwrap();
    assert!(token.is_cancelled());
}

#[test]
fn missing_runtime_is_reported_without_external_process_fallback() {
    let dir = tempfile_dir();
    let model = dir.join("voice.onnx");
    let config_path = model.with_extension("json");
    fs::write(&model, b"model").unwrap();
    fs::write(&config_path, b"{}").unwrap();
    let output = dir.join("out.wav");
    let config = PiperConfig::new(model, config_path);
    let result = synthesize(&config, "hello", &output, &CancellationToken::default());
    assert!(result.is_err());
}

fn tempfile_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!("piper-adapter-{}", std::process::id()));
    let _ = fs::create_dir_all(&path);
    path
}
