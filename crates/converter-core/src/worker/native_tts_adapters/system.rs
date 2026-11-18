use super::*;

pub(super) struct SystemProvider(pub(super) ProviderConfiguration);
impl TtsProvider for SystemProvider {
    fn descriptor(&self) -> ProviderDescriptor {
        self.0.descriptor.clone()
    }
    fn validate_selection(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<(), TtsFailure> {
        self.0.selection(selection, language).map(|_| ())
    }
    fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        self.0.selection(selection, language)?;
        Ok(Box::new(SystemSession(self.0.session(
            selection.clone(),
            Default::default(),
            false,
        )?)))
    }
}
struct SystemSession(SessionContext);
impl TtsSession for SystemSession {
    fn identity(&self) -> &ResolvedIdentity {
        &self.0.identity
    }
    fn synthesize(
        &mut self,
        text: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure> {
        publish_audio(context, sink, || self.synthesize_audio(text, context))
    }
}
impl SystemSession {
    fn synthesize_audio(
        &self,
        segment: &str,
        context: &SynthesisContext<'_>,
    ) -> Result<Vec<u8>, WorkerError> {
        self.0.check(context)?;
        let shared = &self.0.provider;
        let staging = tempfile::tempdir_in(&shared.staging)?;
        let wav = staging.path().join("segment.wav");
        let adapter = shared
            .platform_tts
            .as_ref()
            .ok_or_else(|| WorkerError::PlatformTts("No installed system speech adapter".into()))?;
        let _guard = loop {
            self.0.check(context)?;
            match shared.platform_gate.try_lock() {
                Ok(guard) => break guard,
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err(WorkerError::PlatformTts(
                        "system speech lock poisoned".into(),
                    ))
                }
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(std::time::Duration::from_millis(25))
                }
            }
        };
        let started = std::time::Instant::now();
        let deadline = std::time::Duration::from_secs(30);
        let cancelled = || {
            shared.cancel.is_cancelled() || (context.replaced)() || started.elapsed() >= deadline
        };
        adapter
            .synthesize_wav(segment, context.language, &wav, &cancelled)
            .map_err(WorkerError::PlatformTts)?;
        if started.elapsed() >= deadline {
            return Err(WorkerError::PlatformTts(
                "System speech deadline exceeded".into(),
            ));
        }
        read_native_audio(&wav)
    }
}
