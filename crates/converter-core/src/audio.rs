//! Typed audio post-processing and archive orchestration.
use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
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

pub fn probe_duration(path: impl AsRef<Path>) -> Result<f64, AudioError> {
    let path = path.as_ref();
    if let Some(info) = native_audio_info(path)? {
        return Ok(info.duration);
    }
    require_external_audio_support()?;
    probe_duration_external(path)
}

fn probe_duration_external(path: &Path) -> Result<f64, AudioError> {
    let output = run(&ProcessSpec::new("ffprobe").args([
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
    let output = run(&ProcessSpec::new("ffprobe").args([
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

fn require_external_audio_support() -> Result<(), AudioError> {
    #[cfg(target_os = "ios")]
    return Err(AudioError::Validation(
        "this audio format requires a desktop editing capability".into(),
    ));
    #[cfg(not(target_os = "ios"))]
    Ok(())
}

struct NativeAudioInfo {
    duration: f64,
    sample_rate: u32,
}

fn invalid_audio(message: impl Into<String>) -> AudioError {
    AudioError::Validation(message.into())
}

fn native_audio_info(path: &Path) -> Result<Option<NativeAudioInfo>, AudioError> {
    use symphonia::core::{
        codecs::DecoderOptions,
        errors::Error,
        formats::FormatOptions,
        io::{MediaSourceStream, MediaSourceStreamOptions},
        meta::MetadataOptions,
        probe::Hint,
    };
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
    } else {
        validate_mpeg_bounds(&mut file)?;
    }
    file.seek(SeekFrom::Start(0))?;
    let source = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());
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

fn validate_wave_bounds(file: &mut File) -> Result<(), AudioError> {
    file.seek(SeekFrom::Start(4))?;
    let mut size = [0u8; 4];
    file.read_exact(&mut size)?;
    let end = u64::from(u32::from_le_bytes(size)) + 8;
    if end > file.metadata()?.len() || end < 12 {
        return Err(invalid_audio("truncated RIFF container"));
    }
    let mut offset = 12;
    let mut data_bytes = 0;
    let mut alignment = 0u16;
    let mut format_tag = 0u16;
    while offset < end {
        if end - offset < 8 {
            return Err(invalid_audio("truncated WAV chunk header"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header)?;
        let size = u64::from(u32::from_le_bytes(header[4..8].try_into().unwrap()));
        let next = offset
            .checked_add(8 + size + size % 2)
            .ok_or_else(|| invalid_audio("WAV chunk overflows"))?;
        if next > end {
            return Err(invalid_audio("truncated WAV chunk"));
        }
        if &header[..4] == b"fmt " {
            if size < 16 {
                return Err(invalid_audio("incomplete WAV format"));
            }
            file.seek(SeekFrom::Start(offset + 8))?;
            let mut tag = [0u8; 2];
            file.read_exact(&mut tag)?;
            format_tag = u16::from_le_bytes(tag);
            file.seek(SeekFrom::Start(offset + 8 + 12))?;
            let mut block = [0u8; 2];
            file.read_exact(&mut block)?;
            alignment = u16::from_le_bytes(block);
        }
        if &header[..4] == b"data" {
            data_bytes += size;
        }
        offset = next;
    }
    if data_bytes == 0
        || alignment == 0
        || (matches!(format_tag, 1 | 3) && data_bytes % u64::from(alignment) != 0)
    {
        return Err(invalid_audio("WAV has incomplete sample frames"));
    }
    Ok(())
}

fn validate_mpeg_bounds(file: &mut File) -> Result<(), AudioError> {
    let mut end = file.metadata()?.len();
    if end >= 128 {
        file.seek(SeekFrom::Start(end - 128))?;
        let mut tag = [0u8; 3];
        file.read_exact(&mut tag)?;
        if &tag == b"TAG" {
            end -= 128;
        }
    }
    if end >= 32 {
        file.seek(SeekFrom::Start(end - 32))?;
        let mut footer = [0u8; 32];
        file.read_exact(&mut footer)?;
        if &footer[..8] == b"APETAGEX" {
            let size = u64::from(u32::from_le_bytes(footer[12..16].try_into().unwrap()));
            if size < 32 || size > end {
                return Err(invalid_audio("invalid APE tag extent"));
            }
            end -= size;
            if end >= 32 {
                file.seek(SeekFrom::Start(end - 32))?;
                let mut header = [0u8; 8];
                file.read_exact(&mut header)?;
                if &header == b"APETAGEX" {
                    end -= 32;
                }
            }
        }
    }
    let mut offset = 0u64;
    let mut frames = 0u64;
    while offset < end {
        if end - offset < 4 {
            return Err(invalid_audio("truncated MPEG frame header"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0u8; 4];
        file.read_exact(&mut header)?;
        if &header[..3] == b"ID3" {
            if end - offset < 10 {
                return Err(invalid_audio("truncated ID3 header"));
            }
            let mut rest = [0u8; 6];
            file.read_exact(&mut rest)?;
            if rest[2..].iter().any(|byte| byte & 0x80 != 0) {
                return Err(invalid_audio("invalid ID3 tag size"));
            }
            let size = rest[2..]
                .iter()
                .fold(0u64, |size, byte| size * 128 + u64::from(*byte));
            let footer = if header[3] == 4 && rest[1] & 0x10 != 0 {
                10
            } else {
                0
            };
            offset += 10 + size + footer;
            if offset > end {
                return Err(invalid_audio("truncated ID3 tag"));
            }
            continue;
        }
        let bits = u32::from_be_bytes(header);
        let version = (bits >> 19) & 3;
        let layer = (bits >> 17) & 3;
        let bitrate_index = ((bits >> 12) & 15) as usize;
        let rate_index = ((bits >> 10) & 3) as usize;
        if bits >> 21 != 0x7ff
            || version == 1
            || layer != 1
            || bitrate_index == 0
            || bitrate_index == 15
            || rate_index == 3
        {
            return Err(invalid_audio("invalid MPEG Layer III frame"));
        }
        let rates = [44100u64, 48000, 32000];
        let rate = rates[rate_index]
            / match version {
                3 => 1,
                2 => 2,
                _ => 4,
            };
        let mpeg1 = [
            0u64, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
        ];
        let mpeg2 = [
            0u64, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
        ];
        let bitrate = if version == 3 {
            mpeg1[bitrate_index]
        } else {
            mpeg2[bitrate_index]
        };
        let length = (if version == 3 { 144000 } else { 72000 }) * bitrate / rate
            + u64::from((bits >> 9) & 1);
        offset += length;
        if offset > end {
            return Err(invalid_audio("truncated MPEG frame payload"));
        }
        frames += 1;
    }
    if frames == 0 {
        return Err(invalid_audio("MPEG audio has no frames"));
    }
    Ok(())
}

fn validate_cover_container(bytes: &[u8], format: image::ImageFormat) -> Result<(), AudioError> {
    match format {
        image::ImageFormat::Png => {
            let mut offset = 8usize;
            loop {
                if bytes.len().saturating_sub(offset) < 12 {
                    return Err(invalid_audio("truncated PNG cover"));
                }
                let length =
                    u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
                let next = offset
                    .checked_add(12)
                    .and_then(|offset| offset.checked_add(length))
                    .filter(|next| *next <= bytes.len())
                    .ok_or_else(|| invalid_audio("truncated PNG cover chunk"))?;
                if &bytes[offset + 4..offset + 8] == b"IEND" {
                    if length != 0 {
                        return Err(invalid_audio("invalid PNG cover terminator"));
                    }
                    if bytes[next - 4..next] != [0xae, 0x42, 0x60, 0x82] {
                        return Err(invalid_audio("invalid PNG cover terminator checksum"));
                    }
                    break;
                }
                offset = next;
            }
        }
        image::ImageFormat::Jpeg => validate_jpeg_extent(bytes)?,
        image::ImageFormat::WebP => {
            if bytes.len() < 12
                || u64::from(u32::from_le_bytes(bytes[4..8].try_into().unwrap())) + 8
                    != bytes.len() as u64
            {
                return Err(invalid_audio("truncated WebP cover"));
            }
        }
        _ => {}
    }
    Ok(())
}

fn validate_jpeg_extent(bytes: &[u8]) -> Result<(), AudioError> {
    let mut position = 2usize;
    let mut has_scan = false;
    while position < bytes.len() {
        if bytes[position] != 0xff {
            return Err(invalid_audio("invalid JPEG marker"));
        }
        while position < bytes.len() && bytes[position] == 0xff {
            position += 1;
        }
        let marker = *bytes
            .get(position)
            .ok_or_else(|| invalid_audio("truncated JPEG marker"))?;
        position += 1;
        if marker == 0xd9 {
            return if has_scan {
                Ok(())
            } else {
                Err(invalid_audio("JPEG has no scan"))
            };
        }
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        if marker == 0xd8 || marker == 0 {
            return Err(invalid_audio("invalid JPEG marker ordering"));
        }
        let length_bytes = bytes
            .get(position..position + 2)
            .ok_or_else(|| invalid_audio("truncated JPEG segment"))?;
        let length = usize::from(u16::from_be_bytes(length_bytes.try_into().unwrap()));
        if length < 2 {
            return Err(invalid_audio("invalid JPEG segment length"));
        }
        position = position
            .checked_add(length)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(|| invalid_audio("truncated JPEG segment"))?;
        if marker == 0xda {
            has_scan = true;
            while position < bytes.len() {
                if bytes[position] != 0xff {
                    position += 1;
                    continue;
                }
                let start = position;
                while position < bytes.len() && bytes[position] == 0xff {
                    position += 1;
                }
                let next = *bytes
                    .get(position)
                    .ok_or_else(|| invalid_audio("truncated JPEG scan"))?;
                if next == 0 || (0xd0..=0xd7).contains(&next) {
                    position += 1;
                    continue;
                }
                position = start;
                break;
            }
        }
    }
    Err(invalid_audio("truncated main JPEG image"))
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

/// Encode WAV audio as mono MP3 and replace the output after validation.
pub fn wav_to_mp3(
    input: impl AsRef<Path>,
    output: impl AsRef<Path>,
    bitrate: &str,
) -> Result<(), AudioError> {
    let input = input.as_ref();
    let output = output.as_ref();
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".encode-mp3-")
        .tempdir_in(parent)?;
    let encoded = staging.path().join("encoded.mp3");
    run(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-i",
        &input.to_string_lossy(),
        "-vn",
        "-c:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        "-ac",
        "1",
        "-f",
        "mp3",
        &encoded.to_string_lossy(),
    ]))?;
    validate_audio(&encoded, 100)?;
    let file = File::open(&encoded)?;
    file.sync_all()?;
    drop(file);
    fs::rename(encoded, output)?;
    Ok(())
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
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".archive-")
        .tempdir_in(parent)?;
    let temp = staging.path().join("archive.zip");
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
    drop(file);
    fs::rename(temp, output)?;
    Ok(())
}

pub fn embed_cover(input: &Path, cover: &Path) -> Result<(), AudioError> {
    use id3::{
        frame::{Picture, PictureType},
        Tag, TagLike, Version,
    };
    // Far above the library's normal 80 KB thumbnail budget, but bounded
    // independently of compressed image dimensions on constrained devices.
    const MAX_COVER_BYTES: u64 = 16 * 1024 * 1024;
    const MAX_DECODE_BYTES: u64 = 64 * 1024 * 1024;
    let source = File::open(cover)?;
    if source.metadata()?.len() > MAX_COVER_BYTES {
        return Err(invalid_audio("cover exceeds compressed image budget"));
    }
    let mut bytes = Vec::new();
    source.take(MAX_COVER_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_COVER_BYTES {
        return Err(invalid_audio("cover exceeds compressed image budget"));
    }
    let format = image::guess_format(&bytes)
        .map_err(|error| AudioError::Validation(format!("invalid cover: {error}")))?;
    let mime = match format {
        image::ImageFormat::Jpeg => "image/jpeg",
        image::ImageFormat::Png => "image/png",
        image::ImageFormat::WebP => "image/webp",
        _ => {
            require_external_audio_support()?;
            return embed_cover_external(input, cover);
        }
    };
    validate_cover_container(&bytes, format)?;
    use image::ImageDecoder;
    let mut reader = image::ImageReader::with_format(io::Cursor::new(&bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    reader.limits(limits);
    let decoder = reader
        .into_decoder()
        .map_err(|error| invalid_audio(format!("invalid cover: {error}")))?;
    if decoder.total_bytes() > MAX_DECODE_BYTES {
        return Err(invalid_audio("cover exceeds decoded image budget"));
    }
    image::DynamicImage::from_decoder(decoder)
        .map_err(|error| invalid_audio(format!("invalid cover: {error}")))?;
    if native_audio_info(input)?.is_none() {
        require_external_audio_support()?;
        return embed_cover_external(input, cover);
    }
    let mut tag = match Tag::read_from_path(input) {
        Ok(tag) => tag,
        Err(error) if matches!(error.kind, id3::ErrorKind::NoTag) => Tag::new(),
        Err(error) => {
            return Err(AudioError::Validation(format!(
                "invalid audio metadata: {error}"
            )))
        }
    };
    tag.remove_picture_by_type(PictureType::CoverFront);
    tag.add_frame(Picture {
        mime_type: mime.into(),
        picture_type: PictureType::CoverFront,
        description: "Cover".into(),
        data: bytes,
    });
    let parent = input.parent().unwrap_or_else(|| Path::new("."));
    let temporary = tempfile::NamedTempFile::new_in(parent)?;
    fs::copy(input, temporary.path())?;
    tag.write_to_path(temporary.path(), Version::Id3v24)
        .map_err(|error| AudioError::Validation(format!("cannot write audio metadata: {error}")))?;
    validate_audio(temporary.path(), 100)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(input)
        .map_err(|error| AudioError::Io(error.error))?;
    #[cfg(unix)]
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn embed_cover_external(input: &Path, cover: &Path) -> Result<(), AudioError> {
    let temp = input.with_extension(format!("cover-{}.mp3", std::process::id()));
    let input_s = input.to_string_lossy().into_owned();
    let cover_s = cover.to_string_lossy().into_owned();
    let temp_s = temp.to_string_lossy().into_owned();
    run(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-i",
        &input_s,
        "-i",
        &cover_s,
        "-map",
        "0:a:0",
        "-map",
        "1:v:0",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "48k",
        "-ac",
        "1",
        "-ar",
        "24000",
        "-c:v",
        "copy",
        "-id3v2_version",
        "3",
        "-metadata:s:v:0",
        "title=Cover",
        &temp_s,
    ]))?;
    fs::rename(temp, input)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn concurrent_archives_publish_a_complete_zip_without_staging_collisions() {
        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("book.zip");
        let sources: Vec<_> = (0..8)
            .map(|index| {
                let path = root.path().join(format!("chapter-{index}.mp3"));
                fs::write(&path, vec![index as u8; 1024 * 1024]).unwrap();
                (path, format!("chapter-{index}.mp3"))
            })
            .collect();
        let barrier = std::sync::Barrier::new(sources.len());
        std::thread::scope(|scope| {
            let handles: Vec<_> = sources
                .iter()
                .map(|source| {
                    let output = &output;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        create_archive(output, std::slice::from_ref(source))
                    })
                })
                .collect();
            for handle in handles {
                handle.join().unwrap().unwrap();
            }
        });

        let mut archive = zip::ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert_eq!(archive.len(), 1);
        let mut chapter = archive.by_index(0).unwrap();
        let index = sources
            .iter()
            .position(|(_, name)| name == chapter.name())
            .unwrap();
        let mut bytes = Vec::new();
        chapter.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, vec![index as u8; 1024 * 1024]);
        assert_eq!(
            fs::read_dir(root.path()).unwrap().count(),
            sources.len() + 1
        );
    }

    #[test]
    fn failed_archive_preserves_previous_zip_and_removes_temporary_files() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("chapter.mp3");
        let output = root.path().join("book.zip");
        fs::write(&source, b"complete chapter").unwrap();
        create_archive(&output, &[(source, "chapter.mp3".into())]).unwrap();
        let previous = fs::read(&output).unwrap();
        assert!(create_archive(
            &output,
            &[(root.path().join("missing.mp3"), "missing.mp3".into())]
        )
        .is_err());
        assert_eq!(fs::read(output).unwrap(), previous);
        assert_eq!(
            fs::read_dir(root.path()).unwrap().count(),
            2,
            "failed archive creation must not leave temporary files"
        );
    }

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
