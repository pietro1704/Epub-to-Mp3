use super::*;

/// A bounded installed-Piper audition creates no book, job, manifest or selection.
#[no_mangle]
pub unsafe extern "C" fn converter_voice_audition_v1(
    options_json: *const c_char,
    text: *const c_char,
    output: *const c_char,
    control: *const ConverterJobControl,
) -> bool {
    clear_last_error();
    let result =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<(), String> {
            let options: EmbeddedConversionOptionsV1 =
                serde_json::from_str(&c_string(options_json, "audition options")?)
                    .map_err(|error| error.to_string())?;
            if options.contract_version != Some(2)
                || options
                    .tts_preferences
                    .as_ref()
                    .is_none_or(|preferences| preferences.primary.session.is_none())
            {
                return Err("Audition requires version-2 captured voice identity".into());
            }
            options.validate_contract()?;
            let text = c_string(text, "audition text")?;
            if text.trim().is_empty() || text.chars().count() > 300 {
                return Err("Audition requires 1–300 characters".into());
            }
            let output = std::path::PathBuf::from(c_string(output, "audition output")?);
            if !output.is_absolute()
                || output.extension().and_then(|value| value.to_str()) != Some("mp3")
                || std::fs::symlink_metadata(&output).is_ok()
            {
                return Err("Audition requires a new absolute MP3 output path".into());
            }
            let control = control
                .as_ref()
                .ok_or("Audition requires an independent cancellation control")?;
            let token = control.control.cancellation_token();
            if token.is_cancelled() {
                return Err("Audition cancelled".into());
            }
            // Swift cooperative workers have small stacks. Match the conversion
            // boundary's stack budget for embedded eSpeak/ONNX inference.
            std::thread::Builder::new()
                .name("converter-ffi-audition".into())
                .stack_size(8 * 1024 * 1024)
                .spawn(move || synthesize_audition(options, &text, &output, &token))
                .map_err(|error| format!("Failed to start audition thread: {error}"))?
                .join()
                .map_err(|_| "Voice audition panicked".to_owned())?
        }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            fail::<()>(error);
            false
        }
        Err(_) => {
            fail::<()>("Voice audition panicked".into());
            false
        }
    }
}

fn synthesize_audition(
    options: EmbeddedConversionOptionsV1,
    text: &str,
    output: &Path,
    token: &piper::CancellationToken,
) -> Result<(), String> {
    #[cfg(not(feature = "piper-runtime"))]
    {
        let _ = (options, text, output, token);
        Err("Embedded Piper audition runtime unavailable".into())
    }
    #[cfg(feature = "piper-runtime")]
    {
        let preferences = options
            .tts_preferences
            .as_ref()
            .ok_or("Audition requires captured voice identity")?;
        if preferences.primary.engine != "piper" || preferences.secondary.is_some() {
            return Err("Audition accepts one installed Piper voice without fallback".into());
        }
        let selection = &preferences.primary;
        let model_id = selection
            .model_id
            .as_deref()
            .ok_or("Audition model is missing")?;
        let root = std::path::PathBuf::from(
            options
                .models_root
                .as_ref()
                .ok_or("Installed model root is missing")?,
        );
        let manifest = converter_core::model_store::ModelStore::catalog_manifest(model_id)
            .map_err(|error| error.to_string())?;
        if !converter_core::model_store::ModelStore::new(&root)
            .is_manifest_installed(&manifest)
            .map_err(|error| error.to_string())?
        {
            return Err("Audition model failed installed-integrity verification".into());
        }
        if let Some(data) = &options.espeak_data_directory {
            piper_runtime::set_espeak_data_directory(Path::new(data))?;
        }
        let runtime = Arc::new(piper_runtime_boundary::EmbeddedPiperRuntime);
        let prepared = piper::PreparedPiperModel::prepare(
            &root,
            model_id,
            Path::new("model.onnx"),
            Path::new("model.onnx.json"),
            runtime,
        )
        .map_err(|error| error.to_string())?;
        prepared
            .synthesize(text, output, token)
            .map_err(|error| error.to_string())?;
        if token.is_cancelled() {
            let _ = std::fs::remove_file(output);
            return Err("Audition cancelled".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn audition_rejects_invalid_text_cancelled_controls_and_existing_outputs() {
        unsafe {
            let root = tempfile::tempdir().unwrap();
            let output = root.path().join("preview.mp3");
            let path = CString::new(output.to_str().unwrap()).unwrap();
            let mut primary = converter_core::tts_preferences::TtsSelection::default();
            primary.session =
                Some(converter_core::tts_session::SessionSelection::from_legacy(&primary).unwrap());
            let preferences = converter_core::tts_preferences::TtsPreferences {
                primary,
                secondary: None,
                ..Default::default()
            };
            let options = CString::new(
                serde_json::json!({"contract_version": 2, "tts_preferences": preferences})
                    .to_string(),
            )
            .unwrap();
            let empty = CString::new("").unwrap();
            let text = CString::new("A short sample.").unwrap();
            let control = converter_job_control_create();
            assert!(!converter_voice_audition_v1(
                options.as_ptr(),
                empty.as_ptr(),
                path.as_ptr(),
                control
            ));
            converter_job_control_cancel(control);
            assert!(!converter_voice_audition_v1(
                options.as_ptr(),
                text.as_ptr(),
                path.as_ptr(),
                control
            ));
            assert!(!output.exists());
            std::fs::write(&output, b"existing audio").unwrap();
            assert!(!converter_voice_audition_v1(
                options.as_ptr(),
                text.as_ptr(),
                path.as_ptr(),
                control
            ));
            assert_eq!(std::fs::read(output).unwrap(), b"existing audio");
            converter_job_control_free(control);
        }
    }
}
