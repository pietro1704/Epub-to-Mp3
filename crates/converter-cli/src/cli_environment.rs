//! Packaged runtime directories and explicit home-relative path expansion.
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn packaged_data_root(
    executable: &Path,
    home: Option<&Path>,
    local_data: Option<&Path>,
) -> Option<PathBuf> {
    let package = executable.parent()?.parent()?;
    let metadata = fs::read(package.join("package.json")).ok()?;
    let metadata: serde_json::Value = serde_json::from_slice(&metadata).ok()?;
    if metadata["runtime"] != "native Rust/Piper" {
        return None;
    }
    if cfg!(target_os = "macos") {
        return Some(
            home?
                .join("Library")
                .join("Application Support")
                .join("EpubToMp3"),
        );
    }
    if cfg!(target_os = "windows") {
        return local_data
            .map(Path::to_path_buf)
            .or_else(|| home.map(|path| path.join("AppData").join("Local")))
            .map(|path| path.join("EpubToMp3"));
    }
    local_data
        .map(Path::to_path_buf)
        .or_else(|| home.map(|path| path.join(".local").join("share")))
        .map(|path| path.join("epub-to-mp3"))
}

pub(super) fn cli_config() -> converter_core::config::AppConfig {
    let mut config = converter_core::config::AppConfig::from_env();
    if std::env::var_os("PERSISTENT_ROOT").is_some_and(|value| !value.is_empty()) {
        return config;
    }
    let home = std::env::var_os(if cfg!(target_os = "windows") {
        "USERPROFILE"
    } else {
        "HOME"
    })
    .map(PathBuf::from);
    let local_data = std::env::var_os(if cfg!(target_os = "windows") {
        "LOCALAPPDATA"
    } else {
        "XDG_DATA_HOME"
    })
    .map(PathBuf::from)
    .filter(|path| path.is_absolute());
    let packaged_root = std::env::current_exe().ok().and_then(|executable| {
        packaged_data_root(&executable, home.as_deref(), local_data.as_deref())
    });
    if let Some(root) = packaged_root {
        let environment = std::env::vars_os().chain(std::iter::once((
            std::ffi::OsString::from("PERSISTENT_ROOT"),
            root.into_os_string(),
        )));
        config.paths = converter_core::paths::resolve_paths_from(
            environment,
            config.paths.project_root.clone(),
        );
    }
    config
}

pub(super) fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub(super) trait ExpandPath {
    fn expand(&self) -> PathBuf;
}
impl ExpandPath for Path {
    fn expand(&self) -> PathBuf {
        if self == Path::new("~") {
            return home_dir();
        }
        if let Some(value) = self.to_str() {
            if let Some(rest) = value.strip_prefix("~/") {
                return home_dir().join(rest);
            }
        }
        self.to_path_buf()
    }
}
