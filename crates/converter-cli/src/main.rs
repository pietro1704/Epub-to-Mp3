use std::env;
use std::path::Path;

mod cli_arguments;
mod cli_book_inputs;
mod cli_cache_commands;
mod cli_chapter_ranges;
mod cli_environment;
mod cli_help;
mod conversion_command;
mod conversion_retry;
mod existing_output_verification;
mod model_commands;
mod output_reporting;
mod tts_preferences_command;
use cli_help::print_help;
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
    /// `--from-chapter-to-end` or `--from-chapter-to-chapter`, never both.
    chapter_range: Option<cli_chapter_ranges::ChapterRange>,
    show_structure: bool,
    clean_cache: bool,
    /// Ignore cached audio and synthesize the selected chapters again.
    force_reprocess: bool,
    /// Whole-job retry rounds after a failed conversion; absent means none.
    retry_failed_rounds: Option<u32>,
    /// One more retry pass after the automatic rounds.
    retry_failed_manual: bool,
    verify: bool,
    /// Audit the newest existing output of each book without converting.
    verify_only: bool,
    /// Audit, then reconvert only the chapters that failed the audit.
    fix: bool,
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
            chapter_range: None,
            show_structure: false,
            clean_cache: false,
            force_reprocess: false,
            retry_failed_rounds: None,
            retry_failed_manual: false,
            verify: false,
            verify_only: false,
            fix: false,
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

#[cfg(test)]
mod cli_conversion_lifecycle_tests;
#[cfg(test)]
mod cli_execution_contract_tests;
#[cfg(test)]
mod cli_existing_output_tests;
#[cfg(test)]
mod cli_option_contract_tests;
#[cfg(test)]
mod cli_preferences_contract_tests;
