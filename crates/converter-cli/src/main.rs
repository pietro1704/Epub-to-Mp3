use std::env;
use std::path::Path;

mod cli_arguments;
mod cli_book_inputs;
mod cli_cache_commands;
mod cli_environment;
mod conversion_command;
mod model_commands;
mod output_reporting;
mod tts_preferences_command;
use conversion_command::run_cli_command;

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
    help: bool,
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
            help: false,
        }
    }
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
    match run_cli_command(raw) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("error: {error}");
            std::process::exit(2);
        }
    }
}

fn print_help() {
    println!("EBook to Audiobook Converter\n\nUsage: convert [INPUT ...] [OPTIONS]\n       clear-cache [BOOK]\n\nInputs accept EPUB files, directories, loose multiword names, and fuzzy matches. PDF ingestion is not supported.\n\nPreferences: preferences show | preferences set JSON\nModels: models list | models install MODEL_ID | models remove MODEL_ID --yes\nOptions: --tts-preferences-json JSON (per-job snapshot; exclusive of other TTS options)\n         --engine {{edge,piper,system}} --fallback-engine {{none,edge,piper,system}} --allow-online-fallback | --no-online-fallback --voice VOICE --model MODEL --chapter CHAPTER --show-structure --clean-cache --verify --batch PATH --batch-file FILE --yes");
}

#[cfg(test)]
mod cli_execution_contract_tests;
#[cfg(test)]
mod cli_preferences_contract_tests;
