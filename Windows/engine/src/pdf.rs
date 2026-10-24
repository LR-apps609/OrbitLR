//! PDF: foto in PDF (scritto a mano, una foto per pagina), unisci, dividi ed estrai pagine (con lopdf).

use crate::error::{EngineError, Result};
use crate::names;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Pagine con una foto JPEG ciascuna. Le pagine hanno le proporzioni della foto, lato lungo come un A4.
pub fn images_to_pdf(pages: &[(Vec<u8>, u32, u32)], out: &Path) -> Result<()> {
    if pages.is_empty() {
        return Err(EngineError::new("nessuna foto da mettere nel PDF"));
    }
    let mut buf: Vec<u8> = Vec::new();
    let mut offsets: Vec<usize> = Vec::new();
    buf.extend_from_slice(b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
    let n = pages.len();
    // Oggetti: 1 catalogo, 2 pagine, poi per ogni pagina: pagina, immagine, contenuto
    let page_id = |i: usize| 3 + i * 3;
    let obj = |buf: &mut Vec<u8>, offsets: &mut Vec<usize>, id: usize, body: &[u8]| {
        if offsets.len() <= id {
            offsets.resize(id + 1, 0);
        }
        offsets[id] = buf.len();
        let _ = write!(buf, "{id} 0 obj\n");
        buf.extend_from_slice(body);
        buf.extend_from_slice(b"\nendobj\n");
    };
    obj(&mut buf, &mut offsets, 1, b"<< /Type /Catalog /Pages 2 0 R >>");
    let kids: Vec<String> = (0..n).map(|i| format!("{} 0 R", page_id(i))).collect();
    obj(&mut buf, &mut offsets, 2, format!("<< /Type /Pages /Kids [{}] /Count {n} >>", kids.join(" ")).as_bytes());
    for (i, (jpg, w, h)) in pages.iter().enumerate() {
        let (w, h) = ((*w).max(1) as f64, (*h).max(1) as f64);
        let k = 842.0 / w.max(h);
        let (pw, ph) = ((w * k).round(), (h * k).round());
        let pid = page_id(i);
        obj(
            &mut buf,
            &mut offsets,
            pid,
            format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pw} {ph}] /Resources << /XObject << /Im0 {} 0 R >> >> /Contents {} 0 R >>", pid + 1, pid + 2).as_bytes(),
        );
        let mut img = format!("<< /Type /XObject /Subtype /Image /Width {} /Height {} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {} >>\nstream\n", w as u32, h as u32, jpg.len()).into_bytes();
        img.extend_from_slice(jpg);
        img.extend_from_slice(b"\nendstream");
        obj(&mut buf, &mut offsets, pid + 1, &img);
        let content = format!("q {pw} 0 0 {ph} 0 0 cm /Im0 Do Q");
        obj(&mut buf, &mut offsets, pid + 2, format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()).as_bytes());
    }
    let xref = buf.len();
    let count = offsets.len();
    let _ = write!(buf, "xref\n0 {count}\n0000000000 65535 f \n");
    for off in offsets.iter().skip(1) {
        let _ = write!(buf, "{off:010} 00000 n \n");
    }
    let _ = write!(buf, "trailer\n<< /Size {count} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
    std::fs::write(out, buf)?;
    Ok(())
}

fn load(p: &Path) -> Result<lopdf::Document> {
    let doc = lopdf::Document::load(p).map_err(|_| EngineError::new(format!("«{}» non è un PDF valido", p.file_name().unwrap_or_default().to_string_lossy())))?;
    if doc.is_encrypted() {
        return Err(EngineError::new(format!("«{}» è protetto da password", p.file_name().unwrap_or_default().to_string_lossy())));
    }
    Ok(doc)
}

pub fn page_count(p: &Path) -> Result<usize> {
    Ok(load(p)?.get_pages().len())
}

/// «1-3, 5» → [1, 2, 3, 5] (pagine contate da 1).
pub fn parse_pages(s: &str, total: usize) -> Result<Vec<u32>> {
    let mut out = Vec::new();
    for part in s.split([',', ';', ' ']).filter(|p| !p.trim().is_empty()) {
        let part = part.trim().replace('–', "-");
        let (a, b) = match part.split_once('-') {
            Some((a, b)) => (a.trim().to_string(), b.trim().to_string()),
            None => (part.clone(), part.clone()),
        };
        let a: usize = a.parse().map_err(|_| EngineError::new(format!("non capisco «{part}»: scrivi per esempio 1-3, 5")))?;
        let b: usize = if b.is_empty() { total } else { b.parse().map_err(|_| EngineError::new(format!("non capisco «{part}»")))? };
        if a == 0 || b < a || b > total {
            return Err(EngineError::new(format!("il PDF ha {total} pagine: «{part}» non va bene")));
        }
        for n in a..=b {
            if !out.contains(&(n as u32)) {
                out.push(n as u32);
            }
        }
    }
    if out.is_empty() {
        return Err(EngineError::new("scrivi quali pagine, per esempio 1-3, 5"));
    }
    Ok(out)
}

/// Tiene solo le pagine scelte, in un PDF nuovo.
pub fn extract(src: &Path, pages: &str, dir: &Path) -> Result<PathBuf> {
    let mut doc = load(src)?;
    let total = doc.get_pages().len();
    let keep = parse_pages(pages, total)?;
    let drop: Vec<u32> = (1..=total as u32).filter(|n| !keep.contains(n)).collect();
    doc.delete_pages(&drop);
    doc.prune_objects();
    doc.compress();
    let of = names::OutFile::new(dir, &format!("{} (pagine {})", names::stem(src), pages.trim()), "pdf")?;
    doc.save(&of.tmp).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    of.commit()
}

/// Un PDF per ogni pagina.
pub fn split(src: &Path, dir: &Path) -> Result<Vec<PathBuf>> {
    let total = page_count(src)?;
    if total == 0 {
        return Err(EngineError::new("il PDF non ha pagine"));
    }
    if total < 2 {
        return Err(EngineError::new("il PDF ha una pagina sola"));
    }
    let mut outs = Vec::new();
    for n in 1..=total as u32 {
        let mut doc = load(src)?;
        let drop: Vec<u32> = (1..=total as u32).filter(|&k| k != n).collect();
        doc.delete_pages(&drop);
        doc.prune_objects();
        doc.compress();
        let of = names::OutFile::new(dir, &format!("{} - pagina {n}", names::stem(src)), "pdf")?;
        doc.save(&of.tmp).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
        outs.push(of.commit()?);
    }
    Ok(outs)
}

/// Unisci più PDF in uno, nell'ordine dato. Ogni pagina si porta dietro le misure, le risorse e la rotazione
/// che ereditava dal suo documento; poi un indice nuovo e pulito.
pub fn merge(files: &[PathBuf], dir: &Path) -> Result<PathBuf> {
    use lopdf::{Dictionary, Document, Object, ObjectId};
    if files.len() < 2 {
        return Err(EngineError::new("servono almeno due PDF"));
    }
    let mut out = Document::with_version("1.5");
    let mut max_id = 1;
    let mut kids: Vec<ObjectId> = Vec::new();
    for f in files {
        let mut doc = load(f)?;
        doc.renumber_objects_with(max_id);
        max_id = doc.max_id + 1;
        let pages: Vec<ObjectId> = doc.get_pages().into_values().collect();
        // Attributi ereditati dai genitori: dentro ogni pagina
        for &pid in &pages {
            let mut inherited: Vec<(Vec<u8>, Object)> = Vec::new();
            let mut parent = doc.get_dictionary(pid).ok().and_then(|d| d.get(b"Parent").ok()).and_then(|o| o.as_reference().ok());
            let mut guard = 0;
            while let Some(par) = parent {
                guard += 1;
                if guard > 64 {
                    break;
                }
                let Ok(pd) = doc.get_dictionary(par) else { break };
                for key in [&b"MediaBox"[..], b"CropBox", b"Resources", b"Rotate"] {
                    if !inherited.iter().any(|(k, _)| k == key) {
                        if let Ok(v) = pd.get(key) {
                            inherited.push((key.to_vec(), v.clone()));
                        }
                    }
                }
                parent = pd.get(b"Parent").ok().and_then(|o| o.as_reference().ok());
            }
            if let Ok(Object::Dictionary(d)) = doc.get_object_mut(pid) {
                for (k, v) in inherited {
                    if d.get(&k).is_err() {
                        d.set(k, v);
                    }
                }
            }
            kids.push(pid);
        }
        out.objects.extend(doc.objects);
    }
    if kids.is_empty() {
        return Err(EngineError::new("PDF senza pagine"));
    }
    let pages_id: ObjectId = (max_id, 0);
    let catalog_id: ObjectId = (max_id + 1, 0);
    for pid in &kids {
        if let Ok(Object::Dictionary(d)) = out.get_object_mut(*pid) {
            d.set("Parent", Object::Reference(pages_id));
        }
    }
    let mut pages = Dictionary::new();
    pages.set("Type", Object::Name(b"Pages".to_vec()));
    pages.set("Count", Object::Integer(kids.len() as i64));
    pages.set("Kids", Object::Array(kids.iter().map(|k| Object::Reference(*k)).collect()));
    out.objects.insert(pages_id, Object::Dictionary(pages));
    let mut catalog = Dictionary::new();
    catalog.set("Type", Object::Name(b"Catalog".to_vec()));
    catalog.set("Pages", Object::Reference(pages_id));
    out.objects.insert(catalog_id, Object::Dictionary(catalog));
    out.trailer.set("Root", Object::Reference(catalog_id));
    out.max_id = max_id + 1;
    // Via i vecchi indici e tutto ciò che non serve più
    out.prune_objects();
    out.renumber_objects();
    out.compress();
    let of = names::OutFile::new(dir, &format!("{} (uniti)", names::stem(&files[0])), "pdf")?;
    out.save(&of.tmp).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    of.commit()
}

/// Livelli di «Comprimi» (come su Mac): qualità JPEG e lato lungo massimo delle immagini.
pub fn level_settings(level: &str) -> (u8, u32) {
    match level {
        "light" => (80, 2400),  // qualità di stampa
        "strong" => (50, 1100), // il più leggero possibile, ancora leggibile
        _ => (65, 1600),        // schermo ed email
    }
}

/// Comprimi un PDF: le foto dentro vengono ricompresse in JPEG e riportate a una misura sensata.
/// Testo, link e moduli restano come sono. Solo le immagini RGB o in scala di grigi a 8 bit
/// (le altre, rare, restano com'erano).
pub fn compress(src: &Path, level: &str, dir: &Path, cancel: &crate::run::Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    use lopdf::Object;
    let before = std::fs::metadata(src)?.len();
    let mut doc = load(src)?;
    let pages = doc.get_pages().len();
    let (quality, max_side) = level_settings(level);
    let ids: Vec<lopdf::ObjectId> = doc
        .objects
        .iter()
        .filter(|(_, o)| matches!(o, Object::Stream(st) if st.dict.get(b"Subtype").and_then(|v| v.as_name()).map(|n| n == b"Image").unwrap_or(false)))
        .map(|(id, _)| *id)
        .collect();
    let n = ids.len().max(1);
    for (k, id) in ids.iter().enumerate() {
        cancel.check()?;
        progress(k as f64 / n as f64 * 0.9);
        let Some(Object::Stream(st)) = doc.objects.get(id) else { continue };
        let num = |key: &[u8]| st.dict.get(key).ok().and_then(|v| v.as_i64().ok()).unwrap_or(0);
        let (w, h, bpc) = (num(b"Width") as u32, num(b"Height") as u32, num(b"BitsPerComponent"));
        if w < 64 || h < 64 || bpc != 8 || st.dict.get(b"Decode").is_ok() || st.dict.get(b"ImageMask").is_ok() {
            continue;
        }
        let cs = st.dict.get(b"ColorSpace").ok().and_then(|v| v.as_name().ok()).map(|n| n.to_vec());
        let gray = match cs.as_deref() {
            Some(b"DeviceRGB") => false,
            Some(b"DeviceGray") => true,
            _ => continue, // CMYK, Indexed, ICC: restano com'erano
        };
        let filters: Vec<Vec<u8>> = st.filters().map(|f| f.iter().map(|x| x.to_vec()).collect()).unwrap_or_default();
        let img: Option<image::DynamicImage> = if filters.len() == 1 && filters[0] == b"DCTDecode" {
            image::load_from_memory_with_format(&st.content, image::ImageFormat::Jpeg).ok()
        } else if filters.is_empty() || (filters.len() == 1 && filters[0] == b"FlateDecode") {
            let raw = if filters.is_empty() { Some(st.content.clone()) } else { st.decompressed_content_with_limit(400_000_000).ok() };
            raw.and_then(|r| {
                let ch = if gray { 1 } else { 3 };
                if r.len() < (w * h * ch) as usize {
                    return None;
                }
                let r = r[..(w * h * ch) as usize].to_vec();
                if gray { image::GrayImage::from_raw(w, h, r).map(image::DynamicImage::ImageLuma8) } else { image::RgbImage::from_raw(w, h, r).map(image::DynamicImage::ImageRgb8) }
            })
        } else {
            None
        };
        let Some(img) = img else { continue };
        let img = if img.width().max(img.height()) > max_side { img.resize(max_side, max_side, image::imageops::FilterType::Lanczos3) } else { img };
        let mut buf = Vec::new();
        let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality);
        let ok = if gray { img.to_luma8().write_with_encoder(enc).is_ok() } else { img.to_rgb8().write_with_encoder(enc).is_ok() };
        if !ok || buf.len() as f64 >= st.content.len() as f64 * 0.9 {
            continue; // non conviene: resta com'era
        }
        let (nw, nh) = (img.width(), img.height());
        if let Some(Object::Stream(st)) = doc.objects.get_mut(id) {
            st.dict.set("Width", nw as i64);
            st.dict.set("Height", nh as i64);
            st.dict.set("Filter", Object::Name(b"DCTDecode".to_vec()));
            st.dict.remove(b"DecodeParms");
            st.set_content(buf);
            st.allows_compression = false;
        }
    }
    doc.prune_objects();
    doc.compress();
    let of = names::OutFile::new(dir, &format!("{} (compresso)", names::stem(src)), "pdf")?;
    doc.save(&of.tmp).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    // Deve restare un PDF valido, con tutte le pagine
    if load(&of.tmp).map(|d| d.get_pages().len()).unwrap_or(0) != pages {
        return Err(EngineError::new("la compressione ha rovinato il PDF: lascio l'originale"));
    }
    let after = std::fs::metadata(&of.tmp)?.len();
    if after >= before * 97 / 100 {
        return Err(EngineError::new(format!("«{}» è già compresso al massimo", src.file_name().unwrap_or_default().to_string_lossy())));
    }
    progress(1.0);
    of.commit()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pagine() {
        assert_eq!(parse_pages("1-3, 5", 6).unwrap(), vec![1, 2, 3, 5]);
        assert_eq!(parse_pages("4-", 6).unwrap(), vec![4, 5, 6]);
        assert!(parse_pages("7", 6).is_err());
        assert!(parse_pages("", 6).is_err());
    }
}
