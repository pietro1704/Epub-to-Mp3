use super::{
    default_edge_voice, dispatch_playback_chunk, ensure_android_piper_runtime, run_edge_synthesis,
    ConversionWorker, WorkerError,
};
use crate::{
    piper::{self, PiperConfig},
    tts::EdgeError,
};
use std::{fs, path::Path, sync::Arc};

impl ConversionWorker {
    pub(super) fn synthesize(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
        timeout: std::time::Duration,
        stale_window_cancelled: &std::sync::atomic::AtomicBool,
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or_else(|| default_edge_voice(language));
            if let Some(sink) = self.streaming_chunk.as_ref() {
                use std::io::Write as _;
                let mut output = fs::File::create(out)?;
                let mut write_error = None;
                let result = run_edge_synthesis(
                    crate::tts::synthesize_with_reference_client_stream(
                        text,
                        voice,
                        Arc::clone(&self.adaptive),
                        self.telemetry.clone(),
                        |segment_index, bytes| {
                            if !dispatch_playback_chunk(
                                self.control.as_ref(),
                                Some(sink),
                                source_index,
                                segment_index,
                                bytes,
                                stale_window_cancelled,
                            ) {
                                return false;
                            }
                            if let Err(error) = output.write_all(bytes) {
                                write_error = Some(error);
                                return false;
                            }
                            true
                        },
                    ),
                    &self.cancel,
                    timeout,
                );
                if let Some(error) = write_error {
                    return Err(WorkerError::Io(error));
                }
                result?;
                return Ok(());
            }
            match run_edge_synthesis(
                crate::tts::synthesize_with_reference_client_chunks(
                    text,
                    voice,
                    Arc::clone(&self.adaptive),
                    self.telemetry.clone(),
                    |segment_index, bytes| {
                        dispatch_playback_chunk(
                            self.control.as_ref(),
                            self.streaming_chunk.as_ref(),
                            source_index,
                            segment_index,
                            bytes,
                            &stale_window_cancelled,
                        )
                    },
                ),
                &self.cancel,
                timeout,
            ) {
                Ok(bytes) => {
                    fs::write(out, bytes).map_err(|error| {
                        WorkerError::Edge(EdgeError::Transport(format!(
                            "failed to write synthesized audio {}: {error}",
                            out.display()
                        )))
                    })?;
                    return Ok(());
                }
                Err(error) => {
                    return Err(error);
                }
            }
        }
        if engine == "system" {
            return Err(WorkerError::PlatformTts(
                "No system speech adapter is installed for this conversion".into(),
            ));
        }
        self.synthesize_with_piper(text, out, piper_model, piper_config)
    }
}

impl ConversionWorker {
    pub(super) fn synthesize_with_piper(
        &self,
        text: &str,
        out: &Path,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
    ) -> Result<(), WorkerError> {
        let runtime_status = piper::piper_runtime_status();
        if cfg!(target_os = "android") {
            ensure_android_piper_runtime(runtime_status)?;
        }
        // A captured manual/typed selection takes precedence over a legacy prepared default.
        if piper_model.is_none() && piper_config.is_none() {
            if let Some(model) = &self.piper_model {
                return model
                    .synthesize(text, out, &self.cancel)
                    .map_err(|error| WorkerError::Piper(error.to_string()));
            }
        }
        let model = piper_model.map(Path::to_path_buf).unwrap_or_else(|| {
            self.config
                .paths
                .piper_models_dir
                .join("pt_BR-faber-medium.onnx")
        });
        let model = if model.is_file() {
            model
        } else {
            return Err(WorkerError::Piper(format!(
                "Piper model is unavailable at {}",
                model.display()
            )));
        };
        let config = piper_config
            .map(Path::to_path_buf)
            .unwrap_or_else(|| model.with_extension("onnx.json"));
        let mut c = PiperConfig::new(model, config);
        c.chunk_chars = std::env::var("PIPER_CHUNK_CHARS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5_000);
        piper::synthesize(&c, text, out, &self.cancel)
            .map(|_| ())
            .map_err(|e| WorkerError::Piper(e.to_string()))
    }
    pub(super) fn synthesize_with_timeout(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
        stale_window_cancelled: &std::sync::atomic::AtomicBool,
    ) -> Result<(), WorkerError> {
        let timeout_secs = std::env::var("RUST_CHAPTER_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(if cfg!(target_os = "android") {
                300
            } else {
                180
            });
        let timeout = std::time::Duration::from_secs(timeout_secs);
        if engine == "edge" {
            return self.synthesize(
                engine,
                text,
                out,
                source_index,
                voice,
                language,
                piper_model,
                piper_config,
                timeout,
                stale_window_cancelled,
            );
        }
        let result = std::thread::scope(|scope| {
            let handle = scope.spawn(|| {
                self.synthesize(
                    engine,
                    text,
                    out,
                    source_index,
                    voice,
                    language,
                    piper_model,
                    piper_config,
                    timeout,
                    stale_window_cancelled,
                )
            });
            let started = std::time::Instant::now();
            while !handle.is_finished() {
                if self.cancel.is_cancelled()
                    || started.elapsed() >= std::time::Duration::from_secs(timeout_secs)
                {
                    return Err(if engine == "edge" {
                        WorkerError::Edge(EdgeError::Transport(
                            "chapter synthesis timed out".into(),
                        ))
                    } else {
                        WorkerError::Piper("chapter synthesis timed out".into())
                    });
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            handle.join().unwrap_or_else(|_| {
                Err(if engine == "edge" {
                    WorkerError::Edge(EdgeError::Transport("synthesis thread panicked".into()))
                } else {
                    WorkerError::Piper("synthesis thread panicked".into())
                })
            })
        });
        result
    }
}
