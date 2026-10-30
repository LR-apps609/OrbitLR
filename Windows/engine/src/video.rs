//! Video: comprimi con la qualità al primo posto, taglia senza perdita, converti, cambia misura,
//! velocità, GIF, formato social, unisci. Si usa il codificatore più veloce del computer
//! (scheda video NVIDIA, Intel o AMD; altrimenti quello di Windows) e si ricade sugli altri se uno non va.

use crate::args;
use crate::error::{EngineError, Result};
use crate::names;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::Tools;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Bit per pixel per fotogramma sotto cui la qualità cala in modo visibile (come su Mac).
const MIN_BPP_HEVC: f64 = 0.045;
const MIN_BPP_H264: f64 = 0.065;
/// Sopra questi la differenza dall'originale non si vede.
const CLEAN_BPP_HEVC: f64 = 0.075;
const CLEAN_BPP_H264: f64 = 0.11;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Codec {
    H264,
    Hevc,
}

/// Come verrà codificato il video.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub video_bitrate: u64,
    pub audio_bitrate: u64,
    pub codec: Codec,
}

impl Plan {
    pub fn bytes(&self, duration: f64) -> u64 {
        ((self.video_bitrate + self.audio_bitrate) as f64 * duration / 8.0) as u64 + 50_000
    }
}

fn even(x: f64) -> u32 {
    (((x / 2.0).round() as u32) * 2).max(2)
}

/// La misura con il lato corto `short`, senza mai ingrandire.
fn fit_short(w: u32, h: u32, short: u32) -> (u32, u32) {
    let s = w.min(h);
    if short >= s {
        return (even(w as f64), even(h as f64));
    }
    let k = short as f64 / s as f64;
    (even(w as f64 * k), even(h as f64 * k))
}

/// «Stessa qualità, meno peso»: stessa misura e fluidità, il bitrate dove l'occhio non vede differenza.
pub fn plan_best(src: &FileInfo, codec: Codec) -> Result<Plan> {
    if !src.has_video || src.width == 0 || src.height == 0 {
        return Err(EngineError::new("nel file non c'è un video"));
    }
    let fps = if src.fps > 0.0 { src.fps } else { 30.0 };
    let px = src.width as f64 * src.height as f64 * fps;
    let (clean, min) = match codec {
        Codec::Hevc => (CLEAN_BPP_HEVC, MIN_BPP_HEVC),
        Codec::H264 => (CLEAN_BPP_H264, MIN_BPP_H264),
    };
    let src_v = if src.video_bitrate > 0 { src.video_bitrate as f64 } else { px * clean * 2.0 };
    let v = (px * clean).min(src_v * 0.6).max(px * min).max(150_000.0);
    if v >= src_v * 0.9 {
        return Err(EngineError::new("il video è già compresso al massimo: comprimerlo ancora toglierebbe qualità"));
    }
    let a = if src.has_audio { (src.audio_bitrate.clamp(64_000, 160_000)).max(96_000) } else { 0 };
    Ok(Plan { width: even(src.width as f64), height: even(src.height as f64), fps, video_bitrate: v as u64, audio_bitrate: a, codec })
}

/// Sotto un peso preciso (Discord, WhatsApp, email): prima si tengono qualità e misura,
/// poi scende la fluidità sopra i 30 fotogrammi, e solo alla fine la risoluzione.
pub fn plan_target(src: &FileInfo, target_bytes: u64, codec: Codec) -> Result<Plan> {
    if !src.has_video || src.width == 0 || src.height == 0 {
        return Err(EngineError::new("nel file non c'è un video"));
    }
    if src.duration <= 0.0 {
        return Err(EngineError::new("non riesco a leggere la durata del video"));
    }
    let budget = (target_bytes.saturating_sub(60_000)) as f64 * 8.0 * 0.97 / src.duration;
    let mut a: f64 = if src.has_audio { 128_000.0 } else { 0.0 };
    if src.has_audio && budget < 700_000.0 {
        a = 96_000.0;
    }
    if src.has_audio && budget < 300_000.0 {
        a = 64_000.0;
    }
    let v = budget - a;
    if v < 60_000.0 {
        let min_mb = ((60_000.0 + a) * src.duration / 8.0 / 0.97 + 60_000.0) / 1_000_000.0;
        return Err(EngineError::new(format!(
            "per un video così lungo servono almeno {} MB",
            crate::actions::fmt_decimal((min_mb * 10.0).ceil() / 10.0)
        )));
    }
    let min_bpp = if codec == Codec::Hevc { MIN_BPP_HEVC } else { MIN_BPP_H264 };
    let src_fps = if src.fps > 0.0 { src.fps } else { 30.0 };
    let mut fps_choices = vec![src_fps];
    if src_fps > 31.0 {
        fps_choices.push(src_fps / 2.0);
    }
    let short = src.width.min(src.height);
    let mut ladder: Vec<u32> = vec![short];
    for s in [1080, 720, 540, 480, 360, 240] {
        if s < short {
            ladder.push(s);
        }
    }
    for &s in &ladder {
        for &f in &fps_choices {
            let (w, h) = fit_short(src.width, src.height, s);
            let bpp = v / (w as f64 * h as f64 * f);
            if bpp >= min_bpp {
                // Mai più bitrate dell'originale
                let vv = if src.video_bitrate > 0 { v.min(src.video_bitrate as f64) } else { v };
                return Ok(Plan { width: w, height: h, fps: f, video_bitrate: vv as u64, audio_bitrate: a as u64, codec });
            }
        }
    }
    let (w, h) = fit_short(src.width, src.height, *ladder.last().unwrap());
    let f = *fps_choices.last().unwrap();
    Ok(Plan { width: w, height: h, fps: f, video_bitrate: v as u64, audio_bitrate: a as u64, codec })
}

/// Argomenti del codificatore video scelto.
pub fn encoder_args(enc: &str, bitrate: u64) -> Vec<OsString> {
    let b = bitrate.to_string();
    let max = (bitrate as f64 * 1.3) as u64;
    let buf = (bitrate as f64 * 2.0) as u64;
    let mut a = args!["-c:v", enc];
    match enc {
        e if e.ends_with("_nvenc") => a.extend(args!["-preset", "p6", "-tune", "hq", "-rc", "vbr", "-spatial-aq", "1", "-pix_fmt", "yuv420p"]),
        e if e.ends_with("_qsv") => a.extend(args!["-preset", "slower", "-pix_fmt", "nv12"]),
        e if e.ends_with("_amf") => a.extend(args!["-quality", "quality", "-rc", "vbr_peak", "-pix_fmt", "nv12"]),
        e if e.ends_with("_mf") => a.extend(args!["-rate_control", "pc_vbr", "-scenario", "archive", "-pix_fmt", "nv12"]),
        "libx264" | "libx265" => a.extend(args!["-preset", "slow", "-pix_fmt", "yuv420p"]),
        _ => a.extend(args!["-pix_fmt", "yuv420p"]),
    }
    a.extend(args!["-b:v", b, "-maxrate", max.to_string(), "-bufsize", buf.to_string()]);
    if enc.starts_with("hevc") || enc == "libx265" {
        a.extend(args!["-tag:v", "hvc1"]); // così si apre anche su iPhone e Mac
    }
    a
}

/// I codificatori da provare, nell'ordine; l'ultimo di riserva funziona su qualsiasi computer.
pub fn candidates(tools: &Tools, codec: Codec) -> Vec<String> {
    let e = tools.encoders();
    let mut v: Vec<String> = match codec {
        Codec::Hevc => e.hevc.iter().chain(e.h264.iter()).cloned().collect(),
        Codec::H264 => e.h264.clone(),
    };
    if !v.iter().any(|x| x == "mpeg4") && e.all.iter().any(|x| x == "mpeg4") {
        v.push("mpeg4".into());
    }
    v
}

fn codec_of(enc: &str) -> Codec {
    if enc.starts_with("hevc") || enc == "libx265" { Codec::Hevc } else { Codec::H264 }
}

/// Codifica secondo il piano, provando i codificatori finché uno funziona.
#[allow(clippy::too_many_arguments)]
fn encode(
    tools: &Tools,
    src: &Path,
    info: &FileInfo,
    plan: &Plan,
    out: &Path,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
) -> Result<String> {
    let mut last_err = EngineError::new("nessun codificatore video disponibile");
    for enc in candidates(tools, plan.codec) {
        let mut a = args!["-i", src];
        a.extend(args!["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-map_metadata", "0", "-map_chapters", "-1"]);
        let mut vf: Vec<String> = Vec::new();
        if plan.width != even(info.width as f64) || plan.height != even(info.height as f64) {
            vf.push(format!("scale={}:{}:flags=lanczos", plan.width, plan.height));
        }
        if info.fps > 0.0 && (plan.fps - info.fps).abs() > 0.5 {
            vf.push(format!("fps={:.3}", plan.fps));
        }
        if !vf.is_empty() {
            a.extend(args!["-vf", vf.join(",")]);
        }
        // Se il codificatore è H.264 al posto dell'HEVC chiesto, serve un po' più di bitrate
        let b = if plan.codec == Codec::Hevc && codec_of(&enc) == Codec::H264 {
            (plan.video_bitrate as f64 * CLEAN_BPP_H264 / CLEAN_BPP_HEVC) as u64
        } else {
            plan.video_bitrate
        };
        a.extend(encoder_args(&enc, b));
        if plan.audio_bitrate > 0 {
            a.extend(args!["-c:a", "aac", "-b:a", plan.audio_bitrate.to_string(), "-ac", "2"]);
        }
        a.extend(args!["-movflags", "+faststart", out]);
        match run::ffmpeg(tools, &a, info.duration, cancel, progress) {
            Ok(()) if out.metadata().map(|m| m.len() > 0).unwrap_or(false) => return Ok(enc),
            Ok(()) => last_err = EngineError::new("il video creato è vuoto"),
            Err(e) if e.is_cancelled() => {
                let _ = std::fs::remove_file(out);
                return Err(e);
            }
            Err(e) => last_err = e,
        }
        let _ = std::fs::remove_file(out);
    }
    Err(last_err)
}

/// Lo spazio da chiedere per un file di `bytes`: un quinto in più, perché la stima non è mai esatta.
pub fn room_needed(bytes: u64) -> u64 {
    bytes + bytes / 5
}

/// Lo spazio libero sul disco di `dir` (None se non si sa).
pub fn free_space(dir: &Path) -> Option<u64> {
    fs4::available_space(dir).ok()
}

/// C'è posto? Oltre al file (con il suo margine) restano almeno 50 MB liberi per Windows.
pub fn has_room(free: u64, bytes: u64) -> bool {
    free >= room_needed(bytes) + 50_000_000
}

/// Controlla prima che ci sia spazio (con un margine).
pub fn ensure_space(dir: &Path, bytes: u64) -> Result<()> {
    if let Ok(free) = fs4::available_space(dir) {
        if !has_room(free, bytes) {
            return Err(EngineError::new(format!(
                "sul disco servono circa {} liberi, ce ne sono {}",
                crate::actions::fmt_bytes(bytes + bytes / 5),
                crate::actions::fmt_bytes(free)
            )));
        }
    }
    Ok(())
}

/// Comprimi: `target` in byte, oppure `None` per «Stessa qualità, meno peso».
pub fn compress(
    tools: &Tools,
    src: &Path,
    info: &FileInfo,
    target: Option<u64>,
    dir: &Path,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
) -> Result<PathBuf> {
    // HEVC per la qualità; H.264 per i pesi precisi (si apre ovunque, anche su WhatsApp e Discord)
    let codec = if target.is_none() && !tools.encoders().hevc.is_empty() { Codec::Hevc } else { Codec::H264 };
    let mut plan = match target {
        Some(t) => {
            if info.size <= t {
                return Err(EngineError::new(format!(
                    "pesa già {}, meno di {}: non serve comprimerlo",
                    crate::actions::fmt_bytes(info.size),
                    crate::actions::fmt_bytes(t)
                )));
            }
            plan_target(info, t, codec)?
        }
        None => plan_best(info, codec)?,
    };
    ensure_space(dir, plan.bytes(info.duration))?;
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("compresso")), "mp4")?;
    let tmp = of.tmp.clone();
    let attempts = if target.is_some() { 4 } else { 1 };
    let mut factor = 1.0;
    let mut result = Err(EngineError::new("non riesco a comprimere il video"));
    for attempt in 1..=attempts {
        // Ogni tentativo usa una parte dell'avanzamento
        let (lo, span) = if attempt == 1 { (0.0, if attempts > 1 { 0.7 } else { 1.0 }) } else { (0.7 + 0.1 * (attempt - 2) as f64, 0.1) };
        let mut p = |x: f64| progress(lo + x * span);
        let enc = match encode(tools, src, info, &plan, &tmp, cancel, &mut p) {
            Ok(e) => e,
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                return Err(e);
            }
        };
        let got = tmp.metadata().map(|m| m.len()).unwrap_or(0);
        result = Ok(enc);
        match target {
            Some(t) if got > t && attempt < attempts => {
                // I codificatori hardware sforano, soprattutto sui video con molto movimento: si corregge
                let expected = plan.bytes(info.duration).max(1);
                factor *= expected as f64 / got.max(1) as f64;
                let next_target = (t as f64 * factor * 0.95) as u64;
                plan = match plan_target(info, next_target.max(100_000), codec) {
                    Ok(p) => p,
                    Err(_) => {
                        let mut p = plan.clone();
                        p.video_bitrate = ((p.video_bitrate as f64) * t as f64 / got as f64 * 0.9).max(60_000.0) as u64;
                        p
                    }
                };
                let _ = std::fs::remove_file(&tmp);
            }
            Some(t) if got > t => {
                let _ = std::fs::remove_file(&tmp);
                return Err(EngineError::new(format!(
                    "non riesco a farlo stare sotto {}: prova un peso un po' più alto",
                    crate::actions::fmt_bytes(t)
                )));
            }
            None if got >= info.size * 95 / 100 => {
                let _ = std::fs::remove_file(&tmp);
                return Err(EngineError::new("il video è già compresso al massimo: comprimerlo ancora toglierebbe qualità"));
            }
            _ => break,
        }
    }
    result?;
    of.commit()
}

/// Taglia senza ricodificare: istantaneo e senza perdita (l'inizio cade sul fotogramma chiave più vicino).
/// Con `precise` il video si ricodifica e il taglio cade esattamente dove si è scelto.
#[allow(clippy::too_many_arguments)]
pub fn cut(
    tools: &Tools,
    src: &Path,
    info: &FileInfo,
    start: f64,
    end: f64,
    precise: bool,
    dir: &Path,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
) -> Result<PathBuf> {
    let end = if info.duration > 0.0 { end.min(info.duration) } else { end };
    if !(end > start + 0.05) || start < 0.0 {
        return Err(EngineError::new("scegli un pezzo di almeno un decimo di secondo"));
    }
    let ext = match names::ext(src).as_str() {
        e @ ("mp4" | "mov" | "m4v" | "mkv" | "webm" | "avi" | "ts" | "mts" | "m2ts") => e.to_string(),
        _ => "mp4".into(),
    };
    let name = format!("{} ({})", names::stem(src), crate::names::tag("tagliato"));
    let of = names::OutFile::new(dir, &name, &ext)?;
    let d = end - start;
    if !precise {
        let a = args![
            "-ss", format!("{start:.3}"), "-i", src, "-t", format!("{d:.3}"),
            "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero",
            "-map_metadata", "0", of.tmp.clone()
        ];
        match run::ffmpeg(tools, &a, d, cancel, progress) {
            Ok(()) if of.tmp.metadata().map(|m| m.len() > 1000).unwrap_or(false) => return of.commit(),
            Err(e) if e.is_cancelled() => return Err(e),
            _ => {
                let _ = std::fs::remove_file(&of.tmp);
            }
        }
    }
    // Ricodifica (taglio preciso, o se la copia non è riuscita); mai sopra un file che c'è già
    let of = if ext == "mp4" {
        of
    } else {
        drop(of);
        names::OutFile::new(dir, &name, "mp4")?
    };
    let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
    let px = info.width.max(2) as f64 * info.height.max(2) as f64 * fps;
    let b = if info.video_bitrate > 0 { (info.video_bitrate as f64 * 1.05).max(px * CLEAN_BPP_H264) } else { px * CLEAN_BPP_H264 * 1.5 };
    let mut last = EngineError::new("non riesco a tagliare il video");
    for enc in candidates(tools, Codec::H264) {
        let mut a = args!["-ss", format!("{start:.3}"), "-i", src, "-t", format!("{d:.3}"), "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"];
        a.extend(encoder_args(&enc, b as u64));
        a.extend(args!["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", of.tmp.clone()]);
        match run::ffmpeg(tools, &a, d, cancel, progress) {
            Ok(()) => return of.commit(),
            Err(e) if e.is_cancelled() => return Err(e),
            Err(e) => last = e,
        }
    }
    Err(last)
}

/// Ricodifica generica con buona qualità (per velocità, formato social, unione, conversioni).
#[allow(clippy::too_many_arguments)]
fn reencode(
    tools: &Tools,
    pre: Vec<OsString>,
    filters: Vec<OsString>,
    pixels_per_sec: f64,
    has_audio: bool,
    duration: f64,
    out: &Path,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
) -> Result<()> {
    let mut last = EngineError::new("nessun codificatore video disponibile");
    for enc in candidates(tools, Codec::H264) {
        let mut a = pre.clone();
        a.extend(filters.clone());
        a.extend(encoder_args(&enc, (pixels_per_sec * CLEAN_BPP_H264).max(400_000.0) as u64));
        if has_audio {
            a.extend(args!["-c:a", "aac", "-b:a", "192k"]);
        }
        a.extend(args!["-movflags", "+faststart", out]);
        match run::ffmpeg(tools, &a, duration, cancel, progress) {
            Ok(()) => return Ok(()),
            Err(e) if e.is_cancelled() => {
                let _ = std::fs::remove_file(out);
                return Err(e);
            }
            Err(e) => {
                let _ = std::fs::remove_file(out);
                last = e
            }
        }
    }
    Err(last)
}

/// Cambia risoluzione (lato corto 1080, 720, 480…) senza mai ingrandire.
pub fn resize(tools: &Tools, src: &Path, info: &FileInfo, short: u32, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if short >= info.width.min(info.height) {
        return Err(EngineError::new(format!("il video è già {}p o più piccolo", info.width.min(info.height))));
    }
    let (w, h) = fit_short(info.width, info.height, short);
    let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
    let of = names::OutFile::new(dir, &format!("{} ({}p)", names::stem(src), short), "mp4")?;
    ensure_space(dir, (w as f64 * h as f64 * fps * CLEAN_BPP_H264 * info.duration / 8.0) as u64)?;
    let pre = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"];
    reencode(tools, pre, args!["-vf", format!("scale={w}:{h}:flags=lanczos")], w as f64 * h as f64 * fps, info.has_audio, info.duration, &of.tmp, cancel, progress)?;
    of.commit()
}

/// Velocità da 0,25× a 4×: la voce mantiene il suo tono.
pub fn speed(tools: &Tools, src: &Path, info: &FileInfo, factor: f64, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if !(0.25..=4.0).contains(&factor) || (factor - 1.0).abs() < 0.01 {
        return Err(EngineError::new("scegli una velocità tra 0,25× e 4×"));
    }
    let label = crate::actions::fmt_decimal(factor);
    if !info.has_video {
        return crate::audio::speed(tools, src, info, factor, dir, cancel, progress);
    }
    let of = names::OutFile::new(dir, &format!("{} ({label}×)", names::stem(src)), "mp4")?;
    let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
    let pre = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"];
    let mut f = args!["-vf", format!("setpts=PTS/{factor}")];
    if info.has_audio {
        f.extend(args!["-af", crate::audio::atempo_chain(factor)]);
    }
    reencode(tools, pre, f, info.width as f64 * info.height as f64 * fps, info.has_audio, info.duration / factor, &of.tmp, cancel, progress)?;
    of.commit()
}

/// Formato per i social: 9:16 (Reels, TikTok, Shorts), 1:1, 4:5, 16:9. Il video resta intero,
/// i bordi si riempiono con lo stesso video sfocato.
/// `aspect` «9x16», «1x1», «4x5», «16x9»; con «|1» il video riempie lo schermo e l'inquadratura segue le persone
/// («Inquadra le persone», come sul Mac); senza, il video resta intero con i bordi sfocati.
pub fn social(tools: &Tools, src: &Path, info: &FileInfo, aspect: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let (aspect, follow) = match aspect.split_once('|') {
        Some((a, f)) => (a, f.trim() == "1"),
        None => (aspect, false),
    };
    let (w, h, label) = match aspect {
        "1x1" => (1080, 1080, "1-1"),
        "4x5" => (1080, 1350, "4-5"),
        "16x9" => (1920, 1080, "16-9"),
        _ => (1080, 1920, "9-16"),
    };
    let of = names::OutFile::new(dir, &format!("{} ({label})", names::stem(src)), "mp4")?;
    let fps = if info.fps > 0.0 { info.fps.min(60.0) } else { 30.0 };
    let (cw, ch) = crate::reframe::crop_size(info.width.max(2), info.height.max(2), w, h);
    if follow && info.width > 0 && info.height > 0 && (cw + 4 < info.width || ch + 4 < info.height) {
        let path = crate::reframe::subject_path(tools, src, info, cancel, &mut |p| progress(p * 0.25))?;
        let cmds = crate::reframe::commands(&path, info.duration.max(0.1), info.width, info.height, cw, ch, 400);
        let (x0, y0) = cmds.split(';').next().and_then(|c| {
            let n: Vec<&str> = c.split_whitespace().collect();
            Some((n.get(3)?.trim_end_matches(',').to_string(), n.get(6)?.to_string()))
        }).unwrap_or(("0".into(), "0".into()));
        let graph = format!("[0:v]sendcmd=c='{cmds}',crop@f={cw}:{ch}:{x0}:{y0},scale={w}:{h}:flags=lanczos,setsar=1,format=yuv420p[v]");
        let pre = args!["-i", src];
        let mut f = args!["-filter_complex", graph, "-map", "[v]", "-map", "0:a:0?", "-map_metadata", "0"];
        if info.fps > 60.0 {
            f.extend(args!["-r", "60"]);
        }
        reencode(tools, pre, f, w as f64 * h as f64 * fps, info.has_audio, info.duration, &of.tmp, cancel, &mut |p| progress(0.25 + p * 0.75))?;
        return of.commit();
    }
    let graph = format!(
        "[0:v]scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},gblur=sigma=36:steps=2,colorchannelmixer=rr=0.9:gg=0.9:bb=0.9[bg];\
         [0:v]scale={w}:{h}:force_original_aspect_ratio=decrease:flags=lanczos[fg];\
         [bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1,format=yuv420p[v]"
    );
    let pre = args!["-i", src];
    let mut f = args!["-filter_complex", graph, "-map", "[v]", "-map", "0:a:0?", "-map_metadata", "0"];
    if info.fps > 60.0 {
        f.extend(args!["-r", "60"]);
    }
    reencode(tools, pre, f, w as f64 * h as f64 * fps, info.has_audio, info.duration, &of.tmp, cancel, progress)?;
    of.commit()
}

/// Senza audio: istantaneo, il video non si tocca.
pub fn mute(tools: &Tools, src: &Path, info: &FileInfo, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let ext = names::ext(src);
    let ext = if ["mp4", "mov", "m4v", "mkv", "webm"].contains(&ext.as_str()) { ext } else { "mp4".into() };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("senza audio")), &ext)?;
    run::ffmpeg(tools, &args!["-i", src, "-map", "0:v", "-c", "copy", "-an", "-map_metadata", "0", of.tmp.clone()], info.duration, cancel, progress)?;
    of.commit()
}

/// Ruota di 90°, 180° o 270° senza ricodificare (cambia solo l'indicazione per i lettori).
pub fn rotate(tools: &Tools, src: &Path, info: &FileInfo, degrees: i32, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let ext = names::ext(src);
    let ext = if ["mp4", "mov", "m4v"].contains(&ext.as_str()) { ext } else { "mp4".into() };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("ruotato")), &ext)?;
    // La rotazione nuova (oraria) è quella di adesso più quella chiesta;
    // display_rotation la vuole in senso antiorario e sostituisce quella che c'è
    let clockwise = (info.rotation + degrees).rem_euclid(360);
    let total = (360 - clockwise).rem_euclid(360);
    let a = args!["-display_rotation:v:0", total.to_string(), "-i", src, "-map", "0", "-c", "copy", "-map_metadata", "0", of.tmp.clone()];
    match run::ffmpeg(tools, &a, info.duration, cancel, progress) {
        Ok(()) => of.commit(),
        Err(e) if e.is_cancelled() => Err(e),
        Err(_) => {
            // Vecchi contenitori: si ricodifica
            drop(of);
            let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("ruotato")), "mp4")?;
            let t = match degrees.rem_euclid(360) {
                90 => "transpose=1",
                180 => "transpose=1,transpose=1",
                _ => "transpose=2",
            };
            let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
            reencode(tools, args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?"], args!["-vf", t], info.width as f64 * info.height as f64 * fps, info.has_audio, info.duration, &of.tmp, cancel, progress)?;
            of.commit()
        }
    }
}

/// GIF animata da un pezzo del video: 12 fotogrammi al secondo, colori scelti per quel pezzo.
#[allow(clippy::too_many_arguments)]
pub fn gif(tools: &Tools, src: &Path, info: &FileInfo, start: f64, end: f64, width: u32, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let end = if info.duration > 0.0 && end > 0.0 { end.min(info.duration) } else if end > 0.0 { end } else { info.duration.min(10.0) };
    let d = end - start;
    if d <= 0.05 {
        return Err(EngineError::new("scegli un pezzo di almeno un decimo di secondo"));
    }
    if d > 60.0 {
        return Err(EngineError::new("una GIF può essere lunga al massimo 60 secondi: scegli un pezzo più corto"));
    }
    let w = width.min(info.width.max(2));
    let of = names::OutFile::new(dir, &format!("{} (GIF)", names::stem(src)), "gif")?;
    let graph = format!("fps=12,scale={w}:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle");
    run::ffmpeg(tools, &args!["-ss", format!("{start:.3}"), "-t", format!("{d:.3}"), "-i", src, "-filter_complex", graph, "-loop", "0", of.tmp.clone()], d, cancel, progress)?;
    of.commit()
}

/// Converti in un altro formato video. Se il formato lo permette, senza ricodificare (istantaneo e senza perdita).
pub fn convert(tools: &Tools, src: &Path, info: &FileInfo, to: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if to == "gif" {
        return gif(tools, src, info, 0.0, info.duration.min(15.0), 480, dir, cancel, progress);
    }
    let of = names::OutFile::new(dir, &names::stem(src), to)?;
    let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
    let px = info.width.max(2) as f64 * info.height.max(2) as f64 * fps;
    let vc = info.video_codec.as_str();
    let ac = info.audio_codec.as_str();
    let copy_ok = match to {
        "mp4" | "mov" | "m4v" => ["h264", "hevc", "mpeg4", "av1"].contains(&vc) && (!info.has_audio || ["aac", "mp3", "alac", "ac3", "eac3"].contains(&ac)),
        "mkv" => true,
        _ => false,
    };
    if copy_ok {
        let mut a = args!["-i", src, "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-map_metadata", "0"];
        if to != "mkv" {
            a.extend(args!["-movflags", "+faststart"]);
            if vc == "hevc" {
                a.extend(args!["-tag:v", "hvc1"]);
            }
        } else {
            a.extend(args!["-map", "0:s?"]);
        }
        a.push(of.tmp.clone().into());
        match run::ffmpeg(tools, &a, info.duration, cancel, progress) {
            Ok(()) => return of.commit(),
            Err(e) if e.is_cancelled() => return Err(e),
            Err(_) => {
                let _ = std::fs::remove_file(&of.tmp);
            }
        }
    }
    match to {
        "webm" => {
            let b = ((px * 0.08).max(300_000.0)) as u64;
            let mut a = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-b:v", b.to_string(), "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"];
            if info.has_audio {
                a.extend(args!["-c:a", "libopus", "-b:a", "128k"]);
            }
            a.push(of.tmp.clone().into());
            run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
        }
        "avi" => {
            let mut a = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p"];
            if info.has_audio {
                a.extend(args!["-c:a", "libmp3lame", "-q:a", "2"]);
            }
            a.push(of.tmp.clone().into());
            run::ffmpeg(tools, &a, info.duration, cancel, progress)?;
        }
        _ => {
            let pre = args!["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"];
            reencode(tools, pre, vec![], px, info.has_audio, info.duration, &of.tmp, cancel, progress)?;
        }
    }
    of.commit()
}

/// Unisce più video in uno, nell'ordine dato: stessa misura del primo, bande nere dove serve.
pub fn merge(tools: &Tools, files: &[(PathBuf, FileInfo)], dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if files.len() < 2 {
        return Err(EngineError::new("servono almeno due video"));
    }
    let first = &files[0].1;
    let (w, h) = (even(first.width.max(2) as f64), even(first.height.max(2) as f64));
    let fps = if first.fps > 0.0 { first.fps.min(60.0) } else { 30.0 };
    let total: f64 = files.iter().map(|f| f.1.duration).sum();
    let mut a: Vec<OsString> = Vec::new();
    for (p, _) in files {
        a.extend(args!["-i", p]);
    }
    // Ai video senza audio si dà un silenzio della loro durata
    let mut silent_inputs = Vec::new();
    for (i, (_, info)) in files.iter().enumerate() {
        if !info.has_audio {
            silent_inputs.push(i);
            a.extend(args!["-f", "lavfi", "-t", format!("{:.3}", info.duration.max(0.1)), "-i", "anullsrc=r=48000:cl=stereo"]);
        }
    }
    let mut graph = String::new();
    let mut joined = String::new();
    for (i, (_, info)) in files.iter().enumerate() {
        graph.push_str(&format!(
            "[{i}:v]scale={w}:{h}:force_original_aspect_ratio=decrease:flags=lanczos,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps={fps:.3},format=yuv420p[v{i}];"
        ));
        let ain = if info.has_audio {
            format!("[{i}:a]")
        } else {
            let k = files.len() + silent_inputs.iter().position(|&s| s == i).unwrap();
            format!("[{k}:a]")
        };
        graph.push_str(&format!("{ain}aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a{i}];"));
        joined.push_str(&format!("[v{i}][a{i}]"));
    }
    graph.push_str(&format!("{joined}concat=n={}:v=1:a=1[v][a]", files.len()));
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(&files[0].0), crate::names::tag("uniti")), "mp4")?;
    ensure_space(dir, (w as f64 * h as f64 * fps * CLEAN_BPP_H264 * total / 8.0) as u64)?;
    reencode(tools, a, args!["-filter_complex", graph, "-map", "[v]", "-map", "[a]"], w as f64 * h as f64 * fps, true, total, &of.tmp, cancel, progress)?;
    of.commit()
}

/// Un fotogramma piccolo per le miniature (JPEG in memoria).
pub fn thumbnail(tools: &Tools, src: &Path, duration: f64, side: u32) -> Result<Vec<u8>> {
    let at = if duration > 2.0 { (duration * 0.1).min(3.0) } else { 0.0 };
    let mut c = tools.ffmpeg_cmd();
    c.args(["-hide_banner", "-loglevel", "error", "-ss", &format!("{at:.2}"), "-i"])
        .arg(src)
        .args(["-frames:v", "1", "-vf", &format!("scale='min({side},iw)':-2"), "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "5", "pipe:1"]);
    let out = crate::tools::output_timeout(c, 30)?;
    if !out.status.success() || out.stdout.is_empty() {
        return Err(EngineError::new("nessuna anteprima"));
    }
    Ok(out.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(w: u32, h: u32, fps: f64, dur: f64, vb: u64) -> FileInfo {
        FileInfo { width: w, height: h, fps, duration: dur, video_bitrate: vb, has_video: true, has_audio: true, audio_bitrate: 192_000, size: ((vb + 192_000) as f64 * dur / 8.0) as u64, ..Default::default() }
    }

    #[test]
    fn peso_preciso_tiene_la_misura_se_puo() {
        // 1080p, 60 s, 10 MB: si tiene la risoluzione ma si dimezzano i 60 fotogrammi
        let p = plan_target(&info(1920, 1080, 60.0, 60.0, 20_000_000), 10_000_000, Codec::H264).unwrap();
        assert!(p.bytes(60.0) <= 10_000_000, "{p:?}");
        assert!(p.width <= 1920);
        // 2 ore a 50 MB: si scende di risoluzione, ma resta un video
        let long = plan_target(&info(1920, 1080, 30.0, 7200.0, 8_000_000), 500_000_000, Codec::H264).unwrap();
        assert!(long.bytes(7200.0) <= 500_000_000);
        assert!(long.height >= 240);
    }

    #[test]
    fn verticale_resta_verticale() {
        let p = plan_target(&info(1080, 1920, 30.0, 30.0, 12_000_000), 8_000_000, Codec::H264).unwrap();
        assert!(p.height > p.width, "{p:?}");
    }

    #[test]
    fn impossibile_lo_dice() {
        let e = plan_target(&info(1920, 1080, 30.0, 3600.0, 8_000_000), 5_000_000, Codec::H264).unwrap_err();
        assert!(e.0.contains("servono almeno"), "{e}");
    }

    #[test]
    fn stessa_qualita_meno_peso() {
        let p = plan_best(&info(1920, 1080, 30.0, 60.0, 16_000_000), Codec::Hevc).unwrap();
        assert_eq!((p.width, p.height), (1920, 1080));
        assert!(p.video_bitrate < 16_000_000 * 6 / 10 + 1);
        // Un video già leggero non si tocca
        assert!(plan_best(&info(1920, 1080, 30.0, 60.0, 2_500_000), Codec::Hevc).is_err());
    }

    #[test]
    fn misure_pari() {
        assert_eq!(fit_short(1920, 1080, 720), (1280, 720));
        assert_eq!(fit_short(1080, 1920, 720), (720, 1280));
        assert_eq!(fit_short(853, 480, 1080), (854, 480));
    }
}

/// «Estrai i sottotitoli»: un .srt per ogni traccia di sottotitoli scritti (non quelli in immagini dei Blu-ray).
pub fn subtitles_out(tools: &Tools, src: &Path, dir: &Path, cancel: &Cancel) -> Result<Vec<PathBuf>> {
    let mut c = tools.ffprobe_cmd();
    c.args(["-v", "error", "-select_streams", "s", "-show_entries", "stream=codec_name:stream_tags=language", "-of", "csv=p=0"]).arg(src);
    let out = crate::tools::output_timeout(c, 60).map_err(|e| EngineError::new(format!("non riesco a leggere il video: {e}")))?;
    let list: Vec<(String, String)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let mut p = l.split(',');
            (p.next().unwrap_or("").trim().to_string(), p.next().unwrap_or("").trim().to_string())
        })
        .collect();
    if list.is_empty() {
        return Err(EngineError::new("il video non contiene sottotitoli"));
    }
    let base = names::stem(src);
    let mut made = Vec::new();
    for (i, (codec, lang)) in list.iter().enumerate() {
        cancel.check()?;
        if !["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"].contains(&codec.as_str()) {
            continue;
        }
        let name = if list.len() == 1 { base.clone() } else if lang.is_empty() { format!("{base}.{}", i + 1) } else { format!("{base}.{}.{lang}", i + 1) };
        let of = names::OutFile::new(dir, &name, "srt")?;
        let mut a = tools.ffmpeg_cmd();
        a.args(["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i"]).arg(src).args(["-map", &format!("0:s:{i}"), "-c:s", "srt", "-f", "srt"]).arg(&of.tmp);
        let r = crate::tools::output_timeout(a, 600).map_err(|e| EngineError::new(e.to_string()))?;
        if r.status.success() && of.tmp.metadata().map(|m| m.len() > 0).unwrap_or(false) {
            made.push(of.commit()?);
        }
    }
    if made.is_empty() {
        return Err(EngineError::new("i sottotitoli di questo video sono immagini (es. Blu-ray), non convertibili in testo"));
    }
    Ok(made)
}

/// «Aggiungi i sottotitoli»: il video e un .srt (stesso nome, accanto) → video con sottotitoli da accendere nel lettore.
pub fn subtitles_in(tools: &Tools, src: &Path, srt: &Path, info: &FileInfo, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let e = names::ext(src);
    let (oe, sc) = match e.as_str() {
        "mp4" | "mov" | "m4v" => (e.clone(), "mov_text"),
        "mkv" => (e.clone(), "srt"),
        _ => ("mkv".to_string(), "srt"),
    };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), names::tag("con sottotitoli")), &oe)?;
    let mut last = None;
    // Molti .srt italiani non sono in UTF-8
    for enc in ["UTF-8", "CP1252"] {
        let mut a = args!["-i", src, "-sub_charenc", enc, "-i", srt, "-map", "0:v", "-map", "0:a?", "-map", "1:0", "-c:v", "copy", "-c:a", "copy", "-c:s", sc, "-disposition:s:0", "default"];
        if oe != "mkv" {
            a.extend(args!["-movflags", "+faststart"]);
        }
        a.push(of.tmp.clone().into());
        match run::ffmpeg(tools, &a, info.duration, cancel, progress) {
            Ok(_) => return of.commit(),
            Err(err) if err.is_cancelled() => return Err(err),
            Err(err) => last = Some(err),
        }
    }
    Err(last.unwrap_or_else(|| EngineError::new("non riesco ad aggiungere i sottotitoli")))
}

/// «Rimuovi i metadati» dai video: posizione, data e dispositivo via, senza ricodificare.
pub fn strip(tools: &Tools, src: &Path, info: &FileInfo, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let ext = names::ext(src);
    let ext = if ["mp4", "mov", "m4v", "mkv", "webm"].contains(&ext.as_str()) { ext } else { "mp4".into() };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), names::tag("senza metadati")), &ext)?;
    run::ffmpeg(tools, &args!["-i", src, "-map", "0", "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1", "-metadata:s", "location=", "-metadata:s", "creation_time=", of.tmp.clone()], info.duration, cancel, progress)?;
    of.commit()
}
