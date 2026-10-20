use std::{fs, io::Write, path::Path, process::Command};
use zip::{write::SimpleFileOptions, ZipWriter};

fn epub(path: &Path) {
    let mut archive = ZipWriter::new(fs::File::create(path).unwrap());
    for (name, contents) in [
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"),
        ("content.opf", "<package xmlns:dc=\"x\"><metadata><dc:title>Command fixture</dc:title></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>"),
        ("a.xhtml", "<html><body><h1>Readable chapter</h1><p>Preserved EPUB content.</p></body></html>"),
    ] {
        archive.start_file(name, SimpleFileOptions::default()).unwrap();
        archive.write_all(contents.as_bytes()).unwrap();
    }
    archive.finish().unwrap();
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

fn pdf(path: &Path) {
    let mut bytes = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (number, contents) in [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>"),
    ] {
        offsets.push(bytes.len());
        bytes.extend_from_slice(format!("{number} 0 obj\n{contents}\nendobj\n").as_bytes());
    }
    let xref = bytes.len();
    bytes.extend_from_slice(b"xref\n0 4\n0000000000 65535 f \n");
    for offset in offsets {
        bytes.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend_from_slice(
        format!("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n").as_bytes(),
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
fn unsupported_flags_fail_before_input_resolution_synthesis_or_cleanup() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("book.epub");
    epub(&book);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    for flag in ["--verify-only", "--no-cache", "--stop-on-error"] {
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
fn pdf_and_mixed_batches_fail_before_the_first_job_or_cleanup() {
    let fixture = tempfile::tempdir().unwrap();
    let runtime = tempfile::tempdir().unwrap();
    let book = fixture.path().join("first.epub");
    epub(&book);
    let pdf_path = fixture.path().join("second.PDF");
    pdf(&pdf_path);
    fs::write(runtime.path().join("listener.mp3"), b"retained audio").unwrap();
    let list = fixture.path().join("batch.txt");
    fs::write(
        &list,
        format!("{}\n{}\n", book.display(), pdf_path.display()),
    )
    .unwrap();
    for args in [
        vec!["convert", pdf_path.to_str().unwrap()],
        vec!["convert", pdf_path.to_str().unwrap(), "--show-structure"],
        vec![
            "convert",
            book.to_str().unwrap(),
            pdf_path.to_str().unwrap(),
            "--clean-cache",
            "--yes",
        ],
        vec!["convert", "--batch-file", list.to_str().unwrap()],
        vec!["convert", "--batch", fixture.path().to_str().unwrap()],
    ] {
        let output = command(runtime.path(), &args);
        assert_eq!(output.status.code(), Some(2));
        assert!(String::from_utf8_lossy(&output.stderr)
            .contains("PDF conversion and structure inspection are not supported"));
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
