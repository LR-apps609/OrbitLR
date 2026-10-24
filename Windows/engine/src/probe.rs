use crate::error::{EngineError, Result};
use crate::names;
use crate::tools::Tools;
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Image,
    Video,
    Audio,
    Pdf,
    Doc,
    Other,
}

/// Quello che serve sapere di un file per scegliere cosa farne.
#[derive(Debug, Clone, Default, Serialize)]
pub struct FileInfo {
    pub path: String,
    pub name: String,
    pub ext: String,
    pub size: u64,
    pub kind: Option<Kind>,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub has_video: bool,
    pub has_audio: bool,
    /// bit al secondo
    pub video_bitrate: u64,
    pub audio_bitrate: u64,
    pub video_codec: String,
    pub audio_codec: String,
    pub sample_rate: u32,
    pub channels: u32,
    /// rotazione del telefono (0, 90, 180, 270)
    pub rotation: i32,
}

pub const IMAGE_EXTS: &[&str] = &["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "bmp", "tif", "tiff", "ico", "jfif"];
pub const VIDEO_EXTS: &[&str] = &["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "ogv", "vob", "mxf", "asf", "f4v"];
pub const AUDIO_EXTS: &[&str] = &["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "wma", "aiff", "aif", "aifc", "caf", "m4b", "m4r", "amr", "ac3", "oga", "mka"];
pub const DOC_EXTS: &[&str] = &["docx", "doc", "odt", "rtf", "txt", "md", "html", "htm", "xlsx", "xls", "ods", "csv", "pptx", "ppt", "odp", "epub"];

pub fn kind_of_ext(ext: &str) -> Kind {
    let e = ext.to_ascii_lowercase();
    let e = e.as_str();
    if IMAGE_EXTS.contains(&e) {
        Kind::Image
    } else if VIDEO_EXTS.contains(&e) {
        Kind::Video
    } else if AUDIO_EXTS.contains(&e) {
        Kind::Audio
    } else if e == "pdf" {
        Kind::Pdf
    } else if DOC_EXTS.contains(&e) {
        Kind::Doc
    } else {
        Kind::Other
    }
}

/// Legge il file con ffprobe (video e audio) o con le sue intestazioni (foto).
pub fn probe(tools: Option<&Tools>, path: &Path) -> Result<FileInfo> {
    let meta = std::fs::metadata(path)?;
    if !meta.is_file() {
        return Err(EngineError::new("è una cartella, non un file"));
    }
    let ext = names::ext(path);
    let mut info = FileInfo {
        path: path.to_string_lossy().to_string(),
        name: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        ext: ext.clone(),
        size: meta.len(),
        kind: Some(kind_of_ext(&ext)),
        ..Default::default()
    };
    match info.kind {
        Some(Kind::Image) => {
            if let Ok((w, h)) = image::image_dimensions(path) {
                info.width = w;
                info.height = h;
            } else if let Some(t) = tools {
                // HEIC, AVIF: le misure le sa ffprobe
                let _ = fill_from_ffprobe(t, path, &mut info);
            }
        }
        Some(Kind::Video) | Some(Kind::Audio) | Some(Kind::Other) => {
            if let Some(t) = tools {
                fill_from_ffprobe(t, path, &mut info)?;
                // Un «video» senza immagini è audio (per esempio un .mp4 con solo la voce)
                if info.kind == Some(Kind::Video) && !info.has_video && info.has_audio {
                    info.kind = Some(Kind::Audio);
                }
                if info.kind == Some(Kind::Other) {
                    if info.has_video && info.duration > 0.0 {
                        info.kind = Some(Kind::Video);
                    } else if info.has_audio {
                        info.kind = Some(Kind::Audio);
                    }
                }
            }
        }
        _ => {}
    }
    Ok(info)
}

fn fill_from_ffprobe(t: &Tools, path: &Path, info: &mut FileInfo) -> Result<()> {
    let out = t
        .ffprobe_cmd()
        .args(["-v", "error", "-print_format", "json", "-show_format", "-show_streams"])
        .arg(path)
        .output()
        .map_err(|e| EngineError::new(format!("non riesco ad avviare il motore video: {e}")))?;
    if !out.status.success() {
        return Err(EngineError::new("il file sembra danneggiato o in un formato non riconosciuto"));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|_| EngineError::new("non riesco a leggere il file"))?;
    let num = |x: &serde_json::Value| -> f64 {
        x.as_f64().or_else(|| x.as_str().and_then(|s| s.parse().ok())).unwrap_or(0.0)
    };
    info.duration = num(&v["format"]["duration"]);
    let total_bitrate = num(&v["format"]["bit_rate"]) as u64;
    if let Some(streams) = v["streams"].as_array() {
        for s in streams {
            match s["codec_type"].as_str() {
                Some("video") if !info.has_video => {
                    // Le copertine degli MP3 sono «video» di un fotogramma: non contano
                    if s["disposition"]["attached_pic"].as_i64() == Some(1) {
                        continue;
                    }
                    info.has_video = true;
                    info.width = num(&s["width"]) as u32;
                    info.height = num(&s["height"]) as u32;
                    info.video_codec = s["codec_name"].as_str().unwrap_or("").to_string();
                    info.video_bitrate = num(&s["bit_rate"]) as u64;
                    info.fps = parse_rate(s["avg_frame_rate"].as_str()).or_else(|| parse_rate(s["r_frame_rate"].as_str())).unwrap_or(0.0);
                    info.rotation = rotation(s);
                    if info.duration <= 0.0 {
                        info.duration = num(&s["duration"]);
                    }
                }
                Some("audio") if !info.has_audio => {
                    info.has_audio = true;
                    info.audio_codec = s["codec_name"].as_str().unwrap_or("").to_string();
                    info.audio_bitrate = num(&s["bit_rate"]) as u64;
                    info.sample_rate = num(&s["sample_rate"]) as u32;
                    info.channels = num(&s["channels"]) as u32;
                    if info.duration <= 0.0 {
                        info.duration = num(&s["duration"]);
                    }
                }
                _ => {}
            }
        }
    }
    // Alcuni contenitori (MKV, WebM) non dicono il bitrate del video: lo si ricava dal totale
    if info.has_video && info.video_bitrate == 0 {
        let total = if total_bitrate > 0 {
            total_bitrate
        } else if info.duration > 0.0 {
            (info.size as f64 * 8.0 / info.duration) as u64
        } else {
            0
        };
        info.video_bitrate = total.saturating_sub(info.audio_bitrate.max(if info.has_audio { 128_000 } else { 0 }));
    }
    // Con la rotazione del telefono, larghezza e altezza si scambiano
    if info.rotation.abs() % 180 == 90 {
        std::mem::swap(&mut info.width, &mut info.height);
    }
    if info.fps > 240.0 || info.fps.is_nan() {
        info.fps = 30.0;
    }
    Ok(())
}

fn parse_rate(s: Option<&str>) -> Option<f64> {
    let s = s?;
    let (a, b) = s.split_once('/')?;
    let (a, b): (f64, f64) = (a.parse().ok()?, b.parse().ok()?);
    (b > 0.0 && a > 0.0).then(|| a / b)
}

/// Rotazione in senso orario (come la vecchia etichetta «rotate»). La matrice di ffprobe
/// la dà in senso antiorario (-90 per un telefono in verticale), quindi si cambia segno.
fn rotation(s: &serde_json::Value) -> i32 {
    if let Some(list) = s["side_data_list"].as_array() {
        for d in list {
            if let Some(r) = d["rotation"].as_f64() {
                return (-(r.round() as i32)).rem_euclid(360);
            }
        }
    }
    if let Some(r) = s["tags"]["rotate"].as_str().and_then(|r| r.parse::<i32>().ok()) {
        return r.rem_euclid(360);
    }
    0
}
