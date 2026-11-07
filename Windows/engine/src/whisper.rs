//! Trascrivi (testo e sottotitoli) con whisper.cpp, sul computer, senza internet
//! (internet serve solo la prima volta, per scaricare il modello: circa 190 MB, impronta controllata).

use crate::args;
use crate::error::{EngineError, Result};
use crate::names;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::{quiet, Tools};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader};
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

/// Scarica il modello (una volta sola), controllando l'impronta. `progress` tra 0 e 1.
pub fn download_model(data_dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let item = crate::download::Item { url: MODEL_URL, sha256: MODEL_SHA256, bytes: MODEL_BYTES, what: "il modello della voce" };
    crate::download::fetch(&item, &model_path(data_dir), cancel, progress)
}

/// Dal JSON di whisper.cpp con una parola per segmento (-ml 1 -sow): le parole con i tempi,
/// raggruppate in frasi da leggere comode (7 parole, 42 caratteri, 3,5 s; a capo alle pause e ai punti).
pub fn parse_words_json(j: &serde_json::Value) -> Vec<Segment> {
    let mut words: Vec<Word> = Vec::new();
    if let Some(list) = j["transcription"].as_array() {
        for s in list {
            let t = s["text"].as_str().unwrap_or("").trim();
            if t.is_empty() || t.starts_with('[') {
                continue;
            }
            let ms = |v: &serde_json::Value| v.as_f64().unwrap_or(0.0) / 1000.0;
            words.push(Word { text: t.to_string(), start: ms(&s["offsets"]["from"]), end: ms(&s["offsets"]["to"]) });
        }
    }
    group_words(&words)
}

pub fn group_words(words: &[Word]) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    let mut cur: Vec<Word> = Vec::new();
    let flush = |cur: &mut Vec<Word>, out: &mut Vec<Segment>| {
        if let (Some(a), Some(b)) = (cur.first(), cur.last()) {
            out.push(Segment { start: a.start, end: b.end.max(a.start + 0.5), text: cur.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" "), words: cur.clone() });
        }
        cur.clear();
    };
    for w in words {
        if let (Some(first), Some(last)) = (cur.first(), cur.last()) {
            let chars: usize = cur.iter().map(|x| x.text.chars().count() + 1).sum::<usize>() + w.text.chars().count();
            if w.start - last.end > 0.6 || cur.len() >= 7 || chars > 42 || w.end - first.start > 3.5 {
                flush(&mut cur, &mut out);
            }
        }
        cur.push(w.clone());
        if w.text.ends_with(['.', '!', '?']) {
            flush(&mut cur, &mut out);
        }
    }
    flush(&mut cur, &mut out);
    out
}

/// Dal JSON completo di whisper.cpp (pezzi di parole): frasi con i tempi di ogni parola.
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

// ── 2.0.1 · Percorsi con lettere non latine (cirillico, cinese, emoji)
// whisper.cpp apre modello e audio con le funzioni «strette» di Windows (fopen): un percorso fuori dalla
// tabella di caratteri del sistema non si apre. A whisper si passano solo percorsi ASCII: la cartella di
// lavoro (con il nome corto 8.3 di Windows, o una cartella di riserva) e il modello (nome corto, oppure un
// collegamento o una copia nella cartella di lavoro). Il file da trascrivere lo legge ffmpeg, che li sa aprire.

fn is_ascii_path(p: &Path) -> bool {
    p.to_str().is_some_and(|s| s.is_ascii())
}

/// Il nome corto (8.3) di un percorso che esiste, se è tutto ASCII.
#[cfg(windows)]
fn short_ascii(p: &Path) -> Option<PathBuf> {
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;
    let wide: Vec<u16> = p.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut buf = vec![0u16; 2048];
    let n = unsafe { GetShortPathNameW(wide.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) } as usize;
    if n == 0 || n >= buf.len() {
        return None;
    }
    let s = PathBuf::from(std::ffi::OsString::from_wide(&buf[..n]));
    is_ascii_path(&s).then_some(s)
}

#[cfg(not(windows))]
fn short_ascii(_: &Path) -> Option<PathBuf> {
    None
}

/// Una cartella di lavoro nuova con un percorso ASCII: dentro `base` se si può, altrimenti in una di riserva.
pub fn ascii_work_dir(base: &Path, name: &str) -> Result<PathBuf> {
    let mut places = vec![base.to_path_buf()];
    for var in ["ProgramData", "PUBLIC"] {
        if let Some(v) = std::env::var_os(var) {
            places.push(PathBuf::from(v).join("OrbitLR"));
        }
    }
    if let Some(d) = std::env::var_os("SystemDrive") {
        places.push(PathBuf::from(format!("{}\\OrbitLR-temp", d.to_string_lossy())));
    }
    if !cfg!(windows) {
        places.push(PathBuf::from("/tmp"));
    }
    for p in places {
        let dir = p.join(name);
        if std::fs::create_dir_all(&dir).is_err() {
            continue;
        }
        if is_ascii_path(&dir) {
            return Ok(dir);
        }
        if let Some(s) = short_ascii(&dir) {
            return Ok(s);
        }
        let _ = std::fs::remove_dir(&dir);
    }
    Err(EngineError::new("non trovo una cartella senza lettere speciali per il motore della voce"))
}

/// Il modello con un percorso ASCII: com'è, con il nome corto, oppure collegato (o copiato) nella cartella di lavoro.
pub fn ascii_model(model: &Path, work: &Path) -> Result<PathBuf> {
    if is_ascii_path(model) {
        return Ok(model.to_path_buf());
    }
    if let Some(s) = short_ascii(model) {
        return Ok(s);
    }
    let m = work.join("modello.bin");
    if std::fs::hard_link(model, &m).is_err() {
        std::fs::copy(model, &m)?;
    }
    Ok(m)
}

/// Una frase chiara per quando whisper-cli si ferma (mai le righe del suo aiuto o un codice esadecimale).
pub fn whisper_failure(code: Option<i32>, tail: &str) -> String {
    let low = tail.to_lowercase();
    if low.contains("failed to open") || low.contains("failed to load model") || low.contains("no such file") || low.contains("usage:") || low.contains("error: unknown argument") {
        "il motore della voce non riesce ad aprire il modello o l'audio: riprova; se continua, reinstalla OrbitLR".into()
    } else if low.contains("not enough memory") || low.contains("failed to allocate") || low.contains("bad_alloc") {
        "memoria insufficiente per la trascrizione: chiudi altre app e riprova".into()
    } else if matches!(code, Some(c) if c < 0 || c > 255) {
        "il motore della voce si è chiuso all'improvviso: riprova; se continua, reinstalla OrbitLR".into()
    } else {
        "la trascrizione si è fermata: riprova; se continua, reinstalla OrbitLR".into()
    }
}

/// Trascrive un file (anche l'audio di un video). `exe` = whisper-cli.exe; `lang` = «auto», «it», «en»…
#[allow(clippy::too_many_arguments)]
pub fn transcribe(tools: &Tools, exe: &Path, model: &Path, src: &Path, info: &FileInfo, lang: &str, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<Segment>> {
    transcribe_in(&std::env::temp_dir(), tools, exe, model, src, info, lang, cancel, progress)
}

/// Come `transcribe`, con la cartella temporanea scelta (per le prove con percorsi non latini).
#[allow(clippy::too_many_arguments)]
pub fn transcribe_in(tmp: &Path, tools: &Tools, exe: &Path, model: &Path, src: &Path, info: &FileInfo, lang: &str, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<Segment>> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    if !exe.is_file() {
        return Err(EngineError::new("manca il motore della voce: reinstalla OrbitLR"));
    }
    let name = format!("orbitlr-voce-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    let work = ascii_work_dir(tmp, &name)?;
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
    let model = ascii_model(model, &work)?;
    let mut cmd = quiet(std::process::Command::new(exe));
    cmd.current_dir(&work).arg("-m").arg(&model).arg("-f").arg(&wav).args(["-l", lang, "-t", &threads.to_string(), "-ml", "1", "-sow", "-oj", "-pp", "-of"]).arg(&base);
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
            let mut r = BufReader::new(e);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match r.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let line = String::from_utf8_lossy(&buf);
                if let Some(p) = line.split("progress =").nth(1).and_then(|x| x.trim().trim_end_matches('%').trim().parse::<f64>().ok()) {
                    let _ = tx.send(p / 100.0);
                }
                tail.push_str(&line);
                if tail.chars().count() > 8000 {
                    tail = tail.chars().skip(4000).collect();
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
        // 2.0.1 · Niente righe dell'aiuto di whisper nel messaggio: una frase chiara (il resto va nel registro)
        eprintln!("whisper-cli: {status:?}\n{}", tail.chars().rev().take(2000).collect::<String>().chars().rev().collect::<String>());
        return Err(EngineError::new(whisper_failure(status.code(), &tail)));
    }
    let json = std::fs::read(base.with_extension("json")).map_err(|_| EngineError::new("la trascrizione non ha prodotto risultati"))?;
    // Le lettere accentate a volte arrivano spezzate: si legge comunque
    let text = String::from_utf8_lossy(&json);
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|_| EngineError::new("risultato della trascrizione non leggibile"))?;
    let segs = parse_words_json(&v);
    if segs.is_empty() {
        return Err(EngineError::new("non ho sentito parole in questo file"));
    }
    progress(1.0);
    Ok(segs)
}

/// «Trascrivi»: testo (.txt) e sottotitoli (.srt) accanto al file.
#[allow(clippy::too_many_arguments)]
pub fn transcribe_files(tools: &Tools, exe: &Path, model: &Path, src: &Path, info: &FileInfo, lang: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<PathBuf>> {
    // 2.0.1 · Prima di minuti di lavoro: si potrà scrivere il risultato?
    names::check_writable(dir)?;
    let segs = transcribe(tools, exe, model, src, info, lang, cancel, progress)?;
    let txt = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("trascrizione")), "txt")?;
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

    #[test]
    fn percorsi_ascii_per_whisper() {
        let base = std::env::temp_dir().join(format!("orbit voce Привет 你好 🎤 {}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let work = ascii_work_dir(&base, "lavoro").unwrap();
        assert!(is_ascii_path(&work), "{work:?}");
        assert!(work.is_dir());
        let model = base.join("modello ggml.bin");
        std::fs::write(&model, b"finto").unwrap();
        let m = ascii_model(&model, &work).unwrap();
        assert!(is_ascii_path(&m), "{m:?}");
        assert_eq!(std::fs::read(&m).unwrap(), b"finto");
        let _ = std::fs::remove_dir_all(&work);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn errori_chiari() {
        assert!(whisper_failure(Some(1), "usage: whisper-cli [options] file0 file1 ...\n  -h, --help").contains("non riesce ad aprire"));
        assert!(whisper_failure(Some(-1073740791), "").contains("chiuso all'improvviso"));
        assert!(!whisper_failure(Some(1), "--help [default]").contains("--help"));
    }

    #[test]
    fn una_parola_per_segmento() {
        let j: serde_json::Value = serde_json::from_str(r#"{"transcription":[
          {"offsets":{"from":0,"to":400},"text":" Buongiorno."},
          {"offsets":{"from":500,"to":800},"text":" Oggi"},
          {"offsets":{"from":850,"to":1000},"text":" è"},
          {"offsets":{"from":1050,"to":1400},"text":" sabato"},
          {"offsets":{"from":3000,"to":3400},"text":" Dopo"},
          {"offsets":{"from":3400,"to":3500},"text":" [_TT_]"}]}"#).unwrap();
        let s = parse_words_json(&j);
        assert_eq!(s.iter().map(|x| x.text.as_str()).collect::<Vec<_>>(), vec!["Buongiorno.", "Oggi è sabato", "Dopo"]);
        assert!((s[1].words[1].start - 0.85).abs() < 1e-9);
    }
}
