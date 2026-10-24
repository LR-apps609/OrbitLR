//! Testo in voce con le voci di Windows (System.Speech), poi MP3 con ffmpeg.
//! Il testo passa da un file temporaneo, mai dalla riga di comando: nessun carattere può diventare un comando.

use crate::args;
use crate::error::{EngineError, Result};
use crate::names;
use crate::run::{self, Cancel};
use crate::tools::{quiet, Tools};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct Voice {
    pub name: String,
    pub culture: String,
    pub gender: String,
}

fn powershell() -> Command {
    let mut c = quiet(Command::new("powershell.exe"));
    c.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]);
    c
}

/// Le voci installate (prima quelle italiane).
pub fn voices() -> Result<Vec<Voice>> {
    if !cfg!(windows) {
        return Ok(vec![]);
    }
    let script = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Speech; \
        $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; \
        $s.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name + '|' + $_.VoiceInfo.Culture.Name + '|' + $_.VoiceInfo.Gender }";
    let out = powershell().arg(script).output().map_err(|e| EngineError::new(format!("non riesco a leggere le voci di Windows: {e}")))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut v: Vec<Voice> = text
        .lines()
        .filter_map(|l| {
            let mut p = l.trim().splitn(3, '|');
            Some(Voice { name: p.next()?.to_string(), culture: p.next()?.to_string(), gender: p.next().unwrap_or("").to_string() })
        })
        .filter(|v| !v.name.is_empty())
        .collect();
    v.sort_by_key(|x| (!x.culture.starts_with("it"), x.name.clone()));
    Ok(v)
}

/// Scrive il testo in un file audio (MP3) nella cartella `dir`.
#[allow(clippy::too_many_arguments)]
pub fn speak(tools: &Tools, text: &str, voice: Option<&str>, rate: i32, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let text = text.trim();
    if text.is_empty() {
        return Err(EngineError::new("scrivi o incolla un testo"));
    }
    if text.chars().count() > 200_000 {
        return Err(EngineError::new("il testo è troppo lungo: dividilo in parti"));
    }
    if !cfg!(windows) {
        return Err(EngineError::new("la lettura con le voci di Windows funziona solo su Windows"));
    }
    std::fs::create_dir_all(dir)?;
    let first: String = text.split_whitespace().take(6).collect::<Vec<_>>().join(" ");
    let out = names::unique(dir, &format!("{} (voce)", if first.is_empty() { "Testo".into() } else { first }), "mp3");
    let txt = names::temp_beside(&out, "txt");
    let wav = names::temp_beside(&out, "wav");
    let cleanup = |a: &Path, b: &Path| {
        let _ = std::fs::remove_file(a);
        let _ = std::fs::remove_file(b);
        names::track_temp(a, false);
        names::track_temp(b, false);
    };
    std::fs::write(&txt, text.as_bytes())?;
    // Percorsi e voce passano come variabili d'ambiente, non dentro il comando
    let script = "Add-Type -AssemblyName System.Speech; \
        $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; \
        if ($env:ORBIT_VOCE) { try { $s.SelectVoice($env:ORBIT_VOCE) } catch {} }; \
        $s.Rate=[int]$env:ORBIT_VELOCITA; \
        $s.SetOutputToWaveFile($env:ORBIT_WAV); \
        $s.Speak([IO.File]::ReadAllText($env:ORBIT_TESTO, [Text.Encoding]::UTF8)); \
        $s.Dispose()";
    progress(0.05);
    let mut cmd = powershell();
    cmd.arg(script)
        .env("ORBIT_TESTO", &txt)
        .env("ORBIT_WAV", &wav)
        .env("ORBIT_VOCE", voice.unwrap_or(""))
        .env("ORBIT_VELOCITA", rate.clamp(-10, 10).to_string());
    let status = cmd.status().map_err(|e| EngineError::new(format!("non riesco ad avviare la voce di Windows: {e}")));
    if cancel.is_cancelled() {
        cleanup(&txt, &wav);
        return Err(EngineError::cancelled());
    }
    match status {
        Ok(s) if s.success() && wav.metadata().map(|m| m.len() > 100).unwrap_or(false) => {}
        Ok(_) => {
            cleanup(&txt, &wav);
            return Err(EngineError::new("la voce di Windows non è riuscita a leggere il testo"));
        }
        Err(e) => {
            cleanup(&txt, &wav);
            return Err(e);
        }
    }
    progress(0.6);
    let r = run::ffmpeg(tools, &args!["-i", &wav, "-c:a", "libmp3lame", "-q:a", "3", &out], 0.0, cancel, &mut |p| progress(0.6 + p * 0.4));
    cleanup(&txt, &wav);
    r?;
    Ok(out)
}
