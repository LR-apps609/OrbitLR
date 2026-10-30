//! «Vettoriale (SVG)»: la foto o il logo diventa un SVG (motore `vettore`, lo stesso dell'app per Mac).
//! Sulle immagini piccole si ingrandisce prima con Real-ESRGAN (lo stesso motore di «Migliora con l'IA»):
//! i bordi diventano molto più precisi. Se il motore non c'è o non parte, si va avanti senza.

use crate::error::{EngineError, Result};
use crate::names;
use crate::run::Cancel;
use crate::tools::Tools;
use std::path::{Path, PathBuf};

/// Le scelte: «auto», «logo», «logot» (logo senza sfondo), «bw», «photo», «photomax»;
/// con «+» in fondo (per esempio «logo+») la precisione massima: il ricalco lento.
pub fn opts(param: &str) -> vettore::Opts {
    let mut o = vettore::Opts::default();
    // «pack»: il pacchetto logo (ZIP con SVG, PDF, EPS, PNG, un colore, icone), dal ricalco di precisione senza sfondo
    if param == "pack" {
        o.precise = true;
        o.transparent = true;
        return o;
    }
    // «*» in fondo: Estrema (l'SVG intero ottimizzato contro l'originale, qualche minuto)
    let param = match param.strip_suffix('*') {
        Some(p) => {
            o.precise = true;
            o.extreme = true;
            p
        }
        None => param,
    };
    let param = match param.strip_suffix('+') {
        Some(p) => {
            o.precise = true;
            p
        }
        None => param,
    };
    match param {
        "logo" => o.mode = vettore::Mode::Logo,
        "logot" => {
            o.mode = vettore::Mode::Logo;
            o.transparent = true;
        }
        "bw" => o.mode = vettore::Mode::Bw,
        "photo" => o.mode = vettore::Mode::Photo,
        "photomax" => {
            o.mode = vettore::Mode::Photo;
            o.detail = 3;
        }
        _ => {}
    }
    o
}

/// Lato lungo sotto il quale conviene ingrandire con l'IA prima di vettorializzare.
const AI_BELOW: u32 = 1000;
/// Con la precisione massima l'ingrandimento con l'IA vale la pena anche su immagini più grandi.
const AI_BELOW_PRECISE: u32 = 1600;

pub fn vectorize(tools: Option<&Tools>, data_dir: Option<&Path>, src: &Path, param: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let photo = crate::images::open(tools, src)?;
    let img = photo.img;
    let o = opts(param);
    let (w, h) = (img.width(), img.height());
    if w < 2 || h < 2 {
        return Err(EngineError::new("l'immagine è troppo piccola"));
    }
    // Ingrandimento con l'IA (non per le foto: lì si vuole il disegno della foto, non dettagli in più)
    let mut base = 0.0;
    let mut up: Option<image::DynamicImage> = None;
    let below = if o.precise { AI_BELOW_PRECISE } else { AI_BELOW };
    if o.mode != vettore::Mode::Photo && w.max(h) <= below && w.max(h) > 96 {
        if let Some(data) = data_dir {
            let tmp = std::env::temp_dir().join(format!("orbitlr-vettoriale-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)));
            struct Clean(PathBuf);
            impl Drop for Clean {
                fn drop(&mut self) {
                    let _ = std::fs::remove_dir_all(&self.0);
                }
            }
            let _clean = Clean(tmp.clone());
            if std::fs::create_dir_all(&tmp).is_ok() {
                match crate::ai::enhance(tools, data, src, 4, 100, true, &tmp, cancel, &mut |p| progress(p * 0.6)) {
                    Ok(p) => {
                        up = image::open(&p).ok();
                        base = 0.6;
                    }
                    Err(e) if e.is_cancelled() => return Err(e),
                    Err(e) => eprintln!("vettoriale: ingrandimento con l'IA non riuscito ({}), vado avanti senza", e.0),
                }
            }
        }
    }
    cancel.check()?;
    let out = vettore::vectorize(&img, up.as_ref(), &o, &mut |p| progress(base + (1.0 - base) * p), &|| cancel.is_cancelled()).map_err(|e| if cancel.is_cancelled() { EngineError::cancelled() } else { EngineError::new(e) })?;
    // 1.1 · «Interrompi» durante l'ultima pulizia delle forme: niente file
    cancel.check()?;
    if param == "pack" {
        let stem = names::stem(src);
        let root = format!("{stem} ({})", names::tag("pacchetto logo"));
        let of = names::OutFile::new(dir, &root, "zip")?;
        std::fs::write(&of.tmp, out.pack_zip(&stem, &root, names::english()))?;
        return of.commit();
    }
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), names::tag("vettoriale")), "svg")?;
    std::fs::write(&of.tmp, out.svg.as_bytes())?;
    of.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logo_in_svg() {
        let dir = std::env::temp_dir().join(format!("orbit-vett-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // Un logo: quadrato blu con un cerchio giallo, su bianco
        let img = image::RgbImage::from_fn(300, 200, |x, y| {
            let (dx, dy) = (x as f64 - 150.0, y as f64 - 100.0);
            if dx * dx + dy * dy < 60.0 * 60.0 {
                image::Rgb([240, 180, 50])
            } else if (40..260).contains(&x) && (20..180).contains(&y) {
                image::Rgb([30, 80, 120])
            } else {
                image::Rgb([255, 255, 255])
            }
        });
        let src = dir.join("logo.png");
        img.save(&src).unwrap();
        let out = vectorize(None, None, &src, "auto", &dir, &Cancel::new(), &mut |_| {}).unwrap();
        let svg = std::fs::read_to_string(&out).unwrap();
        assert!(out.file_name().unwrap().to_string_lossy().ends_with(".svg"));
        assert!(svg.starts_with("<svg") && svg.contains("viewBox=\"0 0 300 200\""));
        // il cerchio è un cerchio vero (due archi), i colori sono quelli giusti
        assert!(svg.contains('A'), "{svg}");
        assert!(svg.contains("#1e5078") || svg.contains("#1e4f78") || svg.contains("#1f5078"), "{svg}");
        // il pacchetto logo: uno ZIP con dentro SVG, PDF, EPS, PNG e la versione a un colore
        let z = vectorize(None, None, &src, "pack", &dir, &Cancel::new(), &mut |_| {}).unwrap();
        let data = std::fs::read(&z).unwrap();
        assert!(z.to_string_lossy().ends_with(".zip") && data.starts_with(b"PK"));
        let s = String::from_utf8_lossy(&data);
        for f in ["logo.svg", "logo.pdf", "logo.eps", "PNG/logo-1024.png", "logo-nero.svg", "LEGGIMI.txt"] {
            assert!(s.contains(f), "manca {f}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
