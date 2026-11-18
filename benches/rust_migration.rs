//! Rust migration performance suite.
//!
//! Run with `mise run benchmark:rust`; this task is separate from correctness
//! gates. Criterion emits estimates and HTML reports, while the metadata report
//! identifies the baseline and external resource measurements to collect.
use converter_core::{cache, epub::parse_epub, text, tts::split_protocol_chunks};
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use std::{hint::black_box, io::Cursor};

#[path = "../crates/converter-core/tests/support/epub_fixture.rs"]
mod epub_fixture;

fn fixture_bytes() -> Vec<u8> {
    let paragraph = "<p>Performance instrumentation preserves readable chapter text.</p>";
    let chapter = format!(
        "<html><body><h1>Chapter One</h1>{}</body></html>",
        paragraph.repeat(256 * 1024 / paragraph.len())
    );
    epub_fixture::epub_bytes(
        [
            (
                "META-INF/container.xml",
                r#"<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>"#,
            ),
            (
                "content.opf",
                r#"<package><metadata><title>Parser benchmark</title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#,
            ),
            ("chapter.xhtml", chapter.as_str()),
        ],
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
    )
}

fn parser(c: &mut Criterion) {
    let bytes = fixture_bytes();
    let book = parse_epub(Cursor::new(&bytes)).expect("benchmark fixture must parse successfully");
    assert_eq!(book.title, "Parser benchmark");
    assert_eq!(book.chapters.len(), 1);
    assert!(book.chapters[0].text.contains("readable chapter text"));
    let mut group = c.benchmark_group("parser");
    group.throughput(Throughput::Bytes(bytes.len() as u64));
    group.bench_function(BenchmarkId::new("epub_parse", bytes.len()), |b| {
        b.iter(|| {
            black_box(
                parse_epub(Cursor::new(black_box(bytes.as_slice())))
                    .expect("parser benchmark must measure successful parsing"),
            )
        })
    });
    group.finish();
}

fn chunking(c: &mut Criterion) {
    let text = "performance instrumentation sentence ".repeat(20_000);
    let mut group = c.benchmark_group("chunking");
    group.throughput(Throughput::Bytes(text.len() as u64));
    for limit in [4_000usize, 12_000, 24_000] {
        group.bench_with_input(
            BenchmarkId::new("protocol_chunks", limit),
            &limit,
            |b, &limit| b.iter(|| black_box(split_protocol_chunks(black_box(&text), limit))),
        );
    }
    group.finish();
}

fn cache(c: &mut Criterion) {
    let text = "cache normalization throughput ".repeat(20_000);
    let mut group = c.benchmark_group("cache");
    group.throughput(Throughput::Bytes(text.len() as u64));
    group.bench_function("hash_text", |b| {
        b.iter(|| black_box(cache::hash_text(black_box(&text))))
    });
    group.bench_function("normalized_text_hash", |b| {
        b.iter(|| black_box(cache::normalized_text_hash(black_box(&text))))
    });
    group.finish();
}

fn orchestration(c: &mut Criterion) {
    let text = "chapter orchestration text ".repeat(4_000);
    let mut group = c.benchmark_group("orchestration");
    group.throughput(Throughput::Bytes(text.len() as u64));
    group.bench_function("structural_speech_cues", |b| {
        b.iter(|| {
            black_box(text::apply_structural_speech_cues(
                black_box(&text),
                Some("<h1>Chapter One</h1>"),
                Some("Chapter One"),
            ))
        })
    });
    group.finish();
}

criterion_group! { name = rust_migration; config = Criterion::default(); targets = parser, chunking, cache, orchestration }
criterion_main!(rust_migration);
