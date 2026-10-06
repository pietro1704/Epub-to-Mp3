//! Server-facing adapter for the shared native conversion worker.
//!
//! This module deliberately contains no HTTP concerns. It turns server/CLI job
//! inputs into `converter_core::worker` requests and forwards durable progress
//! events to the caller.

use std::{path::PathBuf, sync::Arc};

use converter_core::{
    config::AppConfig,
    worker::{ConversionRequest, ConversionWorker, OutputManifest, ProgressEvent, ProgressSink, WorkerError},
};

/// Input accepted by server and CLI integration layers.
#[derive(Debug, Clone, Default)]
pub struct WorkerInput {
    pub input: PathBuf,
    pub job_id: String,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub language: Option<String>,
    pub no_parallel: bool,
}

impl WorkerInput {
    fn into_request(self) -> ConversionRequest {
        ConversionRequest {
            input: self.input,
            job_id: self.job_id,
            engine: self.engine,
            voice: self.voice,
            language: self.language,
            no_parallel: self.no_parallel,
        }
    }
}

/// Stable entrypoint for a synchronous conversion invocation.
///
/// The returned manifest is durable in the configured output directory, while
/// lifecycle state is persisted by the core job manager.
pub fn run_conversion(
    config: AppConfig,
    input: WorkerInput,
    progress: Option<ProgressSink>,
) -> Result<OutputManifest, WorkerError> {
    let worker = ConversionWorker::new(config)?;
    let worker = match progress {
        Some(sink) => worker.with_progress(sink),
        None => worker,
    };
    worker.run(input.into_request())
}

/// Convenience adapter for callers that only need structured progress events.
pub fn run_conversion_with_callback<F>(
    config: AppConfig,
    input: WorkerInput,
    callback: F,
) -> Result<OutputManifest, WorkerError>
where
    F: Fn(ProgressEvent) + Send + Sync + 'static,
{
    run_conversion(config, input, Some(Arc::new(callback)))
}

/// Construct a callback sink that forwards events to an owned channel.
pub fn channel_progress(
    sender: std::sync::mpsc::Sender<ProgressEvent>,
) -> ProgressSink {
    Arc::new(move |event| {
        let _ = sender.send(event);
    })
}
