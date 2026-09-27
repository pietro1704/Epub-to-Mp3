use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read};
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
    clear_cache: bool,
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
            clear_cache: false,
            no_cache: false,
            no_parallel: false,
            yes: false,
            stop_on_error: false,
            menu: false,
        }
    }
}

fn main() {
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

    if options.clear_cache && options.inputs.is_empty() && batch.is_empty() {
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

    if options.clear_cache {
        for input in &all {
            clear_book_cache(Path::new(input), options.yes)?;
        }
        return Ok(0);
    }

    let config = converter_core::config::AppConfig::from_env();
    for (position, input) in all.iter().enumerate() {
        let request = converter_core::worker::ConversionRequest {
            input: PathBuf::from(input),
            job_id: format!("cli-{}-{}", std::process::id(), position),
            engine: Some(options.engine.clone()),
            voice: options.voice.clone(),
            language: None,
            no_parallel: options.no_parallel,
        };
        let worker = converter_core::worker::ConversionWorker::new(config.clone())?;
        let manifest = worker.run(request).map_err(|error| error.to_string())?;
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
        options.clear_cache = options.command == "clear-cache";
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
            "--clear-cache" => options.clear_cache = true,
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

fn fuzzy_find_book(query: &str) -> Option<PathBuf> {
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
            fs::remove_dir_all(&target).map_err(|error| format!("failed to clear '{}': {error}", target.display()))?;
        }
    }
    println!("Book cache cleared.");
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

fn clear_book_cache(input: &str) -> Result<(), String> {
    let paths = converter_core::paths::resolve_paths();
    let stem = Path::new(input)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or(input);
    let slug = stem
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    for root in [&paths.cache_dir, &paths.output_dir] {
        let candidate = root.join(&slug);
        if candidate.exists() {
            fs::remove_dir_all(&candidate)
                .map_err(|error| format!("failed to clear '{}': {error}", candidate.display()))?;
        }
    }
    Ok(())
}

fn show_structure(inputs: &[String]) -> Result<i32, String> {
    for input in inputs {
        println!("Structure: {input}");
        if input.to_ascii_lowercase().ends_with(".epub") {
            let file = fs::File::open(input).map_err(|error| error.to_string())?;
            let book = converter_core::epub::parse_epub(file).map_err(|error| error.to_string())?;
            if !book.title.is_empty() {
                println!("Title: {}", book.title);
            }
            for chapter in book.chapters {
                println!("{} {}", chapter.index, chapter.name);
            }
        } else {
            println!("PDF structure inspection is delegated to the PDF ingestion adapter.");
        }
    }
    Ok(0)
}

fn print_help() {
    println!("EBook to Audiobook Converter\n\nUsage: convert [INPUT ...] [OPTIONS]\n       clear-cache [BOOK]\n\nInputs accept EPUB/PDF files, directories, loose multiword names, and fuzzy matches.\n\nOptions: --engine {{auto,edge,piper}} --voice VOICE --model MODEL --chapter CHAPTER --show-structure --clear-cache --batch PATH --batch-file FILE --yes");
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

trait ExpandPath {
    fn expand(&self) -> PathBuf;
}
impl ExpandPath for Path {
    fn expand(&self) -> PathBuf {
        if self == Path::new("~") {
            return home_dir();
        }
        if let Ok(value) = self.to_str() {
            if let Some(rest) = value.strip_prefix("~/") {
                return home_dir().join(rest);
            }
        }
        self.to_path_buf()
    }
}
