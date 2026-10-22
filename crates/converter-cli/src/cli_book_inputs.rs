//! Supported book discovery and deterministic fuzzy input matching.
use super::cli_environment::{home_dir, ExpandPath};
use super::SUPPORTED_EXTENSIONS;
use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn resolve_inputs(entries: &[String]) -> Result<Vec<String>, String> {
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

pub(super) fn resolve_entry(entry: &str) -> Result<Vec<String>, String> {
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

pub(super) fn collect_files(path: &Path) -> Vec<PathBuf> {
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

pub(super) fn supported(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|value| {
            SUPPORTED_EXTENSIONS
                .iter()
                .any(|extension| value.eq_ignore_ascii_case(extension))
        })
        .unwrap_or(false)
}

pub(super) fn require_supported_conversion(path: &Path) -> Result<(), String> {
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

pub(super) fn fuzzy_find_book(query: &str) -> Option<std::path::PathBuf> {
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

pub(super) fn is_noise_token(token: &str) -> bool {
    matches!(token, "downloads" | "download" | "home" | "users")
}

pub(super) fn norm_tokens(value: &str) -> Vec<String> {
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

pub(super) fn similarity(left: &str, right: &str) -> f64 {
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
