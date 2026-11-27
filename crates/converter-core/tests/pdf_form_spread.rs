//! Pages cut from a two-page spread: each one draws the whole spread through a
//! Form XObject and shows only its half, so each sentence belongs to one page.
use converter_core::ingestion::pdf_text::PdfTextIngestion;
use pdf_extract::{dictionary, Document, Object, Stream};
use std::path::Path;

/// How a cut page shifts the spread and hides the other half.
#[derive(Clone, Copy)]
enum Cut {
    /// A wrapper Form whose BBox is one page wide.
    WrapperBBox,
    /// The page shifts the spread itself, so only the page box hides a half.
    PageBox,
    /// The wrapper shifts through its /Matrix and its BBox selects the half.
    FormMatrix,
}

fn spread_pdf(cut: Cut) -> Vec<u8> {
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
            let (left, matrix, operations) = match cut {
                Cut::FormMatrix => (-shift, shift, "/S Do".to_string()),
                _ => (0, 0, format!("q 1 0 0 1 {shift} 0 cm /S Do Q")),
            };
            let half = doc.add_object(Stream::new(
                dictionary! {
                    "Type" => "XObject", "Subtype" => "Form",
                    "BBox" => vec![left.into(), 0.into(), (left + 400).into(), 600.into()],
                    "Matrix" => vec![1.into(), 0.into(), 0.into(), 1.into(), matrix.into(), 0.into()],
                    "Resources" => dictionary! { "XObject" => dictionary! { "S" => spread } },
                },
                operations.clone().into_bytes(),
            ));
            let (name, drawn, page_content) = match cut {
                Cut::PageBox => ("S", spread, operations),
                _ => ("H", half, "q /H Do Q".to_string()),
            };
            let content = doc.add_object(Stream::new(dictionary! {}, page_content.into_bytes()));
            doc.add_object(dictionary! {
                "Type" => "Page", "Parent" => pages_id,
                "MediaBox" => vec![0.into(), 0.into(), 400.into(), 600.into()],
                "Contents" => content,
                "Resources" => dictionary! { "XObject" => dictionary! { name => drawn } },
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

fn page_texts(cut: Cut) -> Vec<String> {
    let book = PdfTextIngestion::from_bytes(Path::new("spread.pdf"), &spread_pdf(cut)).unwrap();
    book.chapters.into_iter().map(|c| c.text).collect()
}

#[test]
fn each_half_of_a_cut_spread_is_read_once() {
    assert_eq!(
        page_texts(Cut::WrapperBBox),
        ["Leftsentence.", "Rightsentence."]
    );
}

#[test]
fn the_page_box_hides_the_half_a_form_draws_outside_it() {
    assert_eq!(
        page_texts(Cut::PageBox),
        ["Leftsentence.", "Rightsentence."]
    );
}

#[test]
fn a_form_matrix_places_the_visible_half() {
    assert_eq!(
        page_texts(Cut::FormMatrix),
        ["Leftsentence.", "Rightsentence."]
    );
}
