//! Compatibility input discovery, safe leaf identity and UUID generation.
use converter_core::config::AppConfig;
use converter_core::epub::parse_epub;
use std::path::Path;
use std::path::PathBuf;

#[allow(dead_code)]
pub(super) fn inspect_book(path: &Path) -> (Option<String>, Option<String>) {
    std::fs::File::open(path)
        .ok()
        .and_then(|file| parse_epub(std::io::BufReader::new(file)).ok())
        .map(|book| (Some(book.title), Some(book.author)))
        .unwrap_or((None, None))
}
pub(super) async fn uploaded_file(config: &AppConfig, upload_id: &str) -> Option<PathBuf> {
    if !safe_leaf(upload_id) {
        return None;
    }
    let mut entries = tokio::fs::read_dir(config.paths.uploads_dir.join(upload_id))
        .await
        .ok()?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if entry.file_type().await.ok()?.is_file() {
            return Some(entry.path());
        }
    }
    None
}
pub(super) async fn find_job_input(config: &AppConfig, job_id: &str) -> Option<PathBuf> {
    if !safe_leaf(job_id) {
        return None;
    }
    let mut entries = tokio::fs::read_dir(config.paths.job_inputs_dir.join(job_id))
        .await
        .ok()?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if entry.file_type().await.ok()?.is_file() {
            return Some(entry.path());
        }
    }
    None
}
pub(super) fn safe_leaf(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && Path::new(value).file_name().and_then(|v| v.to_str()) == Some(value)
}
pub(super) fn uuid() -> String {
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        let fallback = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        bytes.copy_from_slice(&fallback.to_le_bytes());
    }
    // UUID v4 layout: random identifier with the version/variant bits set.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        u32::from_be_bytes(bytes[0..4].try_into().unwrap()),
        u16::from_be_bytes(bytes[4..6].try_into().unwrap()),
        u16::from_be_bytes(bytes[6..8].try_into().unwrap()),
        u16::from_be_bytes(bytes[8..10].try_into().unwrap()),
        u64::from_be_bytes([
            0, 0, bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ]),
    )
}
