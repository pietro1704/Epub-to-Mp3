//! Literal argument parsing and loose multiword argument normalization.
use super::cli_chapter_ranges::{ChapterRange, TO_CHAPTER, TO_END};
use super::cli_environment::ExpandPath;
use super::tts_preferences_command::parse_captured_preferences;
use super::CliOptions;
use std::path::Path;

pub(super) fn parse_args(args: &[String]) -> Result<CliOptions, String> {
    let mut options = CliOptions::default();
    let mut positional = Vec::new();
    let mut tts_override_seen = false;
    let mut first_tts_flag: Option<String> = None;
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
        if (tts_override_seen || value == "--tts-preferences-json") && first_tts_flag.is_none() {
            first_tts_flag = Some(value.clone());
        }
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
            TO_END | TO_CHAPTER => {
                let flag = if value == TO_END { TO_END } else { TO_CHAPTER };
                let range = ChapterRange::parse(flag, &next(value)?)?;
                if let Some(previous) = &options.chapter_range {
                    return Err(if previous.flag == flag {
                        format!("{flag} may be supplied only once")
                    } else {
                        format!("{TO_END} and {TO_CHAPTER} are mutually exclusive")
                    });
                }
                options.chapter_range = Some(range);
            }
            "--force-reprocess" => options.force_reprocess = true,
            "--retry-failed" => {
                let rounds = next(value)?;
                options.retry_failed_rounds = Some(rounds.parse::<u32>().map_err(|_| {
                    format!(
                        "--retry-failed requires a non-negative number of rounds, got '{rounds}'"
                    )
                })?);
            }
            "--retry-failed-manual" => options.retry_failed_manual = true,
            "--batch" => options.batch_inputs.push(next(value)?),
            "--batch-file" => options.batch_manifest = Some(next(value)?),
            "--show-structure" => options.show_structure = true,
            "--clear-cache" | "--clean-cache" => options.clean_cache = true,
            "--verify" => options.verify = true,
            "--verify-only" => options.verify_only = true,
            "--fix" => options.fix = true,
            "--no-cache" | "--stop-on-error" => {
                return Err(format!("{value} is not supported by the native CLI"));
            }
            "--no-parallel" => options.no_parallel = true,
            "--yes" | "-y" => options.yes = true,
            "--menu" => options.menu = true,
            "--help" | "-h" => options.help = true,
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
    reject_conversion_options_for_existing_output(&options, first_tts_flag.as_deref())?;
    if options.engine != "auto"
        && !converter_core::tts_session::builtin_descriptors()
            .iter()
            .any(|descriptor| descriptor.provider == options.engine)
    {
        return Err(format!(
            "invalid engine '{}'; expected auto, edge, piper, or system",
            options.engine
        ));
    }
    Ok(options)
}

/// `--verify-only` and `--fix` work on the output of an earlier conversion and
/// replay its persisted request. An option that shapes a new conversion cannot
/// be honoured there, so it is rejected by name instead of being ignored.
fn reject_conversion_options_for_existing_output(
    options: &CliOptions,
    tts_flag: Option<&str>,
) -> Result<(), String> {
    let mode = match (options.verify_only, options.fix) {
        (true, true) => return Err("--verify-only and --fix are mutually exclusive".into()),
        (true, false) => "--verify-only",
        (false, true) => "--fix",
        (false, false) => return Ok(()),
    };
    let range_flag = options.chapter_range.as_ref().map(|range| range.flag);
    let conflict = [
        (tts_flag.is_some(), tts_flag.unwrap_or_default()),
        (!options.chapters.is_empty(), "--chapter"),
        (!options.sections.is_empty(), "--section"),
        (range_flag.is_some(), range_flag.unwrap_or_default()),
        (options.force_reprocess, "--force-reprocess"),
        (options.clean_cache, "--clean-cache"),
        (options.verify, "--verify"),
        (options.show_structure, "--show-structure"),
        (options.menu, "--menu"),
        (options.no_parallel, "--no-parallel"),
        // --fix reconverts, so retry rounds apply there but not to a pure audit.
        (
            options.verify_only && options.retry_failed_rounds.is_some(),
            "--retry-failed",
        ),
        (
            options.verify_only && options.retry_failed_manual,
            "--retry-failed-manual",
        ),
    ]
    .into_iter()
    .find(|(present, _)| *present);
    match conflict {
        Some((_, flag)) => Err(format!(
            "{flag} cannot be combined with {mode}, which works on the existing output of an earlier conversion"
        )),
        None => Ok(()),
    }
}

pub(super) fn normalize_cli_args(raw: &[String]) -> Vec<String> {
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
