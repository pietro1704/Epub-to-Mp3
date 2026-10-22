fn persist_android_chunk(
    root: &Path,
    chapter: usize,
    index: usize,
    audio: &[u8],
    cancelled: &dyn Fn() -> bool,
) -> Result<std::path::PathBuf, String> {
    use std::io::Write;
    if cancelled() {
        return Err("Android audio chunk cancelled".into());
    }
    let directory = root.join(chapter.to_string());
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let path = directory.join(format!("{index:06}.mp3"));
    if path.exists() {
        return Err("Android audio chunk path already exists".into());
    }
    let pending = path.with_extension("mp3.pending");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)
        .map_err(|error| error.to_string())?;
    struct RemovePending(std::path::PathBuf);
    impl Drop for RemovePending {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = RemovePending(pending.clone());
    file.write_all(audio).map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())?;
    drop(file);
    converter_core::audio::validate_audio(&pending, 100).map_err(|error| error.to_string())?;
    if cancelled() {
        return Err("Android audio chunk cancelled".into());
    }
    std::fs::rename(&pending, &path).map_err(|error| error.to_string())?;
    Ok(path)
}

#[cfg(test)]
mod chunk_tests {
    use super::*;
    const AUDIO: &[u8] = include_bytes!("../../../../tests/fixtures/audio/mono-24000-48k.mp3");
    #[test]
    fn platform_chunk_publishes_valid_immutable_audio_without_pending_files() {
        let temp = tempfile::tempdir().unwrap();
        let path = persist_android_chunk(temp.path(), 8, 0, AUDIO, &|| false).unwrap();
        assert_eq!(path, temp.path().join("8/000000.mp3"));
        assert_eq!(std::fs::read(&path).unwrap(), AUDIO);
        assert!(!path.with_extension("mp3.pending").exists());
        assert!(persist_android_chunk(temp.path(), 8, 0, AUDIO, &|| false).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), AUDIO);
    }
    #[test]
    fn platform_chunk_rejects_invalid_or_cancelled_audio_before_publication() {
        let temp = tempfile::tempdir().unwrap();
        assert!(persist_android_chunk(temp.path(), 0, 0, b"Invalid audio", &|| false).is_err());
        assert!(!temp.path().join("0/000000.mp3").exists());
        assert!(!temp.path().join("0/000000.mp3.pending").exists());
        let calls = std::sync::atomic::AtomicUsize::new(0);
        assert!(persist_android_chunk(temp.path(), 0, 0, AUDIO, &|| calls
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel)
            > 0)
        .is_err());
        assert!(!temp.path().join("0/000000.mp3").exists());
        assert!(!temp.path().join("0/000000.mp3.pending").exists());
    }
}

struct AndroidAudioChunks {
    vm: JavaVM,
    activity: GlobalRef,
    request_id: String,
    root: std::path::PathBuf,
    control: ConversionControl,
    delivered: std::sync::atomic::AtomicUsize,
}

impl AndroidAudioChunks {
    fn dispatch(&self, chapter: usize, index: usize, audio: &[u8]) -> bool {
        if self.control.cancellation_token().is_cancelled() || audio.is_empty() {
            return false;
        }
        let result = (|| -> Result<bool, String> {
            let path = persist_android_chunk(&self.root, chapter, index, audio, &|| {
                self.control.cancellation_token().is_cancelled()
            })?;
            let mut env = self
                .vm
                .attach_current_thread()
                .map_err(|error| error.to_string())?;
            let request = JObject::from(
                env.new_string(&self.request_id)
                    .map_err(|error| error.to_string())?,
            );
            let output = JObject::from(
                env.new_string(path.to_string_lossy())
                    .map_err(|error| error.to_string())?,
            );
            let accepted = env
                .call_method(
                    self.activity.as_obj(),
                    "onNativeAudioChunk",
                    "(Ljava/lang/String;IILjava/lang/String;)Z",
                    &[
                        JValue::Object(&request),
                        JValue::Int(chapter.try_into().map_err(|_| "Chapter index overflow")?),
                        JValue::Int(index.try_into().map_err(|_| "Chunk index overflow")?),
                        JValue::Object(&output),
                    ],
                )
                .map_err(|error| error.to_string())?
                .z()
                .map_err(|error| error.to_string())?;
            if accepted {
                self.delivered
                    .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
            }
            Ok(accepted)
        })();
        if let Err(error) = &result {
            eprintln!("Android audio chunk delivery failed: {error}");
        }
        result.unwrap_or(false)
    }
}

unsafe extern "C" fn android_audio_chunk(
    chapter: usize,
    index: usize,
    audio: *const u8,
    length: usize,
    context: *mut c_void,
) -> bool {
    if context.is_null() || audio.is_null() || length == 0 {
        return false;
    }
    // The C ABI joins every conversion worker before this borrowed context is dropped.
    (&*context.cast::<AndroidAudioChunks>()).dispatch(
        chapter,
        index,
        std::slice::from_raw_parts(audio, length),
    )
}
