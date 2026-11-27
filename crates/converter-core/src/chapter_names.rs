//! Book-scoped chapter name overrides and the filename cover. Source text is never edited:
//! an override only replaces the displayed name, and resetting restores the automatic one.
use crate::cache::{atomic_write_json, read_json, CacheError};
use crate::epub::Book;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

const MAX_NAME_CHARS: usize = 200;
const MAX_OVERRIDES: usize = 10_000;

/// Chapter index (`Chapter::index`) to the user's chosen name.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChapterNameOverrides {
    names: BTreeMap<String, String>,
}

impl ChapterNameOverrides {
    pub fn get(&self, index: &str) -> Option<&str> {
        self.names.get(index).map(String::as_str)
    }

    /// Sets a name. A blank name resets the chapter to its automatic name.
    pub fn set(&mut self, index: &str, name: &str) -> Result<(), String> {
        let name = name.trim();
        if name.is_empty() {
            self.reset(index);
            return Ok(());
        }
        if name.chars().count() > MAX_NAME_CHARS || name.chars().any(char::is_control) {
            return Err("Chapter names are bounded single lines without control characters".into());
        }
        if !self.names.contains_key(index) && self.names.len() >= MAX_OVERRIDES {
            return Err("Too many chapter name overrides".into());
        }
        self.names.insert(index.to_owned(), name.to_owned());
        Ok(())
    }

    pub fn reset(&mut self, index: &str) {
        self.names.remove(index);
    }

    pub fn reset_all(&mut self) {
        self.names.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    /// Renames chapters and their contents-list entries. Unknown indexes are ignored.
    pub fn apply(&self, book: &mut Book) {
        for chapter in &mut book.chapters {
            let Some(name) = self.get(&chapter.index) else {
                continue;
            };
            rename_toc(&mut book.toc, &chapter.source_path, name);
            chapter.name = name.to_owned();
        }
    }

    /// Missing file means no overrides; a corrupt file is an error, never silently dropped.
    pub fn load(path: impl AsRef<Path>) -> Result<Self, CacheError> {
        match read_json(path) {
            Err(CacheError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(Self::default())
            }
            other => other,
        }
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), CacheError> {
        atomic_write_json(path, self)
    }
}

fn rename_toc(items: &mut [crate::toc::TocItem], href: &str, name: &str) {
    for item in items {
        if item.href == href {
            item.title = name.to_owned();
        }
        rename_toc(&mut item.children, href, name);
    }
}

/// What a client draws when a book has no cover: the file name and a stable background.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilenameCover {
    pub label: String,
    pub background_rgb: [u8; 3],
}

/// Label is the file stem with separators turned into spaces; the color is derived from the
/// full file name (FNV-1a), so the same file always gets the same cover on every client.
pub fn filename_cover(file_name: &str) -> FilenameCover {
    let stem = Path::new(file_name)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let label = stem
        .chars()
        .map(|c| if matches!(c, '_' | '-' | '.') { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let mut hash: u32 = 0x811c_9dc5;
    for byte in file_name.bytes() {
        hash = (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193);
    }
    // Keep the channels in 40..=167 so white text always has contrast.
    let channel = |shift: u32| 40 + ((hash >> shift) & 0x7f) as u8;
    FilenameCover {
        label: if label.is_empty() {
            file_name.to_owned()
        } else {
            label
        },
        background_rgb: [channel(0), channel(8), channel(16)],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::epub::Chapter;
    use crate::toc::TocItem;

    fn book() -> Book {
        let chapter = |i: &str, name: &str| Chapter {
            index: i.into(),
            name: name.into(),
            source_path: format!("page-{i}"),
            text: "t".into(),
            paragraph_ends: vec![],
            heading_ends: vec![],
            level: 1,
            footnotes: vec![],
            note_marks: vec![],
            anchors: vec![],
        };
        Book {
            title: "B".into(),
            author: String::new(),
            language: None,
            chapters: vec![chapter("1", "Auto 1"), chapter("2", "Auto 2")],
            toc: vec![TocItem {
                title: "Auto 2".into(),
                href: "page-2".into(),
                level: 1,
                children: vec![],
            }],
            cover: None,
            cover_mime: None,
            skipped_documents: vec![],
            skipped_pages: 0,
        }
    }

    #[test]
    fn override_renames_chapter_and_contents_entry_and_reset_restores_it() {
        let mut names = ChapterNameOverrides::default();
        names.set("2", "  A Chegada ").unwrap();
        let mut renamed = book();
        names.apply(&mut renamed);
        assert_eq!(renamed.chapters[1].name, "A Chegada");
        assert_eq!(renamed.toc[0].title, "A Chegada");
        assert_eq!(renamed.chapters[0].name, "Auto 1");
        names.set("2", "   ").unwrap();
        assert!(names.is_empty());
        let mut restored = book();
        names.apply(&mut restored);
        assert_eq!(restored.chapters[1].name, "Auto 2");
    }

    #[test]
    fn invalid_names_are_rejected() {
        let mut names = ChapterNameOverrides::default();
        assert!(names.set("1", "two\nlines").is_err());
        assert!(names.set("1", &"x".repeat(201)).is_err());
        assert!(names.is_empty());
    }

    #[test]
    fn overrides_persist_and_a_missing_file_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("book/names.json");
        assert!(ChapterNameOverrides::load(&path).unwrap().is_empty());
        let mut names = ChapterNameOverrides::default();
        names.set("1", "Prólogo").unwrap();
        names.save(&path).unwrap();
        assert_eq!(ChapterNameOverrides::load(&path).unwrap(), names);
        std::fs::write(&path, "{broken").unwrap();
        assert!(ChapterNameOverrides::load(&path).is_err());
    }

    #[test]
    fn filename_cover_is_stable_and_labelled_from_the_stem() {
        let cover = filename_cover("Meu_livro-final.v2.pdf");
        assert_eq!(cover.label, "Meu livro final v2");
        assert_eq!(cover, filename_cover("Meu_livro-final.v2.pdf"));
        assert!(cover.background_rgb.iter().all(|c| (40..=167).contains(c)));
        assert_eq!(filename_cover("___.pdf").label, "___.pdf");
    }
}
