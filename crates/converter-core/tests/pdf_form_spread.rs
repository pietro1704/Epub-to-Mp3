//! Pages cut from a two-page spread: each one draws the whole spread through a
//! Form XObject and shows only its half, so each sentence belongs to one page.
use converter_core::ingestion::pdf_text::PdfTextIngestion;
use pdf_extract::{dictionary, Document, Object, Stream};
use std::path::Path;

fn spread_pdf() -> Vec<u8> {
    let mut doc = Document::with_version("1.7");
    let font = doc.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
    });
    let spread = doc.add_object(Stream::new(
        dictionary! {
            "Type" => "XObject", "Subtype" => "Form",
            "BBox" => vec![0.into(), 0.into(), 800.into(), 600.into()],
            "Resources" => dictionary! { "Font" => dictionary! { "F1" => font } },
        },
        b"BT /F1 12 Tf 40 500 Td (Leftsentence.) Tj ET BT /F1 12 Tf 440 500 Td (Rightsentence.) Tj ET"
            .to_vec(),
    ));
    let pages_id = doc.new_object_id();
    let kids: Vec<Object> = [0, -400]
        .into_iter()
        .map(|shift| {
            let half = doc.add_object(Stream::new(
                dictionary! {
                    "Type" => "XObject", "Subtype" => "Form",
                    "BBox" => vec![0.into(), 0.into(), 400.into(), 600.into()],
                    "Resources" => dictionary! { "XObject" => dictionary! { "S" => spread } },
                },
                format!("q 1 0 0 1 {shift} 0 cm /S Do Q").into_bytes(),
            ));
            let content = doc.add_object(Stream::new(dictionary! {}, b"q /H Do Q".to_vec()));
            doc.add_object(dictionary! {
                "Type" => "Page", "Parent" => pages_id,
                "MediaBox" => vec![0.into(), 0.into(), 400.into(), 600.into()],
                "Contents" => content,
                "Resources" => dictionary! { "XObject" => dictionary! { "H" => half } },
            })
            .into()
        })
        .collect();
    doc.objects.insert(
        pages_id,
        dictionary! { "Type" => "Pages", "Kids" => kids, "Count" => 2 }.into(),
    );
    let catalog = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog);
    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).unwrap();
    bytes
}

#[test]
fn each_half_of_a_cut_spread_is_read_once() {
    let book = PdfTextIngestion::from_bytes(Path::new("spread.pdf"), &spread_pdf()).unwrap();
    let pages: Vec<&str> = book.chapters.iter().map(|c| c.text.as_str()).collect();
    assert_eq!(pages, ["Leftsentence.", "Rightsentence."]);
}
