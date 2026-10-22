//! Input validation and embedded Rust conversion dispatch for one CLI invocation.
use super::cli_arguments::{normalize_cli_args, parse_args};
use super::cli_book_inputs::{require_supported_conversion, resolve_entry, resolve_inputs};
use super::cli_cache_commands::{clear_book_cache, clear_global_cache};
use super::cli_environment::{cli_config, ExpandPath};
use super::model_commands::command_models;
use super::output_reporting::{show_structure, verify_output};
use super::tts_preferences_command::{command_preferences, effective_preferences};
use super::{print_help, CliOptions};
use std::fs;
use std::path::Path;

pub(super) fn run_cli_command(raw: Vec<String>) -> Result<i32, String> {
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

pub(super) fn conversion_config(options: &CliOptions) -> converter_core::config::AppConfig {
    let mut config = cli_config();
    if let Some(output) = &options.output_dir {
        config.paths.output_dir = Path::new(output).expand();
    }
    config
}
