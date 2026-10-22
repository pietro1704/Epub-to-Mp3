//! Edge framing, SSML, chunk boundaries and the single protocol clock.
use super::{EdgeError, TRUSTED_CLIENT_TOKEN};
use http::{header::HeaderValue, Request};
use rand::Rng;
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicI64, Ordering};
use url::Url;

pub(super) const EDGE_BROWSER_VERSION: &str = "1-143.0.3650.75";
pub(super) static EDGE_CLOCK_SKEW_SECONDS: AtomicI64 = AtomicI64::new(0);

pub(super) const EDGE_ORIGIN: &str = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold";

pub fn xml_escape(value: &str) -> String {
    value
        .chars()
        .fold(String::with_capacity(value.len()), |mut out, ch| {
            if (ch < ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                || (('\u{7f}'..='\u{9f}').contains(&ch))
                || ch == '\u{fffe}'
                || ch == '\u{ffff}'
            {
                out.push(' ');
                return out;
            }
            match ch {
                '&' => out.push_str("&amp;"),
                '<' => out.push_str("&lt;"),
                '>' => out.push_str("&gt;"),
                '"' => out.push_str("&quot;"),
                '\'' => out.push_str("&apos;"),
                _ => out.push(ch),
            }
            out
        })
}

pub fn make_ssml(text: &str, voice: &str, rate: &str, volume: &str, pitch: &str) -> String {
    make_ssml_escaped(text, voice, rate, volume, pitch, true)
}

pub(super) fn make_ssml_escaped(
    text: &str,
    voice: &str,
    rate: &str,
    volume: &str,
    pitch: &str,
    escape_text: bool,
) -> String {
    let text = if escape_text {
        xml_escape(text)
    } else {
        text.to_owned()
    };
    let voice = normalize_voice_for_ssml(voice);
    format!("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='{}'><prosody pitch='{}' rate='{}' volume='{}'>{}</prosody></voice></speak>", xml_escape(&voice), xml_escape(pitch), xml_escape(rate), xml_escape(volume), text)
}

pub(super) fn normalize_voice_for_ssml(voice: &str) -> String {
    const SERVER_VOICE_PREFIX: &str = "Microsoft Server Speech Text to Speech Voice (";
    if voice.starts_with(SERVER_VOICE_PREFIX) {
        return voice.to_owned();
    }
    let mut parts = voice.splitn(3, '-');
    let (Some(language), Some(region), Some(name)) = (parts.next(), parts.next(), parts.next())
    else {
        return voice.to_owned();
    };
    format!("{SERVER_VOICE_PREFIX}{language}-{region}, {name})")
}

// Consume a nonempty prefix without trimming text or splitting a UTF-8 scalar.
// A scalar wider than the configured byte limit is sent whole to make progress.
pub(super) fn next_protocol_chunk(text: &str, limit: usize) -> (&str, &str) {
    let mut end = text.len().min(limit.max(1));
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    if end == 0 {
        end = text.chars().next().unwrap().len_utf8();
    }
    if end < text.len() {
        if let Some(boundary) = text.as_bytes()[..end]
            .iter()
            .rposition(|byte| *byte == b'\n' || *byte == b' ')
        {
            end = boundary + 1;
        }
    }
    text.split_at(end)
}

pub fn split_protocol_chunks(text: &str, limit: usize) -> Vec<String> {
    let limit = limit.max(1);
    let mut bytes = text.as_bytes();
    let mut chunks = Vec::new();

    while bytes.len() > limit {
        let mut split_at = bytes[..limit]
            .iter()
            .rposition(|byte| *byte == b'\n' || *byte == b' ')
            .unwrap_or(limit);

        while std::str::from_utf8(&bytes[..split_at]).is_err() && split_at > 0 {
            split_at -= 1;
        }

        if split_at == 0 {
            split_at = limit;
            while std::str::from_utf8(&bytes[..split_at]).is_err() && split_at > 0 {
                split_at -= 1;
            }
        }

        let chunk = std::str::from_utf8(&bytes[..split_at])
            .expect("split point must remain valid UTF-8")
            .trim();
        if !chunk.is_empty() {
            chunks.push(chunk.to_owned());
        }
        bytes = &bytes[split_at..];
    }

    let tail = std::str::from_utf8(bytes)
        .expect("remaining chunk must remain valid UTF-8")
        .trim();
    if !tail.is_empty() {
        chunks.push(tail.to_owned());
    }
    chunks
}

pub(super) fn random_id() -> String {
    let bytes: [u8; 16] = rand::rng().random();
    hex::encode(bytes)
}

pub(super) fn request_url(
    endpoint: &Url,
    connection_id: &str,
    token: &str,
) -> Result<Url, EdgeError> {
    let mut url = endpoint.clone();
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair("Ocp-Apim-Subscription-Key", token)
            .append_pair("ConnectionId", connection_id)
            .append_pair("Sec-MS-GEC", &sec_ms_gec_now())
            .append_pair("Sec-MS-GEC-Version", EDGE_BROWSER_VERSION);
    }
    Ok(url)
}

pub(super) fn sec_ms_gec_now() -> String {
    const WINDOWS_EPOCH_SECONDS: u64 = 11_644_473_600;
    let seconds = adjusted_unix_seconds().max(0) as u64;
    let rounded_seconds = seconds + WINDOWS_EPOCH_SECONDS;
    let rounded_seconds = rounded_seconds - rounded_seconds % 300;
    let ticks = rounded_seconds * 10_000_000;
    let payload = format!("{ticks}{TRUSTED_CLIENT_TOKEN}");
    hex::encode(Sha256::digest(payload.as_bytes())).to_uppercase()
}

pub(super) fn adjusted_unix_seconds() -> i64 {
    time::OffsetDateTime::now_utc()
        .unix_timestamp()
        .saturating_add(EDGE_CLOCK_SKEW_SECONDS.load(Ordering::Relaxed))
}

pub(super) fn adjust_edge_clock_skew(server_date: &str) -> Result<i64, String> {
    let format = time::format_description::well_known::Rfc2822;
    let server_time = time::OffsetDateTime::parse(server_date, &format)
        .map_err(|error| format!("invalid Edge Date header: {error}"))?;
    let skew = server_time
        .unix_timestamp()
        .saturating_sub(time::OffsetDateTime::now_utc().unix_timestamp());
    if skew.unsigned_abs() > 24 * 60 * 60 {
        return Err("Edge Date header differs from local time by more than 24 hours".into());
    }
    EDGE_CLOCK_SKEW_SECONDS.store(skew, Ordering::Relaxed);
    Ok(skew)
}

pub(super) fn protocol_request(url: Url) -> Result<Request<()>, EdgeError> {
    let mut request = Request::builder()
        .method("GET")
        .uri(url.as_str())
        .body(())
        .map_err(|e| EdgeError::Url(e.to_string()))?;
    request
        .headers_mut()
        .insert("Pragma", HeaderValue::from_static("no-cache"));
    request
        .headers_mut()
        .insert("Cache-Control", HeaderValue::from_static("no-cache"));
    request
        .headers_mut()
        .insert("Sec-WebSocket-Version", HeaderValue::from_static("13"));
    request
        .headers_mut()
        .insert("Origin", HeaderValue::from_static(EDGE_ORIGIN));
    request.headers_mut().insert(
        "Accept-Encoding",
        HeaderValue::from_static("gzip, deflate, br, zstd"),
    );
    request.headers_mut().insert(
        "Accept-Language",
        HeaderValue::from_static("en-US,en;q=0.9"),
    );
    let muid = random_id().to_uppercase();
    request.headers_mut().insert(
        "Cookie",
        HeaderValue::from_str(&format!("muid={muid};"))
            .map_err(|e| EdgeError::Url(e.to_string()))?,
    );
    request.headers_mut().insert(
        "User-Agent",
        HeaderValue::from_static(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
        ),
    );
    Ok(request)
}

pub(super) fn protocol_timestamp() -> String {
    time::OffsetDateTime::from_unix_timestamp(adjusted_unix_seconds())
        .unwrap_or_else(|_| time::OffsetDateTime::now_utc())
        .format(&time::macros::format_description!(
            "[weekday repr:short] [month repr:short] [day padding:zero] [year] [hour]:[minute]:[second] GMT+0000 (Coordinated Universal Time)"
        ))
        .expect("Edge timestamp format is static and valid")
}

pub(super) fn speech_config(timestamp: &str, format: &str) -> String {
    let payload = serde_json::json!({
        "context": {
            "synthesis": {
                "audio": {
                    "metadataoptions": {
                        "sentenceBoundaryEnabled": "false",
                        "wordBoundaryEnabled": "true",
                    },
                    "outputFormat": format,
                },
            },
        },
    });
    format!("X-Timestamp:{timestamp}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{payload}\r\n")
}

pub(super) fn ssml_frame(request_id: &str, timestamp: &str, ssml: &str) -> String {
    format!("X-RequestId:{request_id}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:{timestamp}Z\r\nPath:ssml\r\n\r\n{ssml}")
}

pub(super) fn frame_path(text: &str) -> Option<String> {
    text.split("\r\n")
        .find_map(|line| line.strip_prefix("Path:").map(str::to_owned))
}

pub(super) fn parse_audio_frame(frame: &[u8]) -> Result<Vec<u8>, EdgeError> {
    if frame.len() < 2 {
        return Err(EdgeError::Protocol(
            "binary frame is shorter than header length".into(),
        ));
    }
    let header_len = u16::from_be_bytes([frame[0], frame[1]]) as usize;
    if header_len + 2 > frame.len() {
        return Err(EdgeError::Protocol("binary header exceeds frame".into()));
    }
    let header = std::str::from_utf8(&frame[2..header_len + 2])
        .map_err(|error| EdgeError::Protocol(format!("invalid binary frame header: {error}")))?;
    let path = frame_path(header);
    if path.as_deref() != Some("audio") {
        return Err(EdgeError::Protocol(format!(
            "Edge returned unexpected binary frame path {}",
            path.as_deref().unwrap_or("<missing>")
        )));
    }
    let content_type = header
        .split("\r\n")
        .find_map(|line| line.strip_prefix("Content-Type:"));
    if !matches!(content_type, Some("audio/mpeg") | None) {
        return Err(EdgeError::Protocol(format!(
            "Edge returned unexpected binary content type {}",
            content_type.unwrap_or("<missing>")
        )));
    }
    let payload = frame[header_len + 2..].to_vec();
    if payload.is_empty() && content_type.is_some() {
        return Err(EdgeError::Protocol(
            "Edge returned an empty audio frame".into(),
        ));
    }
    Ok(payload)
}

/// Stable helper for protocol fixtures: returns the Sec-MS-GEC token shape.
pub fn sec_ms_gec(filetime_ticks: u64, token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!(
        "{}{}",
        filetime_ticks - (filetime_ticks % 300_000_000_000),
        token
    ));
    hex::encode_upper(hasher.finalize())
}
