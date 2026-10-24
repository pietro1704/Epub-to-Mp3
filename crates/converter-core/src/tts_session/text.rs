//! Unicode-safe segmentation shared by native and browser sessions.
pub fn segment_text(
    text: &str,
    initial: usize,
    subsequent: usize,
) -> Result<Vec<String>, super::TtsFailure> {
    if initial == 0 || subsequent == 0 {
        return Err(super::TtsFailure::new(
            super::FailureKind::InvalidSelection,
            "Text capacities must be nonzero",
        ));
    }
    let mut result = Vec::new();
    let mut pending = text.trim();
    while !pending.is_empty() {
        let limit = if result.is_empty() {
            initial
        } else {
            subsequent
        };
        let end = pending
            .char_indices()
            .nth(limit)
            .map(|(offset, _)| offset)
            .unwrap_or(pending.len());
        let prefix = &pending[..end];
        let boundary = if end == pending.len() {
            end
        } else {
            prefix
                .char_indices()
                .rev()
                .find(|(_, c)| c.is_whitespace() || matches!(c, '.' | '?' | '!'))
                .map(|(offset, c)| offset + c.len_utf8())
                .filter(|offset| *offset > end / 2)
                .unwrap_or(end)
        };
        result.push(pending[..boundary].trim().to_owned());
        pending = pending[boundary..].trim_start();
    }
    Ok(result)
}
