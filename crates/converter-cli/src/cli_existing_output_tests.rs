//! `--verify-only` and `--fix` against output produced by real conversions.
use super::cli_conversion_lifecycle_tests::{audio_is_valid, write_epub, Fixture, CHAPTERS};
use converter_core::worker::retained_chapter_audio_is_intact;
use std::fs;

#[test]
fn verification_rejects_different_source_bytes_even_with_identical_metadata() {
    let fixture = Fixture::new();
    assert_eq!(fixture.invoke(&["convert", fixture.book()], None).exit, "0");
    let (directory, manifest) = fixture.newest_job();
    let original_manifest = fs::read(directory.join("manifest.json")).unwrap();
    let revised = fixture.root.join("same-length.epub");
    let replacement = CHAPTERS[1].1.replace("antiga", "grande");
    assert_eq!(replacement.chars().count(), CHAPTERS[1].1.chars().count());
    let mut chapters = CHAPTERS;
    chapters[1].1 = &replacement;
    write_epub(&revised, &chapters);
    for mode in ["--verify-only", "--fix"] {
        let run = fixture.invoke(&["convert", revised.to_str().unwrap(), mode], None);
        assert_eq!(run.exit, "1", "{}", run.stdout);
        assert_eq!(run.spoken, "");
    }
    assert_eq!(
        fs::read(directory.join("manifest.json")).unwrap(),
        original_manifest
    );
    assert!(audio_is_valid(&directory, &manifest));

    // A newer job with the same labels does not hide the matching older source.
    assert_eq!(
        fixture
            .invoke(&["convert", revised.to_str().unwrap()], None)
            .exit,
        "0"
    );
    let original = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(original.exit, "0", "{}", original.stdout);
    assert!(original
        .stdout
        .contains(&format!("verified: job {}", manifest.job_id)));
}

#[test]
fn verification_uses_source_identity_across_paths_and_preserves_legacy_outputs() {
    let fixture = Fixture::new();
    assert_eq!(fixture.invoke(&["convert", fixture.book()], None).exit, "0");
    let (directory, _) = fixture.newest_job();
    let relocated = fixture.root.join("relocated.epub");
    fs::copy(fixture.book(), &relocated).unwrap();
    let verified = fixture.invoke(
        &["convert", relocated.to_str().unwrap(), "--verify-only"],
        None,
    );
    assert_eq!(verified.exit, "0", "{}", verified.stdout);

    let manifest_path = directory.join("manifest.json");
    let mut legacy: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    legacy.as_object_mut().unwrap().remove("sourceSha256");
    let original = serde_json::to_vec(&legacy).unwrap();
    fs::write(&manifest_path, &original).unwrap();
    for mode in ["--verify-only", "--fix"] {
        let run = fixture.invoke(&["convert", fixture.book(), mode], None);
        assert_eq!(run.exit, "1", "{}", run.stdout);
        assert!(run.stdout.contains("legacy output has no source identity"));
        assert_eq!(run.spoken, "");
        assert_eq!(fs::read(&manifest_path).unwrap(), original);
    }
}

#[test]
fn fix_refuses_active_jobs_without_withdrawing_receipts() {
    let fixture = Fixture::new();
    assert_eq!(fixture.invoke(&["convert", fixture.book()], None).exit, "0");
    let (directory, manifest) = fixture.newest_job();
    let audio = directory.join(&manifest.chapters[0].filename);
    let receipt = audio.with_extension("mp3.complete.json");
    let original_receipt = fs::read(&receipt).unwrap();
    fs::write(&audio, b"damaged").unwrap();
    let jobs = converter_core::jobs::ConversionJobStore::new(&fixture.paths.jobs_dir).unwrap();
    jobs.delete(&manifest.job_id).unwrap();
    jobs.create(converter_core::jobs::JobRecord::new(
        &manifest.job_id,
        Default::default(),
    ))
    .unwrap();
    let original_record = jobs.load(&manifest.job_id).unwrap();
    let refused = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert!(refused.exit.contains("active"), "{}", refused.exit);
    assert_eq!(refused.spoken, "");
    assert_eq!(fs::read(receipt).unwrap(), original_receipt);
    assert_eq!(fs::read(audio).unwrap(), b"damaged");
    assert_eq!(jobs.load(&manifest.job_id).unwrap(), original_record);
}

#[test]
fn verification_detects_a_corrupt_archive_and_fix_republishes_without_synthesis() {
    let fixture = Fixture::new();
    assert_eq!(fixture.invoke(&["convert", fixture.book()], None).exit, "0");
    let (directory, manifest) = fixture.newest_job();
    let archive = directory.join(&manifest.archive);
    fs::write(&archive, b"not a ZIP archive").unwrap();
    let audited = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(audited.exit, "1", "{}", audited.stdout);
    assert_eq!(fs::read(&archive).unwrap(), b"not a ZIP archive");
    let fixed = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert_eq!(fixed.exit, "0", "{}\n{}", fixed.stdout, fixed.stderr);
    assert_eq!(fixed.spoken, "");
    let packed = zip::ZipArchive::new(fs::File::open(archive).unwrap()).unwrap();
    assert_eq!(packed.len(), manifest.chapters.len());
}

#[test]
fn verify_only_audits_and_fix_reconverts_only_the_damaged_chapter() {
    let fixture = Fixture::new();
    let converted = fixture.invoke(&["convert", fixture.book()], None);
    assert_eq!(converted.exit, "0", "{}", converted.stderr);
    let (directory, manifest) = fixture.newest_job();
    let audio: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| directory.join(&chapter.filename))
        .collect();
    let untouched = [fs::read(&audio[0]).unwrap(), fs::read(&audio[2]).unwrap()];

    // Intact output verifies without synthesis and without a new job.
    let verified = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(verified.exit, "0", "{}", verified.stdout);
    assert_eq!(verified.spoken, "");
    assert!(verified.stdout.contains(&format!(
        "verified: job {}, 3 of 3 source chapters and archive",
        manifest.job_id
    )));
    // With nothing to repair, --fix is the same audit.
    let nothing_to_fix = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert_eq!(nothing_to_fix.exit, "0", "{}", nothing_to_fix.stdout);
    assert_eq!(nothing_to_fix.spoken, "");

    // Damage is reported with exit status 1; the audit itself changes nothing.
    fs::write(&audio[1], b"damaged audio").unwrap();
    let failed = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(failed.exit, "1", "{}", failed.stdout);
    assert_eq!(failed.spoken, "");
    assert!(failed
        .stdout
        .contains("does not match its completion receipt"));
    assert!(failed.stdout.contains(&manifest.chapters[1].filename));
    assert!(failed.stdout.contains("run with --fix"));
    assert_eq!(fs::read(&audio[1]).unwrap(), b"damaged audio");

    // With no cached segment to fall back on, the fix must synthesize: only the
    // damaged chapter reaches the runtime and the others keep their bytes.
    fixture.forget_cached_segments();
    let fixed = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert_eq!(fixed.exit, "0", "{}\n{}", fixed.stdout, fixed.stderr);
    assert_eq!(fixed.chapters(), "B");
    assert!(fixed.stdout.contains("1 chapter(s) failed the audit"));
    assert!(audio_is_valid(&directory, &manifest));
    assert_eq!(fs::read(&audio[0]).unwrap(), untouched[0]);
    assert_eq!(fs::read(&audio[2]).unwrap(), untouched[1]);
    assert_eq!(
        fixture.published_jobs().len(),
        1,
        "the job is repaired in place"
    );

    // A missing archive is republished without speaking any chapter.
    let archive = directory.join(&manifest.archive);
    fs::remove_file(&archive).unwrap();
    let missing_archive = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(missing_archive.exit, "1", "{}", missing_archive.stdout);
    let republished = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert_eq!(
        republished.exit, "0",
        "{}\n{}",
        republished.stdout, republished.stderr
    );
    assert_eq!(republished.spoken, "");
    assert!(fs::metadata(&archive).unwrap().len() > 0);

    // A failed reconversion is a failed command; a retry round completes it.
    fs::remove_file(&audio[2]).unwrap();
    fixture.forget_cached_segments();
    let interrupted = fixture.invoke(&["convert", fixture.book(), "--fix"], Some("Cardoso:1"));
    assert!(
        interrupted.exit.starts_with("error:"),
        "{}",
        interrupted.exit
    );
    assert!(!audio[2].exists());
    assert_eq!(
        fixture
            .invoke(&["convert", fixture.book(), "--verify-only"], None)
            .exit,
        "1"
    );
    let retried = fixture.invoke(
        &["convert", fixture.book(), "--fix", "--retry-failed", "1"],
        Some("Cardoso:1"),
    );
    assert_eq!(retried.exit, "0", "{}\n{}", retried.stdout, retried.stderr);
    assert_eq!(retried.chapters(), "C");
    assert!(retried.stderr.contains("retry round 1/1"));
    assert!(audio_is_valid(&directory, &manifest));
    assert_eq!(fs::read(&audio[0]).unwrap(), untouched[0]);
}

#[test]
fn fix_refuses_output_it_cannot_repair_in_place_and_leaves_it_untouched() {
    let fixture = Fixture::new();
    assert_eq!(fixture.invoke(&["convert", fixture.book()], None).exit, "0");
    let (directory, manifest) = fixture.newest_job();
    let audio: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| directory.join(&chapter.filename))
        .collect();

    // A directory that is not the job its manifest names is never audited.
    let stray = fixture.paths.output_dir.join("stray-copy");
    fs::create_dir_all(&stray).unwrap();
    fs::copy(directory.join("manifest.json"), stray.join("manifest.json")).unwrap();
    let audited = fixture.invoke(&["convert", fixture.book(), "--verify-only"], None);
    assert_eq!(audited.exit, "0", "{}", audited.stdout);
    assert!(audited
        .stdout
        .contains(&format!("verified: job {}", manifest.job_id)));
    fs::remove_dir_all(&stray).unwrap();

    // The same title with rewritten text is a different book for cached audio.
    let revised = fixture.root.join("revised.epub");
    let mut chapters = CHAPTERS;
    chapters[1].1 = "Barbosa passa a tarde na biblioteca antiga e escolhe um livro de histórias.";
    write_epub(&revised, &chapters);
    for mode in ["--verify-only", "--fix"] {
        let changed = fixture.invoke(&["convert", revised.to_str().unwrap(), mode], None);
        assert_eq!(changed.exit, "1", "{}", changed.stdout);
        assert_eq!(changed.spoken, "");
        assert!(
            changed.stdout.contains("the book chapter now has"),
            "{}",
            changed.stdout
        );
    }
    let refused = fixture.invoke(&["convert", revised.to_str().unwrap(), "--fix"], None);
    assert!(refused.stdout.contains("cannot be repaired in place"));
    assert!(audio_is_valid(&directory, &manifest));
    assert_eq!(fixture.published_jobs().len(), 1);

    // Without the job's persisted request there is nothing to replay, and the
    // damaged chapter keeps its receipt because nothing was started.
    fs::write(&audio[0], b"damaged audio").unwrap();
    let request = fixture
        .paths
        .jobs_dir
        .join("requests")
        .join(format!("{}.json", manifest.job_id));
    fs::remove_file(&request).unwrap();
    let unreplayable = fixture.invoke(&["convert", fixture.book(), "--fix"], None);
    assert!(
        unreplayable.exit.starts_with(&format!(
            "error: --fix cannot reopen job {}",
            manifest.job_id
        )),
        "{}",
        unreplayable.exit
    );
    assert_eq!(unreplayable.spoken, "");
    assert_eq!(fs::read(&audio[0]).unwrap(), b"damaged audio");
    assert!(retained_chapter_audio_is_intact(&audio[1]));
    assert!(retained_chapter_audio_is_intact(&audio[2]));
    assert!(audio[0].with_extension("mp3.complete.json").is_file());
}
