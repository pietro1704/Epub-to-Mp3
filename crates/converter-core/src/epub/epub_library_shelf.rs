//! A whole library shelf in one call, with covers reduced to card-sized
//! JPEG thumbnails so clients never hold or decode full-size artwork.
use super::{read_library_metadata, EpubError, LibraryMetadata};
use image::codecs::jpeg::JpegEncoder;
use image::{ImageReader, Limits, Rgb, RgbImage};
use std::io::Cursor;
use std::path::PathBuf;

const THUMBNAIL_QUALITY: u8 = 85;
/// Decode bounds for untrusted cover art.
const MAX_SOURCE_EDGE: u32 = 10_000;
const MAX_DECODE_BYTES: u64 = 128 * 1024 * 1024;

/// Metadata for each book, in the order given. One unreadable book yields its
/// own error. A cover fits within `cover_max_edge` pixels per side, keeps its
/// aspect ratio and is never enlarged; art that cannot be decoded is omitted.
/// Books are read one at a time, so only one full-size cover is in memory.
pub fn read_library_shelf(
    paths: &[PathBuf],
    cover_max_edge: u32,
) -> Vec<Result<LibraryMetadata, EpubError>> {
    paths
        .iter()
        .map(|path| {
            let file = std::fs::File::open(path)?;
            let mut metadata = read_library_metadata(std::io::BufReader::new(file))?;
            metadata.cover = metadata
                .cover
                .and_then(|cover| thumbnail(&cover, cover_max_edge));
            metadata.cover_mime = metadata.cover.as_ref().map(|_| "image/jpeg".to_string());
            Ok(metadata)
        })
        .collect()
}

fn thumbnail(cover: &[u8], max_edge: u32) -> Option<Vec<u8>> {
    let mut reader = ImageReader::new(Cursor::new(cover))
        .with_guessed_format()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_SOURCE_EDGE);
    limits.max_image_height = Some(MAX_SOURCE_EDGE);
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    reader.limits(limits);
    let mut image = reader.decode().ok()?;
    if image.width() > max_edge || image.height() > max_edge {
        image = image.thumbnail(max_edge, max_edge);
    }
    // JPEG has no alpha: composite onto white rather than keep hidden colors.
    let source = image.to_rgba8();
    let flattened = RgbImage::from_fn(source.width(), source.height(), |x, y| {
        let [red, green, blue, alpha] = source.get_pixel(x, y).0;
        Rgb([red, green, blue].map(|channel| {
            let alpha = u32::from(alpha);
            ((u32::from(channel) * alpha + 255 * (255 - alpha)) / 255) as u8
        }))
    });
    let mut bytes = Vec::new();
    JpegEncoder::new_with_quality(&mut bytes, THUMBNAIL_QUALITY)
        .encode_image(&flattened)
        .ok()?;
    Some(bytes)
}
