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
#[serde(try_from = "ModelConfigFields")]
pub struct ModelConfig {
    pub audio: AudioConfig,
    pub espeak: ESpeakConfig,
    pub inference: InferenceConfig,
    pub num_speakers: u32,
    pub speaker_id_map: HashMap<String, i64>,
    pub phoneme_id_map: HashMap<char, Vec<i64>>,
}

// Piper's single-speaker exports may omit the optional name-to-ID mapping.
// Preserve the required mapping for multi-speaker exports and reject malformed
// present values through serde rather than silently discarding voice identity.
#[derive(Deserialize)]
struct ModelConfigFields {
    audio: AudioConfig,
    espeak: ESpeakConfig,
    inference: InferenceConfig,
    num_speakers: u32,
    speaker_id_map: Option<HashMap<String, i64>>,
    phoneme_id_map: HashMap<char, Vec<i64>>,
}

impl TryFrom<ModelConfigFields> for ModelConfig {
    type Error = &'static str;

    fn try_from(fields: ModelConfigFields) -> Result<Self, Self::Error> {
        let speaker_id_map = match fields.speaker_id_map {
            Some(mapping) => mapping,
            None if fields.num_speakers == 1 => HashMap::new(),
            None => return Err("Multi-speaker models require speaker_id_map"),
        };
        Ok(Self {
            audio: fields.audio,
            espeak: fields.espeak,
            inference: fields.inference,
            num_speakers: fields.num_speakers,
            speaker_id_map,
            phoneme_id_map: fields.phoneme_id_map,
        })
    }
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
    fn piper_single_speaker_empty_or_named_map_preserves_existing_exports() {
        let mut source = fixture();
        for mapping in [serde_json::json!({}), serde_json::json!({"Faber": 0})] {
            source["speaker_id_map"] = mapping.clone();
            let parsed: ModelConfig = serde_json::from_value(source.clone()).unwrap();
            assert_eq!(
                serde_json::to_value(parsed.speaker_id_map).unwrap(),
                mapping
            );
        }
        source["speaker_id_map"] = serde_json::json!({"Faber": "not an ID"});
        assert!(serde_json::from_value::<ModelConfig>(source).is_err());
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
