//! Piper JSON configuration, independent of ONNX session initialization.
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
pub struct AudioConfig {
    pub sample_rate: u32,
}

#[derive(Deserialize)]
pub struct ESpeakConfig {
    pub voice: String,
}

#[derive(Deserialize, Clone)]
pub struct InferenceConfig {
    pub noise_scale: f32,
    pub length_scale: f32,
    pub noise_w: f32,
}

#[derive(Deserialize)]
pub struct ModelConfig {
    pub audio: AudioConfig,
    pub espeak: ESpeakConfig,
    pub inference: InferenceConfig,
    pub num_speakers: u32,
    pub speaker_id_map: HashMap<String, i64>,
    pub phoneme_id_map: HashMap<char, Vec<i64>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> serde_json::Value {
        serde_json::from_str(include_str!("config_fixtures/pt_BR-cadu-medium.json")).unwrap()
    }

    #[test]
    fn piper_single_speaker_configs_without_named_speakers_load() {
        for source in [
            include_str!("config_fixtures/pt_BR-cadu-medium.json"),
            include_str!("config_fixtures/pt_BR-jeff-medium.json"),
        ] {
            let parsed: ModelConfig = serde_json::from_str(source).unwrap();
            assert_eq!(parsed.num_speakers, 1);
            assert_eq!(parsed.audio.sample_rate, 22050);
            assert_eq!(parsed.espeak.voice, "pt-br");
            assert!(parsed.speaker_id_map.is_empty());
            assert!(!parsed.phoneme_id_map.is_empty());
        }
        let mut source = fixture();
        source["speaker_id_map"] = serde_json::Value::Null;
        let parsed: ModelConfig = serde_json::from_value(source).unwrap();
        assert!(parsed.speaker_id_map.is_empty());
    }

    #[test]
    fn piper_named_speakers_preserve_voice_identity_and_reject_malformed_maps() {
        let mut source = fixture();
        source["num_speakers"] = serde_json::json!(2);
        source["speaker_id_map"] = serde_json::json!({"first": 0, "second": 1});
        let parsed: ModelConfig = serde_json::from_value(source.clone()).unwrap();
        assert_eq!(parsed.speaker_id_map["first"], 0);
        assert_eq!(parsed.speaker_id_map["second"], 1);
        for invalid in [
            serde_json::Value::Null,
            serde_json::json!([]),
            serde_json::json!({"first": "wrong"}),
        ] {
            source["speaker_id_map"] = invalid;
            assert!(serde_json::from_value::<ModelConfig>(source.clone()).is_err());
        }
        source.as_object_mut().unwrap().remove("speaker_id_map");
        assert!(serde_json::from_value::<ModelConfig>(source).is_err());
    }
}
