use converter_core::tts::synthesize_with_reference_client;
use converter_core::adaptive::AdaptiveThroughputController;
use std::io::Read;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    let started = std::time::Instant::now();
    let audio = synthesize_with_reference_client(
        &text,
        "pt-BR-FranciscaNeural",
        Arc::new(AdaptiveThroughputController::default()),
        None,
    )
    .await?;
    eprintln!("elapsed_s={:.3}", started.elapsed().as_secs_f64());
    if let Some(path) = std::env::args().nth(1) {
        std::fs::write(&path, &audio)?;
        println!("audio_path={path}");
    }
    println!("audio={}", audio.len());
    Ok(())
}
