//! Foto: converti, comprimi (stessa qualità o sotto un peso preciso), ridimensiona, ruota,
//! togli i metadati. La posizione GPS e la data restano quando si converte o si comprime
//! (come su Mac): si tolgono solo con «Rimuovi i metadati».

use crate::args;
use crate::error::{EngineError, Result};
use crate::meta;
use crate::names;
use crate::run::{self, Cancel};
use crate::tools::Tools;
use image::{DynamicImage, GenericImageView, ImageDecoder, ImageEncoder, ImageFormat};
use std::io::Cursor;
use std::path::{Path, PathBuf};

/// Una foto aperta: i pixel già raddrizzati, e i metadati da riportare.
pub struct Photo {
    pub img: DynamicImage,
    /// EXIF (TIFF) con l'orientamento già messo a 1
    pub exif: Option<Vec<u8>>,
    pub icc: Option<Vec<u8>>,
}

/// Formati in cui sappiamo scrivere.
pub const WRITE: &[&str] = &["jpg", "png", "webp", "avif", "bmp", "tiff", "gif", "ico", "pdf"];

pub fn open(tools: Option<&Tools>, path: &Path) -> Result<Photo> {
    let direct = (|| -> Result<Photo> {
        let reader = image::ImageReader::open(path)?.with_guessed_format()?;
        let mut dec = reader.into_decoder()?;
        let orientation = dec.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
        let mut exif = dec.exif_metadata().ok().flatten();
        let icc = dec.icc_profile().ok().flatten();
        let mut img = DynamicImage::from_decoder(dec)?;
        img.apply_orientation(orientation);
        if let Some(t) = exif.as_mut() {
            meta::exif_reset_orientation(t);
            if t.len() > 60_000 {
                exif = None; // un EXIF enorme (anteprime dentro) non sta in un JPEG
            }
        }
        Ok(Photo { img, exif, icc })
    })();
    match direct {
        Ok(p) => Ok(p),
        Err(first) => {
            // HEIC, AVIF e altri: li apre ffmpeg
            let Some(t) = tools else { return Err(first) };
            let mut c = t.ffmpeg_cmd();
            c.args(["-hide_banner", "-loglevel", "error", "-i"])
                .arg(path)
                .args(["-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"]);
            let out = crate::tools::output_timeout(c, 60)?;
            if !out.status.success() || out.stdout.is_empty() {
                let e = names::ext(path);
                if e == "heic" || e == "heif" {
                    return Err(EngineError::new("non riesco ad aprire questa foto HEIC: prova a esportarla dall'iPhone come «Più compatibile» (JPG)"));
                }
                return Err(first);
            }
            // L'EXIF dell'iPhone (posizione, data, fotocamera) passa nel JPG; ffmpeg ha già raddrizzato la foto
            let exif = std::fs::read(path).ok().and_then(|d| crate::heif::exif(&d)).and_then(|mut t| {
                meta::exif_reset_orientation(&mut t);
                (t.len() <= 60_000).then_some(t)
            });
            Ok(Photo { img: image::load_from_memory_with_format(&out.stdout, ImageFormat::Png)?, exif, icc: None })
        }
    }
}

fn has_alpha(img: &DynamicImage) -> bool {
    if !img.color().has_alpha() {
        return false;
    }
    img.to_rgba8().pixels().any(|p| p.0[3] < 250)
}

/// Su fondo bianco (il JPEG non ha la trasparenza).
fn flatten(img: &DynamicImage) -> image::RgbImage {
    if !img.color().has_alpha() {
        return img.to_rgb8();
    }
    let rgba = img.to_rgba8();
    image::RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let p = rgba.get_pixel(x, y).0;
        let a = p[3] as u32;
        let mix = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        image::Rgb([mix(p[0]), mix(p[1]), mix(p[2])])
    })
}

pub fn encode_jpeg(p: &Photo, quality: u8) -> Result<Vec<u8>> {
    let rgb = flatten(&p.img);
    let mut buf = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality.clamp(1, 100));
    if let Some(icc) = &p.icc {
        let _ = enc.set_icc_profile(icc.clone());
    }
    enc.write_image(rgb.as_raw(), rgb.width(), rgb.height(), image::ExtendedColorType::Rgb8)?;
    Ok(match &p.exif {
        Some(t) => meta::jpeg_with_exif(&buf, t),
        None => buf,
    })
}

fn encode_png(p: &Photo) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut enc = image::codecs::png::PngEncoder::new_with_quality(&mut buf, image::codecs::png::CompressionType::Best, image::codecs::png::FilterType::Adaptive);
    if let Some(icc) = &p.icc {
        let _ = enc.set_icc_profile(icc.clone());
    }
    let img = if p.img.color().has_alpha() { DynamicImage::ImageRgba8(p.img.to_rgba8()) } else { DynamicImage::ImageRgb8(p.img.to_rgb8()) };
    img.write_with_encoder(enc)?;
    Ok(buf)
}

/// WebP con perdita e AVIF: li scrive ffmpeg (da un PNG temporaneo).
fn encode_with_ffmpeg(tools: &Tools, p: &Photo, ext: &str, quality: u8, out: &Path) -> Result<()> {
    let tmp = names::temp_beside(out, "png");
    std::fs::write(&tmp, encode_png(&Photo { img: p.img.clone(), exif: None, icc: None })?)?;
    let cancel = Cancel::new();
    let mut nothing = |_: f64| {};
    let r = match ext {
        "webp" => {
            let a = args!["-i", &tmp, "-frames:v", "1", "-c:v", "libwebp", "-quality", quality.to_string(), "-compression_level", "6", out];
            run::ffmpeg(tools, &a, 0.0, &cancel, &mut nothing)
        }
        _ => {
            // AVIF: prima libaom, poi SVT-AV1
            let crf = (63.0 - quality as f64 * 0.5).round().clamp(10.0, 50.0) as u32;
            let a = args!["-i", &tmp, "-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf.to_string(), "-cpu-used", "6", "-pix_fmt", "yuv420p", out];
            run::ffmpeg(tools, &a, 0.0, &cancel, &mut nothing).or_else(|_| {
                let a = args!["-i", &tmp, "-frames:v", "1", "-c:v", "libsvtav1", "-crf", crf.to_string(), "-pix_fmt", "yuv420p", out];
                run::ffmpeg(tools, &a, 0.0, &cancel, &mut nothing)
            })
        }
    };
    let _ = std::fs::remove_file(&tmp);
    names::track_temp(&tmp, false);
    r
}

/// Scrive la foto nel formato chiesto.
pub fn save(tools: Option<&Tools>, p: &Photo, ext: &str, quality: u8, out: &Path) -> Result<()> {
    match ext {
        "jpg" | "jpeg" => std::fs::write(out, encode_jpeg(p, quality)?)?,
        "png" => std::fs::write(out, encode_png(p)?)?,
        "webp" | "avif" => {
            let t = tools.ok_or_else(|| EngineError::new("manca il motore per questo formato"))?;
            encode_with_ffmpeg(t, p, ext, quality, out)?
        }
        "ico" => {
            // Le icone di Windows arrivano a 256 × 256
            let img = if p.img.width() > 256 || p.img.height() > 256 { p.img.resize(256, 256, image::imageops::FilterType::Lanczos3) } else { p.img.clone() };
            let mut c = Cursor::new(Vec::new());
            DynamicImage::ImageRgba8(img.to_rgba8()).write_to(&mut c, ImageFormat::Ico)?;
            std::fs::write(out, c.into_inner())?
        }
        "bmp" | "tiff" | "tif" | "gif" => {
            let fmt = match ext {
                "bmp" => ImageFormat::Bmp,
                "gif" => ImageFormat::Gif,
                _ => ImageFormat::Tiff,
            };
            let img = if fmt == ImageFormat::Bmp { DynamicImage::ImageRgb8(flatten(&p.img)) } else { DynamicImage::ImageRgba8(p.img.to_rgba8()) };
            let mut c = Cursor::new(Vec::new());
            img.write_to(&mut c, fmt)?;
            std::fs::write(out, c.into_inner())?
        }
        "pdf" => {
            let jpg = encode_jpeg(&Photo { img: p.img.clone(), exif: None, icc: None }, 90)?;
            crate::pdf::images_to_pdf(&[(jpg, p.img.width(), p.img.height())], out)?
        }
        _ => return Err(EngineError::new(format!("non so scrivere il formato {}", ext.to_uppercase()))),
    }
    if out.metadata().map(|m| m.len() == 0).unwrap_or(true) {
        let _ = std::fs::remove_file(out);
        return Err(EngineError::new("il file creato è vuoto"));
    }
    Ok(())
}

pub fn convert(tools: Option<&Tools>, src: &Path, to: &str, dir: &Path) -> Result<PathBuf> {
    let to = if to == "jpeg" { "jpg" } else if to == "tif" { "tiff" } else { to };
    let p = open(tools, src)?;
    let of = names::OutFile::new(dir, &names::stem(src), to)?;
    save(tools, &p, to, 92, &of.tmp)?;
    of.commit()
}

/// Comprimi: `target` in byte, oppure `None` per «Stessa qualità, meno peso».
/// Il risultato è un JPEG (la scelta giusta per le foto); le immagini trasparenti diventano WebP.
pub fn compress(tools: Option<&Tools>, src: &Path, target: Option<u64>, dir: &Path) -> Result<PathBuf> {
    let before = std::fs::metadata(src)?.len();
    if let Some(t) = target {
        if before <= t {
            return Err(EngineError::new(format!("pesa già {}, meno di {}", crate::actions::fmt_bytes(before), crate::actions::fmt_bytes(t))));
        }
    }
    let p = open(tools, src)?;
    if has_alpha(&p.img) {
        return Err(EngineError::new("l'immagine ha parti trasparenti: comprimendola in JPG diventerebbero bianche. Usa «Converti in WebP», che le tiene"));
    }
    let of = names::OutFile::new(dir, &format!("{} (compresso)", names::stem(src)), "jpg")?;
    let bytes = match target {
        None => {
            // 82: sopra non si vede differenza, sotto iniziano i difetti sui bordi
            let b = encode_jpeg(&p, 82)?;
            if b.len() as u64 >= before * 95 / 100 {
                return Err(EngineError::new("la foto è già compressa al massimo: comprimerla ancora toglierebbe qualità"));
            }
            b
        }
        Some(t) => fit(&p, t)?,
    };
    std::fs::write(&of.tmp, bytes)?;
    of.commit()
}

/// La qualità più alta che sta sotto il peso; se non basta, la foto si rimpicciolisce un po' alla volta.
pub fn fit(p: &Photo, target: u64) -> Result<Vec<u8>> {
    let mut cur = Photo { img: p.img.clone(), exif: p.exif.clone(), icc: p.icc.clone() };
    // I metadati pesano: sotto i 100 KB se ne fa a meno
    if target < 100_000 {
        cur.exif = None;
        cur.icc = None;
    }
    for _ in 0..12 {
        let (mut lo, mut hi) = (60u8, 95u8);
        let mut best: Option<Vec<u8>> = None;
        while lo <= hi {
            let q = (lo + hi) / 2;
            let b = encode_jpeg(&cur, q)?;
            if b.len() as u64 <= target {
                best = Some(b);
                lo = q + 1;
            } else {
                if q == 0 {
                    break;
                }
                hi = q - 1;
            }
        }
        if let Some(b) = best {
            return Ok(b);
        }
        let (w, h) = cur.img.dimensions();
        if w.max(h) <= 200 {
            break;
        }
        cur.img = cur.img.resize((w as f64 * 0.85) as u32, (h as f64 * 0.85) as u32, image::imageops::FilterType::Lanczos3);
    }
    Err(EngineError::new(format!("non riesco a farla stare sotto {}", crate::actions::fmt_bytes(target))))
}

/// Ridimensiona: «50%» oppure il lato lungo in pixel («1920»). Mai ingrandire.
pub fn resize(tools: Option<&Tools>, src: &Path, param: &str, dir: &Path) -> Result<PathBuf> {
    let p = open(tools, src)?;
    let (w, h) = p.img.dimensions();
    let long = w.max(h) as f64;
    let k = if let Some(pc) = param.trim().strip_suffix('%') {
        pc.trim().replace(',', ".").parse::<f64>().map_err(|_| EngineError::new("scrivi una percentuale, per esempio 50%"))? / 100.0
    } else {
        param.trim().parse::<f64>().map_err(|_| EngineError::new("scrivi i pixel del lato lungo, per esempio 1920"))? / long
    };
    if !(0.01..1.0).contains(&k) {
        return Err(EngineError::new("la nuova misura deve essere più piccola di quella di adesso"));
    }
    let (nw, nh) = (((w as f64 * k).round() as u32).max(1), ((h as f64 * k).round() as u32).max(1));
    let img = p.img.resize_exact(nw, nh, image::imageops::FilterType::Lanczos3);
    let e = names::ext(src);
    let ext = match e.as_str() {
        "jpeg" | "jfif" => "jpg".to_string(),
        "tif" => "tiff".into(),
        x if WRITE.contains(&x) && x != "pdf" => x.to_string(),
        _ => "jpg".into(),
    };
    let of = names::OutFile::new(dir, &format!("{} ({nw}×{nh})", names::stem(src)), &ext)?;
    save(tools, &Photo { img, exif: p.exif, icc: p.icc }, &ext, 92, &of.tmp)?;
    of.commit()
}

pub fn rotate(tools: Option<&Tools>, src: &Path, degrees: i32, dir: &Path) -> Result<PathBuf> {
    let p = open(tools, src)?;
    let img = match degrees.rem_euclid(360) {
        90 => p.img.rotate90(),
        180 => p.img.rotate180(),
        270 => p.img.rotate270(),
        _ => return Err(EngineError::new("scegli 90°, 180° o 270°")),
    };
    let e = names::ext(src);
    let ext = if ["jpg", "png", "webp", "bmp", "tiff", "gif"].contains(&e.as_str()) { e } else { "jpg".into() };
    let of = names::OutFile::new(dir, &format!("{} (ruotata)", names::stem(src)), &ext)?;
    save(tools, &Photo { img, exif: p.exif, icc: p.icc }, &ext, 95, &of.tmp)?;
    of.commit()
}

/// Rimuovi i metadati senza perdere qualità (JPG, PNG, WebP).
pub fn strip(src: &Path, dir: &Path) -> Result<PathBuf> {
    let data = std::fs::read(src)?;
    let e = names::ext(src);
    let clean = match e.as_str() {
        "jpg" | "jpeg" | "jfif" => meta::strip_jpeg(&data)?,
        "png" => meta::strip_png(&data)?,
        "webp" => meta::strip_webp(&data)?,
        _ => return Err(EngineError::new("per questo formato converti prima la foto in JPG: la conversione si può fare senza metadati")),
    };
    let ext = if e == "jpeg" || e == "jfif" { "jpg".to_string() } else { e };
    let of = names::OutFile::new(dir, &format!("{} (senza metadati)", names::stem(src)), &ext)?;
    std::fs::write(&of.tmp, clean)?;
    of.commit()
}

/// Più foto in un unico PDF, una per pagina, nell'ordine dato.
pub fn to_pdf(tools: Option<&Tools>, files: &[PathBuf], dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let mut pages = Vec::new();
    for (i, f) in files.iter().enumerate() {
        cancel.check()?;
        let p = open(tools, f)?;
        let jpg = encode_jpeg(&Photo { img: p.img.clone(), exif: None, icc: None }, 90)?;
        pages.push((jpg, p.img.width(), p.img.height()));
        progress((i + 1) as f64 / files.len() as f64 * 0.95);
    }
    let base = if files.len() == 1 { names::stem(&files[0]) } else { format!("{} e altre {}", names::stem(&files[0]), files.len() - 1) };
    let of = names::OutFile::new(dir, &base, "pdf")?;
    crate::pdf::images_to_pdf(&pages, &of.tmp)?;
    progress(1.0);
    of.commit()
}

/// Una miniatura JPEG (lato lungo `side`).
pub fn thumbnail(tools: Option<&Tools>, src: &Path, side: u32) -> Result<Vec<u8>> {
    let p = open(tools, src)?;
    let img = p.img.thumbnail(side, side);
    encode_jpeg(&Photo { img, exif: None, icc: None }, 80)
}
