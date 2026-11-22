#[path = "../../converter-core/tests/support/epub_fixture.rs"]
mod epub_fixture;

use std::{fs, path::Path, process::Command};

#[path = "../../converter-core/tests/support/pdf_fixture.rs"]
mod pdf_fixture;

fn epub(path: &Path) {
    let bytes = epub_fixture::epub_bytes([
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"),
        ("content.opf", "<package xmlns:dc=\"x\"><metadata><dc:title>Command fixture</dc:title></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>"),
        ("a.xhtml", "<html><body><h1>Readable chapter</h1><p>Preserved EPUB content.</p></body></html>"),
    ], zip::write::SimpleFileOptions::default());
    fs::write(path, bytes).unwrap();
}

/// Three spine documents without a TOC: chapter indices 1, 2 and 3.
fn epub_with_three_chapters(path: &Path) {
    let bytes = epub_fixture::epub_bytes([
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"),
        ("content.opf", "<package xmlns:dc=\"x\"><metadata><dc:title>Range fixture</dc:title></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"b\" href=\"b.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c\" href=\"c.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/><itemref idref=\"b\"/><itemref idref=\"c\"/></spine></package>"),
        ("a.xhtml", "<html><body><h1>Opening</h1><p>First chapter content.</p></body></html>"),
        ("b.xhtml", "<html><body><h1>Middle</h1><p>Second chapter content.</p></body></html>"),
        ("c.xhtml", "<html><body><h1>Closing</h1><p>Third chapter content.</p></body></html>"),
    ], zip::write::SimpleFileOptions::default());
    fs::write(path, bytes).unwrap();
}

fn command(root: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_converter-cli"))
        .args(args)
        .env("PERSISTENT_ROOT", root)
        .env("ENGINE", "edge")
        .env_remove("ESPEAK_DATA_DIRECTORY")
        .output()
        .unwrap()
}

/// One page that only draws an image: like a scan, it has no narration text.
fn scanned_pdf(path: &Path) {
    let mut bytes = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (number, contents) in [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (
            3,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>",
        ),
        (4, "<< /Length 7 >>\nstream\n/Im0 Do\nendstream"),
    ] {
        offsets.push(bytes.len());
        bytes.extend_from_slice(format!("{number} 0 obj\n{contents}\nendobj\n").as_bytes());
    }
    let xref = bytes.len();
    bytes.extend_from_slice(b"xref\n0 5\n0000000000 65535 f \n");
    for offset in offsets {
        bytes.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend_from_slice(
        format!("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n").as_bytes(),
    );
    fs::write(path, bytes).unwrap();
}

fn assert_untouched(root: &Path) {
    assert_eq!(
        fs::read(root.join("listener.mp3")).unwrap(),
        b"retained audio"
    );
    assert_eq!(
        fs::read_dir(root).unwrap().count(),
        1,
        "no job, cache or output may be created"
    );
}

#[test]
fn help_documents_explicit_fallback_voice_and_model_selection() {
    let runtime = tempfile::tempdir().unwrap();
    let output = command(runtime.path(), &["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    for option in ["--fallback-voice VOICE", "--fallback-model MODEL"] {
        assert!(
            help.lines().any(|line| {
                line.trim_start().starts_with(option) && line.contains("requires --fallback-engine")
            }),
            "expected {option} and its engine requirement in --help"
        );
    }
}

#[test]
fn unsupported_flags_fail_before_input_resolution_synthesis_or_cleanup() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("book.epub");
    epub(&book);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    for flag in ["--no-cache", "--stop-on-error"] {
        let output = command(
            runtime.path(),
            &[
                "convert",
                book.to_str().unwrap(),
                "--clean-cache",
                "--yes",
                flag,
            ],
        );
        assert_eq!(output.status.code(), Some(2));
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(&format!("{flag} is not supported"))
        );
        assert_untouched(runtime.path());
    }
}

#[test]
fn text_pdf_structure_uses_the_shared_source_dispatch_without_creating_output() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("first.epub");
    epub(&book);
    // The extension match is case-insensitive, as for discovery.
    let pdf_path = fixture.path().join("second.PDF");
    fs::write(
        &pdf_path,
        pdf_fixture::pdf(
            true,
            &["First page body.", "Middle page body.", "Last page body."],
        ),
    )
    .unwrap();
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    let list = fixture.path().join("batch.txt");
    fs::write(
        &list,
        format!("{}\n{}\n", book.display(), pdf_path.display()),
    )
    .unwrap();
    for args in [
        vec!["convert", pdf_path.to_str().unwrap(), "--show-structure"],
        vec![
            "convert",
            "--batch-file",
            list.to_str().unwrap(),
            "--show-structure",
        ],
    ] {
        let output = command(runtime.path(), &args);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8_lossy(&output.stdout);
        assert!(text.contains("Title: PDF fixture"), "{text}");
        assert!(text.contains("First section"), "{text}");
        assert!(text.contains("Second section"), "{text}");
        assert_untouched(runtime.path());
    }
}

#[test]
fn pdf_without_extractable_text_fails_closed_before_any_job_or_output() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let pdf_path = fixture.path().join("scanned.pdf");
    scanned_pdf(&pdf_path);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    for args in [
        vec!["convert", pdf_path.to_str().unwrap()],
        vec!["convert", pdf_path.to_str().unwrap(), "--show-structure"],
    ] {
        let output = command(runtime.path(), &args);
        assert_eq!(output.status.code(), Some(2));
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("not supported by the native CLI"),
            "PDF input is supported; only unreadable sources are rejected"
        );
        assert_untouched(runtime.path());
    }
}

#[test]
fn epub_structure_and_ordinary_verify_remain_distinct_from_rejected_options() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("book.epub");
    epub(&book);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    let output = command(
        runtime.path(),
        &[
            "convert",
            book.to_str().unwrap(),
            "--show-structure",
            "--verify",
        ],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("Command fixture"));
    assert!(text.contains("Readable chapter"));
    assert_untouched(runtime.path());
}

#[test]
fn rejected_range_and_retry_requests_fail_before_any_job_cache_or_output() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("book.epub");
    epub_with_three_chapters(&book);
    let pdf_path = fixture.path().join("book.pdf");
    fs::write(
        &pdf_path,
        pdf_fixture::pdf(
            true,
            &["First page body.", "Middle page body.", "Last page body."],
        ),
    )
    .unwrap();
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    let (book, pdf_path) = (book.to_str().unwrap(), pdf_path.to_str().unwrap());
    for (arguments, expected) in [
        // Both range flags, in either order.
        (
            vec![
                book,
                "--from-chapter-to-end",
                "2",
                "--from-chapter-to-chapter",
                "2..3",
            ],
            "--from-chapter-to-end and --from-chapter-to-chapter are mutually exclusive",
        ),
        (
            vec![
                book,
                "--from-chapter-to-chapter",
                "2..3",
                "--from-chapter-to-end",
                "2",
            ],
            "mutually exclusive",
        ),
        // A range that is not A..B.
        (
            vec![book, "--from-chapter-to-chapter", "2-3"],
            "--from-chapter-to-chapter requires an inclusive range A..B",
        ),
        // Bounds that name no chapter of this book, or only one before the start.
        (
            vec![book, "--from-chapter-to-end", "7"],
            "--from-chapter-to-end: chapter selector '7' matches no chapter",
        ),
        (
            vec![book, "--from-chapter-to-chapter", "2..9"],
            "chapter selector '9' matches no chapter at or after '2'",
        ),
        (
            vec![book, "--from-chapter-to-chapter", "3..1"],
            "chapter selector '1' matches no chapter at or after '3'",
        ),
        // A narrowing selector that leaves the range empty.
        (
            vec![
                book,
                "--from-chapter-to-end",
                "2",
                "--chapter",
                "position:0",
            ],
            "no --chapter or --section selector matches a chapter inside the range",
        ),
        // The same resolution applies to a PDF and to every book of a batch.
        (
            vec![pdf_path, "--from-chapter-to-end", "position:5"],
            "chapter selector 'position:5' matches no chapter",
        ),
        (
            vec![book, pdf_path, "--from-chapter-to-end", "3"],
            "--from-chapter-to-end: chapter selector '3' matches no chapter",
        ),
        (
            vec![book, "--retry-failed", "-1"],
            "--retry-failed requires a non-negative number",
        ),
        (
            vec![book, "--retry-failed", "twice"],
            "--retry-failed requires a non-negative number",
        ),
    ] {
        // Cache cleaning is requested too: it must not run for a rejected request.
        let arguments = [&["convert"][..], &arguments, &["--clean-cache", "--yes"]].concat();
        let output = command(runtime.path(), &arguments);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(2), "{arguments:?}\n{stderr}");
        assert!(stderr.contains(expected), "{arguments:?}\n{stderr}");
        assert_untouched(runtime.path());
    }
}

#[test]
fn existing_output_modes_never_convert_and_report_missing_output_with_status_one() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("book.epub");
    epub_with_three_chapters(&book);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    let book = book.to_str().unwrap();
    for mode in ["--verify-only", "--fix"] {
        let output = command(runtime.path(), &["convert", book, mode]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(output.status.code(), Some(1), "{stdout}");
        assert!(
            stdout.contains("no existing output for 'Range fixture'"),
            "{stdout}"
        );
        assert_untouched(runtime.path());
    }
    for (arguments, expected) in [
        (
            vec![book, "--verify-only", "--fix"],
            "--verify-only and --fix are mutually exclusive",
        ),
        (
            vec![book, "--verify-only", "--force-reprocess"],
            "--force-reprocess cannot be combined with --verify-only",
        ),
        (
            vec![book, "--fix", "--chapter", "2"],
            "--chapter cannot be combined with --fix",
        ),
        (
            vec![book, "--fix", "--engine", "edge"],
            "--engine cannot be combined with --fix",
        ),
        (
            vec![book, "--verify-only", "--clean-cache", "--yes"],
            "--clean-cache cannot be combined with --verify-only",
        ),
    ] {
        let arguments = [&["convert"][..], &arguments].concat();
        let output = command(runtime.path(), &arguments);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(2), "{arguments:?}\n{stderr}");
        assert!(stderr.contains(expected), "{arguments:?}\n{stderr}");
        assert_untouched(runtime.path());
    }
}

#[test]
fn help_documents_every_ported_flag() {
    let runtime = tempfile::tempdir().unwrap();
    let output = command(runtime.path(), &["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8_lossy(&output.stdout);
    for flag in [
        "--from-chapter-to-end CHAPTER",
        "--from-chapter-to-chapter A..B",
        "--force-reprocess",
        "--retry-failed N",
        "--retry-failed-manual",
        "--verify-only",
        "--fix",
        "--verify ",
        "--chapter CHAPTER",
    ] {
        assert!(help.contains(flag), "help lacks {flag}\n{help}");
    }
}
