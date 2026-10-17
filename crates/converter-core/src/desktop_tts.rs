//! Installed desktop speech isolated from Piper's in-process phonemizer.
use crate::platform_tts::PlatformTts;
use std::{
    path::Path,
    process::{Command, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct DesktopPlatformTts {
    gate: Mutex<()>,
}

impl PlatformTts for DesktopPlatformTts {
    fn backend_name(&self) -> &'static str {
        if cfg!(target_os = "linux") {
            "eSpeak NG (installed)"
        } else if cfg!(target_os = "windows") {
            "Windows SAPI (installed)"
        } else {
            "unavailable desktop backend"
        }
    }
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        let started = Instant::now();
        let expired = || cancelled() || started.elapsed() >= Duration::from_secs(30);
        let _guard = loop {
            if expired() {
                return Err("System speech cancelled or timed out".into());
            }
            match self.gate.try_lock() {
                Ok(guard) => break guard,
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err("System speech lock poisoned".into())
                }
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(Duration::from_millis(20))
                }
            }
        };
        if language.is_empty()
            || !language
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err("Invalid system speech language".into());
        }
        let language = normalized_language(language);
        let temporary = tempfile::tempdir().map_err(|e| e.to_string())?;
        let input = temporary.path().join("speech.txt");
        let wav = temporary.path().join("speech.wav");
        std::fs::write(&input, text).map_err(|e| e.to_string())?;
        let mut command = backend_command(language, &input, &wav)?;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = command
            .spawn()
            .map_err(|e| format!("Installed native speech backend unavailable: {e}"))?;
        wait_for_speech(&mut child, &wav, &expired)?;
        if expired() {
            return Err("System speech cancelled or timed out".into());
        }
        let bytes = std::fs::read(&wav).map_err(|e| e.to_string())?;
        if bytes.len() > 64 * 1024 * 1024 {
            return Err("System speech exceeded output limit".into());
        }
        crate::platform_tts::encode_wav(&bytes)?;
        if expired() {
            return Err("System speech cancelled or timed out".into());
        }
        std::fs::write(output, bytes).map_err(|e| e.to_string())
    }
}

fn normalized_language(language: &str) -> &str {
    if language.eq_ignore_ascii_case("pt") {
        "pt-BR"
    } else if language.eq_ignore_ascii_case("en") {
        "en-US"
    } else if language.eq_ignore_ascii_case("es") {
        "es-ES"
    } else {
        language
    }
}

fn wait_for_speech(
    child: &mut std::process::Child,
    wav: &Path,
    expired: &dyn Fn() -> bool,
) -> Result<(), String> {
    loop {
        if expired() || std::fs::metadata(wav).is_ok_and(|m| m.len() > 64 * 1024 * 1024) {
            let _ = child.kill();
            let _ = child.wait();
            return Err("System speech cancelled, timed out or exceeded output limit".into());
        }
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                return Err(format!(
                    "Installed native speech failed ({status}); verify a compatible offline voice"
                ))
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.to_string());
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn backend_command(language: &str, input: &Path, wav: &Path) -> Result<Command, String> {
    let mut command = Command::new("espeak-ng");
    command
        .arg("-v")
        .arg(language.replace('_', "-").to_ascii_lowercase())
        .arg("-w")
        .arg(wav)
        .arg("-f")
        .arg(input);
    Ok(command)
}

#[cfg(target_os = "windows")]
fn backend_command(language: &str, input: &Path, wav: &Path) -> Result<Command, String> {
    // Fixed script only: user data passes via environment/files, never interpolation.
    // SAPI stream synthesis stays in the owned child COM apartment.
    const SCRIPT: &str = r#"
$ErrorActionPreference='Stop'
$voice=New-Object -ComObject SAPI.SpVoice
$stream=New-Object -ComObject SAPI.SpFileStream
try {
  $culture=[Globalization.CultureInfo]::GetCultureInfo($env:EPUB_TTS_LANGUAGE.Replace('_','-'))
  $lcid=$culture.LCID.ToString('x')
  $tokens=@($voice.GetVoices() | Where-Object { ($_.GetAttribute('Language') -split ';') -contains $lcid } | Sort-Object Id)
  if ($tokens.Count -eq 0) { throw 'No installed compatible SAPI voice' }
  $voice.Voice=$tokens[0]
  $stream.Format.Type=22
  $stream.Open($env:EPUB_TTS_WAV,3,$false)
  $voice.AudioOutputStream=$stream
  $null=$voice.Speak([IO.File]::ReadAllText($env:EPUB_TTS_INPUT,[Text.Encoding]::UTF8),0)
  $stream.Close()
} finally {
  [Runtime.InteropServices.Marshal]::FinalReleaseComObject($stream) | Out-Null
  [Runtime.InteropServices.Marshal]::FinalReleaseComObject($voice) | Out-Null
}
"#;
    let mut command = Command::new("powershell.exe");
    command
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            SCRIPT,
        ])
        .env("EPUB_TTS_LANGUAGE", language)
        .env("EPUB_TTS_INPUT", input)
        .env("EPUB_TTS_WAV", wav);
    Ok(command)
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
fn backend_command(_: &str, _: &Path, _: &Path) -> Result<Command, String> {
    Err("This platform requires its app-provided native speech adapter".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn neutral_languages_resolve_without_changing_explicit_regions() {
        assert_eq!(normalized_language("pt"), "pt-BR");
        assert_eq!(normalized_language("en"), "en-US");
        assert_eq!(normalized_language("es"), "es-ES");
        assert_eq!(normalized_language("pt-PT"), "pt-PT");
    }
    #[cfg(unix)]
    #[test]
    fn subprocess_deadline_kills_and_reaps_before_returning() {
        let temp = tempfile::tempdir().unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let started = Instant::now();
        assert!(
            wait_for_speech(&mut child, &temp.path().join("unused.wav"), &|| started
                .elapsed()
                > Duration::from_millis(30))
            .is_err()
        );
        assert!(child.try_wait().unwrap().is_some());
        assert!(started.elapsed() < Duration::from_secs(5));
    }
    #[cfg(unix)]
    #[test]
    fn failed_subprocess_cannot_publish_output() {
        let temp = tempfile::tempdir().unwrap();
        let mut child = Command::new("/usr/bin/false").spawn().unwrap();
        let path = temp.path().join("absent.wav");
        assert!(wait_for_speech(&mut child, &path, &|| false).is_err());
        assert!(!path.exists());
    }
    #[test]
    fn cancellation_never_spawns_or_publishes() {
        let temp = tempfile::tempdir().unwrap();
        let out = temp.path().join("cancelled.wav");
        assert!(DesktopPlatformTts::default()
            .synthesize_wav("Olá", "pt-BR", &out, &|| true)
            .is_err());
        assert!(!out.exists());
    }
    #[test]
    fn installed_native_speech_produces_valid_audio() {
        if std::env::var_os("EPUB_TEST_NATIVE_TTS").is_none() {
            return;
        }
        let language =
            std::env::var("EPUB_TEST_NATIVE_LANGUAGE").unwrap_or_else(|_| "pt-BR".into());
        let temp = tempfile::tempdir().unwrap();
        let out = temp.path().join("native.wav");
        DesktopPlatformTts::default()
            .synthesize_wav(
                "Olá, este é um teste de leitura.",
                &language,
                &out,
                &|| false,
            )
            .unwrap();
        assert!(
            !crate::platform_tts::encode_wav(&std::fs::read(out).unwrap())
                .unwrap()
                .is_empty()
        );
    }
}
