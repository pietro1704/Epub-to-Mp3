use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReaderBook {
    pub book_title: String,
    pub book_author: String,
    pub language: Option<String>,
    pub chapters: Vec<SourceChapter>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceChapter {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub level: u32,
    pub text: String,
    pub html: String,
    pub css: String,
    /// Where each TOC fragment of this file sits on `text`, in scalars; the file stays one chapter.
    pub anchors: Vec<ChapterAnchor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChapterAnchor {
    pub id: String,
    pub offset: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChapterRequest {
    pub version: u32,
    pub html: Option<String>,
    #[serde(default)]
    pub text: String,
    pub css: Option<String>,
    #[serde(default)]
    pub preferences: ReaderPreferences,
    #[serde(default)]
    pub search_text: String,
    #[serde(default)]
    pub audio_text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReaderPreferences {
    pub font_scale: f64,
    pub line_height: f64,
    pub width_rem: f64,
}

impl Default for ReaderPreferences {
    fn default() -> Self {
        Self {
            font_scale: 1.05,
            line_height: 1.75,
            width_rem: 48.0,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReaderChapter {
    pub version: u32,
    pub offset_unit: &'static str,
    pub text: String,
    pub css: String,
    pub pages: Vec<ReaderPage>,
    pub search_matches: Vec<ReaderMatch>,
    pub audio_match: Option<ReaderMatch>,
    pub anchors: Vec<ReaderAnchor>,
}

#[derive(Debug, Serialize)]
pub struct ReaderPage {
    pub html: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReaderMatch {
    pub start: usize,
    pub end: usize,
    pub page_index: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReaderAnchor {
    pub id: String,
    pub page_index: usize,
}
