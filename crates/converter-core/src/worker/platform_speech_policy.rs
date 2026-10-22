use super::{
    default_edge_voice, dispatch_playback_chunk, run_edge_synthesis_checked, ConversionWorker,
    ProgressEvent, WorkerError,
};
use crate::{platform_tts, tts::EdgeError};
use std::{
    fs,
    path::Path,
    sync::{atomic::Ordering, Arc},
};

impl ConversionWorker {
    pub(super) fn synthesize_platform_policy(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        stale: &std::sync::atomic::AtomicBool,
        system_notice_emitted: &std::sync::atomic::AtomicBool,
        job_id: &str,
        total: usize,
        completed: usize,
    ) -> Result<(), WorkerError> {
        use std::io::Write;
        let provider = self
            .platform_tts
            .as_ref()
            .expect("platform adapter installed");
        let started = std::sync::Mutex::new(std::time::Instant::now());
        let deadline = std::time::Duration::from_secs(30);
        let cancelled = || {
            self.cancel.is_cancelled()
                || started.lock().expect("deadline lock").elapsed() >= deadline
                || self
                    .control
                    .as_ref()
                    .is_some_and(|control| !control.chapter_is_in_playback_window(source_index))
        };
        let check = || {
            if self.cancel.is_cancelled() {
                Err(WorkerError::Cancelled)
            } else if self
                .control
                .as_ref()
                .is_some_and(|control| !control.chapter_is_in_playback_window(source_index))
            {
                stale.store(true, Ordering::Release);
                Err(WorkerError::PlaybackWindowChanged)
            } else if started.lock().expect("deadline lock").elapsed() >= deadline {
                Err(WorkerError::PlatformTts(
                    "chapter synthesis timed out".into(),
                ))
            } else {
                Ok(())
            }
        };
        let staging = tempfile::tempdir_in(out.parent().unwrap_or(Path::new(".")))?;
        let mut output = fs::File::create(out)?;
        let mut used_edge = false;
        let mut used_system = false;
        let mut chunk_index = 0usize;
        let dispatch = |bytes: &[u8], output: &mut fs::File, chunk_index: &mut usize| {
            check()?;
            if !dispatch_playback_chunk(
                self.control.as_ref(),
                self.streaming_chunk.as_ref(),
                source_index,
                *chunk_index,
                bytes,
                stale,
            ) {
                return Err(if stale.load(Ordering::Acquire) {
                    WorkerError::PlaybackWindowChanged
                } else {
                    WorkerError::Cancelled
                });
            }
            output.write_all(bytes)?;
            *chunk_index += 1;
            Ok(())
        };
        for segment in platform_tts::segments(text) {
            *started.lock().expect("deadline lock") = std::time::Instant::now();
            check()?;
            let edge = if engine == "system" {
                None
            } else {
                let remaining = std::time::Duration::from_secs(5);
                let synthesize = || {
                    run_edge_synthesis_checked(
                        crate::tts::synthesize_with_reference_client(
                            &segment,
                            voice.unwrap_or_else(|| default_edge_voice(language)),
                            Arc::clone(&self.adaptive),
                            self.telemetry.clone(),
                        ),
                        &cancelled,
                        remaining,
                    )
                };
                #[cfg(test)]
                let result = if let Some(edge) = &self.test_edge {
                    edge(&segment)
                } else {
                    synthesize()
                };
                #[cfg(not(test))]
                let result = synthesize();
                Some(result)
            };
            check()?;
            match edge {
                Some(Ok(bytes)) if platform_tts::validate_mp3(&bytes).is_ok() => {
                    self.consecutive_edge_failures.store(0, Ordering::Release);
                    used_edge = true;
                    dispatch(&bytes, &mut output, &mut chunk_index)?;
                }
                Some(Err(WorkerError::Cancelled))
                | Some(Err(WorkerError::Edge(EdgeError::Cancelled))) => {
                    return Err(WorkerError::Cancelled)
                }
                _ => {
                    if engine == "edge"
                        && self
                            .consecutive_edge_failures
                            .fetch_add(1, Ordering::AcqRel)
                            >= 2
                    {
                        return Err(WorkerError::PlatformTts("Edge is unavailable for consecutive segments. System speech is only an occasional fallback. Check your internet connection and retry.".into()));
                    }
                    let native_segments = platform_tts::native_segments(&segment, !used_system);
                    used_system = true;
                    if !system_notice_emitted.swap(true, Ordering::AcqRel) {
                        self.emit(ProgressEvent {
                            model_id: None,
                            voice: None,
                            fallback_used: engine == "edge",
                            job_id: job_id.into(),
                            state: "running".into(),
                            chapter_index: Some(source_index),
                            chapters_total: total,
                            chapters_completed: completed,
                            percent: if total == 0 {
                                0.0
                            } else {
                                completed as f64 * 100.0 / total as f64
                            },
                            engine: Some("system".into()),
                            message: "Using the system voice for this segment...".into(),
                        });
                    }
                    for native_text in native_segments {
                        let _guard = loop {
                            match self.platform_gate.try_lock() {
                                Ok(guard) => break guard,
                                Err(std::sync::TryLockError::Poisoned(_)) => {
                                    return Err(WorkerError::PlatformTts(
                                        "system speech lock poisoned".into(),
                                    ))
                                }
                                Err(std::sync::TryLockError::WouldBlock) => {
                                    if self.cancel.is_cancelled() {
                                        return Err(WorkerError::Cancelled);
                                    }
                                    if self.control.as_ref().is_some_and(|control| {
                                        !control.chapter_is_in_playback_window(source_index)
                                    }) {
                                        stale.store(true, Ordering::Release);
                                        return Err(WorkerError::PlaybackWindowChanged);
                                    }
                                    std::thread::sleep(std::time::Duration::from_millis(25));
                                }
                            }
                        };
                        *started.lock().expect("deadline lock") = std::time::Instant::now();
                        check()?;
                        let wav = staging.path().join("segment.wav");
                        let synthesis = provider.synthesize_wav(
                            &native_text,
                            language.unwrap_or("pt-BR"),
                            &wav,
                            &cancelled,
                        );
                        check()?;
                        synthesis.map_err(WorkerError::PlatformTts)?;
                        let bytes = platform_tts::encode_wav(&fs::read(&wav)?)
                            .map_err(WorkerError::PlatformTts)?;
                        dispatch(&bytes, &mut output, &mut chunk_index)?;
                    }
                }
            }
        }
        output.sync_all()?;
        check()?;
        fs::write(
            out.with_extension("provider"),
            if used_edge && used_system {
                "edge+system"
            } else if used_system {
                "system"
            } else {
                "edge"
            },
        )?;
        Ok(())
    }
}
