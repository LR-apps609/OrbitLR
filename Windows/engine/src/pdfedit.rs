//! Editor PDF, come sul Mac: compila i campi dei moduli, scrivi testo sulla pagina, metti la firma e
//! oscura le parti da nascondere. L'oscuramento è vero: le pagine oscurate diventano un'immagine con i
//! rettangoli neri, così il testo sotto non si può più copiare né cercare.
//!
//! Coordinate: in punti PDF, dall'angolo in alto a sinistra della pagina (come la vede chi la guarda);
//! qui si convertono in quelle del PDF (dal basso a sinistra, con l'origine della MediaBox).

use crate::error::{EngineError, Result};
use crate::names;
use crate::run::Cancel;
use base64::Engine as _;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Default)]
pub struct TextMark {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    #[serde(default = "default_size")]
    pub size: f64,
    pub text: String,
}

fn default_size() -> f64 {
    12.0
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ImageMark {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// PNG in base64 (la firma disegnata)
    pub png: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Rect {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Edits {
    #[serde(default)]
    pub texts: Vec<TextMark>,
    #[serde(default)]
    pub images: Vec<ImageMark>,
    #[serde(default)]
    pub redactions: Vec<Rect>,
    /// Campi del modulo: nome → valore
    #[serde(default)]
    pub fields: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PageInfo {
    /// Misure in punti, come si vede la pagina
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct FieldInfo {
    pub name: String,
    pub value: String,
    /// "text" o "check"
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PdfInfo {
    pub pages: Vec<PageInfo>,
    pub fields: Vec<FieldInfo>,
}

fn num(o: &Object) -> Option<f64> {
    o.as_float().map(|f| f as f64).ok().or_else(|| o.as_i64().ok().map(|i| i as f64))
}

/// [x0, y0, x1, y1] della MediaBox (ereditata se serve).
fn media_box(doc: &Document, pid: ObjectId) -> [f64; 4] {
    let mut cur = Some(pid);
    let mut guard = 0;
    while let Some(id) = cur {
        guard += 1;
        if guard > 64 {
            break;
        }
        let Ok(d) = doc.get_dictionary(id) else { break };
        if let Ok(arr) = d.get(b"MediaBox").and_then(|o| o.as_array()) {
            if arr.len() == 4 {
                let v: Vec<f64> = arr.iter().filter_map(num).collect();
                if v.len() == 4 {
                    return [v[0].min(v[2]), v[1].min(v[3]), v[0].max(v[2]), v[1].max(v[3])];
                }
            }
        }
        cur = d.get(b"Parent").ok().and_then(|o| o.as_reference().ok());
    }
    [0.0, 0.0, 612.0, 792.0]
}

fn rotation(doc: &Document, pid: ObjectId) -> i64 {
    doc.get_dictionary(pid).ok().and_then(|d| d.get(b"Rotate").ok()).and_then(|o| o.as_i64().ok()).map(|r| ((r % 360) + 360) % 360).unwrap_or(0)
}

/// Pagine e campi, per l'editor.
pub fn info(src: &Path) -> Result<PdfInfo> {
    let doc = crate::pdf::load(src)?;
    let mut pages = Vec::new();
    for (_, pid) in doc.get_pages() {
        let b = media_box(&doc, pid);
        let (w, h) = (b[2] - b[0], b[3] - b[1]);
        let r = rotation(&doc, pid);
        pages.push(if r == 90 || r == 270 { PageInfo { width: h, height: w } } else { PageInfo { width: w, height: h } });
    }
    Ok(PdfInfo { pages, fields: fields(&doc) })
}

fn field_ids(doc: &Document) -> Vec<ObjectId> {
    let mut out = Vec::new();
    let Ok(cat) = doc.catalog() else { return out };
    let form = match cat.get(b"AcroForm") {
        Ok(Object::Reference(id)) => doc.get_dictionary(*id).ok(),
        Ok(Object::Dictionary(d)) => Some(d),
        _ => None,
    };
    let Some(form) = form else { return out };
    let Ok(list) = form.get(b"Fields").and_then(|o| o.as_array()) else { return out };
    let mut stack: Vec<ObjectId> = list.iter().filter_map(|o| o.as_reference().ok()).collect();
    let mut guard = 0;
    while let Some(id) = stack.pop() {
        guard += 1;
        if guard > 5000 {
            break;
        }
        let Ok(d) = doc.get_dictionary(id) else { continue };
        match d.get(b"Kids").and_then(|o| o.as_array()) {
            // Un campo con figli che hanno un nome: si scende
            Ok(kids) if kids.iter().filter_map(|k| k.as_reference().ok()).any(|k| doc.get_dictionary(k).map(|kd| kd.has(b"T")).unwrap_or(false)) => {
                stack.extend(kids.iter().filter_map(|o| o.as_reference().ok()));
            }
            _ => out.push(id),
        }
    }
    out
}

fn text_of(o: &Object) -> String {
    match o {
        Object::String(b, _) => {
            if b.starts_with(&[0xFE, 0xFF]) {
                let u: Vec<u16> = b[2..].chunks(2).filter(|c| c.len() == 2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
                String::from_utf16_lossy(&u)
            } else {
                b.iter().map(|&c| c as char).collect()
            }
        }
        Object::Name(n) => String::from_utf8_lossy(n).to_string(),
        _ => String::new(),
    }
}

fn full_name(doc: &Document, id: ObjectId) -> String {
    let mut parts = Vec::new();
    let mut cur = Some(id);
    let mut guard = 0;
    while let Some(i) = cur {
        guard += 1;
        if guard > 32 {
            break;
        }
        let Ok(d) = doc.get_dictionary(i) else { break };
        if let Ok(t) = d.get(b"T") {
            parts.push(text_of(t));
        }
        cur = d.get(b"Parent").ok().and_then(|o| o.as_reference().ok());
    }
    parts.reverse();
    parts.join(".")
}

fn field_type(doc: &Document, id: ObjectId) -> Vec<u8> {
    let mut cur = Some(id);
    let mut guard = 0;
    while let Some(i) = cur {
        guard += 1;
        if guard > 32 {
            break;
        }
        let Ok(d) = doc.get_dictionary(i) else { break };
        if let Ok(Object::Name(n)) = d.get(b"FT") {
            return n.clone();
        }
        cur = d.get(b"Parent").ok().and_then(|o| o.as_reference().ok());
    }
    Vec::new()
}

fn fields(doc: &Document) -> Vec<FieldInfo> {
    field_ids(doc)
        .into_iter()
        .filter_map(|id| {
            let ft = field_type(doc, id);
            let kind = match ft.as_slice() {
                b"Tx" => "text",
                b"Btn" => "check",
                _ => return None,
            };
            let d = doc.get_dictionary(id).ok()?;
            let value = d.get(b"V").map(text_of).unwrap_or_default();
            let name = full_name(doc, id);
            (!name.is_empty()).then(|| FieldInfo { name, value, kind: kind.into() })
        })
        .take(500)
        .collect()
}

/// Testo per una stringa PDF in WinAnsiEncoding (le lettere accentate italiane ci sono tutte).
fn win_ansi(s: &str) -> Vec<u8> {
    s.chars()
        .map(|c| match c {
            '€' => 0x80,
            '…' => 0x85,
            '‘' => 0x91,
            '’' => 0x92,
            '“' => 0x93,
            '”' => 0x94,
            '–' => 0x96,
            '—' => 0x97,
            c if (c as u32) < 0x80 || (0xA0..=0xFF).contains(&(c as u32)) => c as u32 as u8,
            _ => b'?',
        })
        .collect()
}

/// Un testo come lo vuole il PDF per i campi: UTF-16 con il segno iniziale se serve.
fn pdf_text(s: &str) -> Object {
    if s.chars().all(|c| (c as u32) < 0x80) {
        Object::string_literal(s)
    } else {
        let mut b = vec![0xFE, 0xFF];
        for u in s.encode_utf16() {
            b.extend_from_slice(&u.to_be_bytes());
        }
        Object::String(b, lopdf::StringFormat::Hexadecimal)
    }
}

fn escape(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(b.len() + 8);
    for &c in b {
        if c == b'(' || c == b')' || c == b'\\' {
            out.push(b'\\');
        }
        out.push(c);
    }
    out
}

/// Aggiunge una risorsa (Font o XObject) alla pagina, anche se il dizionario è un riferimento.
fn add_resource(doc: &mut Document, pid: ObjectId, kind: &[u8], name: &str, id: ObjectId) -> Result<()> {
    let res = doc.get_or_create_resources(pid).map_err(|e| EngineError::new(format!("pagina senza risorse: {e}")))?;
    let res_ref = if let Object::Reference(r) = res { Some(*r) } else { None };
    let res = match res_ref {
        Some(r) => doc.get_object_mut(r).map_err(|e| EngineError::new(e.to_string()))?,
        None => doc.get_or_create_resources(pid).map_err(|e| EngineError::new(e.to_string()))?,
    };
    let dict = res.as_dict_mut().map_err(|_| EngineError::new("risorse della pagina non valide"))?;
    let sub_ref = match dict.get(kind) {
        Ok(Object::Reference(r)) => Some(*r),
        Ok(Object::Dictionary(_)) => None,
        _ => {
            dict.set(kind.to_vec(), Dictionary::new());
            None
        }
    };
    match sub_ref {
        Some(r) => {
            if let Ok(Object::Dictionary(d)) = doc.get_object_mut(r) {
                d.set(name.as_bytes().to_vec(), Object::Reference(id));
            }
        }
        None => {
            let res = doc.get_or_create_resources(pid).map_err(|e| EngineError::new(e.to_string()))?;
            let res = match res {
                Object::Reference(r) => {
                    let r = *r;
                    doc.get_object_mut(r).map_err(|e| EngineError::new(e.to_string()))?
                }
                o => o,
            };
            if let Ok(d) = res.as_dict_mut().and_then(|d| d.get_mut(kind)).and_then(|o| o.as_dict_mut()) {
                d.set(name.as_bytes().to_vec(), Object::Reference(id));
            }
        }
    }
    Ok(())
}

/// Il disegno nuovo va sopra la pagina senza risentire dello stato lasciato dal contenuto vecchio.
fn wrap_and_add(doc: &mut Document, pid: ObjectId, ours: Vec<u8>) -> Result<()> {
    let page = doc.get_dictionary(pid).map_err(|e| EngineError::new(e.to_string()))?;
    let old: Vec<Object> = match page.get(b"Contents") {
        Ok(Object::Reference(id)) => vec![Object::Reference(*id)],
        Ok(Object::Array(a)) => a.clone(),
        _ => vec![],
    };
    let q = doc.add_object(Object::Stream(Stream::new(Dictionary::new(), b"q\n".to_vec())));
    let qq = doc.add_object(Object::Stream(Stream::new(Dictionary::new(), b"\nQ\n".to_vec())));
    let mine = doc.add_object(Object::Stream(Stream::new(Dictionary::new(), ours)));
    let mut list = vec![Object::Reference(q)];
    list.extend(old);
    list.push(Object::Reference(qq));
    list.push(Object::Reference(mine));
    if let Ok(Object::Dictionary(d)) = doc.get_object_mut(pid) {
        d.set("Contents", Object::Array(list));
    }
    Ok(())
}

/// Da «in alto a sinistra, come la si vede» alle coordinate del PDF (solo pagine non ruotate).
fn to_pdf(b: [f64; 4], x: f64, y_top: f64) -> (f64, f64) {
    (b[0] + x, b[3] - y_top)
}

fn add_image(doc: &mut Document, png_b64: &str) -> Result<(ObjectId, u32, u32)> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(png_b64.trim_start_matches("data:image/png;base64,")).map_err(|_| EngineError::new("immagine della firma non valida"))?;
    let img = image::load_from_memory(&bytes).map_err(|_| EngineError::new("immagine della firma non valida"))?.to_rgba8();
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 || w > 4000 || h > 4000 {
        return Err(EngineError::new("immagine della firma troppo grande"));
    }
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    let mut alpha = Vec::with_capacity((w * h) as usize);
    for p in img.pixels() {
        rgb.extend_from_slice(&p.0[..3]);
        alpha.push(p.0[3]);
    }
    let mut sd = Dictionary::new();
    sd.set("Type", Object::Name(b"XObject".to_vec()));
    sd.set("Subtype", Object::Name(b"Image".to_vec()));
    sd.set("Width", Object::Integer(w as i64));
    sd.set("Height", Object::Integer(h as i64));
    sd.set("ColorSpace", Object::Name(b"DeviceGray".to_vec()));
    sd.set("BitsPerComponent", Object::Integer(8));
    let mut smask = Stream::new(sd, alpha);
    let _ = smask.compress();
    let smask_id = doc.add_object(Object::Stream(smask));
    let mut d = Dictionary::new();
    d.set("Type", Object::Name(b"XObject".to_vec()));
    d.set("Subtype", Object::Name(b"Image".to_vec()));
    d.set("Width", Object::Integer(w as i64));
    d.set("Height", Object::Integer(h as i64));
    d.set("ColorSpace", Object::Name(b"DeviceRGB".to_vec()));
    d.set("BitsPerComponent", Object::Integer(8));
    d.set("SMask", Object::Reference(smask_id));
    let mut s = Stream::new(d, rgb);
    let _ = s.compress();
    Ok((doc.add_object(Object::Stream(s)), w, h))
}

/// Applica testi, firme e campi; le pagine con zone oscurate diventano immagini (oscuramento vero).
pub fn apply(src: &Path, edits: &Edits, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if edits.texts.is_empty() && edits.images.is_empty() && edits.redactions.is_empty() && edits.fields.is_empty() {
        return Err(EngineError::new("non hai fatto modifiche"));
    }
    if edits.texts.len() + edits.images.len() + edits.redactions.len() > 2000 {
        return Err(EngineError::new("troppe modifiche in una volta"));
    }
    let base_doc = crate::pdf::load(src)?;
    let redacted_pages: std::collections::BTreeSet<u32> = edits.redactions.iter().map(|r| r.page).collect();
    // 1) Oscuramento vero: le pagine coinvolte diventano un'immagine con i rettangoli neri
    let mut doc = if redacted_pages.is_empty() { base_doc } else { rasterize(src, base_doc, &edits.redactions, cancel, progress)? };
    progress(0.6);
    let pages = doc.get_pages();
    // Le pagine ruotate: il disegno andrebbe girato; per ora si chiede di ruotarle prima
    for n in edits.texts.iter().map(|t| t.page).chain(edits.images.iter().map(|i| i.page)) {
        if let Some(&pid) = pages.get(&n) {
            if rotation(&doc, pid) != 0 {
                return Err(EngineError::new(format!("la pagina {n} è ruotata: raddrizzala prima con «Ruota le pagine», poi scrivi o firma")));
            }
        }
    }
    // 2) Testi
    let mut font_id: Option<ObjectId> = None;
    let mut per_page: std::collections::BTreeMap<u32, Vec<u8>> = std::collections::BTreeMap::new();
    for t in &edits.texts {
        let Some(&pid) = pages.get(&t.page) else { continue };
        if t.text.trim().is_empty() {
            continue;
        }
        let fid = *font_id.get_or_insert_with(|| {
            let mut f = Dictionary::new();
            f.set("Type", Object::Name(b"Font".to_vec()));
            f.set("Subtype", Object::Name(b"Type1".to_vec()));
            f.set("BaseFont", Object::Name(b"Helvetica".to_vec()));
            f.set("Encoding", Object::Name(b"WinAnsiEncoding".to_vec()));
            doc.add_object(Object::Dictionary(f))
        });
        crate::pdf::flatten_inherited(&mut doc, pid);
        add_resource(&mut doc, pid, b"Font", "OrbF1", fid)?;
        let b = media_box(&doc, pid);
        let size = t.size.clamp(4.0, 96.0);
        let buf = per_page.entry(t.page).or_default();
        for (i, line) in t.text.lines().enumerate() {
            // Come nell'editor: righe alte 1,15 volte il carattere, la base a circa l'80% della prima riga
            let (x, y) = to_pdf(b, t.x + 1.5, t.y + 1.0 + size * (0.85 + i as f64 * 1.15));
            buf.extend_from_slice(format!("BT /OrbF1 {size:.2} Tf 0 0 0 rg {x:.2} {y:.2} Td (").as_bytes());
            buf.extend_from_slice(&escape(&win_ansi(line)));
            buf.extend_from_slice(b") Tj ET\n");
        }
    }
    // 3) Firme e immagini
    for (k, im) in edits.images.iter().enumerate() {
        let Some(&pid) = pages.get(&im.page) else { continue };
        let (xid, _, _) = add_image(&mut doc, &im.png)?;
        crate::pdf::flatten_inherited(&mut doc, pid);
        let name = format!("OrbIm{k}");
        add_resource(&mut doc, pid, b"XObject", &name, xid)?;
        let b = media_box(&doc, pid);
        let (x, y) = to_pdf(b, im.x, im.y + im.h);
        per_page.entry(im.page).or_default().extend_from_slice(format!("q {:.2} 0 0 {:.2} {x:.2} {y:.2} cm /{name} Do Q\n", im.w.max(1.0), im.h.max(1.0)).as_bytes());
    }
    for (n, content) in per_page {
        if let Some(&pid) = pages.get(&n) {
            wrap_and_add(&mut doc, pid, content)?;
        }
    }
    // 4) Campi del modulo
    if !edits.fields.is_empty() {
        fill_fields(&mut doc, &edits.fields);
    }
    progress(0.9);
    let tag = if !edits.redactions.is_empty() {
        "oscurato"
    } else if !edits.images.is_empty() {
        "firmato"
    } else {
        "compilato"
    };
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), names::tag(tag)), "pdf")?;
    doc.compress();
    doc.save(&of.tmp).map_err(|e| EngineError::new(format!("non riesco a scrivere il PDF: {e}")))?;
    progress(1.0);
    of.commit()
}

fn fill_fields(doc: &mut Document, values: &std::collections::BTreeMap<String, String>) {
    for id in field_ids(doc) {
        let name = full_name(doc, id);
        let Some(v) = values.get(&name) else { continue };
        let ft = field_type(doc, id);
        if let Ok(Object::Dictionary(d)) = doc.get_object_mut(id) {
            if ft == b"Btn" {
                // Casella: «Yes»/«Off» (o il nome che usa il modulo)
                let on = !v.is_empty() && v != "Off" && v != "false" && v != "0";
                let state = if on {
                    d.get(b"AP").ok().and_then(|ap| ap.as_dict().ok()).and_then(|ap| ap.get(b"N").ok()).and_then(|n| n.as_dict().ok()).and_then(|n| n.iter().map(|(k, _)| k.clone()).find(|k| k != b"Off")).unwrap_or_else(|| b"Yes".to_vec())
                } else {
                    b"Off".to_vec()
                };
                d.set("V", Object::Name(state.clone()));
                d.set("AS", Object::Name(state));
            } else {
                d.set("V", pdf_text(v));
                // L'aspetto vecchio mostrerebbe il valore di prima: lo ridisegna il lettore
                d.remove(b"AP");
            }
        }
    }
    // Il lettore ridisegna i campi con i valori nuovi
    let form_ref = doc.catalog().ok().and_then(|c| c.get(b"AcroForm").ok()).and_then(|o| o.as_reference().ok());
    match form_ref {
        Some(r) => {
            if let Ok(Object::Dictionary(d)) = doc.get_object_mut(r) {
                d.set("NeedAppearances", Object::Boolean(true));
            }
        }
        None => {
            if let Ok(root) = doc.trailer.get(b"Root").and_then(|o| o.as_reference()) {
                if let Ok(Object::Dictionary(c)) = doc.get_object_mut(root) {
                    if let Ok(Object::Dictionary(f)) = c.get_mut(b"AcroForm") {
                        f.set("NeedAppearances", Object::Boolean(true));
                    }
                }
            }
        }
    }
}

/// Le pagine con zone da oscurare diventano un'immagine (disegnata da Windows) con i rettangoli neri.
fn rasterize(src: &Path, mut doc: Document, rects: &[Rect], cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Document> {
    let wanted: std::collections::BTreeSet<u32> = rects.iter().map(|r| r.page).collect();
    let pages = doc.get_pages();
    let infos = info(src)?;
    let mut images: Vec<(u32, Vec<u8>, u32, u32)> = Vec::new();
    let total = infos.pages.len().max(1) as f64;
    crate::pdfrender::each_page_png(src, cancel, &mut |i, _t, png| {
        let n = i + 1;
        progress(0.5 * n as f64 / total);
        if !wanted.contains(&n) {
            return Ok(());
        }
        let img = image::open(png).map_err(|e| EngineError::new(format!("non riesco a leggere la pagina disegnata: {e}")))?;
        let mut rgb = crate::pdfrender::flatten_white_pub(&img);
        let pi = &infos.pages[i as usize];
        let sx = rgb.width() as f64 / pi.width.max(1.0);
        let sy = rgb.height() as f64 / pi.height.max(1.0);
        for r in rects.iter().filter(|r| r.page == n) {
            let x0 = (r.x * sx).floor().max(0.0) as u32;
            let y0 = (r.y * sy).floor().max(0.0) as u32;
            let x1 = ((r.x + r.w) * sx).ceil().min(rgb.width() as f64) as u32;
            let y1 = ((r.y + r.h) * sy).ceil().min(rgb.height() as f64) as u32;
            for y in y0..y1 {
                for x in x0..x1 {
                    rgb.put_pixel(x, y, image::Rgb([0, 0, 0]));
                }
            }
        }
        let mut jpg = Vec::new();
        let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpg, 88);
        image::DynamicImage::ImageRgb8(rgb.clone()).write_with_encoder(enc).map_err(|e| EngineError::new(e.to_string()))?;
        images.push((n, jpg, rgb.width(), rgb.height()));
        Ok(())
    })?;
    for (n, jpg, w, h) in images {
        let Some(&pid) = pages.get(&n) else { continue };
        let b = media_box(&doc, pid);
        let mut d = Dictionary::new();
        d.set("Type", Object::Name(b"XObject".to_vec()));
        d.set("Subtype", Object::Name(b"Image".to_vec()));
        d.set("Width", Object::Integer(w as i64));
        d.set("Height", Object::Integer(h as i64));
        d.set("ColorSpace", Object::Name(b"DeviceRGB".to_vec()));
        d.set("BitsPerComponent", Object::Integer(8));
        d.set("Filter", Object::Name(b"DCTDecode".to_vec()));
        let img_id = doc.add_object(Object::Stream(Stream::new(d, jpg)));
        let (pw, ph) = (b[2] - b[0], b[3] - b[1]);
        let r = rotation(&doc, pid);
        // L'immagine è la pagina come si vede: si toglie la rotazione e la pagina prende le misure viste
        let (vw, vh) = if r == 90 || r == 270 { (ph, pw) } else { (pw, ph) };
        let mut res = Dictionary::new();
        let mut xo = Dictionary::new();
        xo.set("OrbPage", Object::Reference(img_id));
        res.set("XObject", Object::Dictionary(xo));
        let content = format!("q {vw:.2} 0 0 {vh:.2} 0 0 cm /OrbPage Do Q\n").into_bytes();
        let cid = doc.add_object(Object::Stream(Stream::new(Dictionary::new(), content)));
        if let Ok(Object::Dictionary(pd)) = doc.get_object_mut(pid) {
            pd.set("Resources", Object::Dictionary(res));
            pd.set("Contents", Object::Reference(cid));
            pd.set("MediaBox", Object::Array(vec![0.into(), 0.into(), Object::Real(vw as f32), Object::Real(vh as f32)]));
            pd.remove(b"CropBox");
            pd.remove(b"Rotate");
            // Note e campi sopra la pagina oscurata non devono mostrare ciò che è stato nascosto
            pd.remove(b"Annots");
        }
    }
    doc.prune_objects();
    Ok(doc)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(dir: &Path) -> PathBuf {
        let img = image::RgbImage::from_pixel(60, 80, image::Rgb([250, 250, 250]));
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut buf, image::ImageFormat::Jpeg).unwrap();
        let p = dir.join("modulo.pdf");
        crate::pdf::images_to_pdf(&[(buf.into_inner(), 60, 80)], &p).unwrap();
        p
    }

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("orbit-pdfedit-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn testo_e_firma() {
        let d = tmp();
        let src = sample(&d);
        let i = info(&src).unwrap();
        assert_eq!(i.pages.len(), 1);
        assert!(i.pages[0].height > i.pages[0].width);
        let sig = {
            let im = image::RgbaImage::from_pixel(10, 4, image::Rgba([0, 0, 0, 255]));
            let mut b = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageRgba8(im).write_to(&mut b, image::ImageFormat::Png).unwrap();
            base64::engine::general_purpose::STANDARD.encode(b.into_inner())
        };
        let e = Edits {
            texts: vec![TextMark { page: 1, x: 40.0, y: 60.0, size: 14.0, text: "Mario Rossi · è così (prova)".into() }],
            images: vec![ImageMark { page: 1, x: 40.0, y: 100.0, w: 120.0, h: 48.0, png: sig }],
            ..Default::default()
        };
        let out = apply(&src, &e, &d, &Cancel::new(), &mut |_| {}).unwrap();
        assert!(out.file_name().unwrap().to_string_lossy().contains("firmato"));
        let doc = Document::load(&out).unwrap();
        let pid = *doc.get_pages().get(&1).unwrap();
        let content = doc.get_page_content(pid);
        let s = String::from_utf8_lossy(&content);
        assert!(s.contains("/OrbF1") && s.contains("/OrbIm0 Do"), "{s}");
        assert!(content.windows(2).any(|w| w == [b'\\', b'(']), "parentesi protette");
        assert!(apply(&src, &Edits::default(), &d, &Cancel::new(), &mut |_| {}).is_err());
    }

    #[test]
    fn caratteri_win_ansi() {
        assert_eq!(win_ansi("è€’"), vec![0xE8, 0x80, 0x92]);
        assert_eq!(win_ansi("中"), vec![b'?']);
        assert_eq!(escape(b"a(b)\\"), b"a\\(b\\)\\\\".to_vec());
    }
}
