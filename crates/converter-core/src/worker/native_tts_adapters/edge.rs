use super::*;

pub(super) struct EdgeProvider(pub(super) ProviderConfiguration);
impl TtsProvider for EdgeProvider {
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
        let mut resolved = selection.clone();
        if resolved.voice.is_none() {
            resolved.voice = Some(default_edge_voice(Some(language)).into());
        }
        Ok(Box::new(EdgeSession(self.0.session(
            resolved,
            Default::default(),
            true,
        )?)))
    }
}
struct EdgeSession(SessionContext);
impl TtsSession for EdgeSession {
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
impl EdgeSession {
    fn synthesize_audio(
        &self,
        segment: &str,
        context: &SynthesisContext<'_>,
    ) -> Result<Vec<u8>, WorkerError> {
        self.0.check(context)?;
        let shared = &self.0.provider;
        #[cfg(test)]
        if let Some(edge) = &shared.test_edge {
            return edge(segment);
        }
        let result = run_edge_synthesis_checked(
            crate::tts::synthesize_with_reference_client(
                segment,
                self.0
                    .identity
                    .selection
                    .voice
                    .as_deref()
                    .unwrap_or_else(|| default_edge_voice(Some(context.language))),
                shared.adaptive.clone(),
                shared.telemetry.clone(),
            ),
            &|| shared.cancel.is_cancelled() || (context.replaced)(),
            crate::tts::reference_synthesis_timeout_for_text(segment.len()),
        );
        if (context.replaced)() {
            return Err(WorkerError::PlaybackWindowChanged);
        }
        result
    }
}
