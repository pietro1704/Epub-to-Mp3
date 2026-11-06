use super::*;

/// Prepare a completed local MP3 before Apple playback/export. The caller must
/// serialize access with writers and must not pass an actively growing file.
#[no_mangle]
pub unsafe extern "C" fn converter_audio_prepare_v1(path: *const c_char) -> bool {
    clear_last_error();
    match std::panic::catch_unwind(|| -> Result<(), String> {
        let value = c_string(path, "completed audio path")?;
        let path = Path::new(&value);
        if !path.is_absolute()
            || !std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
        {
            return Err("Completed audio must be an absolute regular file".into());
        }
        converter_core::worker::prepare_retained_audio(path).map_err(|error| error.to_string())
    }) {
        Ok(Ok(())) => true,
        Ok(Err(error)) => fail(error),
        Err(_) => fail("Audio preparation panicked".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completed_audio_boundary_repairs_and_rejects_missing_input() {
        let root = tempfile::tempdir().unwrap();
        let audio = include_bytes!("../../../tests/fixtures/audio/mono-24000-48k-info.mp3");
        let path = root.path().join("chapter.mp3");
        std::fs::write(&path, [audio.as_slice(), audio.as_slice()].concat()).unwrap();
        let name = CString::new(path.to_str().unwrap()).unwrap();
        assert!(unsafe { converter_audio_prepare_v1(name.as_ptr()) });
        assert!(unsafe { converter_audio_prepare_v1(name.as_ptr()) });
        assert!(!unsafe { converter_audio_prepare_v1(std::ptr::null()) });
    }
}
