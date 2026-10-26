//! Gli strumenti con l'IA per le foto, tutti sul computer (internet solo la prima volta, per i modelli):
//! • «Rimuovi lo sfondo»: ISNet (licenza Apache 2.0), eseguito in Rust puro con tract, sul processore.
//! • «Migliora» e «Ingrandisci»: Real-ESRGAN (licenza BSD-3, Xintao Wang et al.) nella versione
//!   ncnn-vulkan (licenza MIT), che usa la scheda video del PC (NVIDIA, AMD o Intel).

use crate::download::{self, Item};
use crate::error::{EngineError, Result};
use crate::images::{self, Photo};
use crate::names;
use crate::run::Cancel;
use crate::tools::Tools;
use image::{DynamicImage, GenericImageView, GrayImage, RgbImage, RgbaImage};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tract_onnx::prelude::*;

pub const BG_MODEL: Item = Item {
    url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx",
    sha256: "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a",
    bytes: 178_648_008,
    what: "il modello per togliere lo sfondo",
};

pub const ESRGAN_ZIP: Item = Item {
    url: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip",
    sha256: "abc02804e17982a3be33675e4d471e91ea374e65b70167abc09e31acb412802d",
    bytes: 45_474_481,
    what: "il motore per migliorare le foto",
};

/// Lato dell'immagine che entra in ISNet.
const SIDE: usize = 1024;
/// Oltre questi pixel il risultato di «Migliora» diventa enorme e la memoria non basta (come sul Mac).
const MAX_OUTPUT_PIXELS: u64 = 100_000_000;

pub fn models_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("modelli")
}

pub fn bg_model_path(data_dir: &Path) -> PathBuf {
    models_dir(data_dir).join("isnet-general-use.onnx")
}

pub fn esrgan_dir(data_dir: &Path) -> PathBuf {
    models_dir(data_dir).join("realesrgan")
}

fn esrgan_exe(data_dir: &Path) -> PathBuf {
    esrgan_dir(data_dir).join(if cfg!(windows) { "realesrgan-ncnn-vulkan.exe" } else { "realesrgan-ncnn-vulkan" })
}

/// Cosa bisogna ancora scaricare per un'azione (per avvisare prima): (cosa, MB).
pub fn pending_download(action: &str, data_dir: &Path) -> Option<(&'static str, u64)> {
    match action {
        "removebg" if !download::ready(&bg_model_path(data_dir), &BG_MODEL) => Some((BG_MODEL.what, BG_MODEL.bytes / 1_000_000)),
        "aienhance" | "upscale" if !esrgan_ready(data_dir) => Some((ESRGAN_ZIP.what, ESRGAN_ZIP.bytes / 1_000_000)),
        _ => None,
    }
}

// ───────────────────────── Rimuovi lo sfondo

type Model = Arc<TypedRunnableModel<TypedModel>>;
static BG: Mutex<Option<Model>> = Mutex::new(None);

fn bg_model(path: &Path) -> Result<Model> {
    let mut g = BG.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = g.as_ref() {
        return Ok(m.clone());
    }
    let m = tract_onnx::onnx()
        .model_for_path(path)
        .and_then(|m| m.with_input_fact(0, f32::fact([1, 3, SIDE, SIDE]).into()))
        .and_then(|m| m.into_optimized())
        .and_then(|m| m.into_runnable())
        .map_err(|e| EngineError::new(format!("il modello per lo sfondo non si apre ({e}): cancellalo dalle Opzioni e riprova")))?;
    let m = Arc::new(m);
    *g = Some(m.clone());
    Ok(m)
}

/// La maschera del soggetto (0 = sfondo, 255 = soggetto), grande come la foto.
pub fn subject_mask(model_path: &Path, img: &RgbImage) -> Result<GrayImage> {
    let model = bg_model(model_path)?;
    let (w, h) = img.dimensions();
    let small = image::imageops::resize(img, SIDE as u32, SIDE as u32, image::imageops::FilterType::Triangle);
    // Come rembg: valori divisi per il massimo della foto, meno 0,5
    let mx = small.pixels().flat_map(|p| p.0).max().unwrap_or(255).max(1) as f32;
    let input: Tensor = tract_ndarray::Array4::from_shape_fn((1, 3, SIDE, SIDE), |(_, c, y, x)| small.get_pixel(x as u32, y as u32)[c] as f32 / mx - 0.5).into();
    let out = model.run(tvec!(input.into())).map_err(|e| EngineError::new(format!("l'IA per lo sfondo si è fermata: {e}")))?;
    let o = out[0].to_array_view::<f32>().map_err(|e| EngineError::new(e.to_string()))?;
    let (mut mi, mut ma) = (f32::MAX, f32::MIN);
    for v in o.iter() {
        mi = mi.min(*v);
        ma = ma.max(*v);
    }
    let span = (ma - mi).max(1e-6);
    let m = GrayImage::from_fn(SIDE as u32, SIDE as u32, |x, y| image::Luma([(((o[[0, 0, y as usize, x as usize]] - mi) / span) * 255.0).round().clamp(0.0, 255.0) as u8]));
    Ok(image::imageops::resize(&m, w, h, image::imageops::FilterType::Lanczos3))
}

/// «transparent» (PNG), «white» (JPG su bianco), «crop» (PNG ritagliato attorno al soggetto).
pub fn remove_background(tools: Option<&Tools>, data_dir: &Path, src: &Path, mode: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let model = bg_model_path(data_dir);
    let mut base = 0.0;
    if !download::ready(&model, &BG_MODEL) {
        download::fetch(&BG_MODEL, &model, cancel, &mut |p| progress(p * 0.5))?;
        base = 0.5;
    }
    progress(base + 0.05);
    let photo = images::open(tools, src)?;
    if cancel.is_cancelled() {
        return Err(EngineError::cancelled());
    }
    let rgb = photo.img.to_rgb8();
    let mask = subject_mask(&model, &rgb)?;
    progress(0.92);
    // Nessun soggetto: meglio dirlo che consegnare un PNG vuoto
    let strong = mask.pixels().filter(|p| p[0] > 128).count() as f64;
    if strong / (mask.len() as f64).max(1.0) < 0.003 {
        return Err(EngineError::new("non trovo un soggetto da ritagliare in questa foto"));
    }
    let (w, h) = rgb.dimensions();
    let stem = names::stem(src);
    let out = match mode {
        "white" => {
            let img = RgbImage::from_fn(w, h, |x, y| {
                let p = rgb.get_pixel(x, y);
                let a = mask.get_pixel(x, y)[0] as u32;
                image::Rgb([0, 1, 2].map(|c| ((p[c] as u32 * a + 255 * (255 - a)) / 255) as u8))
            });
            let of = names::OutFile::new(dir, &format!("{stem} (sfondo bianco)"), "jpg")?;
            images::save(tools, &Photo { img: DynamicImage::ImageRgb8(img), exif: None, icc: photo.icc }, "jpg", 92, &of.tmp)?;
            of.commit()?
        }
        _ => {
            let mut img = RgbaImage::from_fn(w, h, |x, y| {
                let p = rgb.get_pixel(x, y);
                image::Rgba([p[0], p[1], p[2], mask.get_pixel(x, y)[0]])
            });
            if mode == "crop" {
                let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0, 0);
                for (x, y, p) in mask.enumerate_pixels() {
                    if p[0] > 16 {
                        x0 = x0.min(x);
                        y0 = y0.min(y);
                        x1 = x1.max(x);
                        y1 = y1.max(y);
                    }
                }
                let m = ((x1 - x0).max(y1 - y0) / 50).max(2);
                let (x0, y0) = (x0.saturating_sub(m), y0.saturating_sub(m));
                let (x1, y1) = ((x1 + m).min(w - 1), (y1 + m).min(h - 1));
                img = DynamicImage::ImageRgba8(img).crop_imm(x0, y0, x1 - x0 + 1, y1 - y0 + 1).to_rgba8();
            }
            let of = names::OutFile::new(dir, &format!("{stem} (senza sfondo)"), "png")?;
            images::save(tools, &Photo { img: DynamicImage::ImageRgba8(img), exif: None, icc: photo.icc }, "png", 92, &of.tmp)?;
            of.commit()?
        }
    };
    progress(1.0);
    Ok(out)
}

// ───────────────────────── Migliora e ingrandisci (Real-ESRGAN)

#[cfg(windows)]
const ESRGAN_FILES: &[&str] = &[
    "realesrgan-ncnn-vulkan.exe",
    "vcomp140.dll",
    "models/realesrgan-x4plus.bin",
    "models/realesrgan-x4plus.param",
    "models/realesrgan-x4plus-anime.bin",
    "models/realesrgan-x4plus-anime.param",
];
/// Fuori da Windows (solo per le prove): i file si mettono a mano
#[cfg(not(windows))]
const ESRGAN_FILES: &[&str] = &[
    "realesrgan-ncnn-vulkan",
    "models/realesrgan-x4plus.bin",
    "models/realesrgan-x4plus.param",
    "models/realesrgan-x4plus-anime.bin",
    "models/realesrgan-x4plus-anime.param",
];

pub fn esrgan_ready(data_dir: &Path) -> bool {
    let d = esrgan_dir(data_dir);
    d.join("pronto.txt").is_file() && ESRGAN_FILES.iter().all(|f| d.join(f).is_file())
}

/// Scarica lo zip ufficiale (impronta controllata) e ne prende solo i file che servono.
pub fn install_esrgan(data_dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<()> {
    if esrgan_ready(data_dir) {
        return Ok(());
    }
    let zip_path = models_dir(data_dir).join("realesrgan.zip");
    download::fetch(&ESRGAN_ZIP, &zip_path, cancel, progress)?;
    let dir = esrgan_dir(data_dir);
    std::fs::create_dir_all(dir.join("models"))?;
    let file = std::fs::File::open(&zip_path)?;
    let mut z = zip::ZipArchive::new(file).map_err(|e| EngineError::new(format!("lo zip del motore è rovinato: {e}")))?;
    for i in 0..z.len() {
        let mut f = z.by_index(i).map_err(|e| EngineError::new(e.to_string()))?;
        let name = f.name().replace('\\', "/");
        // Solo i file conosciuti, ognuno al suo posto (nessun percorso preso dallo zip)
        let Some(want) = ESRGAN_FILES.iter().find(|w| name.ends_with(*w)) else { continue };
        let dest = dir.join(want);
        let mut out = std::fs::File::create(&dest)?;
        std::io::copy(&mut f, &mut out)?;
    }
    if !ESRGAN_FILES.iter().all(|f| dir.join(f).is_file()) {
        return Err(EngineError::new("nello zip del motore mancano dei file: riprova"));
    }
    std::fs::write(dir.join("pronto.txt"), "ok")?;
    let _ = std::fs::remove_file(&zip_path);
    Ok(())
}

/// Migliora (`factor` 1 = stessa misura, più pulita e nitida) o ingrandisci (2 o 4).
/// `strength` 0–100: quanto si vede l'IA (il resto è la foto originale ingrandita normalmente).
#[allow(clippy::too_many_arguments)]
pub fn enhance(tools: Option<&Tools>, data_dir: &Path, src: &Path, factor: u32, strength: u32, anime: bool, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let factor = factor.clamp(1, 4);
    if !esrgan_ready(data_dir) {
        install_esrgan(data_dir, cancel, &mut |p| progress(p * 0.3))?;
    }
    let base = 0.3;
    let photo = images::open(tools, src)?;
    let (ow, oh) = photo.img.dimensions();
    if ow < 8 || oh < 8 {
        return Err(EngineError::new("l'immagine è troppo piccola"));
    }
    // Il modello ingrandisce sempre 4×. Si lavora su una copia rimpicciolita quando serve:
    // risultato sotto i 100 megapixel, e «stessa misura» su foto grandi a metà (un quarto del tempo).
    let (tw, th) = (ow * factor, oh * factor);
    if (tw as u64) * (th as u64) > MAX_OUTPUT_PIXELS {
        return Err(EngineError::new(format!("il risultato sarebbe {}×{}: troppo grande. Scegli un ingrandimento minore", tw, th)));
    }
    let mut work = photo.img.clone();
    let max_in = (MAX_OUTPUT_PIXELS / 16) as f64;
    let mut k = 1.0f64;
    if factor == 1 && (ow as u64 * oh as u64) > 4_000_000 {
        k = 0.5;
    }
    if (ow as f64 * k) * (oh as f64 * k) > max_in {
        k = (max_in / (ow as f64 * oh as f64)).sqrt();
    }
    if k < 1.0 {
        work = work.resize_exact(((ow as f64 * k) as u32).max(8), ((oh as f64 * k) as u32).max(8), image::imageops::FilterType::Lanczos3);
    }
    let has_alpha = work.color().has_alpha();
    let alpha = has_alpha.then(|| work.to_luma_alpha8());

    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!("orbitlr-ia-{}-{n}", std::process::id()));
    struct Clean(PathBuf);
    impl Drop for Clean {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _clean = Clean(tmp.clone());
    std::fs::create_dir_all(&tmp)?;
    let inp = tmp.join("dentro.png");
    let outp = tmp.join("fuori.png");
    DynamicImage::ImageRgb8(work.to_rgb8()).save(&inp).map_err(|e| EngineError::new(e.to_string()))?;

    let edir = esrgan_dir(data_dir);
    let exe = esrgan_exe(data_dir);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755));
    }
    let mut cmd = crate::tools::quiet(std::process::Command::new(&exe));
    cmd.current_dir(&edir)
        .arg("-i").arg(&inp)
        .arg("-o").arg(&outp)
        .args(["-n", if anime { "realesrgan-x4plus-anime" } else { "realesrgan-x4plus" }, "-s", "4", "-f", "png", "-m"])
        .arg(edir.join("models"))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().map_err(|_| EngineError::new("il motore per migliorare le foto non parte"))?;
    crate::tools::bind_to_app(&child);
    let stderr = child.stderr.take();
    let tail = Arc::new(Mutex::new(String::new()));
    let (tx, rx) = std::sync::mpsc::channel::<f64>();
    let t2 = tail.clone();
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let Some(mut e) = stderr else { return };
        let mut buf = [0u8; 512];
        let mut line = String::new();
        while let Ok(n) = e.read(&mut buf) {
            if n == 0 {
                break;
            }
            for ch in String::from_utf8_lossy(&buf[..n]).chars() {
                if ch == '\n' || ch == '\r' {
                    // «12.50%»
                    if let Some(v) = line.trim().strip_suffix('%').and_then(|v| v.replace(',', ".").parse::<f64>().ok()) {
                        let _ = tx.send(v / 100.0);
                    } else if !line.trim().is_empty() {
                        let mut t = t2.lock().unwrap();
                        t.push_str(line.trim());
                        t.push('\n');
                        if t.len() > 4000 {
                            let cut = t.len() - 4000;
                            t.drain(..cut);
                        }
                    }
                    line.clear();
                } else {
                    line.push(ch);
                }
            }
        }
    });
    let started = std::time::Instant::now();
    let status = loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::cancelled());
        }
        while let Ok(p) = rx.try_recv() {
            progress(base + (0.9 - base) * p.clamp(0.0, 1.0));
        }
        if let Some(st) = child.try_wait()? {
            break st;
        }
        if started.elapsed().as_secs() > 1800 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::new("ci mette troppo: prova con un ingrandimento minore"));
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
    };
    let _ = reader.join();
    if !status.success() || !outp.is_file() {
        let t = tail.lock().unwrap().to_ascii_lowercase();
        if t.contains("vulkan") || t.contains("gpu") || t.contains("vk") {
            return Err(EngineError::new("la scheda video di questo PC non supporta l'IA (Vulkan): aggiorna i driver della scheda video e riprova"));
        }
        return Err(EngineError::new("il motore per migliorare le foto si è fermato"));
    }
    let up = image::open(&outp).map_err(|e| EngineError::new(e.to_string()))?;
    let mut res = if up.dimensions() != (tw, th) { up.resize_exact(tw, th, image::imageops::FilterType::Lanczos3) } else { up };
    // Intensità: mescola con la foto ingrandita normalmente
    let s = strength.min(100) as f32 / 100.0;
    if s < 0.999 {
        let plain = photo.img.resize_exact(tw, th, image::imageops::FilterType::CatmullRom).to_rgb8();
        let mut ai = res.to_rgb8();
        for (a, p) in ai.pixels_mut().zip(plain.pixels()) {
            for c in 0..3 {
                a[c] = (a[c] as f32 * s + p[c] as f32 * (1.0 - s)).round() as u8;
            }
        }
        res = DynamicImage::ImageRgb8(ai);
    }
    // La trasparenza (PNG) torna com'era, ingrandita
    if let Some(a) = alpha {
        let a = image::imageops::resize(&a, tw, th, image::imageops::FilterType::Lanczos3);
        let rgb = res.to_rgb8();
        res = DynamicImage::ImageRgba8(RgbaImage::from_fn(tw, th, |x, y| {
            let p = rgb.get_pixel(x, y);
            image::Rgba([p[0], p[1], p[2], a.get_pixel(x, y)[1]])
        }));
    }
    progress(0.95);
    let e = names::ext(src);
    let ext = if has_alpha { "png".to_string() } else if ["jpg", "jpeg", "png", "webp", "tiff", "bmp"].contains(&e.as_str()) { if e == "jpeg" { "jpg".into() } else { e } } else { "jpg".into() };
    let label = if factor == 1 { "migliorata".to_string() } else { format!("{factor}×") };
    let of = names::OutFile::new(dir, &format!("{} ({label})", names::stem(src)), &ext)?;
    images::save(tools, &Photo { img: res, exif: photo.exif, icc: photo.icc }, &ext, 93, &of.tmp)?;
    let p = of.commit()?;
    progress(1.0);
    Ok(p)
}
