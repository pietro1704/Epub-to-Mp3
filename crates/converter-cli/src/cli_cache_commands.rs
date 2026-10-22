//! Explicitly confirmed CLI cache cleanup actions.
use std::fs;
use std::io::{self, IsTerminal};
use std::path::Path;

pub(super) fn clear_book_cache(input: &Path, assume_yes: bool) -> Result<(), String> {
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

pub(super) fn clear_global_cache(assume_yes: bool) -> Result<(), String> {
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
