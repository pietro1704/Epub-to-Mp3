//! Range, cache, retry and repair behaviour through real conversions.
//!
//! Every CLI invocation runs in its own child process, as it does for a user:
//! the job identity embeds the process ID and the Piper runtime is process-wide.
//! The child registers a deterministic Piper runtime in place of the embedded
//! one, so no voice model, network access or audio tool is involved.
use converter_core::worker::OutputManifest;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::{Arc, Mutex},
};
use zip::write::SimpleFileOptions;

#[path = "../../converter-core/tests/support/epub_fixture.rs"]
mod epub_fixture;

#[path = "../../converter-core/tests/support/pdf_fixture.rs"]
mod pdf_fixture;

const INVOCATION: &str = "CLI_FAKE_PIPER_INVOCATION";
const FAILURES: &str = "CLI_FAKE_PIPER_FAILURES";
/// One name per fixture chapter; every sentence of a chapter carries its name.
const CHAPTER_NAMES: [&str; 3] = ["Almeida", "Barbosa", "Cardoso"];
pub(super) const CHAPTERS: [(&str, &str); 3] = [
    (
        "Almeida no mercado",
        "Almeida acorda cedo e caminha pela cidade para comprar frutas maduras no mercado. No caminho, Almeida conversa com os vizinhos sobre o tempo e sobre as novidades da semana. Depois das compras, Almeida volta para casa e prepara o almoço para toda a família.",
    ),
    (
        "Barbosa na biblioteca",
        "Barbosa passa a tarde na biblioteca antiga, onde escolhe um livro de histórias para ler com as crianças. As crianças ouvem Barbosa com muita atenção e fazem perguntas sobre os personagens. Quando a leitura termina, Barbosa guarda o livro e todos voltam contentes para casa.",
    ),
    (
        "Cardoso junto ao rio",
        "Cardoso leva a família para um passeio tranquilo junto ao rio no fim da tarde. Enquanto os barcos passam devagar pela ponte, Cardoso conta lembranças da sua infância na aldeia. Ao anoitecer, Cardoso e a família voltam para casa conversando sobre o dia.",
    ),
];

/// A short audible tone: silence would be trimmed away by speech compaction.
fn tone_wav() -> Vec<u8> {
    let rate = 22_050u32;
    let samples: Vec<i16> = (0..rate / 8)
        .map(|i| ((i as f64 * 440.0 * std::f64::consts::TAU / rate as f64).sin() * 4000.0) as i16)
        .collect();
    let length = (samples.len() * 2) as u32;
    let mut wav = b"RIFF".to_vec();
    wav.extend_from_slice(&(36 + length).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&length.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

/// Child-process entry point; a no-op in an ordinary test run.
#[test]
fn fake_piper_invocation() {
    let Ok(arguments) = std::env::var(INVOCATION) else {
        return;
    };
    let arguments: Vec<String> = serde_json::from_str(&arguments).unwrap();
    // "NAME:COUNT" fails the first COUNT synthesis calls that speak NAME.
    let plan = std::env::var(FAILURES).ok().map(|plan| {
        let (name, count) = plan.split_once(':').unwrap();
        (name.to_owned(), Mutex::new(count.parse::<usize>().unwrap()))
    });
    let spoken = Arc::new(Mutex::new(String::new()));
    let recorded = spoken.clone();
    converter_core::piper::register_runtime(Arc::new(
        converter_core::piper::RegisteredPiperRuntime::new(move |text, target, _| {
            let chapter = CHAPTER_NAMES
                .iter()
                .position(|name| text.contains(name))
                .map_or('?', |position| ['A', 'B', 'C'][position]);
            recorded.lock().unwrap().push(chapter);
            if let Some((name, remaining)) = &plan {
                let mut remaining = remaining.lock().unwrap();
                if text.contains(name.as_str()) && *remaining > 0 {
                    *remaining -= 1;
                    return Err(converter_core::piper::PiperError::Synthesis(
                        "injected synthesis failure".into(),
                    ));
                }
            }
            fs::write(target, tone_wav())
                .map_err(|error| converter_core::piper::PiperError::Io(error.to_string()))
        }),
    ));
    let exit = match super::run_cli_command(arguments) {
        Ok(code) => code.to_string(),
        Err(error) => format!("error: {error}"),
    };
    println!("\nFAKE_PIPER_EXIT={exit}");
    println!("FAKE_PIPER_SPOKEN={}", spoken.lock().unwrap());
}

pub(super) struct Invocation {
    /// The exit code, or `error: …` when the command failed.
    pub(super) exit: String,
    /// One letter per synthesis call, naming the chapter it spoke.
    pub(super) spoken: String,
    pub(super) stdout: String,
    pub(super) stderr: String,
}

impl Invocation {
    /// Chapters in the order synthesis first reached them, without repeats of
    /// the chapter being spoken (several segments, or a retried segment).
    pub(super) fn chapters(&self) -> String {
        let mut chapters: Vec<char> = self.spoken.chars().collect();
        chapters.dedup();
        chapters.into_iter().collect()
    }
}

pub(super) struct Fixture {
    _directory: tempfile::TempDir,
    pub(super) root: PathBuf,
    pub(super) paths: converter_core::paths::Paths,
    book: PathBuf,
}

pub(super) fn write_epub(path: &Path, chapters: &[(&str, &str)]) {
    let items: String = (0..chapters.len())
        .map(|n| {
            format!("<item id=\"c{n}\" href=\"c{n}.xhtml\" media-type=\"application/xhtml+xml\"/>")
        })
        .collect();
    let spine: String = (0..chapters.len())
        .map(|n| format!("<itemref idref=\"c{n}\"/>"))
        .collect();
    let mut files = vec![
        ("META-INF/container.xml".to_owned(), "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>".to_owned()),
        ("content.opf".to_owned(), format!("<package xmlns:dc=\"x\"><metadata><dc:title>Passeios da semana</dc:title><dc:language>pt-BR</dc:language></metadata><manifest>{items}</manifest><spine>{spine}</spine></package>")),
    ];
    for (n, (title, text)) in chapters.iter().enumerate() {
        files.push((
            format!("c{n}.xhtml"),
            format!("<html><body><h1>{title}</h1><p>{text}</p></body></html>"),
        ));
    }
    fs::write(
        path,
        epub_fixture::epub_bytes(files, SimpleFileOptions::default()),
    )
    .unwrap();
}

impl Fixture {
    /// A runtime root with an installed synthetic Faber model and a three-chapter book.
    pub(super) fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(directory.path()).unwrap();
        let paths = converter_core::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.clone(),
        );
        let model = paths.models_dir.join("tts").join("pt_BR-faber-medium");
        fs::create_dir_all(&model).unwrap();
        fs::write(model.join("model.onnx"), b"synthetic voice model").unwrap();
        fs::write(model.join("model.onnx.json"), b"{}").unwrap();
        let book = root.join("passeios.epub");
        write_epub(&book, &CHAPTERS);
        Self {
            _directory: directory,
            root,
            paths,
            book,
        }
    }

    pub(super) fn book(&self) -> &str {
        self.book.to_str().unwrap()
    }

    pub(super) fn invoke(&self, arguments: &[&str], failures: Option<&str>) -> Invocation {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "cli_conversion_lifecycle_tests::fake_piper_invocation",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(INVOCATION, serde_json::to_string(arguments).unwrap())
            .env("PERSISTENT_ROOT", &self.root)
            .env("PATH", "/no-tools")
            .env("FFMPEG", "/no-tools/ffmpeg")
            .env("FFPROBE", "/no-tools/ffprobe")
            .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
            .env("RUST_CHAPTER_TIMEOUT_SECONDS", "30");
        for inherited in [
            "ENGINE",
            "CACHE_DIR",
            "OUTPUT_DIR",
            "SPACE_ID",
            "PIPER_MODEL",
            "PIPER_CONFIG",
            FAILURES,
        ] {
            command.env_remove(inherited);
        }
        if let Some(plan) = failures {
            command.env(FAILURES, plan);
        }
        let output = command.output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        assert!(output.status.success(), "{stdout}\n{stderr}");
        let field = |name: &str| {
            stdout
                .lines()
                .find_map(|line| line.strip_prefix(name))
                .unwrap_or_else(|| panic!("child reported no {name}\n{stdout}\n{stderr}"))
                .to_owned()
        };
        Invocation {
            exit: field("FAKE_PIPER_EXIT="),
            spoken: field("FAKE_PIPER_SPOKEN="),
            stdout,
            stderr,
        }
    }

    /// Published jobs, oldest first, each with its directory.
    pub(super) fn published_jobs(&self) -> Vec<(PathBuf, OutputManifest)> {
        let Ok(entries) = fs::read_dir(&self.paths.output_dir) else {
            return Vec::new();
        };
        let mut jobs: Vec<_> = entries
            .flatten()
            .filter_map(|entry| {
                let manifest = entry.path().join("manifest.json");
                let modified = fs::metadata(&manifest).ok()?.modified().ok()?;
                let manifest = converter_core::cache::read_json(&manifest).ok()?;
                Some((modified, entry.path(), manifest))
            })
            .collect();
        jobs.sort_by_key(|(modified, _, _)| *modified);
        jobs.into_iter()
            .map(|(_, directory, manifest)| (directory, manifest))
            .collect()
    }

    pub(super) fn newest_job(&self) -> (PathBuf, OutputManifest) {
        self.published_jobs().pop().expect("a published job")
    }

    /// Drop cached segments so the next synthesis must reach the runtime.
    pub(super) fn forget_cached_segments(&self) {
        let _ = fs::remove_dir_all(self.paths.cache_dir.join("speech-segments-v1"));
    }
}

fn source_indices(manifest: &OutputManifest) -> Vec<usize> {
    manifest
        .chapters
        .iter()
        .map(|chapter| chapter.source_index)
        .collect()
}

pub(super) fn audio_is_valid(directory: &Path, manifest: &OutputManifest) -> bool {
    manifest.chapters.iter().all(|chapter| {
        let audio = directory.join(&chapter.filename);
        converter_core::worker::retained_chapter_audio_is_intact(&audio)
            && converter_core::audio::validate_audio(&audio, 1).is_ok()
    })
}

#[test]
fn chapter_ranges_convert_exactly_the_inclusive_selection() {
    let fixture = Fixture::new();
    let span = fixture.invoke(
        &[
            "convert",
            fixture.book(),
            "--from-chapter-to-chapter",
            "2..3",
        ],
        None,
    );
    assert_eq!(span.exit, "0", "{}", span.stderr);
    assert_eq!(span.chapters(), "BC");
    let (directory, manifest) = fixture.newest_job();
    assert_eq!(source_indices(&manifest), [1, 2]);
    assert_eq!(manifest.source_chapters_total, Some(3));
    assert!(audio_is_valid(&directory, &manifest));

    // --chapter narrows an open range; the already cached chapter is not spoken again.
    let narrowed = fixture.invoke(
        &[
            "convert",
            fixture.book(),
            "--from-chapter-to-end",
            "2",
            "--chapter",
            "3",
        ],
        None,
    );
    assert_eq!(narrowed.exit, "0", "{}", narrowed.stderr);
    assert_eq!(narrowed.spoken, "");
    let (directory, manifest) = fixture.newest_job();
    assert_eq!(source_indices(&manifest), [2]);
    assert!(audio_is_valid(&directory, &manifest));

    // A PDF range resolves through the same source dispatch.
    let pdf = fixture.root.join("passeios.pdf");
    fs::write(
        &pdf,
        pdf_fixture::pdf(
            true,
            &[
                "Almeida acorda cedo e caminha pela cidade para comprar frutas maduras no mercado.",
                "Barbosa passa a tarde na biblioteca antiga, onde escolhe um livro para ler com as criancas.",
                "Cardoso leva a familia para um passeio tranquilo junto ao rio no fim da tarde, enquanto os barcos passam devagar pela ponte.",
            ],
        ),
    )
    .unwrap();
    let from_second_section = fixture.invoke(
        &[
            "convert",
            pdf.to_str().unwrap(),
            "--from-chapter-to-end",
            "position:1",
        ],
        None,
    );
    assert_eq!(
        from_second_section.exit, "0",
        "{}",
        from_second_section.stderr
    );
    assert_eq!(from_second_section.chapters(), "C");
    let (_, manifest) = fixture.newest_job();
    assert_eq!(manifest.title, "PDF fixture");
    assert_eq!(source_indices(&manifest), [1]);

    // A reversed range is rejected without adding a job, request or output.
    let jobs_before = fs::read_dir(&fixture.paths.jobs_dir).unwrap().count();
    let rejected = fixture.invoke(
        &[
            "convert",
            fixture.book(),
            "--from-chapter-to-chapter",
            "3..1",
            "--clean-cache",
        ],
        None,
    );
    assert!(
        rejected.exit.contains("matches no chapter at or after '3'"),
        "{}",
        rejected.exit
    );
    assert_eq!(rejected.spoken, "");
    assert_eq!(fixture.published_jobs().len(), 3);
    assert_eq!(
        fs::read_dir(&fixture.paths.jobs_dir).unwrap().count(),
        jobs_before
    );
}

#[test]
fn force_reprocess_regenerates_audio_that_a_plain_rerun_reuses() {
    let fixture = Fixture::new();
    let selection = ["convert", fixture.book(), "--chapter", "position:0"];
    let forced = [&selection[..], &["--force-reprocess"]].concat();
    for (arguments, expected) in [
        (&selection[..], "A"),
        (&selection[..], ""),
        (&forced[..], "A"),
        (&selection[..], ""),
    ] {
        let run = fixture.invoke(arguments, None);
        assert_eq!(run.exit, "0", "{}", run.stderr);
        assert_eq!(run.chapters(), expected, "{arguments:?}");
        let (directory, manifest) = fixture.newest_job();
        assert_eq!(source_indices(&manifest), [0]);
        assert!(audio_is_valid(&directory, &manifest));
    }
    // Every invocation published its own job; none replaced an earlier one.
    assert_eq!(fixture.published_jobs().len(), 4);
}

#[test]
fn retry_rounds_resume_the_failed_chapter_and_zero_disables_them() {
    // Without a retry round, one failed chapter fails the conversion.
    let fixture = Fixture::new();
    let unretried = fixture.invoke(&["convert", fixture.book()], Some("Cardoso:1"));
    assert!(unretried.exit.starts_with("error:"), "{}", unretried.exit);
    assert_eq!(unretried.chapters(), "ABC");
    let disabled = fixture.invoke(
        &["convert", fixture.book(), "--retry-failed", "0"],
        Some("Cardoso:1"),
    );
    assert!(disabled.exit.starts_with("error:"), "{}", disabled.exit);
    assert!(!disabled.stderr.contains("retry round"));
    assert!(fixture.published_jobs().is_empty());

    // One round resumes at the failed chapter; finished chapters are not spoken again.
    let fixture = Fixture::new();
    let retried = fixture.invoke(
        &["convert", fixture.book(), "--retry-failed", "1"],
        Some("Cardoso:1"),
    );
    assert_eq!(retried.exit, "0", "{}", retried.stderr);
    assert!(
        retried.stderr.contains("retry round 1/1"),
        "{}",
        retried.stderr
    );
    assert_eq!(retried.chapters(), "ABC");
    let (directory, manifest) = fixture.newest_job();
    assert_eq!(source_indices(&manifest), [0, 1, 2]);
    assert!(audio_is_valid(&directory, &manifest));
    assert_eq!(fixture.published_jobs().len(), 1);

    // Forced regeneration stays in force for the round, so it starts over rather
    // than letting the failed chapter fall back to cached audio.
    let forced = fixture.invoke(
        &[
            "convert",
            fixture.book(),
            "--force-reprocess",
            "--retry-failed",
            "1",
        ],
        Some("Cardoso:1"),
    );
    assert_eq!(forced.exit, "0", "{}", forced.stderr);
    assert_eq!(forced.chapters(), "ABCABC");

    // Rounds are bounded: a second failure exhausts one round...
    let fixture = Fixture::new();
    let exhausted = fixture.invoke(
        &["convert", fixture.book(), "--retry-failed", "1"],
        Some("Cardoso:2"),
    );
    assert!(
        exhausted.exit.contains("injected synthesis failure"),
        "{}",
        exhausted.exit
    );
    assert!(fixture.published_jobs().is_empty());

    // ...and the manual pass adds exactly one more attempt.
    let fixture = Fixture::new();
    let manual = fixture.invoke(
        &[
            "convert",
            fixture.book(),
            "--retry-failed",
            "1",
            "--retry-failed-manual",
        ],
        Some("Cardoso:2"),
    );
    assert_eq!(manual.exit, "0", "{}", manual.stderr);
    assert!(
        manual.stderr.contains("manual retry pass"),
        "{}",
        manual.stderr
    );
    assert_eq!(manual.chapters(), "ABC");
    let alone = Fixture::new();
    let manual_only = alone.invoke(
        &["convert", alone.book(), "--retry-failed-manual"],
        Some("Barbosa:1"),
    );
    assert_eq!(manual_only.exit, "0", "{}", manual_only.stderr);
    assert_eq!(manual_only.chapters(), "ABC");
}
