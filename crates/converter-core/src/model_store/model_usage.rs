//! Prepared native sessions retain their model namespace independently of UI preferences.
use super::ModelStoreError;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

static ACTIVE_NAMESPACES: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();

fn namespaces() -> &'static Mutex<HashMap<PathBuf, usize>> {
    ACTIVE_NAMESPACES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) struct ModelUsageLease {
    namespace: PathBuf,
}

impl ModelUsageLease {
    pub(crate) fn acquire(namespace: &Path) -> Result<Self, ModelStoreError> {
        let namespace = namespace.canonicalize()?;
        let mut active = namespaces().lock().map_err(|_| {
            ModelStoreError::InvalidArchive("model usage registry is unavailable".into())
        })?;
        *active.entry(namespace.clone()).or_default() += 1;
        Ok(Self { namespace })
    }
}

impl Drop for ModelUsageLease {
    fn drop(&mut self) {
        let mut active = namespaces()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(count) = active.get_mut(&self.namespace) {
            *count -= 1;
            if *count == 0 {
                active.remove(&self.namespace);
            }
        }
    }
}

pub(super) fn with_unused_model(
    directory: &Path,
    model_id: &str,
    remove: impl FnOnce() -> Result<(), ModelStoreError>,
) -> Result<(), ModelStoreError> {
    if std::fs::symlink_metadata(directory).is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return remove();
    }
    let active = namespaces().lock().map_err(|_| {
        ModelStoreError::InvalidArchive("model usage registry is unavailable".into())
    })?;
    if directory
        .canonicalize()
        .ok()
        .is_some_and(|path| active.contains_key(&path))
    {
        return Err(ModelStoreError::ModelInUse(model_id.into()));
    }
    // Keep admission locked until deletion finishes; no new session can acquire it.
    remove()
}
