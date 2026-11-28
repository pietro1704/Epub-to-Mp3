use super::WorkerError;
use crate::tts::EdgeError;

pub(super) fn run_edge_synthesis_checked<T, F>(
    synthesis: F,
    cancelled: &(dyn Fn() -> bool + Sync),
    timeout: std::time::Duration,
) -> Result<T, WorkerError>
where
    F: std::future::Future<Output = Result<T, EdgeError>>,
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime.block_on(async {
            let stopped = async {
                loop {
                    if cancelled() {
                        return;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            };
            tokio::select! {
                biased;
                _ = stopped => Err(WorkerError::Cancelled),
                result = tokio::time::timeout(timeout, synthesis) => {
                    result.map_err(|_| WorkerError::Edge(EdgeError::Timeout))?
                        .map_err(WorkerError::Edge)
                }
            }
        })
    }))
    .unwrap_or_else(|_| {
        Err(WorkerError::Edge(EdgeError::Transport(
            "synthesis thread panicked".into(),
        )))
    });
    // DNS may use Tokio's blocking pool. Cancellation must not wait for it.
    runtime.shutdown_background();
    result
}

/// The Edge voice a sample uses: the selected one, else the default for the language.
pub fn edge_audition_voice(voice: Option<&str>, language: Option<&str>) -> String {
    voice
        .map(str::trim)
        .filter(|voice| !voice.is_empty())
        .unwrap_or_else(|| super::conversion_input_policy::default_edge_voice(language))
        .to_owned()
}

/// Synthesizes one short Edge sample (MP3 bytes). It creates no job or cache
/// entry. The caller owns the online consent check.
pub fn synthesize_edge_audition(
    text: &str,
    voice: &str,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<Vec<u8>, WorkerError> {
    run_edge_synthesis_checked(
        crate::tts::synthesize_with_reference_client(text, voice, Default::default(), None),
        cancelled,
        crate::tts::reference_synthesis_timeout_for_text(text.len()),
    )
}
