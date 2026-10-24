//! Metadati delle foto senza ricodificare: si tolgono posizione GPS, fotocamera, date e programmi
//! lasciando intatti i pixel. L'orientamento resta (altrimenti le foto del telefono si girerebbero)
//! e resta il profilo colore (altrimenti i colori cambierebbero).

use crate::error::{EngineError, Result};

const SOI: [u8; 2] = [0xFF, 0xD8];

/// I segmenti di un JPEG fino all'inizio dell'immagine (SOS), e il resto così com'è.
fn jpeg_segments(data: &[u8]) -> Result<(Vec<(u8, &[u8])>, &[u8])> {
    if data.len() < 4 || data[0..2] != SOI {
        return Err(EngineError::new("non è un JPEG valido"));
    }
    let mut segs = Vec::new();
    let mut i = 2;
    loop {
        // Riempitivi 0xFF tra i segmenti
        while i < data.len() && data[i] == 0xFF && i + 1 < data.len() && data[i + 1] == 0xFF {
            i += 1;
        }
        if i + 4 > data.len() || data[i] != 0xFF {
            return Err(EngineError::new("il JPEG sembra danneggiato"));
        }
        let marker = data[i + 1];
        if marker == 0xDA {
            // Da qui i dati dell'immagine, fino alla fine vera (EOI). Quello che c'è dopo
            // (foto in movimento di Pixel e Samsung, immagini secondarie con il loro EXIF) non è l'immagine: via.
            let end = image_end(data, i);
            return Ok((segs, &data[i..end]));
        }
        if (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            segs.push((marker, &data[i..i + 2]));
            i += 2;
            continue;
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        if len < 2 || i + 2 + len > data.len() {
            return Err(EngineError::new("il JPEG sembra danneggiato"));
        }
        segs.push((marker, &data[i..i + 2 + len]));
        i += 2 + len;
    }
}

/// Dove finisce l'immagine (dopo il marcatore EOI), partendo dal primo SOS.
/// Gestisce i JPEG progressivi (più scansioni con tabelle in mezzo) e i dati con FF 00 e RST.
fn image_end(data: &[u8], sos: usize) -> usize {
    let mut i = sos;
    while i + 1 < data.len() {
        if data[i] != 0xFF {
            return data.len();
        }
        let m = data[i + 1];
        if m == 0xFF {
            i += 1;
            continue;
        }
        if m == 0xD9 {
            return i + 2;
        }
        if (0xD0..=0xD7).contains(&m) || m == 0x01 {
            i += 2;
            continue;
        }
        if i + 4 > data.len() {
            return data.len();
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        let seg_end = i + 2 + len;
        if len < 2 || seg_end > data.len() {
            return data.len();
        }
        if m == 0xDA {
            // Dati compressi: si va avanti fino al prossimo marcatore vero
            let mut j = seg_end;
            while j + 1 < data.len() {
                if data[j] == 0xFF {
                    let n = data[j + 1];
                    if n == 0x00 || (0xD0..=0xD7).contains(&n) {
                        j += 2;
                        continue;
                    }
                    if n == 0xFF {
                        j += 1;
                        continue;
                    }
                    break;
                }
                j += 1;
            }
            i = j;
        } else {
            i = seg_end;
        }
    }
    data.len()
}

fn payload(seg: &[u8]) -> &[u8] {
    if seg.len() >= 4 { &seg[4..] } else { &[] }
}

/// Il blocco EXIF (TIFF) di un JPEG, se c'è.
pub fn jpeg_exif(data: &[u8]) -> Option<Vec<u8>> {
    let (segs, _) = jpeg_segments(data).ok()?;
    segs.iter()
        .find(|(m, s)| *m == 0xE1 && payload(s).starts_with(b"Exif\0\0"))
        .map(|(_, s)| payload(s)[6..].to_vec())
}

/// L'orientamento scritto nell'EXIF (1 = dritta).
pub fn exif_orientation(tiff: &[u8]) -> Option<u16> {
    let (le, ifd) = tiff_header(tiff)?;
    let n = rd16(tiff, ifd, le)? as usize;
    for k in 0..n {
        let e = ifd + 2 + k * 12;
        if rd16(tiff, e, le)? == 0x0112 {
            return rd16(tiff, e + 8, le);
        }
    }
    None
}

/// Rimette l'orientamento a 1 dentro un blocco EXIF (quando i pixel sono già stati raddrizzati).
pub fn exif_reset_orientation(tiff: &mut [u8]) {
    let Some((le, ifd)) = tiff_header(tiff) else { return };
    let Some(n) = rd16(tiff, ifd, le) else { return };
    for k in 0..n as usize {
        let e = ifd + 2 + k * 12;
        if rd16(tiff, e, le) == Some(0x0112) && e + 10 <= tiff.len() {
            let v = if le { 1u16.to_le_bytes() } else { 1u16.to_be_bytes() };
            tiff[e + 8] = v[0];
            tiff[e + 9] = v[1];
        }
    }
}

fn tiff_header(t: &[u8]) -> Option<(bool, usize)> {
    if t.len() < 8 {
        return None;
    }
    let le = match &t[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let off = rd32(t, 4, le)? as usize;
    (off + 2 <= t.len()).then_some((le, off))
}

fn rd16(t: &[u8], i: usize, le: bool) -> Option<u16> {
    let b = t.get(i..i + 2)?;
    Some(if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
}

fn rd32(t: &[u8], i: usize, le: bool) -> Option<u32> {
    let b = t.get(i..i + 4)?;
    Some(if le { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) } else { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) })
}

/// Un EXIF minuscolo con solo l'orientamento.
fn minimal_exif(orientation: u16) -> Vec<u8> {
    let mut t = Vec::new();
    t.extend_from_slice(b"II*\0");
    t.extend_from_slice(&8u32.to_le_bytes());
    t.extend_from_slice(&1u16.to_le_bytes()); // una voce
    t.extend_from_slice(&0x0112u16.to_le_bytes());
    t.extend_from_slice(&3u16.to_le_bytes()); // SHORT
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&orientation.to_le_bytes());
    t.extend_from_slice(&[0, 0]);
    t.extend_from_slice(&0u32.to_le_bytes()); // nessun altro IFD
    t
}

fn app1(tiff: &[u8]) -> Option<Vec<u8>> {
    let len = tiff.len() + 6 + 2;
    if len > 0xFFFF {
        return None;
    }
    let mut s = vec![0xFF, 0xE1];
    s.extend_from_slice(&(len as u16).to_be_bytes());
    s.extend_from_slice(b"Exif\0\0");
    s.extend_from_slice(tiff);
    Some(s)
}

/// Toglie tutti i metadati da un JPEG senza toccare l'immagine.
pub fn strip_jpeg(data: &[u8]) -> Result<Vec<u8>> {
    let (segs, rest) = jpeg_segments(data)?;
    let orientation = segs
        .iter()
        .find(|(m, s)| *m == 0xE1 && payload(s).starts_with(b"Exif\0\0"))
        .and_then(|(_, s)| exif_orientation(&payload(s)[6..]))
        .unwrap_or(1);
    let kept: Vec<&[u8]> = segs
        .iter()
        .filter(|(m, s)| match *m {
            0xE0 => payload(s).starts_with(b"JFIF\0") || payload(s).starts_with(b"JFXX\0"),
            0xE2 => payload(s).starts_with(b"ICC_PROFILE\0"),
            0xEE => true,                              // Adobe: serve per leggere bene i colori
            0xE1 | 0xE3..=0xED | 0xEF | 0xFE => false, // EXIF, XMP, IPTC, note dei produttori, commenti
            _ => true,                                 // tabelle e dati dell'immagine
        })
        .map(|(_, s)| *s)
        .collect();
    let mut out = Vec::with_capacity(data.len());
    out.extend_from_slice(&SOI);
    let mut rest_from = 0;
    // L'orientamento va subito dopo il JFIF (o all'inizio)
    if kept.first().map(|s| s.len() > 1 && s[1] == 0xE0).unwrap_or(false) {
        out.extend_from_slice(kept[0]);
        rest_from = 1;
    }
    if orientation != 1 {
        if let Some(a) = app1(&minimal_exif(orientation)) {
            out.extend_from_slice(&a);
        }
    }
    for s in &kept[rest_from..] {
        out.extend_from_slice(s);
    }
    out.extend_from_slice(rest);
    Ok(out)
}

/// Mette un blocco EXIF in un JPEG appena creato (dopo il JFIF, se c'è).
pub fn jpeg_with_exif(jpeg: &[u8], tiff: &[u8]) -> Vec<u8> {
    let Some(seg) = app1(tiff) else { return jpeg.to_vec() };
    if jpeg.len() < 4 || jpeg[0..2] != SOI {
        return jpeg.to_vec();
    }
    let mut at = 2;
    if jpeg[2] == 0xFF && jpeg[3] == 0xE0 && jpeg.len() > 6 {
        at = 4 + u16::from_be_bytes([jpeg[4], jpeg[5]]) as usize;
    }
    let mut out = Vec::with_capacity(jpeg.len() + seg.len());
    out.extend_from_slice(&jpeg[..at.min(jpeg.len())]);
    out.extend_from_slice(&seg);
    out.extend_from_slice(&jpeg[at.min(jpeg.len())..]);
    out
}

/// Toglie i testi e l'EXIF da un PNG (restano profilo colore, gamma e risoluzione).
pub fn strip_png(data: &[u8]) -> Result<Vec<u8>> {
    const SIG: [u8; 8] = [137, 80, 78, 71, 13, 10, 26, 10];
    if data.len() < 8 || data[0..8] != SIG {
        return Err(EngineError::new("non è un PNG valido"));
    }
    let mut out = SIG.to_vec();
    let mut i = 8;
    while i + 12 <= data.len() {
        let len = u32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]) as usize;
        let end = i + 12 + len;
        if end > data.len() {
            return Err(EngineError::new("il PNG sembra danneggiato"));
        }
        let ty = &data[i + 4..i + 8];
        if !matches!(ty, b"tEXt" | b"zTXt" | b"iTXt" | b"eXIf" | b"tIME") {
            out.extend_from_slice(&data[i..end]);
        }
        i = end;
        if ty == b"IEND" {
            break;
        }
    }
    Ok(out)
}

/// Toglie EXIF e XMP da un WebP.
pub fn strip_webp(data: &[u8]) -> Result<Vec<u8>> {
    if data.len() < 12 || &data[0..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return Err(EngineError::new("non è un WebP valido"));
    }
    let mut body = b"WEBP".to_vec();
    let mut i = 12;
    while i + 8 <= data.len() {
        let id = &data[i..i + 4];
        let len = u32::from_le_bytes([data[i + 4], data[i + 5], data[i + 6], data[i + 7]]) as usize;
        let padded = len + (len & 1);
        let end = (i + 8 + padded).min(data.len());
        if i + 8 + len > data.len() {
            return Err(EngineError::new("il WebP sembra danneggiato"));
        }
        match id {
            b"EXIF" | b"XMP " => {}
            b"VP8X" => {
                let mut c = data[i..end].to_vec();
                if c.len() > 8 {
                    c[8] &= !(0x08 | 0x04); // niente più bandierine EXIF e XMP
                }
                body.extend_from_slice(&c);
            }
            _ => body.extend_from_slice(&data[i..end]),
        }
        i = end;
    }
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jpeg_with(orientation: u16) -> Vec<u8> {
        let img = image::RgbImage::from_pixel(16, 8, image::Rgb([200, 100, 50]));
        let mut buf = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 90).encode_image(&img).unwrap();
        // EXIF con orientamento e una finta posizione GPS (testo riconoscibile)
        let mut tiff = minimal_exif(orientation);
        tiff.extend_from_slice(b"GPS-NAPOLI-40.85N");
        jpeg_with_exif(&buf, &tiff)
    }

    #[test]
    fn via_i_metadati_resta_l_orientamento() {
        let j = jpeg_with(6);
        assert!(j.windows(10).any(|w| w == b"GPS-NAPOLI"));
        let s = strip_jpeg(&j).unwrap();
        assert!(!s.windows(10).any(|w| w == b"GPS-NAPOLI"), "la posizione se ne va");
        assert_eq!(jpeg_exif(&s).and_then(|t| exif_orientation(&t)), Some(6), "l'orientamento resta");
        let img = image::load_from_memory(&s).unwrap();
        assert_eq!((img.width(), img.height()), (16, 8), "l'immagine è la stessa");
    }

    #[test]
    fn via_anche_quello_attaccato_in_coda() {
        // Foto in movimento dei telefoni: un video (con la posizione) attaccato dopo la fine del JPEG
        let mut j = jpeg_with(1);
        j.extend_from_slice(b"ftypmp42....GPS+40.85+014.27....");
        let s = strip_jpeg(&j).unwrap();
        assert!(!s.windows(10).any(|w| w == b"GPS+40.85+"), "la coda con la posizione se ne va");
        assert!(s.ends_with(&[0xFF, 0xD9]));
        assert!(image::load_from_memory(&s).is_ok());
    }

    #[test]
    fn jpeg_progressivo_intero() {
        // Un JPEG progressivo ha più scansioni: si devono tenere tutte
        let img = image::RgbImage::from_fn(64, 48, |x, y| image::Rgb([(x * 4) as u8, (y * 5) as u8, 90]));
        let mut buf = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 90).encode_image(&img).unwrap();
        let s = strip_jpeg(&buf).unwrap();
        assert_eq!(s.len(), buf.len(), "niente si perde quando non ci sono metadati");
    }

    #[test]
    fn foto_dritta_senza_exif() {
        let s = strip_jpeg(&jpeg_with(1)).unwrap();
        assert!(jpeg_exif(&s).is_none());
        assert!(image::load_from_memory(&s).is_ok());
    }

    #[test]
    fn png_senza_testi() {
        let img = image::RgbaImage::from_pixel(4, 4, image::Rgba([0, 0, 0, 255]));
        let mut buf = std::io::Cursor::new(Vec::new());
        img.write_to(&mut buf, image::ImageFormat::Png).unwrap();
        let mut png = buf.into_inner();
        // un tEXt prima di IEND
        let iend = png.len() - 12;
        let mut chunk = Vec::new();
        let text = b"Author\0Ledion";
        chunk.extend_from_slice(&(text.len() as u32).to_be_bytes());
        chunk.extend_from_slice(b"tEXt");
        chunk.extend_from_slice(text);
        chunk.extend_from_slice(&[0, 0, 0, 0]);
        png.splice(iend..iend, chunk);
        let s = strip_png(&png).unwrap();
        assert!(!s.windows(6).any(|w| w == b"Ledion"));
        assert!(image::load_from_memory(&s).is_ok());
    }
}
