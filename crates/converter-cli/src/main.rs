use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{self, IsTerminal};
use std::path::{Path, PathBuf};

const SUPPORTED_EXTENSIONS: &[&str] = &["epub", "pdf"];

#[derive(Debug, Clone, PartialEq, Eq)]
struct CliOptions {
    command: String,
    inputs: Vec<String>,
    batch_inputs: Vec<String>,
    batch_manifest: Option<String>,
    engine: String,
    fallback_engine: String,
    voice: Option<String>,
    model: Option<String>,
    output_dir: Option<String>,
    chapters: Vec<String>,
    sections: Vec<String>,
    show_structure: bool,
    clean_cache: bool,
    verify: bool,
    no_cache: bool,
    no_parallel: bool,
    yes: bool,
    stop_on_error: bool,
    menu: bool,
}

impl Default for CliOptions {
    fn default() -> Self {
        Self {
            command: "convert".into(),
            inputs: Vec::new(),
            batch_inputs: Vec::new(),
            batch_manifest: None,
            engine: "edge".into(),
            fallback_engine: "none".into(),
            voice: None,
            model: None,
            output_dir: None,
            chapters: Vec::new(),
            sections: Vec::new(),
            show_structure: false,
            clean_cache: false,
            verify: false,
            no_cache: false,
            no_parallel: false,
            yes: false,
            stop_on_error: false,
            menu: false,
        }
    }
}

fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    converter_core::piper::register_runtime(std::sync::Arc::new(
        converter_core::piper::RegisteredPiperRuntime::new(|text, output| {
            let model = std::env::var_os("PIPER_MODEL")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| {
                    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join("../../models/piper/pt_BR-faber-medium.onnx")
                });
            let config = model.with_extension("onnx.json");
            let binary = std::env::var_os("PIPER_BINARY")
                .unwrap_or_else(|| std::ffi::OsString::from("piper"));
            let mut command = std::process::Command::new(binary);
            command
                .arg("--model")
                .arg(model)
                .arg("--config")
                .arg(config)
                .arg("--output_file")
                .arg(output);
            let mut child = command
                .stdin(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .map_err(|error| converter_core::piper::PiperError::Io(error.to_string()))?;
            use std::io::Write;
            child
                .stdin
                .take()
                .ok_or_else(|| converter_core::piper::PiperError::Io("missing Piper stdin".into()))?
                .write_all(text.as_bytes())
                .map_err(|error| converter_core::piper::PiperError::Io(error.to_string()))?;
            let result = child
                .wait_with_output()
                .map_err(|error| converter_core::piper::PiperError::Io(error.to_string()))?;
            if !result.status.success() {
                return Err(converter_core::piper::PiperError::Synthesis(
                    String::from_utf8_lossy(&result.stderr).trim().to_owned(),
                ));
            }
            Ok(())
        }),
    ));
    let raw = env::args().skip(1).collect::<Vec<_>>();
    match run(raw) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("error: {error}");
            std::process::exit(2);
        }
    }
}

fn run(raw: Vec<String>) -> Result<i32, String> {
    if raw.is_empty() {
        print_help();
        return Ok(0);
    }
    let normalized = normalize_cli_args(&raw);
    let mut options = parse_args(&normalized)?;
    let resolved = resolve_inputs(&options.inputs)?;
    options.inputs = resolved;

    let mut batch = Vec::new();
    for value in &options.batch_inputs {
        batch.extend(resolve_entry(value)?);
    }
    if let Some(manifest) = &options.batch_manifest {
        let content = fs::read_to_string(manifest)
            .map_err(|error| format!("failed to read batch file '{}': {error}", manifest))?;
        for line in content
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
        {
            batch.extend(resolve_entry(line)?);
        }
    }

    if options.clean_cache && options.inputs.is_empty() && batch.is_empty() {
        clear_global_cache(options.yes)?;
        return Ok(0);
    }

    if options.menu && options.inputs.is_empty() && batch.is_empty() {
        return Err("--menu requires an EPUB or PDF input file".into());
    }
    if options.inputs.is_empty() && batch.is_empty() {
        print_help();
        return Ok(1);
    }

    let mut all = options.inputs.clone();
    all.extend(batch);
    if options.show_structure {
        return show_structure(&all);
    }

    if options.clean_cache {
        for input in &all {
            clear_book_cache(Path::new(input), true)?;
        }
    }

    let config = converter_core::config::AppConfig::from_env();
    for (position, input) in all.iter().enumerate() {
        let session = converter_core::embedded::EmbeddedConversionSession::open(
            input,
            converter_core::embedded::EmbeddedConversionOptions {
                job_id: Some(format!("cli-{}-{}", std::process::id(), position)),
                engine: Some(options.engine.clone()),
                voice: options.voice.clone(),
                language: None,
                no_parallel: options.no_parallel,
            },
            config.clone(),
        )
        .map_err(|error| error.to_string())?;
        let manifest = session.convert().map_err(|error| error.to_string())?;
        if options.verify {
            verify_output(&config.paths.output_dir.join(&manifest.job_id), &manifest)?;
            println!("verified: {} chapters and archive", manifest.chapters.len());
        }
        println!(
            "{}",
            serde_json::to_string_pretty(&manifest).map_err(|error| error.to_string())?
        );
    }
    Ok(0)
}

fn parse_args(args: &[String]) -> Result<CliOptions, String> {
    let mut options = CliOptions::default();
    let mut positional = Vec::new();
    let mut index = 0;
    if matches!(
        args.first().map(String::as_str),
        Some("convert" | "menu" | "clear-cache")
    ) {
        options.command = args[0].clone();
        options.menu = options.command == "menu";
        options.clean_cache = options.command == "clear-cache";
        index = 1;
    }
    while index < args.len() {
        let value = &args[index];
        let mut next = |name: &str| -> Result<String, String> {
            index += 1;
            args.get(index)
                .cloned()
                .ok_or_else(|| format!("{name} requires a value"))
        };
        match value.as_str() {
            "--engine" => options.engine = next(value)?,
            "--fallback-engine" => options.fallback_engine = next(value)?,
            "--engine-chain-fallback" => options.fallback_engine = "auto".into(),
            "--voice" => options.voice = Some(next(value)?),
            "--model" => options.model = Some(next(value)?),
            "--output-dir" => options.output_dir = Some(next(value)?),
            "--chapter" => options.chapters.push(next(value)?),
            "--section" => options.sections.push(next(value)?),
            "--batch" => options.batch_inputs.push(next(value)?),
            "--batch-file" => options.batch_manifest = Some(next(value)?),
            "--show-structure" => options.show_structure = true,
            "--clear-cache" | "--clean-cache" => options.clean_cache = true,
            "--verify" | "--verify-only" => options.verify = true,
            "--no-cache" => options.no_cache = true,
            "--no-parallel" => options.no_parallel = true,
            "--yes" | "-y" => options.yes = true,
            "--stop-on-error" => options.stop_on_error = true,
            "--menu" => options.menu = true,
            option if option.starts_with('-') => {
                return Err(format!("unknown option '{option}'"));
            }
            _ => positional.push(value.clone()),
        }
        index += 1;
    }
    options.inputs = positional;
    if !matches!(options.engine.as_str(), "auto" | "edge" | "piper") {
        return Err(format!(
            "invalid engine '{}'; expected auto, edge, or piper",
            options.engine
        ));
    }
    Ok(options)
}

fn normalize_cli_args(raw: &[String]) -> Vec<String> {
    if raw.is_empty()
        || raw[0].starts_with('-')
        || matches!(raw[0].as_str(), "convert" | "menu" | "clear-cache")
    {
        return raw.to_vec();
    }
    let mut first = Vec::new();
    let mut consumed = 0;
    for (index, token) in raw.iter().enumerate() {
        if token.starts_with('-') {
            break;
        }
        first.push(token.clone());
        consumed = index + 1;
        if Path::new(&first.join(" ")).expand().exists() {
            break;
        }
    }
    if first.is_empty() {
        return raw.to_vec();
    }
    let mut result = vec![first.join(" ")];
    result.extend_from_slice(&raw[consumed..]);
    result
}

fn resolve_inputs(entries: &[String]) -> Result<Vec<String>, String> {
    let mut resolved = Vec::new();
    for entry in entries {
        let files = resolve_entry(entry)?;
        if files.is_empty() {
            eprintln!("[warn] no EPUB/PDF found at: {entry}");
        }
        resolved.extend(files);
    }
    Ok(resolved)
}

fn resolve_entry(entry: &str) -> Result<Vec<String>, String> {
    let path = PathBuf::from(entry).expand();
    let mut files = collect_files(&path);
    if files.is_empty() {
        if let Some(match_path) = fuzzy_find_book(entry) {
            println!("Fuzzy match: '{entry}' -> {}", match_path.display());
            files.push(match_path);
        }
    }
    Ok(files
        .into_iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect())
}

fn collect_files(path: &Path) -> Vec<PathBuf> {
    if path.is_file() && supported(path) {
        return vec![path.to_path_buf()];
    }
    if !path.is_dir() {
        return Vec::new();
    }
    let mut files = Vec::new();
    let mut stack = vec![path.to_path_buf()];
    while let Some(current) = stack.pop() {
        let Ok(entries) = fs::read_dir(current) else {
            continue;
        };
        for entry in entries.flatten() {
            let child = entry.path();
            if child.is_dir() {
                stack.push(child);
            } else if supported(&child) {
                files.push(child);
            }
        }
    }
    files.sort();
    files
}

fn supported(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|value| {
            SUPPORTED_EXTENSIONS
                .iter()
                .any(|extension| value.eq_ignore_ascii_case(extension))
        })
        .unwrap_or(false)
}

fn fuzzy_find_book(query: &str) -> Option<std::path::PathBuf> {
    let tokens = norm_tokens(query);
    if tokens.is_empty() {
        return None;
    }
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for base in [home_dir().join("Downloads"), env::current_dir().ok()?] {
        let Ok(entries) = fs::read_dir(base) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if supported(&path) && seen.insert(path.clone()) {
                candidates.push(path);
            }
        }
    }
    candidates
        .into_iter()
        .filter_map(|path| {
            let name = path.file_stem()?.to_string_lossy();
            let filename_tokens = norm_tokens(&name);
            let significant = tokens
                .iter()
                .filter(|token| !is_noise_token(token))
                .filter(|token| token.len() >= 2)
                .collect::<Vec<_>>();
            if significant.is_empty() {
                return None;
            }
            let matched = significant
                .iter()
                .filter(|token| {
                    filename_tokens
                        .iter()
                        .any(|candidate| similarity(token, candidate) >= 0.75)
                })
                .count();
            let score = matched as f64 / significant.len() as f64;
            (score >= 0.6).then_some((score, path))
        })
        .max_by(|left, right| left.0.partial_cmp(&right.0).unwrap_or(Ordering::Equal))
        .map(|(_, path)| path)
}

fn is_noise_token(token: &str) -> bool {
    matches!(token, "downloads" | "download" | "home" | "users")
}

fn norm_tokens(value: &str) -> Vec<String> {
    value
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character.to_lowercase().next().unwrap_or(character)
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

fn similarity(left: &str, right: &str) -> f64 {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut row = (0..=right.len()).collect::<Vec<_>>();
    for (i, a) in left.iter().enumerate() {
        let mut next = vec![i + 1; right.len() + 1];
        for (j, b) in right.iter().enumerate() {
            next[j + 1] = (row[j + 1] + 1)
                .min(next[j] + 1)
                .min(row[j] + usize::from(a != b));
        }
        row = next;
    }
    let distance = row[right.len()] as f64;
    1.0 - distance / left.len().max(right.len()).max(1) as f64
}

fn clear_book_cache(input: &Path, assume_yes: bool) -> Result<(), String> {
    let paths = converter_core::paths::resolve_paths();
    let key = converter_core::cache::sha256_file(input).map_err(|error| error.to_string())?;
    let cache_dir = paths.cache_dir.join(key);
    let book_stem = input
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let mut targets = vec![cache_dir];
    if !book_stem.is_empty() {
        targets.push(paths.output_dir.join(book_stem));
    }
    if !assume_yes && !io::stdin().is_terminal() {
        println!("Run with --clear-cache -y to skip confirmation in non-interactive mode.");
        return Ok(());
    }
    if !assume_yes {
        eprint!("Remove cache for '{}'? [y/N]: ", input.display());
        let mut answer = String::new();
        io::stdin()
            .read_line(&mut answer)
            .map_err(|error| error.to_string())?;
        if !matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
            println!("Cache clear aborted.");
            return Ok(());
        }
    }
    for target in targets {
        if target.exists() {
            fs::remove_dir_all(&target)
                .map_err(|error| format!("failed to clear '{}': {error}", target.display()))?;
        }
    }
    println!("Book cache cleared.");
    Ok(())
}

fn verify_output(
    output_dir: &Path,
    manifest: &converter_core::worker::OutputManifest,
) -> Result<(), String> {
    if manifest.chapters.is_empty() {
        return Err("verification failed: manifest has no chapters".into());
    }
    for (position, chapter) in manifest.chapters.iter().enumerate() {
        let expected = position + 1;
        if chapter.index != expected {
            return Err(format!(
                "verification failed: expected chapter {expected}, found {}",
                chapter.index
            ));
        }
        let path = output_dir.join(&chapter.filename);
        let size = fs::metadata(&path)
            .map_err(|error| format!("verification failed: {}: {error}", path.display()))?
            .len();
        if size == 0 {
            return Err(format!(
                "verification failed: empty audio {}",
                path.display()
            ));
        }
        let expected_title = chapter.title.trim();
        if !expected_title.is_empty()
            && !chapter
                .filename
                .to_lowercase()
                .contains(&expected_title.to_lowercase())
        {
            return Err(format!(
                "verification failed: filename '{}' does not contain TOC title '{}'",
                chapter.filename, chapter.title
            ));
        }
    }
    let archive = output_dir.join(&manifest.archive);
    let archive_size = fs::metadata(&archive)
        .map_err(|error| format!("verification failed: {}: {error}", archive.display()))?
        .len();
    if archive_size == 0 {
        return Err(format!(
            "verification failed: empty archive {}",
            archive.display()
        ));
    }
    Ok(())
}

fn clear_global_cache(assume_yes: bool) -> Result<(), String> {
    let paths = converter_core::paths::resolve_paths();
    if !paths.cache_dir.exists() && !paths.output_dir.exists() {
        println!("No cache directory found.");
        return Ok(());
    }
    if !assume_yes && !io::stdin().is_terminal() {
        println!("Run with --clear-cache -y to skip confirmation in non-interactive mode.");
        return Ok(());
    }
    if !assume_yes {
        eprint!("Remove all cached audio/text files? [y/N]: ");
        let mut answer = String::new();
        io::stdin()
            .read_line(&mut answer)
            .map_err(|error| error.to_string())?;
        if !matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
            println!("Cache clear aborted.");
            return Ok(());
        }
    }
    for path in [&paths.cache_dir, &paths.output_dir] {
        if path.exists() {
            fs::remove_dir_all(path)
                .map_err(|error| format!("failed to clear '{}': {error}", path.display()))?;
        }
    }
    println!("Cache directory cleared.");
    Ok(())
}

fn show_structure(inputs: &[String]) -> Result<i32, String> {
    let config = converter_core::config::AppConfig::from_env();
    for input in inputs {
        println!("Structure: {input}");
        if input.to_ascii_lowercase().ends_with(".epub") {
            let session = converter_core::embedded::EmbeddedConversionSession::open(
                input,
                Default::default(),
                config.clone(),
            )
            .map_err(|error| error.to_string())?;
            let metadata = session.metadata();
            if !metadata.title.is_empty() {
                println!("Title: {}", metadata.title);
            }
            for chapter in &metadata.chapters {
                println!("{} {}", chapter.index, chapter.name);
            }
        } else {
            println!("PDF structure inspection is delegated to the PDF ingestion adapter.");
        }
    }
    Ok(0)
}

fn print_help() {
    println!("EBook to Audiobook Converter\n\nUsage: convert [INPUT ...] [OPTIONS]\n       clear-cache [BOOK]\n\nInputs accept EPUB/PDF files, directories, loose multiword names, and fuzzy matches.\n\nOptions: --engine {{auto,edge,piper}} --voice VOICE --model MODEL --chapter CHAPTER --show-structure --clean-cache --verify --batch PATH --batch-file FILE --yes");
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_sources_only_the_embedded_core_api() {
        let source = include_str!("main.rs");
        assert!(source.contains("EmbeddedConversionSession"));
        assert!(!source
            .lines()
            .any(|line| line.trim_start().starts_with("use converter_server")));
        let forbidden_client = ["re", "qwest"].concat();
        assert!(!source.contains(&forbidden_client));
        let forbidden_http = ["http", "://"].concat();
        assert!(!source.contains(&forbidden_http));
    }

    #[test]
    fn verification_rejects_missing_chapter_audio() {
        let root = std::env::temp_dir().join(format!("converter-verify-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temporary directory should be created");
        let manifest = converter_core::worker::OutputManifest {
            job_id: "test".into(),
            title: "Book".into(),
            author: "Author".into(),
            chapters: vec![converter_core::audio::ChapterMetadata {
                index: 1,
                title: "Chapter 1".into(),
                filename: "0001-Chapter_1.mp3".into(),
                text_chars: 10,
            }],
            archive: "archive.zip".into(),
            cover: None,
        };
        let error = verify_output(&root, &manifest).expect_err("missing audio must fail");
        assert!(error.contains("verification failed"));
        let _ = fs::remove_dir_all(root);
    }
}

trait ExpandPath {
    fn expand(&self) -> PathBuf;
}
impl ExpandPath for Path {
    fn expand(&self) -> PathBuf {
        if self == Path::new("~") {
            return home_dir();
        }
        if let Some(value) = self.to_str() {
            if let Some(rest) = value.strip_prefix("~/") {
                return home_dir().join(rest);
            }
        }
        self.to_path_buf()
    }
}
