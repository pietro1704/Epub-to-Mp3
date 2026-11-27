//! Export a finished book's chapter MP3s as one file or one file per chapter, with ID3 tags.
//!
//! Rust exports MP3 only. The format is part of the API so a client with a native encoder
//! (Apple AVFoundation AAC) can own M4A itself; asking Rust for it is a typed refusal.
use super::{audio_validation::validate_audio, embed_cover, join_mp3_segments, AudioError};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Mp3,
    M4a,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportLayout {
    /// One file holding every chapter, named after the book.
    SingleFile,
    /// One file per chapter, named "NN - title".
    PerChapter,
}

#[derive(Debug, Clone)]
pub struct ExportBook<'a> {
    pub title: &'a str,
    pub author: Option<&'a str>,
    /// Embedded only when given; a bad cover never fails the export.
    pub cover: Option<&'a Path>,
}

#[derive(Debug, Clone)]
pub struct ExportChapter {
    pub title: String,
    pub path: PathBuf,
}

/// Write the export into `destination` and return the files created, in chapter order.
/// Existing files are never overwritten: a clash becomes "name (2).mp3", "name (3).mp3".
pub fn export_mp3(
    destination: &Path,
    book: &ExportBook<'_>,
    chapters: &[ExportChapter],
    layout: ExportLayout,
    format: ExportFormat,
) -> Result<Vec<PathBuf>, AudioError> {
    if format != ExportFormat::Mp3 {
        return Err(AudioError::InvalidConfig(
            "converter-core exports MP3 only; M4A is encoded by the client".into(),
        ));
    }
    if chapters.is_empty() {
        return Err(AudioError::InvalidConfig("nothing to export".into()));
    }
    fs::create_dir_all(destination)?;
    let width = chapters.len().to_string().len().max(2);
    match layout {
        ExportLayout::SingleFile => {
            let bytes = chapters
                .iter()
                .map(|chapter| fs::read(&chapter.path))
                .collect::<Result<Vec<_>, _>>()?;
            let parts: Vec<&[u8]> = bytes.iter().map(Vec::as_slice).collect();
            let joined = join_mp3_segments(&parts)?;
            let name = format!("{}.mp3", sanitize(book.title, "Audiobook"));
            Ok(vec![publish(
                destination,
                &name,
                &joined,
                book,
                book.title,
                None,
            )?])
        }
        ExportLayout::PerChapter => chapters
            .iter()
            .enumerate()
            .map(|(position, chapter)| {
                let number = position + 1;
                let name = format!(
                    "{number:0width$} - {}.mp3",
                    sanitize(&chapter.title, "Chapter")
                );
                let bytes = fs::read(&chapter.path)?;
                publish(
                    destination,
                    &name,
                    &bytes,
                    book,
                    &chapter.title,
                    Some(number as u32),
                )
            })
            .collect(),
    }
}

fn publish(
    destination: &Path,
    name: &str,
    bytes: &[u8],
    book: &ExportBook<'_>,
    title: &str,
    track: Option<u32>,
) -> Result<PathBuf, AudioError> {
    use id3::{Tag, TagLike, Version};
    let mut staged = tempfile::NamedTempFile::new_in(destination)?;
    staged.write_all(bytes)?;
    staged.as_file().sync_all()?;
    let mut tag = Tag::new();
    tag.set_album(book.title);
    tag.set_title(title);
    if let Some(author) = book.author.filter(|author| !author.trim().is_empty()) {
        tag.set_artist(author);
    }
    if let Some(track) = track {
        tag.set_track(track);
    }
    tag.write_to_path(staged.path(), Version::Id3v24)
        .map_err(|error| AudioError::Validation(format!("cannot write audio metadata: {error}")))?;
    if let Some(cover) = book.cover {
        // Cheap and optional: an unreadable or unsupported cover leaves the audio untagged
        // with art rather than failing the export.
        let _ = embed_cover(staged.path(), cover);
    }
    validate_audio(staged.path(), 100)?;
    let stem = name.strip_suffix(".mp3").unwrap_or(name);
    let mut staged = staged;
    for attempt in 1.. {
        let target = destination.join(if attempt == 1 {
            name.to_string()
        } else {
            format!("{stem} ({attempt}).mp3")
        });
        match staged.persist_noclobber(&target) {
            Ok(_) => return Ok(target),
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                staged = error.file;
            }
            Err(error) => return Err(AudioError::Io(error.error)),
        }
    }
    unreachable!()
}

/// A portable file name: no separators or reserved characters, no edge dots or spaces.
fn sanitize(title: &str, fallback: &str) -> String {
    let cleaned: String = title
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed: String = collapsed
        .chars()
        .take(80)
        .collect::<String>()
        .trim_matches(|c: char| c == '.' || c == ' ' || c == '-')
        .to_string();
    if trimmed.is_empty() {
        fallback.into()
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use id3::{Tag, TagLike};

    fn tone_mp3() -> Vec<u8> {
        let mut wav = Vec::new();
        let samples: Vec<i16> = (0..24_000)
            .map(|i| ((i as f32 * 0.05).sin() * 8000.0) as i16)
            .collect();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + samples.len() as u32 * 2).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&24_000u32.to_le_bytes());
        wav.extend_from_slice(&48_000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(samples.len() as u32 * 2).to_le_bytes());
        for sample in samples {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        crate::pcm::encode_wav_mp3(&wav).unwrap()
    }

    fn chapters(dir: &Path, titles: &[&str]) -> Vec<ExportChapter> {
        titles
            .iter()
            .enumerate()
            .map(|(i, title)| {
                let path = dir.join(format!("c{i}.mp3"));
                fs::write(&path, tone_mp3()).unwrap();
                ExportChapter {
                    title: (*title).into(),
                    path,
                }
            })
            .collect()
    }

    const BOOK: ExportBook<'static> = ExportBook {
        title: "Dom Casmurro",
        author: Some("Machado"),
        cover: None,
    };

    #[test]
    fn per_chapter_files_are_numbered_titled_and_tagged() {
        let src = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let files = export_mp3(
            out.path(),
            &BOOK,
            &chapters(src.path(), &["Capítulo I", "A/B: \"fim\"?"]),
            ExportLayout::PerChapter,
            ExportFormat::Mp3,
        )
        .unwrap();
        let names: Vec<_> = files
            .iter()
            .map(|f| f.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["01 - Capítulo I.mp3", "02 - A-B- -fim.mp3"]);
        let tag = Tag::read_from_path(&files[1]).unwrap();
        assert_eq!(tag.album(), Some("Dom Casmurro"));
        assert_eq!(tag.title(), Some("A/B: \"fim\"?"));
        assert_eq!(tag.artist(), Some("Machado"));
        assert_eq!(tag.track(), Some(2));
    }

    #[test]
    fn single_file_joins_every_chapter_under_the_book_title() {
        let src = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let list = chapters(src.path(), &["Um", "Dois", "Três"]);
        let files = export_mp3(
            out.path(),
            &BOOK,
            &list,
            ExportLayout::SingleFile,
            ExportFormat::Mp3,
        )
        .unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].file_name().unwrap(), "Dom Casmurro.mp3");
        let one = crate::audio::probe_duration(&list[0].path).unwrap();
        let all = crate::audio::probe_duration(&files[0]).unwrap();
        assert!((all - 3.0 * one).abs() < 0.3, "{all} vs 3x{one}");
        assert_eq!(
            Tag::read_from_path(&files[0]).unwrap().album(),
            Some("Dom Casmurro")
        );
    }

    #[test]
    fn an_existing_file_is_never_overwritten() {
        let src = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        fs::write(out.path().join("01 - Um.mp3"), b"keep").unwrap();
        let files = export_mp3(
            out.path(),
            &BOOK,
            &chapters(src.path(), &["Um"]),
            ExportLayout::PerChapter,
            ExportFormat::Mp3,
        )
        .unwrap();
        assert_eq!(fs::read(out.path().join("01 - Um.mp3")).unwrap(), b"keep");
        assert_eq!(files[0].file_name().unwrap(), "01 - Um (2).mp3");
    }

    #[test]
    fn m4a_is_a_typed_refusal_not_a_silent_mp3() {
        let out = tempfile::tempdir().unwrap();
        let result = export_mp3(
            out.path(),
            &BOOK,
            &[],
            ExportLayout::SingleFile,
            ExportFormat::M4a,
        );
        assert!(matches!(result, Err(AudioError::InvalidConfig(m)) if m.contains("M4A")));
    }
}
