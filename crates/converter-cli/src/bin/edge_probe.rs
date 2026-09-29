use edge_tts_rust::{EdgeTtsClient, SpeakOptions};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = EdgeTtsClient::new()?;
    let result = client
        .synthesize(
            "Teste de síntese em português brasileiro.",
            SpeakOptions {
                voice: "pt-BR-FranciscaNeural".into(),
                ..SpeakOptions::default()
            },
        )
        .await?;
    println!("edge-tts-rust audio bytes: {}", result.audio.len());
    Ok(())
}
