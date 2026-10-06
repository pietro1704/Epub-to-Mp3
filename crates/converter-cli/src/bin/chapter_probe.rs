use converter_core::epub::parse_epub;
use std::{fs::File, io::BufReader};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("missing EPUB path")?;
    let index = std::env::args()
        .nth(2)
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(1);
    let book = parse_epub(BufReader::new(File::open(path)?))?;
    let chapter = book.chapters.get(index - 1).ok_or("no chapter")?;
    print!("{}", chapter.text);
    Ok(())
}
