use super::*;
use std::sync::Arc;

#[derive(Default)]
pub struct TtsRegistry {
    providers: Vec<Arc<dyn TtsProvider>>,
}
impl TtsRegistry {
    pub fn register(&mut self, provider: Arc<dyn TtsProvider>) -> Result<(), TtsFailure> {
        let descriptor = provider.descriptor();
        if descriptor.capabilities.audio_bytes
            && (descriptor.capabilities.max_text_chars == 0
                || descriptor.capabilities.audio_formats.is_empty())
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Audio adapters must declare nonzero text capacity and output formats",
            ));
        }
        if self.providers.iter().any(|existing| {
            let existing = existing.descriptor();
            existing.provider == descriptor.provider && existing.runtime == descriptor.runtime
        }) {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Duplicate provider/runtime adapter",
            ));
        }
        self.providers.push(provider);
        Ok(())
    }
    pub fn descriptors(&self) -> Vec<ProviderDescriptor> {
        self.providers
            .iter()
            .map(|provider| provider.descriptor())
            .collect()
    }
    pub fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        let provider = self
            .providers
            .iter()
            .find(|provider| {
                let descriptor = provider.descriptor();
                descriptor.provider == selection.provider && descriptor.runtime == selection.runtime
            })
            .ok_or_else(|| {
                TtsFailure::new(
                    FailureKind::Unavailable,
                    "Requested provider/runtime adapter is not registered",
                )
            })?;
        selection.validate(&provider.descriptor(), language)?;
        let session = provider.prepare(selection, language)?;
        let resolved = &session.identity().selection;
        let descriptor = provider.descriptor();
        resolved.validate(&descriptor, language)?;
        if session.identity().runtime_revision != descriptor.revision {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Adapter returned an unrecognized runtime revision",
            ));
        }
        if resolved.provider != selection.provider
            || resolved.runtime != selection.runtime
            || resolved.model_id != selection.model_id
            || resolved.options != selection.options
            || selection
                .voice
                .as_ref()
                .is_some_and(|voice| resolved.voice.as_ref() != Some(voice))
            || selection
                .model_revision
                .as_ref()
                .is_some_and(|revision| resolved.model_revision.as_ref() != Some(revision))
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Adapter returned a conflicting resolved identity",
            ));
        }
        Ok(session)
    }
}
