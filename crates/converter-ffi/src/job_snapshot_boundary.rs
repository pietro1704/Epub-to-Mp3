use super::*;

/// Returns the current durable Rust coordinator record for a job. Clients poll
/// this small JSON payload for live conversion status; no HTTP or Python path
/// is involved.
#[no_mangle]
pub unsafe extern "C" fn converter_job_log_json(job_id: *const c_char) -> *mut c_char {
    clear_last_error();
    let job_id = match c_string(job_id, "job id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let paths = resolve_paths_from(
        std::env::vars(),
        Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf(),
    );
    let manager = match converter_core::jobs::ConversionJobStore::new(paths.jobs_dir) {
        Ok(manager) => manager,
        Err(error) => return fail(error.to_string()),
    };
    match manager.load(&job_id) {
        Ok(record) => match serde_json::to_string(&json!([
            format!("job {}: {:?}", record.job_id, record.state),
            format!("progress: {}", record.progress),
            format!("updated: {}", record.updated_at),
        ])) {
            Ok(value) => CString::new(value).map_or_else(
                |_| fail("job log contains an interior NUL byte".to_owned()),
                CString::into_raw,
            ),
            Err(error) => fail(error.to_string()),
        },
        Err(error) => fail(error.to_string()),
    }
}
