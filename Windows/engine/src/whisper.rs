//! Trascrivi (testo e sottotitoli) con whisper.cpp, sul computer, senza internet
//! (internet serve solo la prima volta, per scaricare il modello: circa 190 MB, impronta controllata).

use crate::args;
use crate::error::{EngineError, Result};
use crate::names;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::{quiet, Tools};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;

/// Il modello: whisper «small» quantizzato (buono in italiano, veloce anche senza scheda video).
pub const MODEL_NAME: &str = "ggml-small-q5_1.bin";
pub const MODEL_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin";
/// Impronta e misura del modello (controllate dopo lo scaricamento). Vuota = non ancora fissata.
pub const MODEL_SHA256: &str = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb";
pub const MODEL_BYTES: u64 = 190_085_487;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Word {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    pub start: f64,
    pub end: f64,
    pub text: String,
    pub words: Vec<Word>,
}

pub fn model_path(data_dir: &Path) -> PathBuf {
    data_dir.join("modelli").join(MODEL_NAME)
}

pub fn model_ready(data_dir: &Path) -> bool {
    let p = model_path(data_dir);
    match p.metadata() {
        Ok(m) => m.len() > 50_000_000 && (MODEL_BYTES == 0 || m.len() == MODEL_BYTES),
        Err(_) => false,
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Scarica il modello (una volta sola), controllando l'impronta. `progress` tra 0 e 1.
pub fn download_model(data_dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    use sha2::{Digest, Sha256};
    let dest = model_path(data_dir);
    if model_ready(data_dir) {
        return Ok(dest);
    }
    std::fs::create_dir_all(dest.parent().unwrap())?;
    let part = dest.with_extension("parziale");
    let agent: ureq::Agent = ureq::Agent::config_builder().proxy(ureq::Proxy::try_from_env()).build().into();
    let mut resp = agent
        .get(MODEL_URL)
        .call()
        .map_err(|e| EngineError::new(format!("non riesco a scaricare il modello della voce (serve internet solo questa volta): {e}")))?;
    let total = resp.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(MODEL_BYTES);
    let mut reader = resp.body_mut().as_reader();
    let mut file = std::fs::File::create(&part)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut got: u64 = 0;
    loop {
        if cancel.is_cancelled() {
            drop(file);
            let _ = std::fs::remove_file(&part);
            return Err(EngineError::cancelled());
        }
        let n = reader.read(&mut buf).map_err(|e| EngineError::new(format!("scaricamento interrotto: {e}")))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        hasher.update(&buf[..n]);
        got += n as u64;
        if total > 0 {
            progress((got as f64 / total as f64).min(0.999));
        }
    }
    file.flush()?;
    drop(file);
    let sha = hex(&hasher.finalize());
    if got < 50_000_000 || (!MODEL_SHA256.is_empty() && sha != MODEL_SHA256) || (MODEL_BYTES > 0 && got != MODEL_BYTES) {
        let _ = std::fs::remove_file(&part);
        return Err(EngineError::new("il modello scaricato non è quello giusto (impronta diversa): riprova più tardi"));
    }
    std::fs::rename(&part, &dest)?;
    progress(1.0);
    Ok(dest)
}

/// Dal JSON completo di whisper.cpp: frasi con i tempi di ogni parola.
pub fn parse_json(j: &serde_json::Value) -> Vec<Segment> {
    let mut out = Vec::new();
    let Some(list) = j["transcription"].as_array() else { return out };
    for s in list {
        let text = s["text"].as_str().unwrap_or("").trim().to_string();
        if text.is_empty() {
            continue;
        }
        let ms = |v: &serde_json::Value| v.as_f64().unwrap_or(0.0) / 1000.0;
        let (start, end) = (ms(&s["offsets"]["from"]), ms(&s["offsets"]["to"]));
        let mut words: Vec<Word> = Vec::new();
        if let Some(tokens) = s["tokens"].as_array() {
            for t in tokens {
                let tt = t["text"].as_str().unwrap_or("");
                if tt.starts_with("[_") || tt.is_empty() {
                    continue;
                }
                let (a, b) = (ms(&t["offsets"]["from"]), ms(&t["offsets"]["to"]));
                // Un pezzo che comincia con lo spazio è una parola nuova; gli altri si attaccano
                if tt.starts_with(' ') || words.is_empty() {
                    let w = tt.trim();
                    if w.is_empty() {
                        continue;
                    }
                    words.push(Word { text: w.to_string(), start: a, end: b });
                } else if let Some(last) = words.last_mut() {
                    last.text.push_str(tt);
                    last.end = b;
                }
            }
        }
        out.push(Segment { start, end, text, words });
    }
    out
}

fn srt_time(t: f64) -> String {
    let ms = (t.max(0.0) * 1000.0).round() as u64;
    format!("{:02}:{:02}:{:02},{:03}", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
}

pub fn to_srt(segs: &[Segment]) -> String {
    let mut s = String::new();
    for (i, g) in segs.iter().enumerate() {
        s.push_str(&format!("{}\n{} --> {}\n{}\n\n", i + 1, srt_time(g.start), srt_time(g.end.max(g.start + 0.5)), g.text));
    }
    s
}

/// Il testo in paragrafi: si va a capo dopo una pausa lunga.
pub fn to_text(segs: &[Segment]) -> String {
    let mut s = String::new();
    let mut last_end = 0.0;
    for g in segs {
        if !s.is_empty() {
            s.push_str(if g.start - last_end > 1.5 { "\n\n" } else { " " });
        }
        s.push_str(&g.text);
        last_end = g.end;
    }
    s.push('\n');
    s
}

/// Trascrive un file (anche l'audio di un video). `exe` = whisper-cli.exe; `lang` = «auto», «it», «en»…
#[allow(clippy::too_many_arguments)]
pub fn transcribe(tools: &Tools, exe: &Path, model: &Path, src: &Path, info: &FileInfo, lang: &str, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<Segment>> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    if !exe.is_file() {
        return Err(EngineError::new("manca il motore della voce: reinstalla OrbitLR"));
    }
    let work = std::env::temp_dir().join(format!("orbitlr-voce-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)));
    std::fs::create_dir_all(&work)?;
    struct Clean(PathBuf);
    impl Drop for Clean {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _clean = Clean(work.clone());
    let wav = work.join("audio.wav");
    // 1) Audio a 16 kHz mono (quello che vuole whisper): 10% dell'avanzamento
    run::ffmpeg(tools, &args!["-i", src, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", &wav], info.duration, cancel, &mut |p| progress(p * 0.1))?;
    // 2) Trascrizione
    let base = work.join("risultato");
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8);
    let lang = if lang.chars().all(|c| c.is_ascii_alphabetic()) && (lang.len() == 2 || lang == "auto") { lang } else { "auto" };
    let mut cmd = quiet(std::process::Command::new(exe));
    cmd.arg("-m").arg(model).arg("-f").arg(&wav).args(["-l", lang, "-t", &threads.to_string(), "-ojf", "-pp", "-of"]).arg(&base);
    cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| EngineError::new(format!("non riesco ad avviare il motore della voce: {e}")))?;
    crate::tools::bind_to_app(&child);
    let stderr = child.stderr.take();
    let cancel2 = cancel.clone();
    // L'avanzamento arriva su stderr: «progress = 35%»
    let (tx, rx) = std::sync::mpsc::channel::<f64>();
    let reader = std::thread::spawn(move || {
        let mut tail = String::new();
        if let Some(e) = stderr {
            for line in BufReader::new(e).lines().map_while(|l| l.ok()) {
                if let Some(p) = line.split("progress =").nth(1).and_then(|x| x.trim().trim_end_matches('%').trim().parse::<f64>().ok()) {
                    let _ = tx.send(p / 100.0);
                }
                tail.push_str(&line);
                tail.push('\n');
                if tail.len() > 8000 {
                    tail.drain(..4000);
                }
            }
        }
        tail
    });
    let status = loop {
        while let Ok(p) = rx.try_recv() {
            progress(0.1 + p * 0.88);
        }
        if cancel2.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::cancelled());
        }
        match child.try_wait()? {
            Some(st) => break st,
            None => std::thread::sleep(std::time::Duration::from_millis(100)),
        }
    };
    let tail = reader.join().unwrap_or_default();
    if !status.success() {
        let last = tail.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("errore sconosciuto");
        return Err(EngineError::new(format!("la trascrizione si è fermata: {}", last.chars().take(200).collect::<String>())));
    }
    let json = std::fs::read(base.with_extension("json")).map_err(|_| EngineError::new("la trascrizione non ha prodotto risultati"))?;
    let v: serde_json::Value = serde_json::from_slice(&json).map_err(|_| EngineError::new("risultato della trascrizione non leggibile"))?;
    let segs = parse_json(&v);
    if segs.is_empty() {
        return Err(EngineError::new("non ho sentito parole in questo file"));
    }
    progress(1.0);
    Ok(segs)
}

/// «Trascrivi»: testo (.txt) e sottotitoli (.srt) accanto al file.
#[allow(clippy::too_many_arguments)]
pub fn transcribe_files(tools: &Tools, exe: &Path, model: &Path, src: &Path, info: &FileInfo, lang: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<PathBuf>> {
    let segs = transcribe(tools, exe, model, src, info, lang, cancel, progress)?;
    let txt = names::OutFile::new(dir, &format!("{} (trascrizione)", names::stem(src)), "txt")?;
    std::fs::write(&txt.tmp, to_text(&segs))?;
    let srt = names::OutFile::new(dir, &names::stem(src), "srt")?;
    std::fs::write(&srt.tmp, to_srt(&segs))?;
    Ok(vec![txt.commit()?, srt.commit()?])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dal_json_alle_parole() {
        let j: serde_json::Value = serde_json::from_str(r#"{"transcription":[
          {"offsets":{"from":0,"to":2400},"text":" Ciao a tutti.","tokens":[
            {"text":"[_BEG_]","offsets":{"from":0,"to":0}},
            {"text":" Ciao","offsets":{"from":100,"to":500}},
            {"text":" a","offsets":{"from":600,"to":700}},
            {"text":" tut","offsets":{"from":800,"to":1000}},
            {"text":"ti.","offsets":{"from":1000,"to":1400}},
            {"text":"[_TT_120]","offsets":{"from":2400,"to":2400}}]},
          {"offsets":{"from":5000,"to":6000},"text":" Seconda frase","tokens":[]}]}"#).unwrap();
        let s = parse_json(&j);
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), vec!["Ciao", "a", "tutti."]);
        assert!((s[0].words[2].end - 1.4).abs() < 1e-9);
        assert_eq!(to_srt(&s).lines().nth(1), Some("00:00:00,000 --> 00:00:02,400"));
        assert_eq!(to_text(&s), "Ciao a tutti.\n\nSeconda frase\n");
    }
}
