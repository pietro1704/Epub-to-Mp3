//! Artifact-manifest checks and source-structure reporting.
use super::cli_book_inputs::require_supported_conversion;
use super::cli_environment::cli_config;
use std::fs;
use std::path::Path;

pub(super) fn verify_output(
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

pub(super) fn normalized_name(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

pub(super) fn show_structure(inputs: &[String]) -> Result<i32, String> {
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
