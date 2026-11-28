use super::*;

/// A bounded audition (installed Piper, or Edge with online consent) creates no book, job, manifest or selection.
#[no_mangle]
pub unsafe extern "C" fn converter_voice_audition_v1(
    options_json: *const c_char,
    text: *const c_char,
    output: *const c_char,
    control: *const ConverterJobControl,
) -> bool {
    ffi_guard("converter_voice_audition_v1", false, || {
        clear_last_error();
        let result =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<(), String> {
                let control = control
                    .as_ref()
                    .ok_or("Audition requires an independent cancellation control")?;
                voice_audition_checked(
                    &c_string(options_json, "audition options")?,
                    &c_string(text, "audition text")?,
                    &c_string(output, "audition output")?,
                    &control.control,
                )
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
    })
}

/// Validates and renders one audition. Shared by the C ABI and the Android JNI entrypoint.
pub(crate) fn voice_audition_checked(
    options_json: &str,
    text: &str,
    output: &str,
    control: &ConversionControl,
) -> Result<(), String> {
    let options: EmbeddedConversionOptionsV1 =
        serde_json::from_str(options_json).map_err(|error| error.to_string())?;
    if options.contract_version != Some(2)
        || options
            .tts_preferences
            .as_ref()
            .is_none_or(|preferences| preferences.primary.session.is_none())
    {
        return Err("Audition requires version-2 captured voice identity".into());
    }
    options.validate_contract()?;
    let text = text.to_owned();
    if text.trim().is_empty() || text.chars().count() > 300 {
        return Err("Audition requires 1–300 characters".into());
    }
    let output = std::path::PathBuf::from(output);
    if !output.is_absolute()
        || output.extension().and_then(|value| value.to_str()) != Some("mp3")
        || std::fs::symlink_metadata(&output).is_ok()
    {
        return Err("Audition requires a new absolute MP3 output path".into());
    }
    let token = control.cancellation_token();
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
}

/// Edge is online, so its sample runs only with the captured online consent.
fn synthesize_edge_audition(
    options: &EmbeddedConversionOptionsV1,
    text: &str,
    output: &Path,
    synthesize: &impl Fn(&str, &str) -> Result<Vec<u8>, String>,
) -> Result<(), String> {
    let preferences = options
        .tts_preferences
        .as_ref()
        .ok_or("Audition requires captured voice identity")?;
    if preferences.primary.engine != "edge" || preferences.secondary.is_some() {
        return Err("Audition accepts one voice without fallback".into());
    }
    if !preferences.allow_online_fallback {
        return Err(converter_core::tts_preferences::edge_consent_required_message("primary"));
    }
    let voice = converter_core::worker::edge_audition_voice(
        preferences.primary.voice.as_deref(),
        options.language.as_deref(),
    );
    let audio = synthesize(text, &voice)?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)
        .and_then(|mut file| std::io::Write::write_all(&mut file, &audio))
        .map_err(|error| format!("Failed to write the audition audio: {error}"))
}

fn synthesize_audition(
    options: EmbeddedConversionOptionsV1,
    text: &str,
    output: &Path,
    token: &piper::CancellationToken,
) -> Result<(), String> {
    if options
        .tts_preferences
        .as_ref()
        .is_some_and(|preferences| preferences.primary.engine == "edge")
    {
        let cancelled = || token.is_cancelled();
        return synthesize_edge_audition(&options, text, output, &|text, voice| {
            converter_core::worker::synthesize_edge_audition(text, voice, &cancelled)
                .map_err(|error| error.to_string())
        });
    }
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
        let is_low = converter_core::model_catalog::model_by_id(model_id).is_some_and(|model| {
            model.metadata.presentation.quality == converter_core::model_catalog::QualityTier::Low
        });
        let prepared = if is_low {
            let revision = selection
                .session
                .as_ref()
                .and_then(|session| session.model_revision.as_deref())
                .ok_or("An explicit low quality audition requires a catalog revision")?;
            piper::PreparedPiperModel::prepare_explicit_low(&root, model_id, revision, runtime)
        } else {
            piper::PreparedPiperModel::prepare(
                &root,
                model_id,
                Path::new("model.onnx"),
                Path::new("model.onnx.json"),
                runtime,
            )
        }
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

    fn edge_options(consent: bool) -> EmbeddedConversionOptionsV1 {
        serde_json::from_value(edge_options_value(consent)).unwrap()
    }

    fn edge_options_value(consent: bool) -> serde_json::Value {
        let mut primary = converter_core::tts_preferences::TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: None,
            session: None,
        };
        primary.session =
            Some(converter_core::tts_session::SessionSelection::from_legacy(&primary).unwrap());
        serde_json::json!({
            "contract_version": 2,
            "language": "pt",
            "tts_preferences": converter_core::tts_preferences::TtsPreferences {
                primary,
                secondary: None,
                allow_online_fallback: consent,
                ..Default::default()
            },
        })
    }

    #[test]
    fn consented_edge_audition_renders_the_language_default_voice() {
        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("preview.mp3");
        let options = edge_options(true);
        options.validate_contract().unwrap();
        synthesize_edge_audition(&options, "Uma amostra.", &output, &|text, voice| {
            assert_eq!(text, "Uma amostra.");
            assert_eq!(voice, "pt-BR-FranciscaNeural");
            Ok(b"mp3".to_vec())
        })
        .unwrap();
        assert_eq!(std::fs::read(output).unwrap(), b"mp3");
    }

    #[test]
    fn edge_audition_without_consent_never_reaches_the_network() {
        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("preview.mp3");
        let error =
            synthesize_edge_audition(&edge_options(false), "Uma amostra.", &output, &|_, _| {
                panic!("Edge must not run without consent")
            })
            .unwrap_err();
        assert!(error.contains("[[edge_consent_required_v1"), "{error}");
        assert!(!output.exists());
    }

    #[test]
    fn shared_audition_check_refuses_a_cancelled_control_before_rendering() {
        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("preview.mp3");
        let control = ConversionControl::new();
        control.cancel();
        let error = voice_audition_checked(
            &edge_options_json(),
            "Uma amostra.",
            output.to_str().unwrap(),
            &control,
        )
        .unwrap_err();
        assert_eq!(error, "Audition cancelled");
        assert!(!output.exists());
    }

    fn edge_options_json() -> String {
        edge_options_value(true).to_string()
    }
}
