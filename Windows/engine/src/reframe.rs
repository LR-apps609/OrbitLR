//! «Formato social» con «Inquadra le persone» (come sul Mac): il video riempie lo schermo verticale
//! e l'inquadratura segue chi parla. Le persone si trovano con il rilevamento dei volti di Windows
//! (Windows.Media.FaceAnalysis), su due fotogrammi al secondo, sul computer; poi l'inquadratura si
//! ammorbidisce (niente scatti) e ffmpeg ritaglia muovendo la finestra.

use crate::args;
use crate::error::Result;
use crate::probe::FileInfo;
use crate::run::{self, Cancel};
use crate::tools::Tools;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub t: f64,
    /// Centro dell'inquadratura, in proporzione (0…1)
    pub x: f64,
    pub y: f64,
}

/// Il volto più grande nel fotogramma: il suo centro in proporzione.
#[cfg(windows)]
fn face_center(png: &Path) -> Option<(f64, f64)> {
    use windows::core::HSTRING;
    use windows::Graphics::Imaging::{BitmapDecoder, BitmapPixelFormat, SoftwareBitmap};
    use windows::Media::FaceAnalysis::FaceDetector;
    use windows::Storage::{FileAccessMode, StorageFile};
    thread_local! {
        static DETECTOR: Option<FaceDetector> = FaceDetector::IsSupported().ok().filter(|s| *s).and_then(|_| FaceDetector::CreateAsync().ok()?.join().ok());
    }
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(png.as_os_str())).ok()?.join().ok()?;
    let stream = file.OpenAsync(FileAccessMode::Read).ok()?.join().ok()?;
    let decoder = BitmapDecoder::CreateAsync(&stream).ok()?.join().ok()?;
    let bmp = decoder.GetSoftwareBitmapAsync().ok()?.join().ok()?;
    let (w, h) = (bmp.PixelWidth().ok()? as f64, bmp.PixelHeight().ok()? as f64);
    let gray = SoftwareBitmap::Convert(&bmp, BitmapPixelFormat::Gray8).ok()?;
    DETECTOR.with(|d| {
        let d = d.as_ref()?;
        let faces = d.DetectFacesAsync(&gray).ok()?.join().ok()?;
        let mut best: Option<(u64, f64, f64)> = None;
        for f in faces {
            let b = f.FaceBox().ok()?;
            let area = b.Width as u64 * b.Height as u64;
            if best.map(|x| area > x.0).unwrap_or(true) {
                // Un po' sotto il volto: si inquadra la persona, non solo la testa
                best = Some((area, (b.X as f64 + b.Width as f64 / 2.0) / w, ((b.Y as f64 + b.Height as f64 * 0.9) / h).min(1.0)));
            }
        }
        best.map(|b| (b.1, b.2))
    })
}

#[cfg(not(windows))]
fn face_center(_png: &Path) -> Option<(f64, f64)> {
    None
}

/// I punti grezzi (con buchi dove non c'è nessuno) → un percorso morbido, come sul Mac:
/// buchi riempiti con l'ultimo punto noto, media mobile su ~2 secondi, al massimo un quarto d'immagine al secondo.
pub fn smooth(raw: &[(f64, Option<(f64, f64)>)]) -> Vec<Point> {
    let first = raw.iter().find_map(|r| r.1).unwrap_or((0.5, 0.5));
    let (mut lx, mut ly) = first;
    let pts: Vec<Point> = raw
        .iter()
        .map(|r| {
            if let Some((x, y)) = r.1 {
                lx = x;
                ly = y;
            }
            Point { t: r.0, x: lx, y: ly }
        })
        .collect();
    let radius = 2usize;
    let mut out = pts.clone();
    for i in 0..pts.len() {
        let lo = i.saturating_sub(radius);
        let hi = (i + radius).min(pts.len() - 1);
        let n = (hi - lo + 1) as f64;
        out[i].x = pts[lo..=hi].iter().map(|p| p.x).sum::<f64>() / n;
        out[i].y = pts[lo..=hi].iter().map(|p| p.y).sum::<f64>() / n;
    }
    for i in 1..out.len() {
        let dt = (out[i].t - out[i - 1].t).max(0.001);
        let step = 0.25 * dt;
        let (px, py) = (out[i - 1].x, out[i - 1].y);
        out[i].x = px + (out[i].x - px).clamp(-step, step);
        out[i].y = py + (out[i].y - py).clamp(-step, step);
    }
    out
}

/// Il centro al tempo `t` (tra due punti, in linea retta).
pub fn center_at(path: &[Point], t: f64) -> (f64, f64) {
    match path {
        [] => (0.5, 0.5),
        [p] => (p.x, p.y),
        _ => {
            if t <= path[0].t {
                return (path[0].x, path[0].y);
            }
            for w in path.windows(2) {
                if t <= w[1].t {
                    let k = ((t - w[0].t) / (w[1].t - w[0].t).max(1e-9)).clamp(0.0, 1.0);
                    return (w[0].x + (w[1].x - w[0].x) * k, w[0].y + (w[1].y - w[0].y) * k);
                }
            }
            let l = path[path.len() - 1];
            (l.x, l.y)
        }
    }
}

/// La finestra di ritaglio (larghezza, altezza) con le proporzioni dell'uscita, la più grande che entra.
pub fn crop_size(w: u32, h: u32, ow: u32, oh: u32) -> (u32, u32) {
    let target = ow as f64 / oh as f64;
    let (cw, ch) = if (w as f64 / h as f64) > target { ((h as f64 * target).round() as u32, h) } else { (w, (w as f64 / target).round() as u32) };
    (cw.min(w) & !1, ch.min(h) & !1)
}

/// I comandi per ffmpeg (sendcmd) che spostano il ritaglio «crop@f» nel tempo: al massimo `max` comandi.
pub fn commands(path: &[Point], duration: f64, w: u32, h: u32, cw: u32, ch: u32, max: usize) -> String {
    let step = (duration / max as f64).max(1.0 / 15.0);
    let mut out = String::new();
    let mut t = 0.0;
    let mut last: Option<(u32, u32)> = None;
    while t <= duration + 1e-9 {
        let (cx, cy) = center_at(path, t);
        let x = ((cx * w as f64 - cw as f64 / 2.0).clamp(0.0, (w - cw) as f64)).round() as u32 & !1;
        let y = ((cy * h as f64 - ch as f64 / 2.0).clamp(0.0, (h - ch) as f64)).round() as u32 & !1;
        if last != Some((x, y)) {
            out.push_str(&format!("{t:.3} crop@f x {x}, crop@f y {y};"));
            last = Some((x, y));
        }
        t += step;
    }
    out
}

/// Dove sono le persone nel video: due fotogrammi al secondo (al massimo 240), piccoli.
pub fn subject_path(tools: &Tools, src: &Path, info: &FileInfo, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<Vec<Point>> {
    let d = info.duration.max(0.1);
    let fps = (240.0 / d).min(2.0);
    let tmp = std::env::temp_dir().join(format!("orbitlr-inquadra-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|x| x.as_nanos()).unwrap_or(0)));
    std::fs::create_dir_all(&tmp)?;
    struct Clean(std::path::PathBuf);
    impl Drop for Clean {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _clean = Clean(tmp.clone());
    run::ffmpeg(tools, &args!["-i", src, "-an", "-vf", format!("fps={fps:.4},scale=640:-2"), tmp.join("f%05d.png")], d, cancel, &mut |p| progress(p * 0.4))?;
    let mut frames: Vec<_> = std::fs::read_dir(&tmp)?.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|e| e == "png")).collect();
    frames.sort();
    let n = frames.len().max(1);
    let mut raw = Vec::with_capacity(n);
    for (i, f) in frames.iter().enumerate() {
        cancel.check()?;
        raw.push(((i as f64 + 0.5) / fps, face_center(f)));
        progress(0.4 + 0.6 * (i + 1) as f64 / n as f64);
    }
    Ok(smooth(&raw))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percorso_morbido() {
        // Nessuno all'inizio, poi una persona a destra che salta a sinistra
        let mut raw: Vec<(f64, Option<(f64, f64)>)> = vec![(0.0, None), (0.5, None)];
        for i in 2..10 {
            raw.push((i as f64 * 0.5, Some((0.8, 0.4))));
        }
        for i in 10..20 {
            raw.push((i as f64 * 0.5, Some((0.2, 0.4))));
        }
        let p = smooth(&raw);
        assert!((p[0].x - 0.8).abs() < 1e-9, "i buchi iniziali prendono il primo punto noto");
        for w in p.windows(2) {
            assert!((w[1].x - w[0].x).abs() <= 0.25 * 0.5 + 1e-9, "niente scatti");
        }
        assert!(p.last().unwrap().x < 0.3);
        assert_eq!(center_at(&p, -1.0), (p[0].x, p[0].y));
    }

    #[test]
    fn ritaglio_e_comandi() {
        assert_eq!(crop_size(1920, 1080, 1080, 1920), (608, 1080));
        assert_eq!(crop_size(1080, 1920, 1080, 1080), (1080, 1080));
        let path = vec![Point { t: 0.0, x: 0.0, y: 0.5 }, Point { t: 10.0, x: 1.0, y: 0.5 }];
        let c = commands(&path, 10.0, 1920, 1080, 608, 1080, 400);
        assert!(c.starts_with("0.000 crop@f x 0, crop@f y 0;"), "{}", &c[..60]);
        assert!(c.contains(&format!("crop@f x {}", (1920 - 608) & !1)));
        assert!(c.matches(';').count() <= 401);
    }
}
