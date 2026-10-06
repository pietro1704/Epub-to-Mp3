use converter_core::tts::synthesize_with_reference_client;
use std::io::Read;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    let audio = synthesize_with_reference_client(&text, "pt-BR-FranciscaNeural").await?;
    println!("audio={}", audio.len());
    Ok(())
}
