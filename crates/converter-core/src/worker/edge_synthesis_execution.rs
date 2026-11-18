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
