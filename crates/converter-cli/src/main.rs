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
    fallback_model: Option<String>,
    fallback_voice: Option<String>,
    allow_online_fallback: Option<bool>,
    tts_preferences: Option<converter_core::tts_preferences::TtsPreferences>,
    output_dir: Option<String>,
    chapters: Vec<String>,
    sections: Vec<String>,
    show_structure: bool,
    clean_cache: bool,
    verify: bool,
    no_parallel: bool,
    yes: bool,
    menu: bool,
}

impl Default for CliOptions {
    fn default() -> Self {
        Self {
            command: "convert".into(),
            inputs: Vec::new(),
            batch_inputs: Vec::new(),
            batch_manifest: None,
            engine: "piper".into(),
            fallback_engine: "none".into(),
            voice: None,
            model: None,
            fallback_model: None,
            fallback_voice: None,
            allow_online_fallback: None,
            tts_preferences: None,
            output_dir: None,
            chapters: Vec::new(),
            sections: Vec::new(),
            show_structure: false,
            clean_cache: false,
            verify: false,
            no_parallel: false,
            yes: false,
            menu: false,
        }
    }
}

fn packaged_data_root(
    executable: &Path,
    home: Option<&Path>,
    local_data: Option<&Path>,
) -> Option<PathBuf> {
    let package = executable.parent()?.parent()?;
    let metadata = fs::read(package.join("package.json")).ok()?;
    let metadata: serde_json::Value = serde_json::from_slice(&metadata).ok()?;
    if metadata["runtime"] != "native Rust/Piper" {
        return None;
    }
    if cfg!(target_os = "macos") {
        return Some(
            home?
                .join("Library")
                .join("Application Support")
                .join("EpubToMp3"),
        );
    }
    if cfg!(target_os = "windows") {
        return local_data
            .map(Path::to_path_buf)
            .or_else(|| home.map(|path| path.join("AppData").join("Local")))
            .map(|path| path.join("EpubToMp3"));
    }
    local_data
        .map(Path::to_path_buf)
        .or_else(|| home.map(|path| path.join(".local").join("share")))
        .map(|path| path.join("epub-to-mp3"))
}

fn cli_config() -> converter_core::config::AppConfig {
    let mut config = converter_core::config::AppConfig::from_env();
    if std::env::var_os("PERSISTENT_ROOT").is_some_and(|value| !value.is_empty()) {
        return config;
    }
    let home = std::env::var_os(if cfg!(target_os = "windows") {
        "USERPROFILE"
    } else {
        "HOME"
    })
    .map(PathBuf::from);
    let local_data = std::env::var_os(if cfg!(target_os = "windows") {
        "LOCALAPPDATA"
    } else {
        "XDG_DATA_HOME"
    })
    .map(PathBuf::from)
    .filter(|path| path.is_absolute());
    let packaged_root = std::env::current_exe().ok().and_then(|executable| {
        packaged_data_root(&executable, home.as_deref(), local_data.as_deref())
    });
    if let Some(root) = packaged_root {
        let environment = std::env::vars_os().chain(std::iter::once((
            std::ffi::OsString::from("PERSISTENT_ROOT"),
            root.into_os_string(),
        )));
        config.paths = converter_core::paths::resolve_paths_from(
            environment,
            config.paths.project_root.clone(),
        );
    }
    config
}

fn preference_path(config: &converter_core::config::AppConfig) -> PathBuf {
    config.paths.persistent_root.join("tts-preferences.json")
}
fn saved_preferences(
    config: &converter_core::config::AppConfig,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let path = preference_path(config);
    if !path.exists() {
        return Ok(Default::default());
    }
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| format!("Invalid saved TTS preferences: {e}"))
}
fn command_preferences(raw: &[String]) -> Result<i32, String> {
    let config = cli_config();
    match raw.get(1).map(String::as_str).unwrap_or("show") {
        "show" => println!(
            "{}",
            serde_json::to_string_pretty(&saved_preferences(&config)?).map_err(|e| e.to_string())?
        ),
        "set" => {
            let json = raw.get(2).ok_or("Usage: preferences set JSON")?;
            let preferences: converter_core::tts_preferences::TtsPreferences =
                serde_json::from_str(json).map_err(|e| e.to_string())?;
            preferences.validate(None)?;
            converter_core::cache::atomic_write_json(preference_path(&config), &preferences)
                .map_err(|e| e.to_string())?;
        }
        _ => return Err("Usage: preferences show | preferences set JSON".into()),
    }
    Ok(0)
}
fn command_models(raw: &[String]) -> Result<i32, String> {
    let config = cli_config();
    let root = config.paths.models_dir.join("tts");
    match raw.get(1).map(String::as_str).unwrap_or("list") {
        "list" => {
            for model in converter_core::model_catalog::MODELS
                .iter()
                .filter(|m| m.engine == "piper" && !m.artifacts.is_empty())
            {
                println!(
                    "{}\t{} bytes\t{}",
                    model.id,
                    model.download_bytes,
                    if converter_core::model_store::ModelStore::new(root.clone())
                        .is_manifest_installed(
                            &converter_core::model_store::ModelStore::catalog_manifest(model.id)
                                .map_err(|error| error.to_string())?
                        )
                        .map_err(|error| error.to_string())?
                    {
                        "installed"
                    } else {
                        "not installed"
                    }
                );
            }
        }
        "install" => {
            let id = raw.get(2).ok_or("Usage: models install MODEL_ID")?;
            let manifest = converter_core::model_store::ModelStore::catalog_manifest(id)
                .map_err(|e| e.to_string())?;
            tokio::runtime::Runtime::new()
                .map_err(|e| e.to_string())?
                .block_on(
                    converter_core::model_store::ModelStore::new(root).install_manifest(&manifest),
                )
                .map_err(|e| e.to_string())?;
            println!("Installed {id}");
        }
        "remove" => {
            let id = raw.get(2).ok_or("Usage: models remove MODEL_ID --yes")?;
            if !raw.iter().any(|v| v == "--yes" || v == "-y") {
                return Err("Model removal requires --yes".into());
            }
            converter_core::model_store::ModelStore::catalog_manifest(id)
                .map_err(|e| e.to_string())?;
            let path = root.join(id);
            if path.exists() {
                fs::remove_dir_all(path).map_err(|e| e.to_string())?;
            }
        }
        _ => return Err("Usage: models list | install MODEL_ID | remove MODEL_ID --yes".into()),
    }
    Ok(0)
}

fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    converter_ffi::piper_runtime_register_embedded();
    if let Some(directory) = std::env::var_os("ESPEAK_DATA_DIRECTORY") {
        if let Err(error) = converter_ffi::configure_piper_data_directory(Path::new(&directory)) {
            eprintln!("Piper phonemizer configuration failed: {error}");
            std::process::exit(2);
        }
    }

    let raw = env::args().skip(1).collect::<Vec<_>>();
    match run(raw) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("error: {error}");
            std::process::exit(2);
        }
    }
}

fn preferences_with_legacy_engine(
    mut preferences: converter_core::tts_preferences::TtsPreferences,
    engine: Option<&str>,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let Some(engine) = engine.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(preferences);
    };
    let engine = engine.to_ascii_lowercase();
    if engine == "auto" {
        return Ok(preferences);
    }
    if !matches!(engine.as_str(), "edge" | "piper" | "system") {
        return Err(format!("Invalid ENGINE value: {engine}"));
    }
    if preferences.primary.engine != engine {
        preferences.primary = if engine == "piper" {
            Default::default()
        } else {
            converter_core::tts_preferences::TtsSelection {
                engine,
                model_id: None,
                voice: None,
            }
        };
        preferences.secondary = None;
    }
    Ok(preferences)
}

// Keep CLI snapshots strict without changing persisted preference compatibility.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct CapturedTtsSelection {
    engine: String,
    model_id: Option<String>,
    voice: Option<String>,
}

impl CapturedTtsSelection {
    fn into_selection(self) -> converter_core::tts_preferences::TtsSelection {
        converter_core::tts_preferences::TtsSelection {
            engine: self.engine,
            model_id: self.model_id,
            voice: self.voice,
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct CapturedTtsPreferences {
    #[serde(default)]
    policy_version: Option<u8>,
    primary: CapturedTtsSelection,
    secondary: Option<CapturedTtsSelection>,
    allow_online_fallback: bool,
}

fn parse_captured_preferences(
    json: &str,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let captured: CapturedTtsPreferences = serde_json::from_str(json)
        .map_err(|error| format!("Invalid --tts-preferences-json: {error}"))?;
    let preferences = converter_core::tts_preferences::TtsPreferences {
        policy_version: captured.policy_version,
        primary: captured.primary.into_selection(),
        secondary: captured.secondary.map(CapturedTtsSelection::into_selection),
        allow_online_fallback: captured.allow_online_fallback,
    };
    preferences.validate(None)?;
    Ok(preferences)
}

fn effective_preferences(
    config: &converter_core::config::AppConfig,
    options: &CliOptions,
    raw: &[String],
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    if let Some(captured) = &options.tts_preferences {
        return Ok(captured.clone());
    }
    let legacy_engine = if raw
        .iter()
        .any(|value| matches!(value.as_str(), "--engine" | "--model"))
    {
        None
    } else {
        std::env::var("ENGINE").ok()
    };
    let mut preferences =
        preferences_with_legacy_engine(saved_preferences(config)?, legacy_engine.as_deref())?;
    if raw
        .iter()
        .any(|v| matches!(v.as_str(), "--engine" | "--model" | "--voice"))
        && !raw.iter().any(|v| v == "--use-secondary")
    {
        preferences.secondary = None;
    }
    if (options.fallback_model.is_some() || options.fallback_voice.is_some())
        && !raw.iter().any(|v| v == "--fallback-engine")
    {
        return Err("--fallback-model and --fallback-voice require --fallback-engine".into());
    }
    if raw.iter().any(|v| v == "--engine") {
        if preferences.primary.engine != options.engine {
            preferences.primary.voice = None;
        }
        preferences.primary.engine = if options.engine == "auto" {
            "piper".into()
        } else {
            options.engine.clone()
        };
        preferences.primary.model_id = if matches!(options.engine.as_str(), "piper" | "auto") {
            Some(converter_core::tts_preferences::FABER_MODEL_ID.into())
        } else {
            None
        };
    }
    if let Some(model) = &options.model {
        if preferences.primary.engine != "piper" {
            preferences.primary.voice = None;
        }
        preferences.primary.engine = "piper".into();
        preferences.primary.model_id = Some(model.clone());
    }
    if options.voice.is_some() {
        preferences.primary.voice = options.voice.clone();
    }
    if raw
        .iter()
        .any(|v| v == "--fallback-engine" || v == "--engine-chain-fallback")
    {
        preferences.secondary = match options.fallback_engine.as_str() {
            "none" => None,
            "edge" | "system" | "piper" => {
                Some(converter_core::tts_preferences::TtsSelection {
                    engine: options.fallback_engine.clone(),
                    model_id: if options.fallback_engine == "piper" {
                        Some(options.fallback_model.clone().unwrap_or_else(|| {
                            converter_core::tts_preferences::FABER_MODEL_ID.into()
                        }))
                    } else {
                        None
                    },
                    voice: options.fallback_voice.clone(),
                })
            }
            _ => {
                return Err(
                    "Choose an explicit --fallback-engine: none, edge, piper, system".into(),
                )
            }
        };
    }
    if let Some(allow_online_fallback) = options.allow_online_fallback {
        preferences.allow_online_fallback = allow_online_fallback;
    }
    preferences.validate(None)?;
    Ok(preferences)
}

fn run(raw: Vec<String>) -> Result<i32, String> {
    if raw.first().is_some_and(|v| v == "preferences") {
        return command_preferences(&raw);
    }
    if raw.first().is_some_and(|v| v == "models") {
        return command_models(&raw);
    }
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
        return Err("--menu requires an EPUB input file".into());
    }
    if options.inputs.is_empty() && batch.is_empty() {
        print_help();
        return Ok(1);
    }

    let mut all = options.inputs.clone();
    all.extend(batch);
    // Validate the complete batch before cache cleanup or the first conversion.
    for input in &all {
        require_supported_conversion(Path::new(input))?;
    }
    if options.show_structure {
        return show_structure(&all);
    }

    if options.clean_cache {
        for input in &all {
            clear_book_cache(Path::new(input), true)?;
        }
    }

    let config = conversion_config(&options);
    let preferences = effective_preferences(&config, &options, &raw)?;

    let selected_chapters = if options.chapters.is_empty() && options.sections.is_empty() {
        None
    } else {
        Some(
            options
                .chapters
                .iter()
                .chain(options.sections.iter())
                .cloned()
                .collect(),
        )
    };
    for (position, input) in all.iter().enumerate() {
        let session = converter_core::embedded::EmbeddedConversionSession::open(
            input,
            converter_core::embedded::EmbeddedConversionOptions {
                tts_preferences: Some(preferences.clone()),
                models_root: Some(config.paths.models_dir.join("tts")),
                piper_model: None,
                piper_config: None,
                job_id: Some(format!("cli-{}-{}", std::process::id(), position)),
                engine: Some(preferences.primary.engine.clone()),
                voice: options.voice.clone(),
                language: None,
                chapter_indices: selected_chapters.clone(),
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

fn conversion_config(options: &CliOptions) -> converter_core::config::AppConfig {
    let mut config = cli_config();
    if let Some(output) = &options.output_dir {
        config.paths.output_dir = Path::new(output).expand();
    }
    config
}

fn parse_args(args: &[String]) -> Result<CliOptions, String> {
    let mut options = CliOptions::default();
    let mut positional = Vec::new();
    let mut tts_override_seen = false;
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
        tts_override_seen |= matches!(
            value.as_str(),
            "--engine"
                | "--voice"
                | "--model"
                | "--fallback-engine"
                | "--fallback-model"
                | "--fallback-voice"
                | "--engine-chain-fallback"
                | "--allow-online-fallback"
                | "--no-online-fallback"
                | "--use-secondary"
        );
        let mut next = |name: &str| -> Result<String, String> {
            index += 1;
            args.get(index)
                .cloned()
                .ok_or_else(|| format!("{name} requires a value"))
        };
        match value.as_str() {
            "--tts-preferences-json" => {
                if options.tts_preferences.is_some() {
                    return Err("--tts-preferences-json may be supplied only once".into());
                }
                options.tts_preferences = Some(parse_captured_preferences(&next(value)?)?);
            }
            "--engine" => options.engine = next(value)?,
            "--fallback-engine" => options.fallback_engine = next(value)?,
            "--engine-chain-fallback" => options.fallback_engine = "auto".into(),
            "--voice" => options.voice = Some(next(value)?),
            "--model" => options.model = Some(next(value)?),
            "--fallback-model" => options.fallback_model = Some(next(value)?),
            "--fallback-voice" => options.fallback_voice = Some(next(value)?),
            "--allow-online-fallback" | "--no-online-fallback" => {
                let allowed = value == "--allow-online-fallback";
                if options
                    .allow_online_fallback
                    .is_some_and(|previous| previous != allowed)
                {
                    return Err(
                        "--allow-online-fallback and --no-online-fallback are mutually exclusive"
                            .into(),
                    );
                }
                options.allow_online_fallback = Some(allowed);
            }
            "--use-secondary" => {}
            "--output-dir" => options.output_dir = Some(next(value)?),
            "--chapter" => options.chapters.push(next(value)?),
            "--section" => options.sections.push(next(value)?),
            "--batch" => options.batch_inputs.push(next(value)?),
            "--batch-file" => options.batch_manifest = Some(next(value)?),
            "--show-structure" => options.show_structure = true,
            "--clear-cache" | "--clean-cache" => options.clean_cache = true,
            "--verify" => options.verify = true,
            "--verify-only" | "--no-cache" | "--stop-on-error" => {
                return Err(format!("{value} is not supported by the native CLI"));
            }
            "--no-parallel" => options.no_parallel = true,
            "--yes" | "-y" => options.yes = true,
            "--menu" => options.menu = true,
            option if option.starts_with('-') => {
                return Err(format!("unknown option '{option}'"));
            }
            _ => positional.push(value.clone()),
        }
        index += 1;
    }
    if options.tts_preferences.is_some() && tts_override_seen {
        return Err("--tts-preferences-json cannot be mixed with other TTS options".into());
    }
    options.inputs = positional;
    if !matches!(
        options.engine.as_str(),
        "auto" | "edge" | "piper" | "system"
    ) {
        return Err(format!(
            "invalid engine '{}'; expected auto, edge, piper, or system",
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
        let candidate = Path::new(&first.join(" ")).expand();
        if candidate.is_file() || candidate.is_dir() {
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

fn require_supported_conversion(path: &Path) -> Result<(), String> {
    if path
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("pdf"))
    {
        return Err(format!(
            "PDF conversion and structure inspection are not supported by the native CLI: {}",
            path.display()
        ));
    }
    Ok(())
}

fn fuzzy_find_book(query: &str) -> Option<std::path::PathBuf> {
    let tokens = norm_tokens(query);
    if tokens.is_empty() {
        return None;
    }
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    let mut search_roots = vec![home_dir().join("Downloads"), env::current_dir().ok()?];
    if let Some(parent) = Path::new(query).expand().parent() {
        search_roots.push(parent.to_path_buf());
    }
    for base in search_roots {
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
        let normalized_filename = normalized_name(&chapter.filename);
        let normalized_title = normalized_name(expected_title);
        if !normalized_title.is_empty() && !normalized_filename.contains(&normalized_title) {
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

fn normalized_name(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
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
    for input in inputs {
        require_supported_conversion(Path::new(input))?;
    }
    let config = cli_config();
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
        }
    }
    Ok(0)
}

fn print_help() {
    println!("EBook to Audiobook Converter\n\nUsage: convert [INPUT ...] [OPTIONS]\n       clear-cache [BOOK]\n\nInputs accept EPUB files, directories, loose multiword names, and fuzzy matches. PDF ingestion is not supported.\n\nPreferences: preferences show | preferences set JSON\nModels: models list | models install MODEL_ID | models remove MODEL_ID --yes\nOptions: --tts-preferences-json JSON (per-job snapshot; exclusive of other TTS options)\n         --engine {{edge,piper,system}} --fallback-engine {{none,edge,piper,system}} --allow-online-fallback | --no-online-fallback --voice VOICE --model MODEL --chapter CHAPTER --show-structure --clean-cache --verify --batch PATH --batch-file FILE --yes");
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
    fn a_packaged_cli_uses_user_data_and_preserves_explicit_directory_overrides() {
        let package =
            std::env::temp_dir().join(format!("tts-cli-package-paths-{}", std::process::id()));
        fs::create_dir_all(package.join("bin")).unwrap();
        let executable = package.join("bin").join("converter-cli");
        let home = package.join("user-home");
        assert!(packaged_data_root(&executable, Some(&home), None).is_none());
        fs::write(
            package.join("package.json"),
            r#"{"runtime":"native Rust/Piper"}"#,
        )
        .unwrap();
        let persistent = packaged_data_root(&executable, Some(&home), None).unwrap();
        assert!(persistent.starts_with(&home));
        let cache = package.join("chosen-cache");
        let output = package.join("chosen-output");
        let paths = converter_core::paths::resolve_paths_from(
            [
                ("PERSISTENT_ROOT", persistent.clone()),
                ("CACHE_DIR", cache.clone()),
                ("OUTPUT_DIR", output.clone()),
            ],
            package.join("missing-original-checkout"),
        );
        assert_eq!(paths.persistent_root, persistent);
        assert_eq!(paths.cache_dir, cache);
        assert_eq!(paths.output_dir, output);
        fs::remove_dir_all(package).unwrap();
    }

    #[test]
    fn only_explicit_legacy_engine_overrides_the_faber_default() {
        use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
        let initial = TtsPreferences::default();
        assert_eq!(
            preferences_with_legacy_engine(initial.clone(), None).unwrap(),
            initial
        );
        assert_eq!(
            preferences_with_legacy_engine(initial.clone(), Some("auto")).unwrap(),
            initial
        );
        let explicit = preferences_with_legacy_engine(initial.clone(), Some(" EDGE ")).unwrap();
        assert_eq!(explicit.primary.engine, "edge");
        assert!(explicit.primary.model_id.is_none());
        assert!(explicit.secondary.is_none());
        let saved = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            },
            secondary: None,
            allow_online_fallback: false,
        };
        assert_eq!(
            preferences_with_legacy_engine(saved.clone(), Some("edge")).unwrap(),
            saved
        );
        assert_eq!(
            preferences_with_legacy_engine(saved, Some("piper"))
                .unwrap()
                .primary,
            TtsSelection::default()
        );
        assert!(preferences_with_legacy_engine(initial, Some("invented")).is_err());
    }

    #[test]
    fn manual_override_is_strict_and_model_reaches_effective_preferences() {
        use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
        let root = std::env::temp_dir().join(format!("tts-cli-preferences-{}", std::process::id()));
        let paths = converter_core::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.clone(),
        );
        let config = converter_core::config::AppConfig::from_paths(paths);
        let saved = TtsPreferences {
            policy_version: None,
            primary: TtsSelection::default(),
            secondary: Some(TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            }),
            allow_online_fallback: true,
        };
        converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
        let raw = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--model",
            "pt_BR-faber-medium",
        ]
        .map(str::to_owned);
        let effective = effective_preferences(&config, &parse_args(&raw).unwrap(), &raw).unwrap();
        assert_eq!(
            effective.primary.model_id.as_deref(),
            Some("pt_BR-faber-medium")
        );
        assert!(effective.secondary.is_none());
        assert_eq!(saved_preferences(&config).unwrap(), saved);
        let inherited = ["convert", "book.epub"].map(str::to_owned);
        assert_eq!(
            effective_preferences(&config, &parse_args(&inherited).unwrap(), &inherited).unwrap(),
            saved
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn explicit_secondary_options_are_preserved_for_conversion() {
        let args = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--model",
            "pt_BR-faber-medium",
            "--fallback-engine",
            "edge",
            "--fallback-voice",
            "pt-BR-FranciscaNeural",
            "--allow-online-fallback",
        ]
        .map(str::to_owned);
        let options = parse_args(&args).unwrap();
        assert_eq!(options.model.as_deref(), Some("pt_BR-faber-medium"));
        assert_eq!(options.fallback_engine, "edge");
        assert_eq!(
            options.fallback_voice.as_deref(),
            Some("pt-BR-FranciscaNeural")
        );
        assert_eq!(options.allow_online_fallback, Some(true));
    }

    #[test]
    fn online_fallback_flags_capture_consent_and_reject_conflicts() {
        let inherited = ["convert", "book.epub"].map(str::to_owned);
        assert_eq!(parse_args(&inherited).unwrap().allow_online_fallback, None);
        for (flag, expected) in [
            ("--allow-online-fallback", true),
            ("--no-online-fallback", false),
        ] {
            let args = ["convert", "book.epub", flag, flag].map(str::to_owned);
            assert_eq!(
                parse_args(&args).unwrap().allow_online_fallback,
                Some(expected)
            );
        }
        for flags in [
            ["--allow-online-fallback", "--no-online-fallback"],
            ["--no-online-fallback", "--allow-online-fallback"],
        ] {
            let args = ["convert", "book.epub", flags[0], flags[1]].map(str::to_owned);
            assert!(parse_args(&args)
                .unwrap_err()
                .contains("mutually exclusive"));
        }
    }

    #[test]
    fn explicit_consent_revocation_overrides_saved_consent_without_mutating_it() {
        use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
        let root = std::env::temp_dir().join(format!("tts-cli-revoke-{}", std::process::id()));
        let paths = converter_core::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.clone(),
        );
        let config = converter_core::config::AppConfig::from_paths(paths);
        let saved = TtsPreferences {
            policy_version: None,
            primary: TtsSelection::default(),
            secondary: Some(TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            }),
            allow_online_fallback: true,
        };
        converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
        let stored = fs::read(preference_path(&config)).unwrap();
        let inherited = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--use-secondary",
        ]
        .map(str::to_owned);
        assert_eq!(
            effective_preferences(&config, &parse_args(&inherited).unwrap(), &inherited).unwrap(),
            saved
        );

        let denied = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--fallback-engine",
            "none",
            "--no-online-fallback",
        ]
        .map(str::to_owned);
        let effective =
            effective_preferences(&config, &parse_args(&denied).unwrap(), &denied).unwrap();
        assert!(!effective.allow_online_fallback);
        assert!(effective.secondary.is_none());
        assert_eq!(effective.primary, saved.primary);

        let invalid = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--use-secondary",
            "--no-online-fallback",
        ]
        .map(str::to_owned);
        assert!(effective_preferences(&config, &parse_args(&invalid).unwrap(), &invalid).is_err());
        assert_eq!(saved_preferences(&config).unwrap(), saved);
        assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_edge_secondary_can_be_enabled_only_with_explicit_consent() {
        let root = std::env::temp_dir().join(format!("tts-cli-grant-{}", std::process::id()));
        let paths = converter_core::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.clone(),
        );
        let config = converter_core::config::AppConfig::from_paths(paths);
        let saved = converter_core::tts_preferences::TtsPreferences::default();
        converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
        let stored = fs::read(preference_path(&config)).unwrap();
        let mut args = [
            "convert",
            "book.epub",
            "--engine",
            "piper",
            "--fallback-engine",
            "edge",
        ]
        .map(str::to_owned)
        .to_vec();
        assert!(effective_preferences(&config, &parse_args(&args).unwrap(), &args).is_err());
        args.push("--allow-online-fallback".into());
        let effective = effective_preferences(&config, &parse_args(&args).unwrap(), &args).unwrap();
        assert!(effective.allow_online_fallback);
        assert_eq!(effective.secondary.unwrap().engine, "edge");
        assert_eq!(saved_preferences(&config).unwrap(), saved);
        assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn captured_preferences_replace_saved_voice_and_consent_without_writing_the_profile() {
        use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
        let root = std::env::temp_dir().join(format!("tts-cli-snapshot-{}", std::process::id()));
        let paths = converter_core::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.clone(),
        );
        let config = converter_core::config::AppConfig::from_paths(paths);
        let saved = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            },
            secondary: None,
            allow_online_fallback: true,
        };
        converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
        let stored = fs::read(preference_path(&config)).unwrap();
        let captured = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        };
        let json = serde_json::to_string(&captured).unwrap();
        let args = vec![
            "convert".into(),
            "book.epub".into(),
            "--tts-preferences-json".into(),
            json,
            "--chapter".into(),
            "1-2".into(),
            "--no-parallel".into(),
        ];
        let options = parse_args(&args).unwrap();
        assert_eq!(options.chapters, vec!["1-2"]);
        assert!(options.no_parallel);
        assert_eq!(
            effective_preferences(&config, &options, &args).unwrap(),
            captured
        );
        assert_eq!(saved_preferences(&config).unwrap(), saved);
        assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);

        fs::write(preference_path(&config), b"invalid saved preferences").unwrap();
        assert!(saved_preferences(&config).is_err());
        assert_eq!(
            effective_preferences(&config, &options, &args).unwrap(),
            captured
        );
        assert_eq!(
            fs::read(preference_path(&config)).unwrap(),
            b"invalid saved preferences"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn captured_preferences_reject_invalid_schema_policy_and_duplicate_arguments() {
        use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
        let approved = TtsPreferences {
            policy_version: None,
            primary: TtsSelection::default(),
            secondary: Some(TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            }),
            allow_online_fallback: true,
        };
        assert_eq!(
            parse_captured_preferences(&serde_json::to_string(&approved).unwrap()).unwrap(),
            approved
        );
        let valid =
            serde_json::to_string(&converter_core::tts_preferences::TtsPreferences::default())
                .unwrap();
        for json in [
            "{",
            r#"{"primary":{"engine":"edge"},"secondary":null}"#,
            r#"{"primary":{"engine":"edge"},"allow_online_fallback":false,"unknown":0}"#,
            r#"{"primary":{"engine":"edge","unknown":0},"allow_online_fallback":false}"#,
            r#"{"primary":{"engine":"edge","voice":null,"voice":"other"},"allow_online_fallback":false}"#,
            r#"{"primary":{"engine":"edge"},"allow_online_fallback":false,"allow_online_fallback":true}"#,
            r#"{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium"},"secondary":{"engine":"edge"},"allow_online_fallback":false}"#,
        ] {
            let args = ["convert", "book.epub", "--tts-preferences-json", json].map(str::to_owned);
            assert!(parse_args(&args).is_err(), "Unexpectedly accepted: {json}");
        }
        let duplicate = [
            "convert",
            "book.epub",
            "--tts-preferences-json",
            &valid,
            "--tts-preferences-json",
            &valid,
        ]
        .map(str::to_owned);
        assert!(parse_args(&duplicate).unwrap_err().contains("only once"));
        let missing = ["convert", "book.epub", "--tts-preferences-json"].map(str::to_owned);
        assert!(parse_args(&missing).is_err());
    }

    #[test]
    fn captured_preferences_are_exclusive_of_tts_flags_but_not_literal_flag_values() {
        let json =
            serde_json::to_string(&converter_core::tts_preferences::TtsPreferences::default())
                .unwrap();
        for legacy in [
            vec!["--engine", "edge"],
            vec!["--voice", "pt-BR-FranciscaNeural"],
            vec!["--model", "pt_BR-faber-medium"],
            vec!["--fallback-engine", "none"],
            vec!["--fallback-model", "pt_BR-faber-medium"],
            vec!["--fallback-voice", "pt-BR-FranciscaNeural"],
            vec!["--engine-chain-fallback"],
            vec!["--allow-online-fallback"],
            vec!["--no-online-fallback"],
            vec!["--use-secondary"],
        ] {
            for snapshot_first in [true, false] {
                let mut args = vec!["convert".to_owned(), "book.epub".to_owned()];
                let snapshot = ["--tts-preferences-json", json.as_str()];
                let (first, second): (&[&str], &[&str]) = if snapshot_first {
                    (&snapshot, &legacy)
                } else {
                    (&legacy, &snapshot)
                };
                args.extend(first.iter().chain(second).map(|value| (*value).to_owned()));
                assert!(
                    parse_args(&args).is_err(),
                    "Accepted mixed TTS flags: {args:?}"
                );
            }
        }
        let literal = [
            "convert",
            "book.epub",
            "--tts-preferences-json",
            &json,
            "--output-dir",
            "--engine",
        ]
        .map(str::to_owned);
        assert_eq!(
            parse_args(&literal).unwrap().output_dir.as_deref(),
            Some("--engine")
        );
    }

    #[test]
    fn output_directory_option_overrides_only_the_output_path() {
        let options = parse_args(&[
            "convert".into(),
            "book.epub".into(),
            "--output-dir".into(),
            "chosen output".into(),
        ])
        .unwrap();
        let original = converter_core::config::AppConfig::from_env();
        let configured = conversion_config(&options);
        assert_eq!(configured.paths.output_dir, PathBuf::from("chosen output"));
        assert_eq!(configured.paths.cache_dir, original.paths.cache_dir);
        assert_eq!(configured.paths.jobs_dir, original.paths.jobs_dir);
    }

    #[test]
    fn output_directory_expands_the_home_prefix() {
        let options = CliOptions {
            output_dir: Some("~/audiobooks".into()),
            ..Default::default()
        };
        assert_eq!(
            conversion_config(&options).paths.output_dir,
            home_dir().join("audiobooks")
        );
    }

    #[test]
    fn omitted_output_option_preserves_the_runtime_default() {
        assert_eq!(
            conversion_config(&CliOptions::default()),
            converter_core::config::AppConfig::from_env()
        );
    }

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
            source_chapters_total: None,
            tts_preferences: None,
            used_selections: Vec::new(),
            tts_policy_state: Default::default(),
            fallback_used: false,
            job_id: "test".into(),
            title: "Book".into(),
            author: "Author".into(),
            chapters: vec![converter_core::audio::ChapterMetadata {
                index: 1,
                source_index: 0,
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
