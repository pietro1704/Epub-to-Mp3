//! Typed audio post-processing and archive orchestration.
use id3::{
    frame::{Picture, PictureType},
    Tag, TagLike, Version,
};
use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use symphonia::core::{
    codecs::{Decoder, DecoderOptions},
    errors::Error as MediaError,
    formats::{FormatOptions, Packet},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};
use thiserror::Error;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid audio configuration: {0}")]
    InvalidConfig(String),
    #[error("{program} failed with status {status}: {stderr}")]
    Process {
        program: String,
        status: String,
        stderr: String,
    },
    #[error("audio validation failed: {0}")]
    Validation(String),
    #[error("archive error: {0}")]
    Archive(#[from] zip::result::ZipError),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl ProcessSpec {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
        }
    }
    pub fn arg(mut self, value: impl Into<String>) -> Self {
        self.args.push(value.into());
        self
    }
    pub fn args<I, S>(mut self, values: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(values.into_iter().map(Into::into));
        self
    }
}

fn run(spec: &ProcessSpec) -> Result<Output, AudioError> {
    if cfg!(any(target_os = "ios", target_os = "android"))
        || std::env::var_os("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS").as_deref()
            == Some(OsStr::new("1"))
    {
        return Err(AudioError::InvalidConfig(format!(
            "external audio tool '{}' is unavailable in the embedded runtime",
            spec.program
        )));
    }
    let program = resolve_program(&spec.program);
    let output = Command::new(&program)
        .args(&spec.args)
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(AudioError::Process {
            program: spec.program.clone(),
            status: output.status.to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(output)
}

fn resolve_program(program: &str) -> PathBuf {
    let override_name = match program {
        "ffprobe" => Some("FFPROBE"),
        "ffmpeg" => Some("FFMPEG"),
        _ => None,
    };
    let override_path = override_name.and_then(std::env::var_os).map(PathBuf::from);
    let path_directories = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
        .collect::<Vec<_>>();

    #[cfg(target_os = "macos")]
    let fallback_directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        .into_iter()
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    #[cfg(not(target_os = "macos"))]
    let fallback_directories = Vec::new();

    resolve_program_in(
        program,
        override_path,
        path_directories,
        fallback_directories,
    )
}

fn resolve_program_in(
    program: &str,
    override_path: Option<PathBuf>,
    path_directories: impl IntoIterator<Item = PathBuf>,
    fallback_directories: impl IntoIterator<Item = PathBuf>,
) -> PathBuf {
    if let Some(path) = override_path.filter(|path| path.is_file()) {
        return path;
    }
    let requested = Path::new(program);
    if requested.components().count() > 1 {
        return requested.to_path_buf();
    }
    path_directories
        .into_iter()
        .chain(fallback_directories)
        .map(|directory| directory.join(program))
        .find(|path| path.is_file())
        .unwrap_or_else(|| requested.to_path_buf())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Padding {
    pub intro_ms: u64,
    pub outro_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
}
impl Default for Padding {
    fn default() -> Self {
        Self {
            intro_ms: 0,
            outro_ms: 500,
            sample_rate: 16_000,
            channels: 1,
        }
    }
}

struct AudioInfo {
    duration: f64,
    sample_rate: u32,
}

#[derive(Default)]
struct MpegSegment {
    expected: Option<u64>,
    frames: u64,
}

impl MpegSegment {
    fn finish(&self) -> Result<(), AudioError> {
        if self
            .expected
            .is_some_and(|expected| self.frames != expected)
        {
            return Err(AudioError::Validation(
                "MPEG segment does not match its explicit frame count".into(),
            ));
        }
        Ok(())
    }
}

// None means an audio frame; Some(None) is a metadata frame without a count.
fn mpeg_info_count(frame: &[u8], version: u32) -> Result<Option<Option<u64>>, AudioError> {
    let mono = frame[3] >> 6 == 3;
    let side_info = match (version == 3, mono) {
        (true, true) => 17,
        (true, false) => 32,
        (false, true) => 9,
        (false, false) => 17,
    };
    // LAME keeps Info/Xing at the unprotected offset even when CRC is present.
    // The CRC bytes themselves are not zeroed side information.
    let side_info_start = if frame[1] & 1 == 0 { 6 } else { 4 };
    let offset = 4 + side_info;
    if frame.len() < offset + 8
        || !matches!(&frame[offset..offset + 4], b"Info" | b"Xing")
        || frame[side_info_start..offset].iter().any(|byte| *byte != 0)
    {
        return Ok(None);
    }
    let flags = u32::from_be_bytes(frame[offset + 4..offset + 8].try_into().unwrap());
    let count = if flags & 1 != 0 {
        let bytes = frame
            .get(offset + 8..offset + 12)
            .ok_or_else(|| AudioError::Validation("truncated MPEG Info/Xing frame count".into()))?;
        Some(u64::from(u32::from_be_bytes(bytes.try_into().unwrap())))
    } else {
        None
    };
    Ok(Some(count))
}

// Demuxers use UnexpectedEof for both a clean boundary and an incomplete frame.
// Read and decode exactly one delimited MPEG frame at a time. ID3 bodies must
// never enter the decoder's sync search, including between encoded TTS chunks.
fn inspect_mpeg(path: &Path, decoder: &mut dyn Decoder) -> Result<AudioInfo, AudioError> {
    let file = File::open(path)?;
    let length = file.metadata()?.len();
    let mut source = BufReader::new(file);
    let mut offset = 0u64;
    let mut frame_count = 0u64;
    let mut segment = MpegSegment::default();
    let mut decoded_frames = 0u64;
    let mut sample_rate = 0u32;
    let invalid = || AudioError::Validation("truncated or invalid MPEG frame envelope".into());
    while offset < length {
        let remaining = length - offset;
        if remaining < 4 {
            return Err(invalid());
        }
        let mut header = [0u8; 4];
        source.read_exact(&mut header)?;
        let size = if &header[..3] == b"ID3" {
            segment.finish()?;
            segment = MpegSegment::default();
            decoder.reset();
            if remaining < 10 || !matches!(header[3], 2..=4) {
                return Err(invalid());
            }
            let mut tail = [0u8; 6];
            source.read_exact(&mut tail)?;
            if tail[2..].iter().any(|byte| byte & 0x80 != 0) {
                return Err(invalid());
            }
            let tag = tail[2..]
                .iter()
                .fold(0u64, |size, byte| (size << 7) | u64::from(*byte));
            10 + tag
                + if header[3] == 4 && tail[1] & 0x10 != 0 {
                    10
                } else {
                    0
                }
        } else if &header[..3] == b"TAG" && remaining == 128 {
            128
        } else if header == [0; 4] && frame_count > 0 {
            let mut buffer = [0u8; 4096];
            loop {
                let count = source.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                if buffer[..count].iter().any(|byte| *byte != 0) {
                    return Err(invalid());
                }
            }
            offset = length;
            continue;
        } else {
            let bits = u32::from_be_bytes(header);
            let version = (bits >> 19) & 3;
            let layer = (bits >> 17) & 3;
            let rate_index = ((bits >> 10) & 3) as usize;
            let bitrate_index = ((bits >> 12) & 15) as usize;
            if bits & 0xffe0_0000 != 0xffe0_0000
                || version == 1
                || layer != 1
                || rate_index == 3
                || bitrate_index == 0
                || bitrate_index == 15
            {
                return Err(invalid());
            }
            let rate = [44_100u64, 48_000, 32_000][rate_index]
                / match version {
                    3 => 1,
                    2 => 2,
                    _ => 4,
                };
            let bitrate = if version == 3 {
                [
                    0u64, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
                ][bitrate_index]
            } else {
                [
                    0u64, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
                ][bitrate_index]
            };
            frame_count += 1;
            let size = (if version == 3 { 144_000 } else { 72_000 }) * bitrate / rate
                + u64::from((bits >> 9) & 1);
            if size > remaining {
                return Err(invalid());
            }
            // Only one MPEG frame is buffered, independent of chapter length.
            let mut frame = vec![0; size as usize];
            frame[..4].copy_from_slice(&header);
            source.read_exact(&mut frame[4..])?;
            if let Some(expected) = mpeg_info_count(&frame, version)? {
                segment.finish()?;
                segment = MpegSegment {
                    expected,
                    frames: 0,
                };
                decoder.reset();
            } else {
                segment.frames += 1;
                let samples = if version == 3 { 1152 } else { 576 };
                let packet = Packet::new_from_boxed_slice(
                    0,
                    decoded_frames,
                    samples,
                    frame.into_boxed_slice(),
                );
                let decoded = decoder.decode(&packet).map_err(|error| {
                    AudioError::Validation(format!("invalid MPEG audio: {error}"))
                })?;
                let decoded_rate = decoded.spec().rate;
                if decoded_rate == 0 || (sample_rate != 0 && decoded_rate != sample_rate) {
                    return Err(AudioError::Validation("inconsistent sample rate".into()));
                }
                sample_rate = decoded_rate;
                decoded_frames = decoded_frames
                    .checked_add(decoded.frames() as u64)
                    .ok_or_else(|| AudioError::Validation("audio frame count overflow".into()))?;
            }
            size
        };
        if size < 4 || size > remaining {
            return Err(invalid());
        }
        offset += size;
        source.seek(SeekFrom::Start(offset))?;
    }
    if frame_count == 0 {
        return Err(invalid());
    }
    segment.finish()?;
    if decoded_frames == 0 || sample_rate == 0 {
        return Err(AudioError::Validation("empty MPEG audio stream".into()));
    }
    Ok(AudioInfo {
        duration: decoded_frames as f64 / sample_rate as f64,
        sample_rate,
    })
}

fn inspect_audio(path: &Path) -> Result<AudioInfo, AudioError> {
    let invalid = |error: &dyn std::fmt::Display| {
        AudioError::Validation(format!("invalid audio {}: {error}", path.display()))
    };
    let stream = MediaSourceStream::new(Box::new(File::open(path)?), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(OsStr::to_str) {
        hint.with_extension(extension);
    }
    let options = FormatOptions {
        // A chapter can contain independently encoded TTS chunks. Xing/Info
        // counts belong to the first chunk, not the whole concatenated stream.
        enable_gapless: false,
        ..Default::default()
    };
    let mut format = symphonia::default::get_probe()
        .format(&hint, stream, &options, &MetadataOptions::default())
        .map_err(|error| invalid(&error))?
        .format;
    let track = format
        .default_track()
        .ok_or_else(|| invalid(&"missing audio track"))?;
    let track_id = track.id;
    let is_mpeg = track.codec_params.codec == symphonia::core::codecs::CODEC_TYPE_MP3;
    let declared_frames = track.codec_params.n_frames;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|error| invalid(&error))?;
    if is_mpeg {
        return inspect_mpeg(path, decoder.as_mut());
    }
    let mut frames = 0u64;
    let mut sample_rate = 0u32;
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(MediaError::IoError(error)) if error.kind() == io::ErrorKind::UnexpectedEof => {
                break
            }
            Err(error) => return Err(invalid(&error)),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = decoder.decode(&packet).map_err(|error| invalid(&error))?;
        let rate = decoded.spec().rate;
        if rate == 0 || (sample_rate != 0 && rate != sample_rate) {
            return Err(invalid(&"inconsistent sample rate"));
        }
        sample_rate = rate;
        frames = frames
            .checked_add(decoded.frames() as u64)
            .ok_or_else(|| invalid(&"audio frame count overflow"))?;
    }
    if frames == 0 || sample_rate == 0 || declared_frames.is_some_and(|expected| frames < expected)
    {
        return Err(invalid(&"empty or truncated audio stream"));
    }
    Ok(AudioInfo {
        duration: frames as f64 / sample_rate as f64,
        sample_rate,
    })
}

pub fn probe_duration(path: impl AsRef<Path>) -> Result<f64, AudioError> {
    Ok(inspect_audio(path.as_ref())?.duration)
}

pub fn probe_sample_rate(path: impl AsRef<Path>) -> Result<u32, AudioError> {
    Ok(inspect_audio(path.as_ref())?.sample_rate)
}

fn atomic_replace(source: &Path, target: &Path) -> Result<(), AudioError> {
    let temp = target.with_extension(format!(
        "{}.tmp-{}",
        target
            .extension()
            .and_then(OsStr::to_str)
            .unwrap_or("audio"),
        std::process::id()
    ));
    fs::copy(source, &temp)?;
    let file = File::open(&temp)?;
    file.sync_all()?;
    fs::rename(temp, target)?;
    Ok(())
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

pub fn add_silence_padding(
    path: impl AsRef<Path>,
    padding: Padding,
    bitrate: &str,
) -> Result<(), AudioError> {
    let path = path.as_ref();
    if padding.intro_ms == 0 && padding.outro_ms == 0 {
        return Ok(());
    }
    validate_audio(path, 100)?;
    let rate = probe_sample_rate(path).unwrap_or(padding.sample_rate);
    let temp = path.with_extension(format!("padded-{}.mp3", std::process::id()));
    let mut filters = Vec::new();
    if padding.intro_ms > 0 {
        filters.push(format!("adelay={}:all=1", padding.intro_ms));
    }
    if padding.outro_ms > 0 {
        filters.push(format!(
            "apad=pad_dur={:.3}",
            padding.outro_ms as f64 / 1000.0
        ));
    }
    run(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-i",
        &path.to_string_lossy(),
        "-af",
        &filters.join(","),
        "-b:a",
        bitrate,
        "-ar",
        &rate.to_string(),
        "-ac",
        &padding.channels.to_string(),
        &temp.to_string_lossy(),
    ]))?;
    validate_audio(&temp, 100)?;
    atomic_replace(&temp, path)?;
    let _ = fs::remove_file(temp);
    Ok(())
}

pub fn concatenate(
    inputs: &[PathBuf],
    output: impl AsRef<Path>,
    bitrate: &str,
) -> Result<(), AudioError> {
    if inputs.is_empty() {
        return Err(AudioError::InvalidConfig("no audio inputs".into()));
    }
    let output = output.as_ref();
    let list = output.with_extension(format!("concat-{}.txt", std::process::id()));
    let temp = output.with_extension(format!("concat-{}.mp3", std::process::id()));
    let mut text = String::new();
    for input in inputs {
        validate_audio(input, 100)?;
        text.push_str(&format!("file '{} value'\n", input.display()).replace(" value", ""));
    }
    fs::write(&list, text)?;
    run(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        &list.to_string_lossy(),
        "-c:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        &temp.to_string_lossy(),
    ]))?;
    validate_audio(&temp, 100)?;
    atomic_replace(&temp, output)?;
    let _ = fs::remove_file(list);
    let _ = fs::remove_file(temp);
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChapterMetadata {
    pub index: usize,
    #[serde(default)]
    pub source_index: usize,
    pub title: String,
    pub filename: String,
    pub text_chars: usize,
}

pub fn write_metadata(
    path: impl AsRef<Path>,
    chapters: &[ChapterMetadata],
) -> Result<(), AudioError> {
    crate::cache::atomic_write_json(path, chapters)
        .map_err(|e| AudioError::Io(io::Error::other(e.to_string())))
}

pub fn create_archive(
    output: impl AsRef<Path>,
    files: &[(PathBuf, String)],
) -> Result<(), AudioError> {
    let output = output.as_ref();
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = output.with_extension(format!("zip.tmp-{}", std::process::id()));
    let file = File::create(&temp)?;
    let mut archive = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let mut buffer = [0u8; 1024 * 1024];
    for (source, name) in files {
        archive.start_file(name, options)?;
        let mut input = File::open(source)?;
        loop {
            let count = input.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            archive.write_all(&buffer[..count])?;
        }
    }
    let file = archive.finish()?;
    file.sync_all()?;
    fs::rename(temp, output)?;
    Ok(())
}

/// Validated cover artwork can be reused across all chapters in a conversion.
pub struct CoverArtwork {
    mime_type: &'static str,
    data: Vec<u8>,
}

impl CoverArtwork {
    pub fn read(path: &Path) -> Result<Self, AudioError> {
        if fs::metadata(path)?.len() > 16 * 1024 * 1024 {
            return Err(AudioError::Validation(
                "cover image exceeds the memory budget".into(),
            ));
        }
        let picture = fs::read(path)?;
        let mut reader =
            image::ImageReader::new(io::Cursor::new(&picture)).with_guessed_format()?;
        let mime_type = match reader.format() {
            Some(image::ImageFormat::Png) => "image/png",
            Some(image::ImageFormat::Jpeg) => "image/jpeg",
            Some(image::ImageFormat::WebP) => "image/webp",
            _ => return Err(AudioError::Validation("unsupported cover image".into())),
        };
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(8192);
        limits.max_image_height = Some(8192);
        limits.max_alloc = Some(64 * 1024 * 1024);
        reader.limits(limits);
        reader
            .decode()
            .map_err(|error| AudioError::Validation(format!("invalid cover: {error}")))?;
        Ok(Self {
            mime_type,
            data: picture,
        })
    }

    pub fn embed_into(&self, input: &Path) -> Result<(), AudioError> {
        let duration = validate_audio(input, 100)?;
        let mut tag = match Tag::read_from_path(input) {
            Ok(tag) => tag,
            Err(error) if matches!(&error.kind, id3::ErrorKind::NoTag) => Tag::new(),
            Err(error) => {
                return Err(AudioError::Validation(format!(
                    "invalid audio tags: {error}"
                )))
            }
        };
        tag.remove_picture_by_type(PictureType::CoverFront);
        tag.add_frame(Picture {
            mime_type: self.mime_type.into(),
            picture_type: PictureType::CoverFront,
            description: "Cover".into(),
            data: self.data.clone(),
        });
        let parent = input.parent().unwrap_or_else(|| Path::new("."));
        let temporary = tempfile::NamedTempFile::new_in(parent)?;
        fs::copy(input, temporary.path())?;
        tag.write_to_path(temporary.path(), Version::Id3v24)
            .map_err(|error| {
                AudioError::Validation(format!("cover metadata write failed: {error}"))
            })?;
        let tagged_duration = validate_audio(temporary.path(), 100)?;
        if (tagged_duration - duration).abs() > 1e-6 {
            return Err(AudioError::Validation(
                "cover metadata changed audio duration".into(),
            ));
        }
        File::open(temporary.path())?.sync_all()?;
        temporary
            .persist(input)
            .map_err(|error| AudioError::Io(error.error))?;
        File::open(parent)?.sync_all()?;
        Ok(())
    }
}

pub fn embed_cover(input: &Path, cover: &Path) -> Result<(), AudioError> {
    CoverArtwork::read(cover)?.embed_into(input)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn zero_padding_is_noop() {
        assert_eq!(
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                ..Default::default()
            },
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                sample_rate: 16_000,
                channels: 1
            }
        );
    }
    #[test]
    fn process_is_typed() {
        assert_eq!(
            ProcessSpec::new("ffmpeg").arg("-y").args(["-i", "input"]),
            ProcessSpec {
                program: "ffmpeg".into(),
                args: vec!["-y".into(), "-i".into(), "input".into()]
            }
        );
    }

    #[test]
    fn resolves_probe_from_package_manager_paths_when_app_path_is_restricted() {
        let path_dir = tempfile::tempdir().unwrap();
        let fallback_dir = tempfile::tempdir().unwrap();
        let expected = fallback_dir.path().join("ffprobe");
        fs::write(&expected, b"test executable placeholder").unwrap();

        let resolved = resolve_program_in(
            "ffprobe",
            None,
            [path_dir.path().to_path_buf()],
            [fallback_dir.path().to_path_buf()],
        );

        assert_eq!(resolved, expected);
    }
}
