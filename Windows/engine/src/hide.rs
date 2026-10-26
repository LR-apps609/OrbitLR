//! «Nascondi un logo» (come su Mac): una o più zone sfocate o a pixel, su foto e video.
//! Le zone sono in proporzione (0…1) rispetto all'immagine diritta.

use crate::args;
use crate::error::{EngineError, Result};
use crate::images::{self, Photo};
use crate::names;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::Tools;
use crate::video;
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
pub struct Zone {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Params {
    pub zones: Vec<Zone>,
    /// «blur» sfocatura, «pixel» a quadretti
    #[serde(default = "blur")]
    pub mode: String,
    /// 0…1
    #[serde(default = "strong")]
    pub strength: f64,
}

fn blur() -> String {
    "blur".into()
}
fn strong() -> f64 {
    0.7
}

fn pixels(z: &Zone, w: u32, h: u32) -> Option<(u32, u32, u32, u32)> {
    let x = (z.x.clamp(0.0, 1.0) * w as f64).floor() as u32;
    let y = (z.y.clamp(0.0, 1.0) * h as f64).floor() as u32;
    let zw = ((z.w.clamp(0.0, 1.0) * w as f64).ceil() as u32).min(w.saturating_sub(x));
    let zh = ((z.h.clamp(0.0, 1.0) * h as f64).ceil() as u32).min(h.saturating_sub(y));
    // ffmpeg vuole misure pari
    let (x, y) = (x & !1, y & !1);
    let (zw, zh) = ((zw.max(4) & !1).min(w - x), (zh.max(4) & !1).min(h - y));
    (zw >= 2 && zh >= 2).then_some((x, y, zw, zh))
}

pub fn photo(tools: Option<&Tools>, src: &Path, p: &Params, dir: &Path) -> Result<PathBuf> {
    if p.zones.is_empty() {
        return Err(EngineError::new("disegna almeno una zona sul logo"));
    }
    let mut ph = images::open(tools, src)?;
    let (w, h) = (ph.img.width(), ph.img.height());
    let mut img = ph.img.to_rgba8();
    for z in &p.zones {
        let Some((x, y, zw, zh)) = pixels(z, w, h) else { continue };
        let region = image::imageops::crop_imm(&img, x, y, zw, zh).to_image();
        let out = if p.mode == "pixel" {
            let cell = ((zw.max(zh) as f64) / (6.0 + (1.0 - p.strength) * 20.0)).max(4.0) as u32;
            let small = image::imageops::resize(&region, (zw / cell).max(1), (zh / cell).max(1), image::imageops::FilterType::Triangle);
            image::imageops::resize(&small, zw, zh, image::imageops::FilterType::Nearest)
        } else {
            let sigma = (zw.min(zh) as f32 * (0.08 + 0.25 * p.strength as f32)).max(3.0);
            image::imageops::blur(&region, sigma)
        };
        image::imageops::replace(&mut img, &out, x as i64, y as i64);
    }
    ph.img = image::DynamicImage::ImageRgba8(img);
    let e = names::ext(src);
    let ext = if ["jpg", "jpeg", "png", "webp", "bmp", "tiff"].contains(&e.as_str()) { if e == "jpeg" { "jpg".to_string() } else { e } } else { "jpg".into() };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("logo nascosto")), &ext)?;
    // Senza EXIF: dentro c'è spesso una miniatura della foto originale, con il logo ancora visibile
    images::save(tools, &Photo { img: ph.img, exif: None, icc: ph.icc }, &ext, 93, &of.tmp)?;
    of.commit()
}

/// Il grafo di ffmpeg per le zone (pubblico per le prove).
pub fn video_graph(p: &Params, w: u32, h: u32) -> Option<String> {
    let mut g = String::new();
    let mut cur = "0:v".to_string();
    let mut n = 0;
    let zones: Vec<_> = p.zones.iter().filter_map(|z| pixels(z, w, h)).collect();
    if zones.is_empty() {
        return None;
    }
    g.push_str(&format!("[0:v]split={}[base]", zones.len() + 1));
    for i in 0..zones.len() {
        g.push_str(&format!("[s{i}]"));
    }
    g.push(';');
    cur = if cur == "0:v" { "base".into() } else { cur };
    for (i, (x, y, zw, zh)) in zones.iter().enumerate() {
        let fx = if p.mode == "pixel" {
            let cell = ((*zw.max(zh) as f64) / (6.0 + (1.0 - p.strength) * 20.0)).max(4.0) as u32;
            format!("scale={}:{}:flags=area,scale={zw}:{zh}:flags=neighbor", (zw / cell).max(1), (zh / cell).max(1))
        } else {
            format!("gblur=sigma={:.1}", (*zw.min(zh) as f64 * (0.08 + 0.25 * p.strength)).max(3.0))
        };
        g.push_str(&format!("[s{i}]crop={zw}:{zh}:{x}:{y},{fx}[z{i}];[{cur}][z{i}]overlay={x}:{y}[o{i}];"));
        cur = format!("o{i}");
        n += 1;
    }
    let _ = n;
    g.push_str(&format!("[{cur}]format=yuv420p[v]"));
    Some(g)
}

pub fn movie(tools: &Tools, src: &Path, info: &FileInfo, p: &Params, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let graph = video_graph(p, info.width, info.height).ok_or_else(|| EngineError::new("disegna almeno una zona sul logo"))?;
    let fps = if info.fps > 0.0 { info.fps } else { 30.0 };
    let px = info.width as f64 * info.height as f64 * fps;
    let bitrate = if info.video_bitrate > 0 { (info.video_bitrate as f64 * 1.1).max(px * 0.08) } else { px * 0.11 } as u64;
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("logo nascosto")), "mp4")?;
    let mut last = EngineError::new("nessun codificatore video disponibile");
    for enc in video::candidates(tools, video::Codec::H264) {
        let mut a = args!["-i", src, "-filter_complex", &graph, "-map", "[v]", "-map", "0:a:0?", "-map_metadata", "0"];
        a.extend(video::encoder_args(&enc, bitrate));
        let copy = ["aac", "mp3", "alac", "ac3", "eac3"].contains(&info.audio_codec.as_str());
        if copy { a.extend(args!["-c:a", "copy"]) } else { a.extend(args!["-c:a", "aac", "-b:a", "192k"]) }
        a.extend(args!["-movflags", "+faststart", &of.tmp]);
        match run::ffmpeg(tools, &a, info.duration, cancel, progress) {
            Ok(()) => return of.commit(),
            Err(e) if e.is_cancelled() => return Err(e),
            Err(e) => {
                let _ = std::fs::remove_file(&of.tmp);
                last = e;
            }
        }
    }
    Err(last)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn grafo_con_due_zone() {
        let p = Params { zones: vec![Zone { x: 0.8, y: 0.05, w: 0.15, h: 0.1 }, Zone { x: 0.0, y: 0.9, w: 0.3, h: 0.1 }], mode: "pixel".into(), strength: 0.7 };
        let g = video_graph(&p, 1920, 1080).unwrap();
        assert!(g.starts_with("[0:v]split=3[base][s0][s1];"), "{g}");
        assert!(g.contains("[s0]crop=288:108:1536:54"), "{g}");
        assert!(g.ends_with("[o1]format=yuv420p[v]"));
        assert!(video_graph(&Params { zones: vec![], mode: "blur".into(), strength: 0.5 }, 100, 100).is_none());
    }
}
