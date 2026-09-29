use edge_tts_rust::{EdgeTtsClient, SpeakOptions};
use std::io::Read;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    let client = EdgeTtsClient::builder()
        .ws_pool_size(1)
        .ws_warmup(false)
        .request_chunk_reuse(true)
        .receive_timeout(std::time::Duration::from_secs(30))
        .build()?;
    let result = client
        .synthesize(
            text,
            SpeakOptions {
                voice: "pt-BR-FranciscaNeural".into(),
                ..SpeakOptions::default()
            },
        )
        .await?;
    println!("audio={}", result.audio.len());
    Ok(())
}
