//! «Nascondi un logo» con l'IA (come «Rimuovi filigrana» sul Mac): LaMa (Apache-2.0) ricostruisce
//! quello che c'era dietro il logo, invece di sfocarlo. Gira con tract, sul processore, sul computer.
//! Ogni zona si lavora in una finestra quadrata attorno (con un po' di contesto), a 512 pixel.

use crate::download::{self, Item};
use crate::error::{EngineError, Result};
use crate::run::Cancel;
use image::{GrayImage, Luma, RgbImage, RgbaImage};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tract_onnx::prelude::*;

pub const LAMA_MODEL: Item = Item {
    url: "https://github.com/LR-apps609/OrbitLR/releases/download/modelli-1/lama-512.onnx",
    sha256: LAMA_SHA256,
    bytes: LAMA_BYTES,
    what: "il modello per togliere i loghi",
};
const LAMA_SHA256: &str = "";
const LAMA_BYTES: u64 = 0;

const S: usize = 512;

pub fn model_path(data_dir: &Path) -> PathBuf {
    crate::ai::models_dir(data_dir).join("lama-512.onnx")
}

/// Il modello c'è già (non serve scaricarlo)?
pub fn ready(data_dir: &Path) -> bool {
    download::ready(&model_path(data_dir), &LAMA_MODEL)
}

type Model = Arc<TypedRunnableModel<TypedModel>>;
static LAMA: Mutex<Option<Model>> = Mutex::new(None);

fn model(path: &Path) -> Result<Model> {
    let mut g = LAMA.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = g.as_ref() {
        return Ok(m.clone());
    }
    let m = tract_onnx::onnx()
        .model_for_path(path)
        .and_then(|m| m.with_input_fact(0, f32::fact([1, 3, S, S]).into()))
        .and_then(|m| m.with_input_fact(1, f32::fact([1, 1, S, S]).into()))
        .and_then(|m| m.into_optimized())
        .and_then(|m| m.into_runnable())
        .map_err(|e| EngineError::new(format!("il modello per i loghi non si apre ({e}): cancellalo dalle Opzioni e riprova")))?;
    let m = Arc::new(m);
    *g = Some(m.clone());
    Ok(m)
}

/// Una finestra 512×512 (foto e maschera) → la foto ricostruita (512×512).
pub type Infer<'a> = dyn FnMut(&RgbImage, &GrayImage) -> Result<RgbImage> + 'a;

fn lama_infer(m: &Model, img: &RgbImage, mask: &GrayImage) -> Result<RgbImage> {
    let it: Tensor = tract_ndarray::Array4::from_shape_fn((1, 3, S, S), |(_, c, y, x)| img.get_pixel(x as u32, y as u32)[c] as f32 / 255.0).into();
    let mt: Tensor = tract_ndarray::Array4::from_shape_fn((1, 1, S, S), |(_, _, y, x)| if mask.get_pixel(x as u32, y as u32)[0] > 127 { 1.0f32 } else { 0.0 }).into();
    let out = m.run(tvec!(it.into(), mt.into())).map_err(|e| EngineError::new(format!("l'IA per i loghi si è fermata: {e}")))?;
    let o = out[0].to_array_view::<f32>().map_err(|e| EngineError::new(e.to_string()))?;
    // Alcune versioni danno 0…1, altre 0…255
    let ma = o.iter().fold(0.0f32, |a, v| a.max(*v));
    let k = if ma > 2.0 { 1.0 } else { 255.0 };
    Ok(RgbImage::from_fn(S as u32, S as u32, |x, y| image::Rgb([0, 1, 2].map(|c| (o[[0, c, y as usize, x as usize]] * k).round().clamp(0.0, 255.0) as u8))))
}

/// La finestra quadrata attorno a una zona: lato ~2,5 volte la zona (più contesto), dentro la foto.
pub fn window(zone: (u32, u32, u32, u32), w: u32, h: u32) -> (u32, u32, u32) {
    let (x, y, zw, zh) = zone;
    let side = ((zw.max(zh) as f32 * 2.5) as u32).max(192).min(w.min(h)).max(1);
    let cx = x + zw / 2;
    let cy = y + zh / 2;
    let x0 = cx.saturating_sub(side / 2).min(w - side);
    let y0 = cy.saturating_sub(side / 2).min(h - side);
    (x0, y0, side)
}

/// Ricostruisce le zone (in pixel) della foto con `infer`.
pub fn fill_zones(img: &mut RgbaImage, zones: &[(u32, u32, u32, u32)], infer: &mut Infer, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<()> {
    let (w, h) = img.dimensions();
    for (i, &z) in zones.iter().enumerate() {
        cancel.check()?;
        let (x0, y0, side) = window(z, w, h);
        let crop = image::imageops::crop_imm(img, x0, y0, side, side).to_image();
        let rgb = image::DynamicImage::ImageRgba8(crop.clone()).to_rgb8();
        let small = image::imageops::resize(&rgb, S as u32, S as u32, image::imageops::FilterType::Triangle);
        // La maschera: la zona, un po' allargata (i bordi del logo sfumano nel fondo)
        let k = S as f32 / side as f32;
        let pad = 3.0;
        let (mx0, my0) = (((z.0 - x0) as f32 * k - pad).max(0.0), ((z.1 - y0) as f32 * k - pad).max(0.0));
        let (mx1, my1) = (((z.0 - x0 + z.2) as f32 * k + pad).min(S as f32), ((z.1 - y0 + z.3) as f32 * k + pad).min(S as f32));
        let mask = GrayImage::from_fn(S as u32, S as u32, |x, y| {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            Luma([if fx >= mx0 && fx < mx1 && fy >= my0 && fy < my1 { 255 } else { 0 }])
        });
        let out = infer(&small, &mask)?;
        let back = image::imageops::resize(&out, side, side, image::imageops::FilterType::Lanczos3);
        // Si rimette solo la zona (con un bordo sfumato di qualche pixel): il resto della foto resta originale
        let feather = 4.0f32;
        let (zx0, zy0, zx1, zy1) = ((z.0 - x0) as f32, (z.1 - y0) as f32, (z.0 - x0 + z.2) as f32, (z.1 - y0 + z.3) as f32);
        for yy in 0..side {
            for xx in 0..side {
                let (fx, fy) = (xx as f32 + 0.5, yy as f32 + 0.5);
                let d = (zx0 - feather - fx).max(fx - zx1 - feather).max(zy0 - feather - fy).max(fy - zy1 - feather);
                // d ≤ -feather: dentro del tutto; d ≥ 0: fuori
                let a = (-d / feather).clamp(0.0, 1.0);
                if a <= 0.0 {
                    continue;
                }
                let p = img.get_pixel_mut(x0 + xx, y0 + yy);
                let q = back.get_pixel(xx, yy).0;
                for c in 0..3 {
                    p.0[c] = (p.0[c] as f32 * (1.0 - a) + q[c] as f32 * a).round() as u8;
                }
            }
        }
        progress((i + 1) as f64 / zones.len() as f64);
    }
    Ok(())
}

/// Con il modello vero (lo scarica la prima volta).
pub fn fill_with_lama(data_dir: &Path, img: &mut RgbaImage, zones: &[(u32, u32, u32, u32)], cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<()> {
    if LAMA_SHA256.is_empty() {
        return Err(EngineError::new("la rimozione con l'IA non è ancora disponibile su Windows: usa «Sfocatura» o «A quadretti»"));
    }
    let path = model_path(data_dir);
    let mut base = 0.0;
    if !ready(data_dir) {
        download::fetch(&LAMA_MODEL, &path, cancel, &mut |p| progress(p * 0.6))?;
        base = 0.6;
    }
    let m = model(&path)?;
    let mut infer = |a: &RgbImage, b: &GrayImage| lama_infer(&m, a, b);
    fill_zones(img, zones, &mut infer, cancel, &mut |p| progress(base + p * (1.0 - base)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finestra_dentro_la_foto() {
        let (x, y, s) = window((10, 10, 40, 20), 1000, 800);
        assert!(x == 0 && y == 0 && s == 192);
        let (x, y, s) = window((900, 700, 90, 90), 1000, 800);
        assert!(x + s <= 1000 && y + s <= 800 && x <= 900 && y <= 700 && s == 225);
        let (_, _, s) = window((0, 0, 400, 400), 300, 200);
        assert_eq!(s, 200);
    }

    #[test]
    fn solo_la_zona_cambia() {
        let mut img = RgbaImage::from_pixel(600, 400, image::Rgba([10, 200, 30, 255]));
        for y in 100..140 {
            for x in 300..380 {
                img.put_pixel(x, y, image::Rgba([255, 0, 0, 255]));
            }
        }
        // Un finto modello: la parte mascherata diventa il colore del fondo
        let mut infer = |a: &RgbImage, m: &GrayImage| -> Result<RgbImage> {
            Ok(RgbImage::from_fn(a.width(), a.height(), |x, y| if m.get_pixel(x, y)[0] > 127 { image::Rgb([10, 200, 30]) } else { *a.get_pixel(x, y) }))
        };
        fill_zones(&mut img, &[(300, 100, 80, 40)], &mut infer, &Cancel::new(), &mut |_| {}).unwrap();
        assert_eq!(img.get_pixel(340, 120).0[0..3], [10, 200, 30]);
        assert_eq!(img.get_pixel(5, 5).0[0..3], [10, 200, 30]);
        // Il bordo della foto, lontano dalla zona, è identico
        assert_eq!(img.get_pixel(599, 399).0, [10, 200, 30, 255]);
    }
}
