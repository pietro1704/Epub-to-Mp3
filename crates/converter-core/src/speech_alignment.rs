//! Word timing travels with the audio it describes, including retained MP3s.
use serde::{Deserialize, Serialize};
#[cfg(not(target_arch = "wasm32"))]
use std::io::{Read, Seek, SeekFrom};

const OWNER: &[u8] = b"epubtomp3.speech-alignment\0";
const MAX_JSON: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Word {
    pub location: usize,
    pub length: usize,
    pub start: f64,
    pub end: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Passage {
    pub version: u32,
    pub text: String,
    pub words: Vec<Word>,
    #[serde(default)]
    pub audio_start: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_offset: Option<usize>,
}

impl Passage {
    pub fn parse(json: &[u8], duration: f64) -> Result<Self, String> {
        if json.len() > MAX_JSON {
            return Err("Speech alignment exceeds its budget".into());
        }
        let value: Self = serde_json::from_slice(json).map_err(|e| e.to_string())?;
        let length = value.text.encode_utf16().count();
        let boundaries: std::collections::HashSet<_> = std::iter::once(0)
            .chain(value.text.chars().scan(0, |offset, character| {
                *offset += character.len_utf16();
                Some(*offset)
            }))
            .collect();
        if value.version != 1
            || value.words.is_empty()
            || value.words.len() > 20_000
            || !value.audio_start.is_finite()
            || value.audio_start < 0.0
            || value.words.iter().any(|word| {
                word.length == 0
                    || word
                        .location
                        .checked_add(word.length)
                        .is_none_or(|end| end > length)
                    || !boundaries.contains(&word.location)
                    || !boundaries.contains(&(word.location + word.length))
                    || !word.start.is_finite()
                    || !word.end.is_finite()
                    || word.start < 0.0
                    || word.end <= word.start
                    || word.end > duration + 0.05
            })
            || value.words.windows(2).any(|pair| {
                pair[0].end > pair[1].start + 0.001
                    || pair[0].location + pair[0].length > pair[1].location
            })
        {
            return Err("Invalid speech word alignment".into());
        }
        Ok(value)
    }

    /// Apply exactly the same digital-zero edits as the encoder, in sample coordinates.
    pub fn compact(&mut self, pcm: &[u8], rate: u32) {
        let edits = crate::speech_silence::removed_ranges(pcm, rate);
        let map = |seconds: f64| {
            let frame = seconds * f64::from(rate);
            let removed: f64 = edits
                .iter()
                .map(|(start, end)| (frame - *start as f64).clamp(0.0, (*end - *start) as f64))
                .sum();
            (frame - removed) / f64::from(rate)
        };
        for word in &mut self.words {
            word.start = map(word.start);
            word.end = map(word.end);
        }
        self.words.retain(|word| word.end > word.start);
    }
}

pub(crate) fn tag(passages: &[Passage]) -> Result<Vec<u8>, String> {
    if passages.is_empty() {
        return Ok(Vec::new());
    }
    let json = serde_json::to_vec(passages).map_err(|e| e.to_string())?;
    if json.len() > MAX_JSON {
        return Err("Speech alignment exceeds its budget".into());
    }
    let size = OWNER.len() + json.len();
    let mut frame = b"PRIV".to_vec();
    frame.extend_from_slice(&(size as u32).to_be_bytes());
    frame.extend_from_slice(&[0, 0]);
    frame.extend_from_slice(OWNER);
    frame.extend_from_slice(&json);
    let n = frame.len();
    let mut tag = b"ID3\x03\0\0".to_vec();
    tag.extend_from_slice(&[
        ((n >> 21) & 127) as u8,
        ((n >> 14) & 127) as u8,
        ((n >> 7) & 127) as u8,
        (n & 127) as u8,
    ]);
    tag.extend(frame);
    Ok(tag)
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn merge_tag(passages: &[Passage], leading: &[u8]) -> Result<Vec<u8>, String> {
    use id3::{frame::Private, Tag, TagLike, Version};
    let mut metadata = if leading.is_empty() {
        Tag::new()
    } else {
        Tag::read_from2(std::io::Cursor::new(leading)).map_err(|error| error.to_string())?
    };
    let json = serde_json::to_vec(passages).map_err(|error| error.to_string())?;
    if json.len() > MAX_JSON {
        return Err("Speech alignment exceeds its budget".into());
    }
    let owner = String::from_utf8_lossy(&OWNER[..OWNER.len() - 1]).into_owned();
    for frame in metadata.remove("PRIV") {
        if !matches!(frame.content(), id3::Content::Private(value) if value.owner_identifier == owner)
        {
            metadata.add_frame(frame);
        }
    }
    metadata.add_frame(Private {
        owner_identifier: owner,
        private_data: json,
    });
    let mut bytes = Vec::new();
    metadata
        .write_to(&mut bytes, Version::Id3v23)
        .map_err(|error| error.to_string())?;
    Ok(bytes)
}

/// Reads our bounded private frame; unknown metadata remains untouched.
pub(crate) fn from_tag(bytes: &[u8]) -> Vec<Passage> {
    if bytes.len() < 10 || &bytes[..3] != b"ID3" || ![3, 4].contains(&bytes[3]) || bytes[5] != 0 {
        return Vec::new();
    }
    let mut cursor = 10;
    while cursor + 10 <= bytes.len() {
        let length = &bytes[cursor + 4..cursor + 8];
        let size = if bytes[3] == 4 {
            if length.iter().any(|byte| *byte >= 128) {
                break;
            }
            length
                .iter()
                .fold(0usize, |size, byte| size * 128 + usize::from(*byte))
        } else {
            u32::from_be_bytes(length.try_into().unwrap()) as usize
        };
        let Some(end) = (cursor + 10)
            .checked_add(size)
            .filter(|end| *end <= bytes.len())
        else {
            break;
        };
        let payload = &bytes[cursor + 10..end];
        if &bytes[cursor..cursor + 4] == b"PRIV"
            && payload.starts_with(OWNER)
            && payload.len() <= MAX_JSON + OWNER.len()
        {
            return serde_json::from_slice(&payload[OWNER.len()..]).unwrap_or_default();
        }
        cursor = end;
    }
    Vec::new()
}

/// Bind synthesis-local markers to the normalized source text, before publication.
pub(crate) fn bind_source(bytes: Vec<u8>, text: &str, source_offset: usize) -> Vec<u8> {
    if bytes.len() < 10 || &bytes[..3] != b"ID3" {
        return bytes;
    }
    let size = bytes[6..10]
        .iter()
        .fold(0usize, |n, b| n * 128 + usize::from(*b));
    let end = (10 + size).min(bytes.len());
    let mut passages = from_tag(&bytes[..end]);
    if passages.len() != 1 || passages[0].text != text {
        return bytes;
    }
    passages[0].source_offset = Some(source_offset);
    let Ok(mut result) = tag(&passages) else {
        return bytes;
    };
    result.extend_from_slice(&bytes[end..]);
    result
}

/// Aggregate metadata before the MPEG assembler removes internal ID3 headers.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn collect(file: &mut std::fs::File) -> Result<Vec<Passage>, std::io::Error> {
    let end = file.metadata()?.len();
    let mut offset = 0;
    let mut seconds = 0.0;
    let mut passages = Vec::new();
    while offset + 10 <= end {
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0u8; 10];
        file.read_exact(&mut header)?;
        if &header[..3] == b"ID3" {
            if header[6..10].iter().any(|b| *b >= 128) {
                break;
            }
            let size = header[6..10]
                .iter()
                .fold(0usize, |n, b| n * 128 + usize::from(*b));
            if size > MAX_JSON + 1024 || offset + 10 + size as u64 > end {
                break;
            }
            let mut bytes = header.to_vec();
            bytes.resize(10 + size, 0);
            file.read_exact(&mut bytes[10..])?;
            for mut passage in from_tag(&bytes) {
                passage.audio_start += seconds;
                passages.push(passage);
            }
            offset += (10 + size) as u64;
        } else {
            let Ok(frame) = rusty_mp3::header::FrameHeader::parse(header[..4].try_into().unwrap())
            else {
                break;
            };
            let length = frame.frame_size();
            let marker_offset = 4 + usize::from(frame.crc_protected) * 2 + frame.side_info_len();
            file.seek(SeekFrom::Start(offset + marker_offset as u64))?;
            let mut marker = [0u8; 4];
            file.read_exact(&mut marker)?;
            if marker != *b"Info" && marker != *b"Xing" {
                seconds += frame.version.samples_per_frame() as f64 / f64::from(frame.sample_rate);
            }
            offset += length as u64;
        }
    }
    Ok(passages)
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;

    fn passage() -> Passage {
        Passage {
            version: 1,
            text: "hello hello".into(),
            audio_start: 0.0,
            source_offset: None,
            words: vec![
                Word {
                    location: 0,
                    length: 5,
                    start: 0.0,
                    end: 1.0,
                },
                Word {
                    location: 6,
                    length: 5,
                    start: 2.0,
                    end: 3.0,
                },
            ],
        }
    }

    #[test]
    fn real_word_times_follow_the_same_silence_edits_as_audio() {
        let mut pcm = vec![1; 16_000 * 2];
        pcm.extend(vec![0; 16_000 * 2]);
        pcm.extend(vec![1; 16_000 * 2]);
        let mut value = passage();
        value.compact(&pcm, 16_000);
        assert!((value.words[1].start - 1.3).abs() < 0.001);
        assert!((value.words[1].end - 2.3).abs() < 0.001);
        assert_eq!(value.words[1].location, 6);
    }

    #[test]
    fn wav_markers_survive_the_production_encoder_and_silence_compaction() {
        let rate = 16_000u32;
        let mut pcm = vec![1; rate as usize * 2];
        pcm.extend(vec![0; rate as usize * 2]);
        pcm.extend(vec![1; rate as usize * 2]);
        let json = serde_json::to_vec(&passage()).unwrap();
        let mut wav = b"RIFF".to_vec();
        wav.extend_from_slice(
            &(36 + pcm.len() as u32 + 8 + json.len() as u32 + (json.len() % 2) as u32)
                .to_le_bytes(),
        );
        wav.extend_from_slice(b"WAVEfmt \x10\0\0\0\x01\0\x01\0");
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 2).to_le_bytes());
        wav.extend_from_slice(b"\x02\0\x10\0data");
        wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        wav.extend(pcm);
        wav.extend_from_slice(b"spch");
        wav.extend_from_slice(&(json.len() as u32).to_le_bytes());
        wav.extend(json.clone());
        if json.len() % 2 != 0 {
            wav.push(0);
        }
        let encoded = crate::pcm::encode_speech_wav_mp3(&wav).unwrap();
        crate::pcm::validate_mp3(&encoded).unwrap();
        let words = from_tag(&encoded)[0].words.clone();
        assert_eq!(words[1].location, 6);
        assert!((words[1].start - 1.3).abs() < 0.001);
        assert!((words[1].end - 2.3).abs() < 0.001);
        assert!(crate::pcm::mp3_duration_seconds(&encoded).unwrap() < 2.5);
        let version = wav
            .windows(11)
            .position(|bytes| bytes == b"\"version\":1")
            .unwrap();
        wav[version + 10] = b'9';
        let without_invalid_markers = crate::pcm::encode_speech_wav_mp3(&wav).unwrap();
        crate::pcm::validate_mp3(&without_invalid_markers).unwrap();
        assert!(
            from_tag(&without_invalid_markers).is_empty(),
            "Invalid optional timing must not disable working system audio"
        );
    }

    #[test]
    fn invalid_timing_and_text_ranges_are_rejected() {
        let mut value = passage();
        assert!(Passage::parse(&serde_json::to_vec(&value).unwrap(), 3.0).is_ok());
        value.words[1].location = 100;
        assert!(Passage::parse(&serde_json::to_vec(&value).unwrap(), 3.0).is_err());
        value = passage();
        value.words[1].end = 4.0;
        assert!(Passage::parse(&serde_json::to_vec(&value).unwrap(), 3.0).is_err());
    }

    #[test]
    fn source_binding_and_final_assembly_preserve_repeated_word_identity() {
        const AUDIO: &[u8] =
            include_bytes!("../../../tests/fixtures/audio/mono-24000-48k-info.mp3");
        let mut bytes = tag(&[passage()]).unwrap();
        bytes.extend_from_slice(AUDIO);
        let first = bind_source(bytes.clone(), "hello hello", 23);
        let second = bind_source(bytes, "hello hello", 91);
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("chapter.mp3");
        std::fs::write(&file, [first, second].concat()).unwrap();
        assert_eq!(
            collect(&mut std::fs::File::open(&file).unwrap())
                .unwrap()
                .len(),
            2
        );
        assert!(crate::audio::finalize_mp3(&file).unwrap());
        let collected = collect(&mut std::fs::File::open(&file).unwrap()).unwrap();
        assert_eq!(collected.len(), 2);
        assert_eq!(collected[0].source_offset, Some(23));
        assert_eq!(collected[1].source_offset, Some(91));
        assert!(collected[1].audio_start > collected[0].audio_start);
        assert!(!crate::audio::mp3_needs_finalization(&file).unwrap());
        let mut cover_metadata = id3::Tag::read_from_path(&file).unwrap();
        use id3::TagLike;
        cover_metadata.set_title("Chapter with retained word timing");
        cover_metadata
            .write_to_path(&file, id3::Version::Id3v24)
            .unwrap();
        let rewritten = collect(&mut std::fs::File::open(&file).unwrap()).unwrap();
        assert_eq!(rewritten.len(), 2);
        assert_eq!(rewritten[1].source_offset, Some(91));
    }
}
