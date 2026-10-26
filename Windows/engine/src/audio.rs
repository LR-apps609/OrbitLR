//! Audio (e l'audio dei video): converti, taglia, suoneria, volume uniforme, voce più pulita,
//! togli i silenzi, velocità, vocale per WhatsApp, unisci.

use crate::args;
use crate::error::{EngineError, Result};
use crate::names;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::Tools;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

pub const LOUDNORM: &str = "loudnorm=I=-16:TP=-1.5:LRA=11";
/// Voce più pulita: via il rombo sotto gli 80 Hz, il fruscio costante attenuato con delicatezza
/// (12 dB: di più la voce diventa metallica), poi il volume uniforme. Stessa catena dell'app per Mac.
pub const VOICE_CLEAN: &str = "highpass=f=80,afftdn=nr=12:nf=-35:tn=1,loudnorm=I=-16:TP=-1.5:LRA=11";

/// Il codificatore e la qualità per ogni formato audio.
pub fn codec_args(ext: &str) -> Vec<OsString> {
    match ext {
        "mp3" => args!["-c:a", "libmp3lame", "-q:a", "2"],
        "m4a" | "m4r" | "m4b" | "aac" => args!["-c:a", "aac", "-b:a", "192k"],
        "wav" => args!["-c:a", "pcm_s16le"],
        "flac" => args!["-c:a", "flac", "-compression_level", "8"],
        "ogg" => args!["-c:a", "libvorbis", "-q:a", "6"],
        "opus" => args!["-c:a", "libopus", "-b:a", "128k"],
        "aiff" | "aif" => args!["-c:a", "pcm_s16be"],
        _ => args!["-c:a", "aac", "-b:a", "192k"],
    }
}

/// Le estensioni in cui sappiamo scrivere.
pub fn writable(ext: &str) -> bool {
    ["mp3", "m4a", "m4r", "wav", "flac", "ogg", "opus", "aiff", "aac"].contains(&ext)
}

fn container_args(ext: &str) -> Vec<OsString> {
    match ext {
        "m4r" => args!["-f", "ipod"],
        "aac" => args!["-f", "adts"],
        _ => vec![],
    }
}

/// Estensione del risultato quando si tiene lo stesso formato del file (formati che non sappiamo scrivere → m4a).
fn same_or_m4a(src: &Path) -> String {
    let e = names::ext(src);
    if writable(&e) && e != "m4r" { e } else { "m4a".into() }
}

/// Converti in un altro formato audio (dai video: solo l'audio).
pub fn convert(tools: &Tools, src: &Path, info: &FileInfo, to: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let of = names::OutFile::new(dir, &names::stem(src), to)?;
    let mut a = args!["-i", src, "-map", "0:a:0", "-vn", "-map_metadata", "0"];
    // Se l'audio è già in quel formato, si copia: niente perdita
    let same = matches!((to, info.audio_codec.as_str()), ("mp3", "mp3") | ("m4a", "aac") | ("opus", "opus") | ("flac", "flac"));
    if same {
        a.extend(args!["-c:a", "copy"]);
    } else {
        a.extend(codec_args(to));
        if to == "opus" || (to == "ogg" && info.sample_rate > 48_000) {
            a.extend(args!["-ar", "48000"]);
        }
    }
    a.extend(container_args(to));
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
    of.commit()
}

/// Taglia un pezzo dell'audio. Per MP3, M4A e WAV senza ricodificare.
#[allow(clippy::too_many_arguments)]
pub fn cut(tools: &Tools, src: &Path, info: &FileInfo, start: f64, end: f64, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let end = if info.duration > 0.0 { end.min(info.duration) } else { end };
    if !(end > start + 0.05) || start < 0.0 {
        return Err(EngineError::new("scegli un pezzo di almeno un decimo di secondo"));
    }
    let ext = same_or_m4a(src);
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("tagliato")), &ext)?;
    let d = end - start;
    let mut a = args!["-ss", format!("{start:.3}"), "-i", src, "-t", format!("{d:.3}"), "-map", "0:a:0", "-vn", "-map_metadata", "0"];
    let copy = (ext == "mp3" && info.audio_codec == "mp3") || ext == "wav" || (ext == "flac" && info.audio_codec == "flac");
    if copy { a.extend(args!["-c:a", "copy"]) } else { a.extend(codec_args(&ext)) }
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, d, cancel, progress)?;
    of.commit()
}

/// Suoneria: al massimo 30 secondi (il limite per usarla direttamente sull'iPhone),
/// con dissolvenza e volume uniforme. `m4r` per iPhone, `mp3` per Android.
#[allow(clippy::too_many_arguments)]
pub fn ringtone(
    tools: &Tools, src: &Path, info: &FileInfo, start: f64, end: f64, fade: bool, normalize: bool, format: &str,
    dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64),
) -> Result<PathBuf> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let end = if info.duration > 0.0 { end.min(info.duration) } else { end };
    let d = (end - start).min(30.0);
    if d < 1.0 || start < 0.0 {
        return Err(EngineError::new("scegli almeno un secondo"));
    }
    let ext = if format == "mp3" { "mp3" } else { "m4r" };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("suoneria")), ext)?;
    let mut af: Vec<String> = Vec::new();
    if fade {
        af.push("afade=t=in:st=0:d=0.6".into());
        af.push(format!("afade=t=out:st={:.3}:d=1.5", (d - 1.5).max(0.0)));
    }
    if normalize {
        af.push(LOUDNORM.into());
    }
    let mut a = args!["-ss", format!("{start:.3}"), "-i", src, "-t", format!("{d:.3}"), "-map", "0:a:0", "-vn", "-map_metadata", "-1"];
    if !af.is_empty() {
        a.extend(args!["-af", af.join(",")]);
    }
    a.extend(args!["-ar", "44100"]);
    a.extend(codec_args(ext));
    a.extend(container_args(ext));
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, d, cancel, progress)?;
    of.commit()
}

/// Volume uniforme (`clean = false`) o Voce più pulita (`clean = true`). Nei video l'immagine non si tocca.
pub fn level(tools: &Tools, src: &Path, info: &FileInfo, clean: bool, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let chain = if clean { VOICE_CLEAN } else { LOUDNORM };
    let tag = crate::names::tag(if clean { "voce pulita" } else { "volume uniforme" });
    let sr = if info.sample_rate > 0 { info.sample_rate.min(48_000) } else { 48_000 };
    if info.has_video {
        let e = names::ext(src);
        let ext = if ["mp4", "mov", "m4v", "mkv"].contains(&e.as_str()) { e } else { "mp4".into() };
        let of = names::OutFile::new(dir, &format!("{} ({tag})", names::stem(src)), &ext)?;
        let mut a = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", chain, "-ar", sr.to_string(), "-c:a", "aac", "-b:a", "192k", "-map_metadata", "0"];
        if ext != "mkv" {
            a.extend(args!["-movflags", "+faststart"]);
        }
        a.push(of.tmp.clone().into());
        run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
        return of.commit();
    }
    let ext = same_or_m4a(src);
    let of = names::OutFile::new(dir, &format!("{} ({tag})", names::stem(src)), &ext)?;
    let sr = if ext == "opus" { 48_000 } else { sr };
    let mut a = args!["-i", src, "-map", "0:a:0", "-vn", "-map_metadata", "0", "-af", chain, "-ar", sr.to_string()];
    a.extend(codec_args(&ext));
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
    of.commit()
}

/// Togli i silenzi: le pause più lunghe di 0,7 secondi diventano corte (restano 0,25 s di respiro).
pub fn remove_silence(tools: &Tools, src: &Path, info: &FileInfo, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let ext = same_or_m4a(src);
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("senza pause")), &ext)?;
    let f = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.1:stop_periods=-1:stop_duration=0.7:stop_threshold=-45dB:stop_silence=0.25:detection=rms";
    let mut a = args!["-i", src, "-map", "0:a:0", "-vn", "-map_metadata", "0", "-af", f];
    a.extend(codec_args(&ext));
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
    let after = crate::probe::probe(Some(tools), &of.tmp).map(|i| i.duration).unwrap_or(0.0);
    if after > 0.0 && after >= info.duration - 0.3 {
        return Err(EngineError::new("non ho trovato pause lunghe da togliere"));
    }
    of.commit()
}

/// La catena di atempo per qualsiasi velocità (ogni anello tra 0,5 e 2).
pub fn atempo_chain(factor: f64) -> String {
    let mut f = if factor.is_finite() { factor.clamp(0.25, 4.0) } else { 1.0 };
    let mut parts = Vec::new();
    while f > 2.0 {
        parts.push("atempo=2.0".to_string());
        f /= 2.0;
    }
    while f < 0.5 {
        parts.push("atempo=0.5".to_string());
        f /= 0.5;
    }
    parts.push(format!("atempo={f:.4}"));
    parts.join(",")
}

pub fn speed(tools: &Tools, src: &Path, info: &FileInfo, factor: f64, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !(0.25..=4.0).contains(&factor) {
        return Err(EngineError::new("scegli una velocità tra 0,25× e 4×"));
    }
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let ext = same_or_m4a(src);
    let of = names::OutFile::new(dir, &format!("{} ({}×)", names::stem(src), crate::actions::fmt_decimal(factor)), &ext)?;
    let mut a = args!["-i", src, "-map", "0:a:0", "-vn", "-map_metadata", "0", "-af", atempo_chain(factor)];
    a.extend(codec_args(&ext));
    a.push(of.tmp.clone().into());
    run::ffmpeg(tools, &a, info.duration / factor, cancel, progress)?;
    of.commit()
}

/// Un vocale leggero con la voce chiara, che parte subito anche con poca rete (Opus, come WhatsApp).
pub fn voice_note(tools: &Tools, src: &Path, info: &FileInfo, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !info.has_audio {
        return Err(EngineError::new("il file non contiene audio"));
    }
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("vocale")), "ogg")?;
    let a = args!["-i", src, "-map", "0:a:0", "-vn", "-map_metadata", "-1", "-af", VOICE_CLEAN, "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k", "-application", "voip", of.tmp.clone()];
    run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
    of.commit()
}

/// Più file audio in uno, nell'ordine dato (nel formato del primo).
pub fn merge(tools: &Tools, files: &[(PathBuf, FileInfo)], dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if files.len() < 2 {
        return Err(EngineError::new("servono almeno due file audio"));
    }
    if let Some((p, _)) = files.iter().find(|f| !f.1.has_audio) {
        return Err(EngineError::new(format!("«{}» non contiene audio", p.file_name().unwrap_or_default().to_string_lossy())));
    }
    let ext = same_or_m4a(&files[0].0);
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(&files[0].0), crate::names::tag("uniti")), &ext)?;
    let mut a: Vec<OsString> = Vec::new();
    for (p, _) in files {
        a.extend(args!["-i", p]);
    }
    let mut graph = String::new();
    for i in 0..files.len() {
        graph.push_str(&format!("[{i}:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a{i}];"));
    }
    for i in 0..files.len() {
        graph.push_str(&format!("[a{i}]"));
    }
    graph.push_str(&format!("concat=n={}:v=0:a=1[a]", files.len()));
    a.extend(args!["-filter_complex", graph, "-map", "[a]"]);
    a.extend(codec_args(&ext));
    a.push(of.tmp.clone().into());
    let total = files.iter().map(|f| f.1.duration).sum();
    run::ffmpeg(tools, &a, total, cancel, progress)?;
    of.commit()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn catena_atempo() {
        assert_eq!(atempo_chain(1.5), "atempo=1.5000");
        assert_eq!(atempo_chain(4.0), "atempo=2.0,atempo=2.0000");
        assert_eq!(atempo_chain(0.25), "atempo=0.5,atempo=0.5000");
    }
}

/// La forma d'onda per il disegno: `points` valori tra 0 e 1 (il picco di ogni tratto).
/// L'audio si legge a 4000 campioni al secondo, un pezzo alla volta: va bene anche per file di ore.
pub fn waveform(tools: &Tools, src: &Path, duration: f64, points: usize) -> Result<Vec<f32>> {
    use std::io::Read;
    let points = points.clamp(16, 4000);
    let rate = 4000.0;
    let total = (duration.max(0.1) * rate) as usize;
    let per = (total / points).max(1);
    let mut child = tools
        .ffmpeg_cmd()
        .args(["-hide_banner", "-loglevel", "error", "-i"])
        .arg(src)
        .args(["-map", "0:a:0", "-vn", "-ac", "1", "-ar", "4000", "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| EngineError::new(format!("non riesco ad avviare il motore audio: {e}")))?;
    crate::tools::bind_to_app(&child);
    let mut out = child.stdout.take().ok_or_else(|| EngineError::new("nessun audio"))?;
    let mut peaks = vec![0f32; points];
    let mut buf = vec![0u8; 64 * 1024];
    let mut idx = 0usize;
    let mut carry: Option<u8> = None;
    loop {
        let n = out.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let mut bytes: Vec<u8> = Vec::with_capacity(n + 1);
        if let Some(c) = carry.take() {
            bytes.push(c);
        }
        bytes.extend_from_slice(&buf[..n]);
        if bytes.len() % 2 == 1 {
            carry = bytes.pop();
        }
        for ch in bytes.chunks_exact(2) {
            let v = (i16::from_le_bytes([ch[0], ch[1]]) as f32 / 32768.0).abs();
            let k = (idx / per).min(points - 1);
            if v > peaks[k] {
                peaks[k] = v;
            }
            idx += 1;
        }
    }
    let _ = child.wait();
    if idx == 0 {
        return Err(EngineError::new("il file non contiene audio"));
    }
    Ok(peaks)
}
