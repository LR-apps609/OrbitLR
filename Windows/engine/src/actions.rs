//! Le azioni, con gli stessi nomi dell'app per Mac («vcompress», «cut», «to:mp3»…).
//! L'app chiama `run_action` per ogni file (o una volta sola per le azioni che uniscono più file).

use crate::error::{EngineError, Result};
use crate::probe::{self, FileInfo, Kind};
use crate::run::Cancel;
use crate::tools::Tools;
use crate::{audio, images, pdf, video};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub struct Ctx {
    pub tools: Option<Tools>,
    /// Dove mettere i risultati; `None` = accanto all'originale
    pub out_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Output {
    pub path: String,
    pub name: String,
    pub size: u64,
}

impl Output {
    pub fn of(p: &Path) -> Output {
        Output {
            path: p.to_string_lossy().to_string(),
            name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            size: std::fs::metadata(p).map(|m| m.len()).unwrap_or(0),
        }
    }
}

/// Le azioni che lavorano su tutti i file insieme (una sola volta).
pub fn is_multi(id: &str) -> bool {
    matches!(id, "vmerge" | "amerge" | "merge" | "pdfmerge")
}

/// «2,8 MB», «850 KB»: numeri all'italiana.
pub fn fmt_bytes(b: u64) -> String {
    let b = b as f64;
    if b >= 1e9 {
        format!("{} GB", fmt_decimal((b / 1e8).round() / 10.0))
    } else if b >= 1e6 {
        format!("{} MB", fmt_decimal((b / 1e5).round() / 10.0))
    } else if b >= 1e3 {
        format!("{} KB", (b / 1e3).round())
    } else {
        format!("{} B", b)
    }
}

/// 1.5 → «1,5»; 2.0 → «2».
pub fn fmt_decimal(x: f64) -> String {
    let s = format!("{:.2}", x);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    s.replace('.', ",")
}

fn num(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().replace(',', ".").parse().ok()))
}

fn field(v: &Value, k: &str) -> Option<f64> {
    num(&v[k])
}

fn tools(ctx: &Ctx) -> Result<&Tools> {
    ctx.tools.as_ref().ok_or_else(|| EngineError::new("manca il motore video (ffmpeg): reinstalla OrbitLR"))
}

fn out_dir(ctx: &Ctx, src: &Path) -> Result<PathBuf> {
    let d = match &ctx.out_dir {
        Some(d) => d.clone(),
        None => src.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from(".")),
    };
    if !d.is_dir() {
        std::fs::create_dir_all(&d)?;
    }
    Ok(d)
}

/// Esegue un'azione. Restituisce i file creati.
pub fn run_action(ctx: &Ctx, id: &str, files: &[PathBuf], param: &Value, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<Output>> {
    let first = files.first().ok_or_else(|| EngineError::new("nessun file"))?;
    for f in files {
        if !f.is_file() {
            return Err(EngineError::new(format!("non trovo «{}» (spostato o cancellato?)", f.file_name().unwrap_or_default().to_string_lossy())));
        }
    }
    let dir = out_dir(ctx, first)?;
    let t = ctx.tools.as_ref();

    // Azioni su più file insieme
    if is_multi(id) {
        let out = match id {
            "vmerge" | "amerge" => {
                let tt = tools(ctx)?;
                let infos: Vec<(PathBuf, FileInfo)> = files.iter().map(|f| probe::probe(Some(tt), f).map(|i| (f.clone(), i))).collect::<Result<_>>()?;
                if id == "vmerge" { video::merge(tt, &infos, &dir, cancel, progress)? } else { audio::merge(tt, &infos, &dir, cancel, progress)? }
            }
            "merge" => images::to_pdf(t, files, &dir, cancel, progress)?,
            _ => pdf::merge(files, &dir)?,
        };
        return Ok(vec![Output::of(&out)]);
    }

    let src = first;
    let info = probe::probe(t, src)?;
    let kind = info.kind.unwrap_or(Kind::Other);
    let s = |k: &str| param[k].as_str().map(str::to_string).unwrap_or_default();
    let p_str = param.as_str().map(str::to_string).or_else(|| num(param).map(|n| n.to_string())).unwrap_or_default();

    let outs: Vec<PathBuf> = match id {
        // ── Converti
        x if x.starts_with("to:") => {
            let to = &x[3..];
            match kind {
                Kind::Image => {
                    if to == "pdf" { vec![images::to_pdf(t, files, &dir, cancel, progress)?] } else { vec![images::convert(t, src, to, &dir)?] }
                }
                Kind::Video if audio::writable(to) => vec![audio::convert(tools(ctx)?, src, &info, to, &dir, cancel, progress)?],
                Kind::Video => vec![video::convert(tools(ctx)?, src, &info, to, &dir, cancel, progress)?],
                Kind::Audio if audio::writable(to) => vec![audio::convert(tools(ctx)?, src, &info, to, &dir, cancel, progress)?],
                _ => return Err(EngineError::new(format!("non so convertire questo file in {}", to.to_uppercase()))),
            }
        }
        // ── Video
        "vcompress" => {
            let target = if p_str == "best" || p_str.is_empty() { None } else { Some((num(param).ok_or_else(|| EngineError::new("scegli un peso"))? * 1_000_000.0) as u64) };
            vec![video::compress(tools(ctx)?, src, &info, target, &dir, cancel, progress)?]
        }
        "vresize" => {
            if p_str == "hevc" {
                vec![video::compress(tools(ctx)?, src, &info, None, &dir, cancel, progress)?]
            } else {
                let short = num(param).ok_or_else(|| EngineError::new("scegli una risoluzione"))? as u32;
                vec![video::resize(tools(ctx)?, src, &info, short, &dir, cancel, progress)?]
            }
        }
        "cut" => {
            let (a, b) = (field(param, "start").unwrap_or(0.0), field(param, "end").unwrap_or(info.duration));
            if kind == Kind::Video {
                vec![video::cut(tools(ctx)?, src, &info, a, b, param["precise"].as_bool().unwrap_or(false), &dir, cancel, progress)?]
            } else {
                vec![audio::cut(tools(ctx)?, src, &info, a, b, &dir, cancel, progress)?]
            }
        }
        "gifcut" => {
            let (a, b) = (field(param, "start").unwrap_or(0.0), field(param, "end").unwrap_or(0.0));
            vec![video::gif(tools(ctx)?, src, &info, a, b, field(param, "width").unwrap_or(480.0) as u32, &dir, cancel, progress)?]
        }
        "speed" => {
            let f = num(param).ok_or_else(|| EngineError::new("scegli una velocità"))?;
            if kind == Kind::Video { vec![video::speed(tools(ctx)?, src, &info, f, &dir, cancel, progress)?] } else { vec![audio::speed(tools(ctx)?, src, &info, f, &dir, cancel, progress)?] }
        }
        "social" => vec![video::social(tools(ctx)?, src, &info, if p_str.is_empty() { "9x16" } else { &p_str }, &dir, cancel, progress)?],
        "mute" => vec![video::mute(tools(ctx)?, src, &info, &dir, cancel, progress)?],
        "rotate" => {
            let d = num(param).unwrap_or(90.0) as i32;
            if kind == Kind::Image { vec![images::rotate(t, src, d, &dir)?] } else { vec![video::rotate(tools(ctx)?, src, &info, d, &dir, cancel, progress)?] }
        }
        // ── Audio
        "normalize" => vec![audio::level(tools(ctx)?, src, &info, false, &dir, cancel, progress)?],
        "voiceclean" => vec![audio::level(tools(ctx)?, src, &info, true, &dir, cancel, progress)?],
        "silence" => vec![audio::remove_silence(tools(ctx)?, src, &info, &dir, cancel, progress)?],
        "whatsapp" => vec![audio::voice_note(tools(ctx)?, src, &info, &dir, cancel, progress)?],
        "ringtone" => {
            let (a, b) = (field(param, "start").unwrap_or(0.0), field(param, "end").unwrap_or(30.0));
            let fade = param["fade"].as_bool().unwrap_or(true);
            let norm = param["normalize"].as_bool().unwrap_or(true);
            let fmt = s("format");
            vec![audio::ringtone(tools(ctx)?, src, &info, a, b, fade, norm, if fmt.is_empty() { "m4r" } else { &fmt }, &dir, cancel, progress)?]
        }
        // ── Foto
        "icompress" => {
            let target = if p_str == "best" || p_str.is_empty() { None } else { Some((num(param).ok_or_else(|| EngineError::new("scegli un peso"))? * 1000.0) as u64) };
            vec![images::compress(t, src, target, &dir)?]
        }
        "resize" => vec![images::resize(t, src, &p_str, &dir)?],
        "strip" => {
            if kind == Kind::Image {
                vec![images::strip(src, &dir)?]
            } else {
                return Err(EngineError::new("per ora i metadati si tolgono dalle foto (JPG, PNG, WebP)"));
            }
        }
        // ── PDF
        "split" => pdf::split(src, &dir)?,
        "extract" => vec![pdf::extract(src, &p_str, &dir)?],
        _ => return Err(EngineError::new(format!("azione sconosciuta: {id}"))),
    };
    Ok(outs.iter().map(|p| Output::of(p)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeri_all_italiana() {
        assert_eq!(fmt_decimal(1.5), "1,5");
        assert_eq!(fmt_decimal(2.0), "2");
        assert_eq!(fmt_bytes(2_840_000), "2,8 MB");
        assert_eq!(fmt_bytes(850_400), "850 KB");
        assert_eq!(fmt_bytes(5_200_000_000), "5,2 GB");
    }
}
