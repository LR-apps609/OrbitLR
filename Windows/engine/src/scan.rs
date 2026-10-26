//! «Raddrizza»: la foto di un documento (scattata storta, con il tavolo attorno) diventa una pagina dritta,
//! come uno scanner. «Unisci più scatti»: più foto della stessa scena, allineate e fuse, per meno rumore
//! (foto di sera, al buio). Tutto sul computer.

use crate::error::{EngineError, Result};
use crate::names;
use crate::tools::Tools;
use image::{GrayImage, Rgb, RgbImage};
use imageproc::point::Point;
use std::path::{Path, PathBuf};

const WORK: u32 = 900;

fn area(p: &[Point<f64>]) -> f64 {
    let n = p.len();
    (0..n).map(|i| p[i].x * p[(i + 1) % n].y - p[(i + 1) % n].x * p[i].y).sum::<f64>().abs() / 2.0
}

fn perimeter(p: &[Point<i32>]) -> f64 {
    let n = p.len();
    (0..n).map(|i| (((p[i].x - p[(i + 1) % n].x) as f64).powi(2) + ((p[i].y - p[(i + 1) % n].y) as f64).powi(2)).sqrt()).sum()
}

/// I quattro angoli del documento (in alto a sinistra, in alto a destra, in basso a destra, in basso a sinistra).
pub fn find_corners(gray: &GrayImage) -> Option<[(f32, f32); 4]> {
    let (w, h) = gray.dimensions();
    let blur = imageproc::filter::gaussian_blur_f32(gray, 2.0);
    let edges = imageproc::edges::canny(&blur, 25.0, 75.0);
    let edges = imageproc::morphology::dilate(&edges, imageproc::distance_transform::Norm::LInf, 2);
    let contours = imageproc::contours::find_contours::<i32>(&edges);
    let total = (w as f64) * (h as f64);
    let mut best: Option<(f64, Vec<Point<f64>>)> = None;
    for c in contours.iter().filter(|c| c.border_type == imageproc::contours::BorderType::Outer && c.points.len() > 20) {
        let hull = imageproc::geometry::convex_hull(c.points.clone());
        if hull.len() < 4 {
            continue;
        }
        let eps = 0.02 * perimeter(&hull);
        let poly = imageproc::geometry::approximate_polygon_dp(&hull, eps, true);
        if poly.len() != 4 {
            continue;
        }
        let pf: Vec<Point<f64>> = poly.iter().map(|p| Point::new(p.x as f64, p.y as f64)).collect();
        let a = area(&pf);
        // Il documento occupa una buona parte della foto (ma non è il bordo della foto stessa)
        if a < total * 0.2 || a > total * 0.995 {
            continue;
        }
        if best.as_ref().map(|b| a > b.0).unwrap_or(true) {
            best = Some((a, pf));
        }
    }
    let pts = best?.1;
    // Ordine: somma minima = in alto a sinistra, massima = in basso a destra; differenza per gli altri due
    let by = |f: &dyn Fn(&Point<f64>) -> f64, max: bool| -> Point<f64> {
        *pts.iter().max_by(|a, b| {
            let (x, y) = (f(a), f(b));
            if max { x.partial_cmp(&y).unwrap() } else { y.partial_cmp(&x).unwrap() }
        }).unwrap()
    };
    let tl = by(&|p| p.x + p.y, false);
    let br = by(&|p| p.x + p.y, true);
    let tr = by(&|p| p.x - p.y, true);
    let bl = by(&|p| p.x - p.y, false);
    Some([(tl.x as f32, tl.y as f32), (tr.x as f32, tr.y as f32), (br.x as f32, br.y as f32), (bl.x as f32, bl.y as f32)])
}

fn dist(a: (f32, f32), b: (f32, f32)) -> f32 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

/// Raddrizza una foto: restituisce la pagina dritta.
pub fn straighten_image(img: &RgbImage) -> Result<RgbImage> {
    let (w, h) = img.dimensions();
    let k = (WORK as f32 / w.max(h) as f32).min(1.0);
    let small = image::imageops::resize(img, ((w as f32 * k).round() as u32).max(1), ((h as f32 * k).round() as u32).max(1), image::imageops::FilterType::Triangle);
    let gray = image::imageops::grayscale(&small);
    let c = find_corners(&gray).ok_or_else(|| EngineError::new("non trovo i bordi del documento: fotografalo su un fondo scuro, con tutti e quattro gli angoli dentro la foto"))?;
    let c = c.map(|(x, y)| (x / k, y / k));
    let out_w = dist(c[0], c[1]).max(dist(c[3], c[2])).round().max(16.0) as u32;
    let out_h = dist(c[0], c[3]).max(dist(c[1], c[2])).round().max(16.0) as u32;
    let to = [(0.0, 0.0), (out_w as f32 - 1.0, 0.0), (out_w as f32 - 1.0, out_h as f32 - 1.0), (0.0, out_h as f32 - 1.0)];
    let proj = imageproc::geometric_transformations::Projection::from_control_points(c, to).ok_or_else(|| EngineError::new("non riesco a raddrizzare questa foto"))?;
    let mut out = RgbImage::new(out_w, out_h);
    imageproc::geometric_transformations::warp_into(img, &proj, imageproc::geometric_transformations::Interpolation::Bilinear, Rgb([255, 255, 255]), &mut out);
    Ok(out)
}

/// «Raddrizza»: una foto di un documento → JPG dritto (o PDF con `pdf`).
pub fn straighten(tools: Option<&Tools>, src: &Path, pdf: bool, dir: &Path) -> Result<PathBuf> {
    let photo = crate::images::open(tools, src)?;
    let out = straighten_image(&photo.img.to_rgb8())?;
    let base = format!("{} ({})", names::stem(src), names::tag("raddrizzato"));
    let mut jpg = Vec::new();
    image::DynamicImage::ImageRgb8(out.clone())
        .write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpg, 90))
        .map_err(|e| EngineError::new(e.to_string()))?;
    if pdf {
        let of = names::OutFile::new(dir, &base, "pdf")?;
        crate::pdf::images_to_pdf(&[(jpg, out.width(), out.height())], &of.tmp)?;
        of.commit()
    } else {
        let of = names::OutFile::new(dir, &base, "jpg")?;
        std::fs::write(&of.tmp, jpg)?;
        of.commit()
    }
}

// ───────────────────────── Unisci più scatti

/// Lo spostamento (dx, dy) che sovrappone `b` ad `a` (immagini piccole, in grigio).
fn shift(a: &GrayImage, b: &GrayImage, range: i32, cx: i32, cy: i32, step: i32) -> (i32, i32) {
    let (w, h) = a.dimensions();
    let margin = range + cx.abs().max(cy.abs()) + 1;
    let mut best = (cx, cy, f64::MAX);
    let mut dy = cy - range;
    while dy <= cy + range {
        let mut dx = cx - range;
        while dx <= cx + range {
            let mut sum = 0u64;
            let mut n = 0u64;
            let mut y = margin;
            while y < h as i32 - margin {
                let mut x = margin;
                while x < w as i32 - margin {
                    let pa = a.get_pixel(x as u32, y as u32)[0] as i64;
                    let pb = b.get_pixel((x + dx) as u32, (y + dy) as u32)[0] as i64;
                    sum += (pa - pb).unsigned_abs();
                    n += 1;
                    x += 2;
                }
                y += 2;
            }
            let s = sum as f64 / n.max(1) as f64;
            if s < best.2 {
                best = (dx, dy, s);
            }
            dx += step;
        }
        dy += step;
    }
    (best.0, best.1)
}

/// Fonde più foto della stessa scena: allineate (spostamenti della mano) e mediate, per meno rumore.
pub fn stack_images(imgs: &[RgbImage]) -> Result<RgbImage> {
    if imgs.len() < 2 {
        return Err(EngineError::new("servono almeno due foto della stessa scena"));
    }
    let (w, h) = imgs[0].dimensions();
    if imgs.iter().any(|i| i.dimensions() != (w, h)) {
        return Err(EngineError::new("le foto devono avere la stessa misura (scattate con lo stesso telefono, una dopo l'altra)"));
    }
    let k = (480.0 / w.max(h) as f32).min(1.0);
    let sw = ((w as f32 * k) as u32).max(16);
    let sh = ((h as f32 * k) as u32).max(16);
    let small: Vec<GrayImage> = imgs.iter().map(|i| image::imageops::grayscale(&image::imageops::resize(i, sw, sh, image::imageops::FilterType::Triangle))).collect();
    let range = (sw.max(sh) as f32 * 0.04).ceil() as i32;
    let mut sums = vec![0u32; (w * h * 3) as usize];
    let mut counts = vec![0u16; (w * h) as usize];
    for (idx, img) in imgs.iter().enumerate() {
        let (dx, dy) = if idx == 0 { (0, 0) } else {
            let (cx, cy) = shift(&small[0], &small[idx], range, 0, 0, 1);
            ((cx as f32 / k).round() as i32, (cy as f32 / k).round() as i32)
        };
        for y in 0..h as i32 {
            let sy = y + dy;
            if sy < 0 || sy >= h as i32 {
                continue;
            }
            for x in 0..w as i32 {
                let sx = x + dx;
                if sx < 0 || sx >= w as i32 {
                    continue;
                }
                let p = img.get_pixel(sx as u32, sy as u32).0;
                let o = (y as u32 * w + x as u32) as usize;
                sums[o * 3] += p[0] as u32;
                sums[o * 3 + 1] += p[1] as u32;
                sums[o * 3 + 2] += p[2] as u32;
                counts[o] += 1;
            }
        }
    }
    Ok(RgbImage::from_fn(w, h, |x, y| {
        let o = (y * w + x) as usize;
        let n = counts[o].max(1) as u32;
        Rgb([(sums[o * 3] / n) as u8, (sums[o * 3 + 1] / n) as u8, (sums[o * 3 + 2] / n) as u8])
    }))
}

pub fn stack(tools: Option<&Tools>, files: &[PathBuf], dir: &Path) -> Result<PathBuf> {
    if files.len() < 2 || files.len() > 30 {
        return Err(EngineError::new("scegli da 2 a 30 foto della stessa scena"));
    }
    let imgs: Vec<RgbImage> = files.iter().map(|f| crate::images::open(tools, f).map(|p| p.img.to_rgb8())).collect::<Result<_>>()?;
    let out = stack_images(&imgs)?;
    let of = names::OutFile::new(dir, &format!("{} ({} {})", names::stem(&files[0]), files.len(), names::tag("scatti")), "jpg")?;
    let mut f = std::io::BufWriter::new(std::fs::File::create(&of.tmp)?);
    image::DynamicImage::ImageRgb8(out).write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(&mut f, 93)).map_err(|e| EngineError::new(e.to_string()))?;
    drop(f);
    of.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Un foglio bianco storto su un tavolo scuro.
    fn photo() -> RgbImage {
        let mut img = RgbImage::from_pixel(400, 300, Rgb([40, 40, 45]));
        let quad = [(80.0f32, 50.0f32), (330.0, 70.0), (310.0, 260.0), (60.0, 240.0)];
        for y in 0..300 {
            for x in 0..400 {
                let (px, py) = (x as f32, y as f32);
                // dentro il quadrilatero (convesso): stesso lato per tutti i bordi
                let inside = (0..4).all(|i| {
                    let (ax, ay) = quad[i];
                    let (bx, by) = quad[(i + 1) % 4];
                    (bx - ax) * (py - ay) - (by - ay) * (px - ax) >= 0.0
                });
                if inside {
                    img.put_pixel(x, y, Rgb([245, 245, 240]));
                }
            }
        }
        img
    }

    #[test]
    fn trova_gli_angoli_e_raddrizza() {
        let img = photo();
        let gray = image::imageops::grayscale(&img);
        let c = find_corners(&gray).expect("angoli");
        let near = |p: (f32, f32), q: (f32, f32)| dist(p, q) < 12.0;
        assert!(near(c[0], (80.0, 50.0)) && near(c[2], (310.0, 260.0)), "{c:?}");
        let out = straighten_image(&img).unwrap();
        assert!(out.width() > 200 && out.height() > 150);
        // Al centro la pagina è bianca
        let p = out.get_pixel(out.width() / 2, out.height() / 2).0;
        assert!(p[0] > 200, "{p:?}");
        // Una foto senza documento: messaggio chiaro
        assert!(straighten_image(&RgbImage::from_pixel(200, 200, Rgb([128, 128, 128]))).is_err());
    }

    #[test]
    fn allinea_e_fonde() {
        let base = RgbImage::from_fn(200, 150, |x, y| Rgb([((x * 7 + y * 3) % 256) as u8, ((x * x / 50 + y) % 256) as u8, ((x + y * y / 40) % 256) as u8]));
        // Lo stesso scatto spostato di 4 pixel
        let moved = RgbImage::from_fn(200, 150, |x, y| *base.get_pixel(x.saturating_sub(4).min(199), y.saturating_sub(3).min(149)));
        let out = stack_images(&[base.clone(), moved]).unwrap();
        let (a, b) = (base.get_pixel(100, 75).0, out.get_pixel(100, 75).0);
        assert!((a[0] as i32 - b[0] as i32).abs() <= 3, "{a:?} {b:?}");
    }
}
