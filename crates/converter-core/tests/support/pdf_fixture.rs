/// A tiny standards-shaped PDF built independently of the extraction library.
pub fn pdf(outline: bool, texts: &[&str]) -> Vec<u8> {
    pdf_with(outline, texts, |_| {})
}

pub fn pdf_with(outline: bool, texts: &[&str], change: impl FnOnce(&mut Vec<String>)) -> Vec<u8> {
    let mut objects = vec![String::new(), String::new()];
    let mut pages = Vec::new();
    for text in texts {
        let page = objects.len() + 1;
        pages.push(page);
        objects.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {} 0 R >>", page + 1));
        let escaped = text
            .replace('\\', "\\\\")
            .replace('(', "\\(")
            .replace(')', "\\)");
        let stream = format!("BT /F1 12 Tf 50 700 Td ({escaped}) Tj ET");
        objects.push(format!(
            "<< /Length {} >>\nstream\n{stream}\nendstream",
            stream.len()
        ));
    }
    let info = objects.len() + 1;
    objects.push("<< /Title (PDF fixture) /Author (Fixture author) >>".into());
    let outlines = if outline {
        let root = objects.len() + 1;
        objects.push(format!(
            "<< /Type /Outlines /First {} 0 R /Last {} 0 R /Count 2 >>",
            root + 1,
            root + 2
        ));
        objects.push(format!(
            "<< /Title (First section) /Parent {root} 0 R /Next {} 0 R /Dest [{} 0 R /Fit] >>",
            root + 2,
            pages[0]
        ));
        objects.push(format!(
            "<< /Title (Second section) /Parent {root} 0 R /Prev {} 0 R /Dest [{} 0 R /Fit] >>",
            root + 1,
            pages[2]
        ));
        format!("/Outlines {root} 0 R")
    } else {
        String::new()
    };
    objects[0] = format!("<< /Type /Catalog /Pages 2 0 R /Lang (pt-BR) {outlines} /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /St 1 >>] >> >>");
    objects[1] = format!(
        "<< /Type /Pages /Count {} /Kids [{}] >>",
        pages.len(),
        pages
            .iter()
            .map(|id| format!("{id} 0 R"))
            .collect::<Vec<_>>()
            .join(" ")
    );
    change(&mut objects);
    let mut bytes = b"%PDF-1.7\n".to_vec();
    let mut offsets = vec![0];
    for (index, object) in objects.iter().enumerate() {
        offsets.push(bytes.len());
        bytes.extend_from_slice(format!("{} 0 obj\n{object}\nendobj\n", index + 1).as_bytes());
    }
    let xref = bytes.len();
    bytes.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", offsets.len()).as_bytes());
    for offset in &offsets[1..] {
        bytes.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R /Info {info} 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            offsets.len()
        )
        .as_bytes(),
    );
    bytes
}
