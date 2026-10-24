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
    let out = names::unique(dir, &format!("{} (pagine {})", names::stem(src), pages.trim()), "pdf");
    doc.save(&out).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    Ok(out)
}

/// Un PDF per ogni pagina.
pub fn split(src: &Path, dir: &Path) -> Result<Vec<PathBuf>> {
    let total = page_count(src)?;
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
        let out = names::unique(dir, &format!("{} - pagina {n}", names::stem(src)), "pdf");
        doc.save(&out).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
        outs.push(out);
    }
    Ok(outs)
}

/// Unisci più PDF in uno, nell'ordine dato (il metodo dell'esempio ufficiale di lopdf).
pub fn merge(files: &[PathBuf], dir: &Path) -> Result<PathBuf> {
    use lopdf::{Document, Object, ObjectId};
    use std::collections::BTreeMap;
    if files.len() < 2 {
        return Err(EngineError::new("servono almeno due PDF"));
    }
    let mut max_id = 1;
    let mut pages_all: Vec<(ObjectId, Object)> = Vec::new();
    let mut objects_all: BTreeMap<ObjectId, Object> = BTreeMap::new();
    let mut out = Document::with_version("1.5");
    for f in files {
        let mut doc = load(f)?;
        doc.renumber_objects_with(max_id);
        max_id = doc.max_id + 1;
        for (_, id) in doc.get_pages() {
            if let Ok(o) = doc.get_object(id) {
                pages_all.push((id, o.to_owned()));
            }
        }
        objects_all.extend(doc.objects);
    }
    let mut catalog: Option<(ObjectId, Object)> = None;
    let mut pages_root: Option<(ObjectId, Object)> = None;
    for (id, obj) in objects_all.iter() {
        match obj.type_name().unwrap_or(b"") {
            b"Catalog" => {
                if catalog.is_none() {
                    catalog = Some((*id, obj.clone()));
                }
            }
            b"Pages" => {
                if let Ok(d) = obj.as_dict() {
                    let mut d = d.clone();
                    if let Some((_, ref o)) = pages_root {
                        if let Ok(old) = o.as_dict() {
                            d.extend(old);
                        }
                    }
                    pages_root = Some((pages_root.as_ref().map(|p| p.0).unwrap_or(*id), Object::Dictionary(d)));
                }
            }
            b"Page" | b"Outlines" | b"Outline" => {}
            _ => {
                out.objects.insert(*id, obj.clone());
            }
        }
    }
    let (pages_id, pages_obj) = pages_root.ok_or_else(|| EngineError::new("PDF senza pagine"))?;
    let (catalog_id, catalog_obj) = catalog.ok_or_else(|| EngineError::new("PDF senza indice"))?;
    for (id, obj) in &pages_all {
        if let Ok(d) = obj.as_dict() {
            let mut d = d.clone();
            d.set("Parent", pages_id);
            out.objects.insert(*id, Object::Dictionary(d));
        }
    }
    if let Ok(d) = pages_obj.as_dict() {
        let mut d = d.clone();
        d.set("Count", pages_all.len() as u32);
        d.set("Kids", pages_all.iter().map(|(id, _)| Object::Reference(*id)).collect::<Vec<_>>());
        out.objects.insert(pages_id, Object::Dictionary(d));
    }
    if let Ok(d) = catalog_obj.as_dict() {
        let mut d = d.clone();
        d.set("Pages", pages_id);
        d.remove(b"Outlines");
        out.objects.insert(catalog_id, Object::Dictionary(d));
    }
    out.trailer.set("Root", catalog_id);
    out.max_id = out.objects.len() as u32;
    out.renumber_objects();
    out.compress();
    let dest = names::unique(dir, &format!("{} (uniti)", names::stem(&files[0])), "pdf");
    out.save(&dest).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    Ok(dest)
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
