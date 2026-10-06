use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use converter_core::{
    AudioFormat, ConversionJob, ConversionOptions, ConversionPlan, Engine, JobSnapshot,
    epub::parse_epub, validate_input_path,
};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    match run(env::args().skip(1)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::from(2)
        }
    }
}

fn run(arguments: impl IntoIterator<Item = String>) -> Result<(), String> {
    let mut input: Option<PathBuf> = None;
    let mut options = ConversionOptions::default();
    let mut arguments = arguments.into_iter();

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--help" | "-h" => {
                print_help();
                return Ok(());
            }
            "--version" | "-V" => {
                println!("epub2mp3 {VERSION}");
                return Ok(());
            }
            "--engine" => {
                let value = arguments.next().ok_or("--engine requires a value")?;
                options.engine = value.parse::<Engine>().map_err(|error| error.to_string())?;
            }
            "--format" | "--audio-format" => {
                let value = arguments.next().ok_or("--format requires a value")?;
                options.audio_format = value
                    .parse::<AudioFormat>()
                    .map_err(|error| error.to_string())?;
            }
            value if value.starts_with('-') => {
                return Err(format!("unknown option: {value}"));
            }
            value if input.is_none() => input = Some(PathBuf::from(value)),
            _ => return Err("only one input path is supported in this first Rust slice".to_owned()),
        }
    }

    let input = input.ok_or("an EPUB/PDF input path is required")?;
    validate_input_path(&input).map_err(|error| error.to_string())?;
    println!(
        "input={} engine={:?} format={}",
        input.display(),
        options.engine,
        options.audio_format
    );
    if input
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("epub"))
        && input.exists()
    {
        let book = parse_epub(&input).map_err(|error| error.to_string())?;
        println!("book={} chapters={}", book.title, book.chapters.len());
        let snapshot = process_book(&book, options.clone())?;
        println!(
            "job={} state={:?} completed={}/{}",
            snapshot.job_id, snapshot.state, snapshot.chapters_completed, snapshot.chapters_total
        );
    }
    Ok(())
}

fn process_book(
    book: &converter_core::BookStructure,
    options: ConversionOptions,
) -> Result<JobSnapshot, String> {
    let plan = ConversionPlan::from_book(book, options).map_err(|error| error.to_string())?;
    let mut job = ConversionJob::new(&plan.title, plan.chapters.len());
    job.start().map_err(|error| error.to_string())?;
    for _ in &plan.chapters {
        job.complete_chapter().map_err(|error| error.to_string())?;
    }
    job.finish().map_err(|error| error.to_string())?;
    Ok(job.snapshot())
}

fn print_help() {
    println!("epub2mp3 {VERSION} — Rust conversion foundation");
    println!();
    println!("Usage: epub2mp3 [OPTIONS] <INPUT>");
    println!();
    println!("Options:");
    println!("  --engine <auto|edge|piper>   Select the TTS engine");
    println!("  --format <mp3|m4a>           Select the output format");
    println!("  -h, --help                   Show this help");
    println!("  -V, --version                Show the version");
}

#[cfg(test)]
mod tests {
    use super::run;

    #[test]
    fn accepts_shared_conversion_options() {
        let result = run([
            "--engine".to_owned(),
            "piper".to_owned(),
            "--format".to_owned(),
            "m4a".to_owned(),
            "book.epub".to_owned(),
        ]);
        assert!(result.is_ok());
    }

    #[test]
    fn completes_a_book_job() {
        let book = converter_core::BookStructure {
            title: "Book".to_owned(),
            author: None,
            chapters: (0..3)
                .map(|index| converter_core::Chapter {
                    index: index.to_string(),
                    title: format!("Chapter {index}"),
                    text: "Text".to_owned(),
                })
                .collect(),
        };
        let snapshot =
            super::process_book(&book, converter_core::ConversionOptions::default()).unwrap();
        assert_eq!(snapshot.chapters_completed, 3);
        assert_eq!(snapshot.chapters_total, 3);
        assert_eq!(snapshot.state, converter_core::JobState::Finished);
    }

    #[test]
    fn rejects_missing_input() {
        assert!(run(std::iter::empty::<String>()).is_err());
    }
}
