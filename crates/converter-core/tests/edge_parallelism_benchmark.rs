//! Opt-in live Edge benchmark for representative LOTR chapters.
//!
//! Run with:
//! `EPUB2MP3_BENCHMARK_EPUB=/path/to/book.epub cargo test -p converter-core --test edge_parallelism_benchmark -- --ignored --nocapture`

use std::{collections::HashMap, path::PathBuf, time::Instant};

use converter_core::{
    config::AppConfig,
    paths::resolve_paths_from,
    worker::{ConversionRequest, ConversionWorker},
};

#[test]
#[ignore = "requires an imported EPUB and live Edge TTS access"]
fn compares_serial_and_two_worker_edge_throughput() {
    let input = std::env::var_os("EPUB2MP3_BENCHMARK_EPUB")
        .map(PathBuf::from)
        .expect("set EPUB2MP3_BENCHMARK_EPUB to the imported LOTR EPUB");
    assert!(
        input.is_file(),
        "benchmark EPUB is missing: {}",
        input.display()
    );
    assert!(
        std::env::var_os("RUST_CHAPTER_PARALLELISM").is_none(),
        "unset RUST_CHAPTER_PARALLELISM so this benchmark controls only no_parallel"
    );

    let serial_seconds = run_case(&input, true, "serial");
    let parallel_seconds = run_case(&input, false, "parallel-2");
    let speedup = serial_seconds / parallel_seconds.max(0.001);
    println!(
        "[Rust Edge benchmark] chapters=9-10 serial={serial_seconds:.1}s parallel2={parallel_seconds:.1}s speedup={speedup:.2}x"
    );
}

fn run_case(input: &std::path::Path, no_parallel: bool, label: &str) -> f64 {
    let root = tempfile::tempdir().expect("create benchmark workspace");
    let root_path = root.path().to_path_buf();
    let paths = resolve_paths_from(
        HashMap::from([("PERSISTENT_ROOT", root_path.clone())]),
        root_path,
    );
    let mut config = AppConfig::from_paths(paths);
    config.max_parallel = 2;
    let job_id = format!("edge-benchmark-{label}");
    let request = ConversionRequest {
        input: input.to_path_buf(),
        job_id,
        engine: Some("edge".into()),
        voice: Some("en-US-GuyNeural".into()),
        language: Some("en-US".into()),
        chapter_indices: Some(vec!["position:8".into(), "position:9".into()]),
        no_parallel,
    };
    let started = Instant::now();
    let manifest = ConversionWorker::new(config)
        .expect("create conversion worker")
        .run(request)
        .expect("convert benchmark chapters");
    let elapsed = started.elapsed().as_secs_f64();
    assert_eq!(manifest.chapters.len(), 2);
    println!("[Rust Edge benchmark] {label} completed both validated MP3s in {elapsed:.1}s");
    elapsed
}
