//! PDF in immagini (una per pagina) e «Estrai il testo» dai PDF, come sul Mac.
//! Le pagine si disegnano con il lettore PDF di Windows (Windows.Data.Pdf), sul computer.
//! Il testo: prima quello scritto nel PDF; se non c'è (PDF scansionato), si legge dalle pagine con
//! il riconoscimento del testo di Windows.

use crate::error::{EngineError, Result};
use crate::names;
use crate::run::Cancel;
use std::path::{Path, PathBuf};

/// Punti per pollice delle immagini: nitide da leggere e da stampare, senza file enormi.
#[cfg_attr(not(windows), allow(dead_code))]
const DPI: f32 = 200.0;
/// Il lato lungo di una pagina non supera mai questi pixel (pagine giganti, tavole tecniche).
#[cfg_attr(not(windows), allow(dead_code))]
const MAX_SIDE: f32 = 6000.0;

#[cfg_attr(not(windows), allow(dead_code))]
fn tmp_name(tag: &str) -> String {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("orbitlr-{tag}-{}-{n}.png", std::process::id())
}

/// Ogni pagina in un PNG temporaneo; `each(indice, totale, png)` decide cosa farne. Restituisce le pagine.
#[cfg(windows)]
fn render_pages(src: &Path, cancel: &Cancel, each: &mut dyn FnMut(u32, u32, &Path) -> Result<()>) -> Result<u32> {
    use windows::core::HSTRING;
    use windows::Data::Pdf::{PdfDocument, PdfPageRenderOptions};
    use windows::Storage::{CreationCollisionOption, FileAccessMode, StorageFile, StorageFolder};
    let fail = |e: windows::core::Error| EngineError::new(format!("il lettore PDF di Windows non riesce ad aprirlo: {}", e.message()));
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(src.as_os_str())).map_err(fail)?.join().map_err(fail)?;
    let doc = PdfDocument::LoadFromFileAsync(&file).map_err(fail)?.join().map_err(|e| {
        if e.message().to_lowercase().contains("password") {
            EngineError::new("il PDF è protetto da password: toglila prima con «Togli la password»")
        } else {
            fail(e)
        }
    })?;
    let total = doc.PageCount().map_err(fail)?;
    if total == 0 {
        return Err(EngineError::new("il PDF non ha pagine"));
    }
    let tmpdir = std::env::temp_dir();
    let folder = StorageFolder::GetFolderFromPathAsync(&HSTRING::from(tmpdir.as_os_str())).map_err(fail)?.join().map_err(fail)?;
    for i in 0..total {
        cancel.check()?;
        let page = doc.GetPage(i).map_err(fail)?;
        let size = page.Size().map_err(fail)?;
        let (w, h) = (size.Width.max(1.0), size.Height.max(1.0));
        let mut scale = DPI / 72.0;
        if w.max(h) * scale > MAX_SIDE {
            scale = MAX_SIDE / w.max(h);
        }
        let opts = PdfPageRenderOptions::new().map_err(fail)?;
        opts.SetDestinationWidth((w * scale).round().max(1.0) as u32).map_err(fail)?;
        opts.SetDestinationHeight((h * scale).round().max(1.0) as u32).map_err(fail)?;
        let name = tmp_name("pagina");
        let out = folder.CreateFileAsync(&HSTRING::from(name.as_str()), CreationCollisionOption::ReplaceExisting).map_err(fail)?.join().map_err(fail)?;
        {
            let stream = out.OpenAsync(FileAccessMode::ReadWrite).map_err(fail)?.join().map_err(fail)?;
            page.RenderWithOptionsToStreamAsync(&stream, &opts).map_err(fail)?.join().map_err(fail)?;
            let _ = stream.FlushAsync().map_err(fail)?.join();
        }
        let png = tmpdir.join(&name);
        let r = each(i, total, &png);
        let _ = std::fs::remove_file(&png);
        r?;
    }
    Ok(total)
}

#[cfg(not(windows))]
fn render_pages(_src: &Path, _cancel: &Cancel, _each: &mut dyn FnMut(u32, u32, &Path) -> Result<()>) -> Result<u32> {
    Err(EngineError::new("le pagine dei PDF si disegnano con Windows: qui non è disponibile"))
}

/// Ogni pagina del PDF in un'immagine PNG o JPG, accanto all'originale: «documento - pagina 1.png».
pub fn to_images(src: &Path, to: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<PathBuf>> {
    let to = if to == "jpeg" { "jpg" } else { to };
    if to != "png" && to != "jpg" {
        return Err(EngineError::new(format!("le pagine dei PDF diventano PNG o JPG, non {}", to.to_uppercase())));
    }
    let stem = names::stem(src);
    let mut outs = Vec::new();
    let mut made = |i: u32, total: u32, png: &Path| -> Result<()> {
        let base = if total == 1 { stem.clone() } else { format!("{stem} - {} {}", names::tag("pagina"), i + 1) };
        let of = names::OutFile::new(dir, &base, to)?;
        if to == "png" {
            std::fs::copy(png, &of.tmp)?;
        } else {
            let img = image::open(png).map_err(|e| EngineError::new(format!("non riesco a leggere la pagina disegnata: {e}")))?;
            // Il JPG non ha trasparenza: pagina su bianco
            let rgb = image::DynamicImage::ImageRgb8(flatten_white(&img));
            let mut f = std::io::BufWriter::new(std::fs::File::create(&of.tmp)?);
            let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut f, 90);
            rgb.write_with_encoder(enc).map_err(|e| EngineError::new(format!("non riesco a scrivere il JPG: {e}")))?;
        }
        outs.push(of.commit()?);
        progress((i + 1) as f64 / total as f64);
        Ok(())
    };
    render_pages(src, cancel, &mut made)?;
    Ok(outs)
}

fn flatten_white(img: &image::DynamicImage) -> image::RgbImage {
    let rgba = img.to_rgba8();
    image::RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let p = rgba.get_pixel(x, y).0;
        let a = p[3] as u32;
        let mix = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        image::Rgb([mix(p[0]), mix(p[1]), mix(p[2])])
    })
}

/// Il testo scritto nel PDF (vuoto se è una scansione).
pub fn embedded_text(src: &Path) -> Result<String> {
    let doc = lopdf::Document::load(src).map_err(|_| EngineError::new("non è un PDF valido"))?;
    if doc.is_encrypted() {
        return Err(EngineError::new("il PDF è protetto da password: toglila prima con «Togli la password»"));
    }
    let pages: Vec<u32> = doc.get_pages().keys().copied().collect();
    let mut out = String::new();
    for p in pages {
        if let Ok(t) = doc.extract_text(&[p]) {
            out.push_str(t.trim_end());
            out.push_str("\n\n");
        }
    }
    Ok(out)
}

/// «Estrai il testo» da un PDF: il testo scritto; se non c'è, lo legge dalle pagine.
pub fn text_file(src: &Path, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let mut text = embedded_text(src).unwrap_or_default();
    let letters = text.chars().filter(|c| c.is_alphanumeric()).count();
    if letters < 20 {
        // Scansione: si legge pagina per pagina
        let mut read = String::new();
        let mut each = |i: u32, total: u32, png: &Path| -> Result<()> {
            let t = crate::ocr::recognize_png(png).unwrap_or_default();
            read.push_str(t.trim_end());
            read.push_str("\n\n");
            progress((i + 1) as f64 / total as f64);
            Ok(())
        };
        render_pages(src, cancel, &mut each)?;
        if read.chars().filter(|c| c.is_alphanumeric()).count() < 3 {
            return Err(EngineError::new("non ho trovato testo in questo PDF"));
        }
        text = read;
    }
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), names::tag("testo")), "txt")?;
    std::fs::write(&of.tmp, text.trim())?;
    progress(1.0);
    of.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn testo_di_un_pdf_senza_testo_e_vuoto() {
        let d = std::env::temp_dir().join(format!("orbit-pdftext-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let img = image::RgbImage::from_pixel(20, 20, image::Rgb([255, 255, 255]));
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut buf, image::ImageFormat::Jpeg).unwrap();
        let p = d.join("scansione.pdf");
        crate::pdf::images_to_pdf(&[(buf.into_inner(), 20, 20)], &p).unwrap();
        let t = embedded_text(&p).unwrap();
        assert!(t.chars().filter(|c| c.is_alphanumeric()).count() < 20);
        assert!(to_images(&p, "gif", &d, &Cancel::new(), &mut |_| {}).is_err());
    }

    #[test]
    fn bianco_sotto_la_trasparenza() {
        let img = image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(1, 1, image::Rgba([0, 0, 0, 0])));
        assert_eq!(flatten_white(&img).get_pixel(0, 0).0, [255, 255, 255]);
    }
}
