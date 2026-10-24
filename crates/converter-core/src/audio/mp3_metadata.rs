//! Chapter metadata publication and bounded front-cover embedding.
use super::audio_process::{require_external_audio_support, run_audio_process, ProcessSpec};
use super::audio_validation::{invalid_audio, native_audio_info, validate_audio};
use super::cover_image_validation::validate_cover_container;
use super::AudioError;
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChapterMetadata {
    pub index: usize,
    #[serde(default)]
    pub source_index: usize,
    pub title: String,
    pub filename: String,
    pub text_chars: usize,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub text_offset: usize,
}

fn is_zero(value: &usize) -> bool {
    *value == 0
}

pub fn write_metadata(
    path: impl AsRef<Path>,
    chapters: &[ChapterMetadata],
) -> Result<(), AudioError> {
    crate::cache::atomic_write_json(path, chapters)
        .map_err(|e| AudioError::Io(io::Error::other(e.to_string())))
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
    run_audio_process(&ProcessSpec::new("ffmpeg").args([
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
