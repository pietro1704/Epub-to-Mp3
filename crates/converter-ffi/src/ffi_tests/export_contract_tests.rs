fn tone_mp3_for_export() -> Vec<u8> {
    let samples: Vec<i16> = (0..24_000).map(|i| ((i as f32 * 0.05).sin() * 8000.0) as i16).collect();
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + samples.len() as u32 * 2).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&24_000u32.to_le_bytes());
    wav.extend_from_slice(&48_000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(samples.len() as u32 * 2).to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    converter_core::pcm::encode_wav_mp3(&wav).unwrap()
}

fn call_export(request: &serde_json::Value) -> Option<serde_json::Value> {
    let request = CString::new(request.to_string()).unwrap();
    unsafe {
        let raw = converter_export_mp3_json_v1(request.as_ptr());
        if raw.is_null() {
            return None;
        }
        let value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        Some(value)
    }
}

#[test]
fn export_writes_one_file_per_chapter_or_a_single_book_file() {
    let src = tempfile::tempdir().unwrap();
    let chapters: Vec<_> = ["Um", "Dois"]
        .iter()
        .enumerate()
        .map(|(i, title)| {
            let path = src.path().join(format!("c{i}.mp3"));
            std::fs::write(&path, tone_mp3_for_export()).unwrap();
            serde_json::json!({"title": title, "path": path})
        })
        .collect();
    let out = tempfile::tempdir().unwrap();
    let per_chapter = call_export(&serde_json::json!({
        "destination": out.path(), "layout": "perChapter", "title": "Hamlet", "author": "Shakespeare",
        "chapters": chapters,
    }))
    .unwrap();
    let names: Vec<_> = per_chapter["files"].as_array().unwrap().iter()
        .map(|f| std::path::Path::new(f.as_str().unwrap()).file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["01 - Um.mp3", "02 - Dois.mp3"]);
    let single = call_export(&serde_json::json!({
        "destination": out.path(), "layout": "single", "title": "Hamlet", "chapters": chapters,
    }))
    .unwrap();
    assert_eq!(single["files"].as_array().unwrap().len(), 1);
    assert!(single["files"][0].as_str().unwrap().ends_with("Hamlet.mp3"));
}

#[test]
fn export_rejects_a_bad_request_with_an_error() {
    assert!(call_export(&serde_json::json!({
        "destination": "/tmp/x", "layout": "zip", "title": "t", "chapters": [],
    }))
    .is_none());
    unsafe {
        let error = converter_last_error();
        assert!(!error.is_null());
        converter_string_free(error);
        assert!(converter_export_mp3_json_v1(ptr::null()).is_null());
    }
}
