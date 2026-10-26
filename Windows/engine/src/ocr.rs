//! «Estrai il testo» dalle foto e dagli screenshot, con il riconoscimento del testo di Windows
//! (sul computer, senza internet, nelle lingue installate in Windows).

use crate::error::{EngineError, Result};
use crate::images::{self, Photo};
use crate::names;
use crate::tools::Tools;
use std::path::{Path, PathBuf};

/// Il testo di una foto, riga per riga.
pub fn read_text(tools: Option<&Tools>, src: &Path) -> Result<String> {
    // La foto passa da un PNG dritto (così vanno anche HEIC, WebP e le foto girate del telefono)
    let p = images::open(tools, src)?;
    let max = max_dimension();
    let img = if p.img.width().max(p.img.height()) > max { p.img.resize(max, max, image::imageops::FilterType::Lanczos3) } else { p.img };
    let png = std::env::temp_dir().join(format!("orbitlr-ocr-{}-{}.png", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)));
    images::save(None, &Photo { img, exif: None, icc: None }, "png", 90, &png)?;
    let r = recognize(&png);
    let _ = std::fs::remove_file(&png);
    let text = r?;
    if text.trim().is_empty() {
        return Err(EngineError::new("non ho trovato testo in questa immagine"));
    }
    Ok(text)
}

pub fn to_file(tools: Option<&Tools>, src: &Path, dir: &Path) -> Result<PathBuf> {
    let text = read_text(tools, src)?;
    let of = names::OutFile::new(dir, &format!("{} ({})", names::stem(src), crate::names::tag("testo")), "txt")?;
    std::fs::write(&of.tmp, text)?;
    of.commit()
}

/// Il testo di un PNG già pronto (le pagine dei PDF scansionati).
pub fn recognize_png(png: &Path) -> Result<String> {
    recognize(png)
}

#[cfg(windows)]
fn max_dimension() -> u32 {
    windows::Media::Ocr::OcrEngine::MaxImageDimension().unwrap_or(4000).max(1000)
}

#[cfg(not(windows))]
fn max_dimension() -> u32 {
    4000
}

#[cfg(windows)]
fn recognize(png: &Path) -> Result<String> {
    use windows::core::HSTRING;
    use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapDecoder, BitmapPixelFormat, SoftwareBitmap};
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::{FileAccessMode, StorageFile};
    let fail = |e: windows::core::Error| EngineError::new(format!("il riconoscimento del testo di Windows non ha funzionato: {}", e.message()));
    let engine = OcrEngine::TryCreateFromUserProfileLanguages()
        .map_err(|_| EngineError::new("in Windows manca il riconoscimento del testo per la tua lingua: Impostazioni → Ora e lingua → Lingua, poi aggiungi le funzionalità della lingua"))?;
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(png.as_os_str())).map_err(fail)?.join().map_err(fail)?;
    let stream = file.OpenAsync(FileAccessMode::Read).map_err(fail)?.join().map_err(fail)?;
    let decoder = BitmapDecoder::CreateAsync(&stream).map_err(fail)?.join().map_err(fail)?;
    let bmp = decoder.GetSoftwareBitmapAsync().map_err(fail)?.join().map_err(fail)?;
    let bmp = SoftwareBitmap::ConvertWithAlpha(&bmp, BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied).map_err(fail)?;
    let result = engine.RecognizeAsync(&bmp).map_err(fail)?.join().map_err(fail)?;
    let lines = result.Lines().map_err(fail)?;
    let mut out = String::new();
    for i in 0..lines.Size().map_err(fail)? {
        let line = lines.GetAt(i).map_err(fail)?;
        out.push_str(&line.Text().map_err(fail)?.to_string_lossy());
        out.push('\n');
    }
    Ok(out)
}

#[cfg(not(windows))]
fn recognize(_png: &Path) -> Result<String> {
    Err(EngineError::new("il riconoscimento del testo usa Windows: qui non è disponibile"))
}
