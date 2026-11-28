//! Text a client OCR recognised for the image-only pages of a PDF, kept in a sidecar file
//! next to the book (`<book>.ocr.json`, page number -> text) and read back on every open.
use crate::ingestion::pdf_text::PageOcr;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OcrPages {
    pub pages: BTreeMap<u32, String>,
}

impl OcrPages {
    pub fn sidecar_path(book: &Path) -> PathBuf {
        let mut name = book.as_os_str().to_owned();
        name.push(".ocr.json");
        PathBuf::from(name)
    }

    /// Blank text clears the page.
    pub fn set(&mut self, page: u32, text: &str) {
        if text.trim().is_empty() {
            self.pages.remove(&page);
        } else {
            self.pages.insert(page, text.trim().to_owned());
        }
    }

    /// A missing sidecar means no recognised pages; a corrupt one is an error.
    pub fn load(book: &Path) -> Result<Self, crate::cache::CacheError> {
        match crate::cache::read_json(Self::sidecar_path(book)) {
            Err(crate::cache::CacheError::Io(error))
                if error.kind() == std::io::ErrorKind::NotFound =>
            {
                Ok(Self::default())
            }
            other => other,
        }
    }

    pub fn save(&self, book: &Path) -> Result<(), crate::cache::CacheError> {
        let sidecar = Self::sidecar_path(book);
        if self.pages.is_empty() {
            return match std::fs::remove_file(sidecar) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
                _ => Ok(()),
            };
        }
        crate::cache::atomic_write_json(sidecar, self)
    }
}

impl PageOcr for OcrPages {
    fn recognize(&self, page_number: u32) -> Option<String> {
        self.pages.get(&page_number).cloned()
    }
}
