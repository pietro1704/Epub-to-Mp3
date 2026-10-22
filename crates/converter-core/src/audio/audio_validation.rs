//! Decode and inspect complete native audio before accepting an artifact.
use super::audio_process::{require_external_audio_support, run_audio_process, ProcessSpec};
use super::mpeg_frame_validation::{validate_mpeg_bounds, AudioSegmentSource};
use super::wave_bounds::validate_wave_bounds;
use super::AudioError;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

pub fn probe_duration(path: impl AsRef<Path>) -> Result<f64, AudioError> {
    let path = path.as_ref();
    if let Some(info) = native_audio_info(path)? {
        return Ok(info.duration);
    }
    require_external_audio_support()?;
    probe_duration_external(path)
}

fn probe_duration_external(path: &Path) -> Result<f64, AudioError> {
    let output = run_audio_process(&ProcessSpec::new("ffprobe").args([
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=nw=1:nk=1",
        &path.to_string_lossy(),
    ]))?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| AudioError::Validation(format!("invalid duration for {}", path.display())))
}

pub fn probe_sample_rate(path: impl AsRef<Path>) -> Result<u32, AudioError> {
    let path = path.as_ref();
    if let Some(info) = native_audio_info(path)? {
        return Ok(info.sample_rate);
    }
    require_external_audio_support()?;
    probe_sample_rate_external(path)
}

fn probe_sample_rate_external(path: &Path) -> Result<u32, AudioError> {
    let output = run_audio_process(&ProcessSpec::new("ffprobe").args([
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=sample_rate",
        "-of",
        "default=nw=1:nk=1",
        &path.to_string_lossy(),
    ]))?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u32>()
        .map_err(|_| AudioError::Validation(format!("invalid sample rate for {}", path.display())))
}

pub(super) struct NativeAudioInfo {
    duration: f64,
    sample_rate: u32,
}

pub(super) fn invalid_audio(message: impl Into<String>) -> AudioError {
    AudioError::Validation(message.into())
}

/// Collect native encoder output using the same portable metadata contract as WASM.
#[cfg(test)]
pub(crate) fn collect_rusty_mp3_output(
    encoder: &mut rusty_mp3::Mp3Encoder,
) -> Result<Vec<u8>, AudioError> {
    crate::pcm::collect_rusty_mp3_output(encoder).map_err(invalid_audio)
}

pub(super) fn native_audio_info(path: &Path) -> Result<Option<NativeAudioInfo>, AudioError> {
    let mut file = File::open(path)?;
    let mut prefix = [0u8; 12];
    let count = file.read(&mut prefix)?;
    let is_wave = count >= 12 && &prefix[..4] == b"RIFF" && &prefix[8..12] == b"WAVE";
    let mut is_mpeg = count >= 2
        && (prefix.starts_with(b"ID3") || (prefix[0] == 0xff && prefix[1] & 0xe0 == 0xe0));
    if prefix.starts_with(b"ID3") && count >= 10 {
        if prefix[6..10].iter().any(|byte| byte & 0x80 != 0) {
            return Err(invalid_audio("invalid ID3 extent"));
        }
        let tag_size = prefix[6..10]
            .iter()
            .fold(0u64, |size, byte| size * 128 + u64::from(*byte));
        let offset = 10
            + tag_size
            + if prefix[3] == 4 && prefix[5] & 0x10 != 0 {
                10
            } else {
                0
            };
        if offset > file.metadata()?.len() {
            return Err(invalid_audio("truncated ID3 extent"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut payload = [0u8; 4];
        let count = file.read(&mut payload)?;
        if count > 0 && !(payload[0] == 0xff && payload[1] & 0xe0 == 0xe0) {
            // ID3 can prefix other desktop formats, such as FLAC.
            is_mpeg = false;
        }
        if count >= 4 {
            prefix[..4].copy_from_slice(&payload);
        }
    }
    if is_mpeg && prefix[0] == 0xff && prefix[1] & 0xe0 == 0xe0 {
        let bits = u32::from_be_bytes(prefix[..4].try_into().unwrap());
        if (bits >> 17) & 3 != 1 || (bits >> 12) & 15 == 0 {
            // Preserve desktop/Android support for other MPEG layers and
            // free-format bitrate streams through the existing capability.
            return Ok(None);
        }
    }
    if !is_wave && !is_mpeg {
        return Ok(None);
    }
    if is_wave {
        validate_wave_bounds(&mut file)?;
        file.seek(SeekFrom::Start(0))?;
        return decode_native_audio(Box::new(file));
    }
    let segments = validate_mpeg_bounds(&mut file)?;
    let mut combined: Option<NativeAudioInfo> = None;
    for segment in segments {
        // The decoder must never resynchronize into binary ID3 payloads or
        // interpret another segment's metadata as part of the current stream.
        // Reuse the validated inode even if the path is atomically replaced.
        // Segments decode sequentially, so cloned descriptors may share a cursor.
        let source = AudioSegmentSource::new(file.try_clone()?, segment)?;
        let Some(info) = decode_native_audio(Box::new(source))? else {
            return Ok(None);
        };
        if let Some(total) = combined.as_mut() {
            if total.sample_rate != info.sample_rate {
                return Err(invalid_audio("audio changes sample rate"));
            }
            total.duration += info.duration;
        } else {
            combined = Some(info);
        }
    }
    Ok(combined)
}

fn decode_native_audio(
    source: Box<dyn symphonia::core::io::MediaSource>,
) -> Result<Option<NativeAudioInfo>, AudioError> {
    use symphonia::core::{
        codecs::DecoderOptions,
        errors::Error,
        formats::FormatOptions,
        io::{MediaSourceStream, MediaSourceStreamOptions},
        meta::MetadataOptions,
        probe::Hint,
    };
    let source = MediaSourceStream::new(source, MediaSourceStreamOptions::default());
    let mut format = match symphonia::default::get_probe().format(
        &Hint::new(),
        source,
        &FormatOptions::default(),
        &MetadataOptions::default(),
    ) {
        Ok(probed) => probed.format,
        Err(Error::Unsupported(_)) => return Ok(None),
        Err(error) => return Err(invalid_audio(format!("cannot inspect audio: {error}"))),
    };
    let track = format
        .default_track()
        .ok_or_else(|| invalid_audio("audio has no track"))?;
    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .filter(|rate| *rate > 0)
        .ok_or_else(|| invalid_audio("audio has no sample rate"))?;
    let mut decoder = match symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
    {
        Ok(decoder) => decoder,
        Err(Error::Unsupported(_)) => return Ok(None),
        Err(error) => return Err(invalid_audio(format!("unsupported audio codec: {error}"))),
    };
    let mut frames = 0u64;
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(Error::IoError(error)) if error.kind() == io::ErrorKind::UnexpectedEof => break,
            Err(error) => return Err(invalid_audio(format!("invalid audio packet: {error}"))),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(Error::Unsupported(_)) => return Ok(None),
            Err(error) => return Err(invalid_audio(format!("invalid audio samples: {error}"))),
        };
        if decoded.spec().rate != sample_rate {
            return Err(invalid_audio("audio changes sample rate"));
        }
        frames = frames
            .checked_add(decoded.frames() as u64)
            .ok_or_else(|| invalid_audio("audio duration overflows"))?;
    }
    if frames == 0 {
        return Err(invalid_audio("audio has no decoded samples"));
    }
    Ok(Some(NativeAudioInfo {
        duration: frames as f64 / sample_rate as f64,
        sample_rate,
    }))
}

pub fn validate_audio(path: impl AsRef<Path>, minimum_bytes: u64) -> Result<f64, AudioError> {
    let path = path.as_ref();
    let size = fs::metadata(path)
        .map_err(|_| AudioError::Validation(format!("missing audio: {}", path.display())))?
        .len();
    if size < minimum_bytes {
        return Err(AudioError::Validation(format!(
            "audio is too small: {} bytes",
            size
        )));
    }
    let duration = probe_duration(path)?;
    if !duration.is_finite() || duration <= 0.0 {
        return Err(AudioError::Validation(
            "audio has no positive duration".into(),
        ));
    }
    Ok(duration)
}
