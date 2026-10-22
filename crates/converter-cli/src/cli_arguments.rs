//! Literal argument parsing and loose multiword argument normalization.
use super::cli_environment::ExpandPath;
use super::tts_preferences_command::parse_captured_preferences;
use super::CliOptions;
use std::path::Path;

pub(super) fn parse_args(args: &[String]) -> Result<CliOptions, String> {
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
