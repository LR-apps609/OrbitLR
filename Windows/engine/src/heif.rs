//! L'EXIF (posizione GPS, data, fotocamera) dentro un file HEIC/HEIF dell'iPhone.
//! Il contenitore è ISO BMFF: si legge il box «meta» → «iinf» (quale elemento è l'Exif) → «iloc» (dove sta).

fn be16(d: &[u8], i: usize) -> Option<u64> {
    d.get(i..i + 2).map(|b| u16::from_be_bytes([b[0], b[1]]) as u64)
}
fn be32(d: &[u8], i: usize) -> Option<u64> {
    d.get(i..i + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as u64)
}
fn be64(d: &[u8], i: usize) -> Option<u64> {
    d.get(i..i + 8).map(|b| u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
}
fn ben(d: &[u8], i: usize, n: usize) -> Option<u64> {
    match n {
        0 => Some(0),
        2 => be16(d, i),
        4 => be32(d, i),
        8 => be64(d, i),
        _ => None,
    }
}

/// I box dentro un intervallo: (tipo, inizio del contenuto, fine).
fn boxes(d: &[u8], start: usize, end: usize) -> Vec<([u8; 4], usize, usize)> {
    let mut out = Vec::new();
    let mut i = start;
    while i + 8 <= end && out.len() < 1000 {
        let Some(size32) = be32(d, i) else { break };
        let ty = [d[i + 4], d[i + 5], d[i + 6], d[i + 7]];
        let (hdr, size) = match size32 {
            1 => match be64(d, i + 8) {
                Some(s) => (16usize, s as usize),
                None => break,
            },
            0 => (8, end - i),
            s => (8, s as usize),
        };
        if size < hdr || i + size > end {
            break;
        }
        out.push((ty, i + hdr, i + size));
        i += size;
    }
    out
}

/// Il blocco EXIF (TIFF, senza «Exif\0\0») di un HEIC, se c'è.
pub fn exif(d: &[u8]) -> Option<Vec<u8>> {
    let top = boxes(d, 0, d.len());
    let &(_, ms, me) = top.iter().find(|b| &b.0 == b"meta")?;
    // «meta» è un FullBox: 4 byte di versione e flag
    let inner = boxes(d, ms + 4, me);
    // iinf: trova l'item di tipo «Exif»
    let &(_, is, ie) = inner.iter().find(|b| &b.0 == b"iinf")?;
    let iv = *d.get(is)?;
    let count_len = if iv == 0 { 2 } else { 4 };
    let mut exif_id = None;
    for (ty, s, _) in boxes(d, is + 4 + count_len, ie) {
        if &ty != b"infe" {
            continue;
        }
        let v = *d.get(s)?;
        if v < 2 {
            continue;
        }
        let (id, off) = if v == 2 { (be16(d, s + 4)?, s + 6) } else { (be32(d, s + 4)?, s + 8) };
        // poi protection index (2 byte) e item_type (4 caratteri)
        if d.get(off + 2..off + 6)? == b"Exif" {
            exif_id = Some(id);
            break;
        }
    }
    let exif_id = exif_id?;
    // iloc: dove sta l'item
    let &(_, ls, le) = inner.iter().find(|b| &b.0 == b"iloc")?;
    let v = *d.get(ls)?;
    let mut p = ls + 4;
    let a = *d.get(p)?;
    let b = *d.get(p + 1)?;
    let (off_size, len_size, base_size) = ((a >> 4) as usize, (a & 15) as usize, (b >> 4) as usize);
    let index_size = if v == 1 || v == 2 { (b & 15) as usize } else { 0 };
    p += 2;
    let count = if v < 2 { let c = be16(d, p)?; p += 2; c } else { let c = be32(d, p)?; p += 4; c };
    for _ in 0..count.min(10_000) {
        if p >= le {
            break;
        }
        let id = if v < 2 { let x = be16(d, p)?; p += 2; x } else { let x = be32(d, p)?; p += 4; x };
        if v == 1 || v == 2 {
            p += 2; // construction method
        }
        p += 2; // data reference index
        let base = ben(d, p, base_size)?;
        p += base_size;
        let ext_count = be16(d, p)?;
        p += 2;
        let mut data = Vec::new();
        for _ in 0..ext_count.min(64) {
            if index_size > 0 {
                p += index_size;
            }
            let off = ben(d, p, off_size)?;
            p += off_size;
            let len = ben(d, p, len_size)?;
            p += len_size;
            if id == exif_id {
                let s = (base + off) as usize;
                let e = s.checked_add(len as usize)?;
                data.extend_from_slice(d.get(s..e)?);
            }
        }
        if id == exif_id {
            // 4 byte: dove inizia il TIFF; prima ci può essere «Exif\0\0»
            let skip = be32(&data, 0)? as usize;
            let tiff = data.get(4 + skip..)?;
            let tiff = tiff.strip_prefix(b"Exif\0\0").unwrap_or(tiff);
            return (tiff.starts_with(b"II") || tiff.starts_with(b"MM")).then(|| tiff.to_vec());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bx(ty: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(ty);
        v.extend_from_slice(body);
        v
    }

    fn infe(id: u16, ty: &[u8; 4]) -> Vec<u8> {
        let mut b = vec![2, 0, 0, 0];
        b.extend_from_slice(&id.to_be_bytes());
        b.extend_from_slice(&[0, 0]);
        b.extend_from_slice(ty);
        b.push(0);
        bx(b"infe", &b)
    }

    /// Un HEIC finto come quelli dell'iPhone: ftyp, meta (iinf + iloc v1, offset a 4 byte), mdat.
    fn fake(tiff: &[u8], version: u8) -> Vec<u8> {
        let mut payload = vec![0, 0, 0, 6];
        payload.extend_from_slice(b"Exif\0\0");
        payload.extend_from_slice(tiff);
        let ftyp = bx(b"ftyp", b"heicmif1heic");
        let mut iinf_b = vec![0, 0, 0, 0, 0, 2];
        iinf_b.extend(infe(1, b"hvc1"));
        iinf_b.extend(infe(2, b"Exif"));
        let iinf = bx(b"iinf", &iinf_b);
        let build = |mdat_at: u32| {
            let mut il = vec![version, 0, 0, 0, 0x44, 0x00, 0, 2];
            for (id, off, len) in [(1u16, mdat_at, 3u32), (2, mdat_at + 3, payload.len() as u32)] {
                il.extend_from_slice(&id.to_be_bytes());
                if version == 1 {
                    il.extend_from_slice(&[0, 0]);
                }
                il.extend_from_slice(&[0, 0, 0, 1]);
                il.extend_from_slice(&off.to_be_bytes());
                il.extend_from_slice(&len.to_be_bytes());
            }
            let iloc = bx(b"iloc", &il);
            let mut m = vec![0, 0, 0, 0];
            m.extend_from_slice(&iinf);
            m.extend_from_slice(&iloc);
            bx(b"meta", &m)
        };
        let len0 = ftyp.len() + build(0).len();
        let meta = build((len0 + 8) as u32);
        let mut body = vec![9, 9, 9];
        body.extend_from_slice(&payload);
        let mut f = ftyp;
        f.extend(meta);
        f.extend(bx(b"mdat", &body));
        f
    }

    #[test]
    fn exif_dentro_heic() {
        let tiff = b"MM\0\x2a\0\0\0\x08\0\0posizione";
        for v in [0, 1] {
            assert_eq!(exif(&fake(tiff, v)).as_deref(), Some(&tiff[..]), "iloc v{v}");
        }
        assert_eq!(exif(b"non un heic"), None);
        let mut rotto = fake(tiff, 1);
        rotto.truncate(rotto.len() - 5);
        assert_eq!(exif(&rotto), None);
    }
}
