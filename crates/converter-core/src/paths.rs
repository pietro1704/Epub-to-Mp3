//! Persistent directory resolution matching `python_app/src/paths.py`.
//!
//! Resolution is intentionally explicit and side-effect free: callers may create
//! the returned directories when they begin using them. Environment variables
//! are read for each [`resolve_paths`] call, which keeps CLI/server embedding
//! behavior predictable when a process configures its environment at startup.

use std::env;
use std::ffi::OsStr;
use std::fmt;
use std::path::{Component, Path, PathBuf};

/// Errors raised when a path supplied for a managed directory is unsafe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathError {
    /// A managed child path escaped its configured root.
    Traversal { root: PathBuf, candidate: PathBuf },
}

impl fmt::Display for PathError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Traversal { root, candidate } => write!(
                f,
                "path escapes managed root: candidate '{}' is outside '{}'",
                candidate.display(),
                root.display()
            ),
        }
    }
}

impl std::error::Error for PathError {}

/// All persistent directories used by the embedded conversion runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub project_root: PathBuf,
    pub persistent_root: PathBuf,
    pub cache_dir: PathBuf,
    pub output_dir: PathBuf,
    pub jobs_dir: PathBuf,
    pub uploads_dir: PathBuf,
    pub job_inputs_dir: PathBuf,
    pub source_backups_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub telemetry_dir: PathBuf,
    pub models_dir: PathBuf,
    pub piper_models_dir: PathBuf,
}

impl Paths {
    /// Resolve a path below `CACHE_DIR`, rejecting absolute paths and traversal.
    pub fn cache_path<P: AsRef<Path>>(&self, child: P) -> Result<PathBuf, PathError> {
        managed_child(&self.cache_dir, child.as_ref())
    }

    /// Resolve a path below `OUTPUT_DIR`, rejecting absolute paths and traversal.
    pub fn output_path<P: AsRef<Path>>(&self, child: P) -> Result<PathBuf, PathError> {
        managed_child(&self.output_dir, child.as_ref())
    }

    /// Resolve a path below an arbitrary managed root.
    pub fn managed_path<P: AsRef<Path>>(
        &self,
        root: &Path,
        child: P,
    ) -> Result<PathBuf, PathError> {
        managed_child(root, child.as_ref())
    }
}

/// Resolve paths using the current process environment.
///
/// Semantics mirror Python: `SPACE_ID` selects `/data/epub-to-mp3` unless
/// `PERSISTENT_ROOT` is supplied; local defaults use the project root. Explicit
/// `CACHE_DIR` and `OUTPUT_DIR` always win. `JOBS_DIR` and `UPLOADS_DIR` are
/// persistent-root children, matching the Python implementation.
pub fn resolve_paths() -> Paths {
    resolve_paths_from(env::vars_os(), detect_project_root())
}

/// Resolve paths from an explicit environment iterator and project root.
/// Primarily useful to embedders that need deterministic startup configuration.
pub fn resolve_paths_from<I, K, V>(vars: I, project_root: PathBuf) -> Paths
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let env: std::collections::HashMap<String, String> = vars
        .into_iter()
        .map(|(key, value)| {
            (
                key.as_ref().to_string_lossy().into_owned(),
                value.as_ref().to_string_lossy().into_owned(),
            )
        })
        .collect();
    resolve_paths_with_env(&env, project_root)
}

fn resolve_paths_with_env(
    env: &std::collections::HashMap<String, String>,
    project_root: PathBuf,
) -> Paths {
    let persistent_override = env_path(env, "PERSISTENT_ROOT");
    let persistent_root = if let Some(path) = persistent_override.clone() {
        path
    } else if env.contains_key("SPACE_ID") {
        PathBuf::from("/data/epub-to-mp3")
    } else {
        project_root.clone()
    };

    let cache_dir = env_path(env, "CACHE_DIR").unwrap_or_else(|| {
        if persistent_override.is_some() || env.contains_key("SPACE_ID") {
            persistent_root.join(".cache")
        } else {
            project_root.join(".cache")
        }
    });
    let output_dir = env_path(env, "OUTPUT_DIR").unwrap_or_else(|| {
        if persistent_override.is_some() || env.contains_key("SPACE_ID") {
            persistent_root.join("output")
        } else {
            project_root.join("output")
        }
    });
    let models_dir = if persistent_override.is_some() {
        persistent_root.join("models")
    } else {
        project_root.join("models")
    };

    Paths {
        project_root,
        jobs_dir: persistent_root.join(".jobs"),
        uploads_dir: persistent_root.join(".uploads"),
        job_inputs_dir: persistent_root.join(".job_inputs"),
        source_backups_dir: persistent_root.join(".source_backups"),
        logs_dir: persistent_root.join(".logs"),
        telemetry_dir: cache_dir.join("telemetry"),
        piper_models_dir: models_dir.join("piper"),
        persistent_root,
        cache_dir,
        output_dir,
        models_dir,
    }
}

fn env_path(env: &std::collections::HashMap<String, String>, key: &str) -> Option<PathBuf> {
    env.get(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn managed_child(root: &Path, child: &Path) -> Result<PathBuf, PathError> {
    if child.is_absolute() {
        return Err(PathError::Traversal {
            root: root.to_path_buf(),
            candidate: child.to_path_buf(),
        });
    }
    let mut depth = 0usize;
    for component in child.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(_) => depth += 1,
            Component::ParentDir if depth > 0 => depth -= 1,
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(PathError::Traversal {
                    root: root.to_path_buf(),
                    candidate: root.join(child),
                });
            }
        }
    }
    Ok(root.join(child))
}

fn detect_project_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .find(|candidate| candidate.join(".git").exists() || candidate.join("CLAUDE.md").exists())
        .unwrap_or(manifest.as_path())
        .to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(entries: &[(&str, &str)]) -> HashMap<String, String> {
        entries
            .iter()
            .map(|(k, v)| ((*k).into(), (*v).into()))
            .collect()
    }

    #[test]
    fn local_defaults_match_python() {
        let paths = resolve_paths_with_env(&env(&[]), PathBuf::from("/project"));
        assert_eq!(paths.persistent_root, PathBuf::from("/project"));
        assert_eq!(paths.cache_dir, PathBuf::from("/project/.cache"));
        assert_eq!(paths.output_dir, PathBuf::from("/project/output"));
    }

    #[test]
    fn hf_profile_and_override_semantics_match_python() {
        let hf = resolve_paths_with_env(
            &env(&[("SPACE_ID", "owner/space")]),
            PathBuf::from("/project"),
        );
        assert_eq!(hf.persistent_root, PathBuf::from("/data/epub-to-mp3"));
        assert_eq!(hf.cache_dir, PathBuf::from("/data/epub-to-mp3/.cache"));
        let override_paths = resolve_paths_with_env(
            &env(&[
                ("PERSISTENT_ROOT", "/state"),
                ("CACHE_DIR", "/cache"),
                ("OUTPUT_DIR", "/out"),
            ]),
            PathBuf::from("/project"),
        );
        assert_eq!(override_paths.cache_dir, PathBuf::from("/cache"));
        assert_eq!(override_paths.output_dir, PathBuf::from("/out"));
        assert_eq!(override_paths.models_dir, PathBuf::from("/state/models"));
    }

    #[test]
    fn managed_paths_reject_traversal() {
        let paths = resolve_paths_with_env(&env(&[]), PathBuf::from("/project"));
        assert!(matches!(
            paths.cache_path("../secret"),
            Err(PathError::Traversal { .. })
        ));
        assert!(matches!(
            paths.output_path("/tmp/secret"),
            Err(PathError::Traversal { .. })
        ));
        assert_eq!(
            paths.cache_path("book/a.json").unwrap(),
            PathBuf::from("/project/.cache/book/a.json")
        );
    }
}
