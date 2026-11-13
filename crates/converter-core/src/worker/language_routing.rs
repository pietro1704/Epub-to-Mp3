use super::{ConversionWorker, WorkerError};

impl ConversionWorker {
    pub fn with_language_overrides(
        mut self,
        corrections: Vec<crate::language::LanguageOverride>,
    ) -> Result<Self, WorkerError> {
        if corrections.len() > 4096 {
            return Err(WorkerError::Unsupported(
                "Too many passage language corrections".into(),
            ));
        }
        for correction in &corrections {
            correction.validate().map_err(WorkerError::Unsupported)?;
        }
        self.language_overrides = corrections;
        Ok(self)
    }

    pub(super) fn plan_language_passages(
        &self,
        request: &super::ConversionRequest,
        text: &str,
        paragraph_ends: &[usize],
        heading_ends: &[usize],
        source_index: usize,
        language: Option<&str>,
    ) -> (usize, Vec<crate::language::LanguagePassage>, Vec<usize>) {
        let source_offset = self
            .control
            .as_ref()
            .and_then(|control| control.listening_plan())
            .filter(|plan| plan.position.chapter_index == source_index)
            .map_or(0, |plan| plan.position.text_offset);
        let language_passages = crate::language::passages(
            text,
            paragraph_ends,
            language,
            &self.language_overrides,
            source_index,
            source_offset,
            request.language.as_deref(),
        );
        let mut forced_boundaries = heading_ends.to_vec();
        forced_boundaries.extend(
            language_passages
                .iter()
                .map(|passage| passage.scalars.end)
                .filter(|end| *end < text.chars().count()),
        );
        forced_boundaries.sort_unstable();
        forced_boundaries.dedup();
        (source_offset, language_passages, forced_boundaries)
    }
}

/// Surface an unresolved source range only after representative book/chapter analysis.
pub(super) fn language_for_segment<'a>(
    passages: &'a [crate::language::LanguagePassage],
    range: std::ops::Range<usize>,
    fallback: Option<&'a str>,
    chapter: usize,
    source_offset: usize,
) -> Result<&'a str, WorkerError> {
    if let Some(language) = passages
        .iter()
        .find(|passage| passage.scalars.contains(&range.start))
        .and_then(|passage| passage.language.as_deref())
        .or(fallback)
    {
        return Ok(language);
    }
    let evidence = serde_json::json!({"chapter_index": chapter,
        "start": source_offset + range.start, "end": source_offset + range.end});
    Err(WorkerError::Unsupported(format!(
        "Passage language remains inconclusive [[book_language_uncertain_v1]]{evidence}[[/book_language_uncertain_v1]]"
    )))
}

pub(super) fn recovery_failure(
    mut failure: crate::tts_session::TtsFailure,
    language: Option<&str>,
    model: Option<&str>,
) -> WorkerError {
    if failure.kind == crate::tts_session::FailureKind::Unavailable && language.is_some() {
        let evidence =
            serde_json::json!({"language": language, "model_id": model.unwrap_or("system")});
        failure.message.push_str(&format!(
            " [[tts_language_mismatch_v1]]{evidence}[[/tts_language_mismatch_v1]]"
        ));
    }
    super::native_tts_adapters::worker_from_failure(failure)
}
