use super::WorkerError;
use crate::{piper::CancellationToken, tts::EdgeError};

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
    let result = runtime.block_on(async {
        let stopped = async { loop { if cancelled() { return; } tokio::time::sleep(std::time::Duration::from_millis(50)).await; } };
        tokio::select! { biased;
            _ = stopped => Err(WorkerError::Cancelled),
            result = tokio::time::timeout(timeout, synthesis) => result.map_err(|_| WorkerError::Edge(EdgeError::Timeout))?.map_err(WorkerError::Edge),
        }
    });
    runtime.shutdown_background();
    result
}

#[cfg(test)]
pub(super) fn run_preference_edge_synthesis<T, F>(
    synthesis: F,
    cancel: &CancellationToken,
    text_bytes: usize,
) -> Result<T, WorkerError>
where
    F: std::future::Future<Output = Result<T, EdgeError>>,
{
    run_edge_synthesis(
        synthesis,
        cancel,
        crate::tts::reference_synthesis_timeout_for_text(text_bytes),
    )
}

pub(super) fn run_edge_synthesis<T, F>(
    synthesis: F,
    cancel: &CancellationToken,
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
            let cancelled = async {
                loop {
                    if cancel.is_cancelled() {
                        return;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            };
            tokio::select! {
                biased;
                _ = cancelled => Err(WorkerError::Cancelled),
                result = tokio::time::timeout(timeout, synthesis) => {
                    match result {
                        Ok(result) => result.map_err(WorkerError::Edge),
                        Err(_) => Err(WorkerError::Edge(EdgeError::Transport(
                            "chapter synthesis timed out".into(),
                        ))),
                    }
                }
            }
        })
    }))
    .unwrap_or_else(|_| {
        Err(WorkerError::Edge(EdgeError::Transport(
            "synthesis thread panicked".into(),
        )))
    });
    // DNS resolution can use Tokio's blocking pool. Dropping the runtime would
    // wait for those calls even after the network future has been cancelled.
    runtime.shutdown_background();
    result
}
