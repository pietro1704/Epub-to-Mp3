//! Only bounded raster payloads with bounded dimensions enter data image URLs.
//! No SVG/XML, remote URL, MIME guessing by extension or browser fetch is used.
use base64::{engine::general_purpose::STANDARD, Engine};
pub(super) const MAX_IMAGE_BYTES: usize = 1024 * 1024;

pub(crate) fn safe_data_image(source: &str) -> bool {
    if source.len() > MAX_IMAGE_BYTES * 4 / 3 + 128 {
        return false;
    }
    let Some((prefix, encoded)) = source.split_once(',') else {
        return false;
    };
    let declared = match prefix {
        "data:image/png;base64" => "image/png",
        "data:image/jpeg;base64" => "image/jpeg",
        "data:image/webp;base64" => "image/webp",
        _ => return false,
    };
    STANDARD
        .decode(encoded)
        .ok()
        .is_some_and(|bytes| mime(&bytes) == Some(declared))
}

fn dimensions(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= 8192
        && height <= 8192
        && u64::from(width) * u64::from(height) <= 20_000_000
}

pub(super) fn mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() > MAX_IMAGE_BYTES {
        return None;
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        && bytes.len() >= 33
        && &bytes[12..16] == b"IHDR"
        && bytes[8..12] == 13u32.to_be_bytes()
    {
        let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
        let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
        if !dimensions(width, height) || !png_chunks(bytes) {
            return None;
        }
        return Some("image/png");
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        if !bytes.ends_with(&[0xff, 0xd9]) {
            return None;
        }
        let mut cursor = 2;
        let mut frame = false;
        while cursor + 4 <= bytes.len() {
            if bytes[cursor] != 0xff {
                return None;
            }
            while cursor < bytes.len() && bytes[cursor] == 0xff {
                cursor += 1;
            }
            let marker = *bytes.get(cursor)?;
            cursor += 1;
            if marker == 0xd9 {
                return None;
            }
            let length = usize::from(u16::from_be_bytes(
                bytes.get(cursor..cursor + 2)?.try_into().ok()?,
            ));
            if length < 2 || cursor + length > bytes.len() {
                return None;
            }
            if marker == 0xda {
                return (frame && cursor + length + 2 < bytes.len()).then_some("image/jpeg");
            }
            if matches!(marker, 0xc0 | 0xc1 | 0xc2) && length >= 8 {
                let height = u32::from(u16::from_be_bytes(
                    bytes[cursor + 3..cursor + 5].try_into().ok()?,
                ));
                let width = u32::from(u16::from_be_bytes(
                    bytes[cursor + 5..cursor + 7].try_into().ok()?,
                ));
                if !dimensions(width, height) {
                    return None;
                }
                frame = true;
            }
            cursor += length;
        }
    }
    if bytes.len() >= 30 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return webp(bytes).then_some("image/webp");
    }
    None
}

fn png_chunks(bytes: &[u8]) -> bool {
    let mut cursor = 8;
    let mut image = false;
    while cursor + 12 <= bytes.len() {
        let length =
            u32::from_be_bytes(bytes[cursor..cursor + 4].try_into().expect("four bytes")) as usize;
        if length > bytes.len() - cursor - 12 {
            return false;
        }
        let kind = &bytes[cursor + 4..cursor + 8];
        match kind {
            b"IHDR" if cursor != 8 => return false,
            b"acTL" | b"fcTL" | b"fdAT" => return false,
            b"IDAT" => image |= length > 0,
            b"IEND" => return length == 0 && image && cursor + 12 == bytes.len(),
            _ => {}
        }
        cursor += length + 12;
    }
    false
}

fn webp(bytes: &[u8]) -> bool {
    let declared = u32::from_le_bytes(bytes[4..8].try_into().expect("four bytes")) as usize;
    if declared != bytes.len() - 8 {
        return false;
    }
    let mut cursor = 12;
    let mut canvas = None;
    let mut frame = None;
    while cursor + 8 <= bytes.len() {
        let length = u32::from_le_bytes(
            bytes[cursor + 4..cursor + 8]
                .try_into()
                .expect("four bytes"),
        ) as usize;
        if length > bytes.len() - cursor - 8 {
            return false;
        }
        let payload = &bytes[cursor + 8..cursor + 8 + length];
        let size = match &bytes[cursor..cursor + 4] {
            b"ANIM" | b"ANMF" => return false,
            b"VP8X" if length == 10 && payload[0] & 2 == 0 => {
                if canvas.is_some() || frame.is_some() {
                    return false;
                }
                canvas = Some((1 + le24(&payload[4..7]), 1 + le24(&payload[7..10])));
                None
            }
            b"VP8 " if length > 10 && payload[0] & 1 == 0 && &payload[3..6] == b"\x9d\x01\x2a" => {
                Some((
                    u32::from(u16::from_le_bytes([payload[6], payload[7]]) & 0x3fff),
                    u32::from(u16::from_le_bytes([payload[8], payload[9]]) & 0x3fff),
                ))
            }
            b"VP8L" if length > 5 && payload[0] == 0x2f => Some((
                1 + u32::from(payload[1]) + (u32::from(payload[2] & 0x3f) << 8),
                1 + (u32::from(payload[2]) >> 6)
                    + (u32::from(payload[3]) << 2)
                    + (u32::from(payload[4] & 0x0f) << 10),
            )),
            b"VP8X" | b"VP8 " | b"VP8L" => return false,
            _ => None,
        };
        if let Some(size) = size {
            if frame.is_some() || !dimensions(size.0, size.1) {
                return false;
            }
            frame = Some(size);
        }
        cursor += 8 + length + length % 2;
    }
    cursor == bytes.len() && frame.is_some() && canvas.is_none_or(|size| Some(size) == frame)
}

fn le24(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}
