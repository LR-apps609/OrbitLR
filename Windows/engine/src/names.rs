use std::path::{Path, PathBuf};

/// Un nome di file sicuro per Windows: niente caratteri vietati, niente nomi riservati (CON, NUL…),
/// niente punti o spazi alla fine, al massimo 180 caratteri.
pub fn safe_name(s: &str) -> String {
    let mut out: String = s
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => '-',
            c if (c as u32) < 32 => '-',
            c => c,
        })
        .collect();
    while out.ends_with('.') || out.ends_with(' ') {
        out.pop();
    }
    while out.starts_with('.') {
        out.remove(0);
    }
    if out.chars().count() > 180 {
        // Si accorcia il nome, non il «(compresso)» finale
        let (head, tail) = match out.rfind(" (") {
            Some(i) if out.ends_with(')') && out.len() - i < 40 => (out[..i].to_string(), out[i..].to_string()),
            _ => (out.clone(), String::new()),
        };
        let keep = 180usize.saturating_sub(tail.chars().count()).max(20);
        out = head.chars().take(keep).collect::<String>().trim_end().to_string() + &tail;
    }
    let upper = out.to_uppercase();
    let stem = upper.split('.').next().unwrap_or("").trim_end();
    let digit = |c: char| c.is_ascii_digit() || matches!(c, '¹' | '²' | '³');
    let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem)
        || ((stem.starts_with("COM") || stem.starts_with("LPT")) && stem.chars().count() == 4 && stem.chars().last().map(digit).unwrap_or(false));
    if out.is_empty() || reserved {
        out = format!("file {out}").trim().to_string();
    }
    out
}

/// «Vacanze (compresso).mp4», e se c'è già «Vacanze (compresso 2).mp4»: mai sovrascrivere niente.
/// Il nome viene subito riservato (un file vuoto creato «solo se non esiste»): due lavori insieme
/// non possono scegliere lo stesso nome.
pub fn unique(dir: &Path, base: &str, ext: &str) -> PathBuf {
    let base = safe_name(base);
    // L'estensione: solo lettere e cifre (mai «mp4\..\x»)
    let ext: String = ext.trim_start_matches('.').chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect::<String>().to_ascii_lowercase();
    let make = |b: &str| if ext.is_empty() { dir.join(b) } else { dir.join(format!("{b}.{ext}")) };
    let reserve = |p: &Path| std::fs::OpenOptions::new().write(true).create_new(true).open(p).is_ok();
    let first = make(&base);
    if !first.exists() && reserve(&first) {
        track_placeholder(&first, true);
        return first;
    }
    // «Vacanze (compresso)» → «Vacanze (compresso 2)»; «Foto (2)» → «Foto (3)»
    let parsed = base.strip_suffix(')').and_then(|b| b.rfind(" (").map(|i| (b[..i].to_string(), b[i + 2..].to_string())));
    let (head, label, start) = match parsed {
        Some((h, t)) => match t.parse::<u32>() {
            Ok(n) => (h, None, n + 1),
            Err(_) => match t.rsplit_once(' ').and_then(|(l, n)| n.parse::<u32>().ok().map(|n| (l.to_string(), n))) {
                Some((l, n)) => (h, Some(l), n + 1),
                None => (h, Some(t), 2),
            },
        },
        None => (base.clone(), None, 2),
    };
    for n in start..start + 10_000 {
        let cand = match &label {
            Some(t) => format!("{head} ({t} {n})"),
            None => format!("{head} ({n})"),
        };
        let p = make(&cand);
        if !p.exists() && reserve(&p) {
            track_placeholder(&p, true);
            return p;
        }
    }
    make(&format!("{base} {}", std::process::id()))
}

/// Un file da creare: si scrive su un temporaneo accanto e alla fine si rinomina sul nome riservato.
/// Se qualcosa va storto (o si interrompe) non resta niente: né il temporaneo né il nome riservato.
pub struct OutFile {
    pub path: PathBuf,
    pub tmp: PathBuf,
    done: bool,
}

impl OutFile {
    pub fn new(dir: &Path, base: &str, ext: &str) -> crate::error::Result<OutFile> {
        std::fs::create_dir_all(dir)?;
        let path = unique(dir, base, ext);
        let e = self::ext(&path);
        let tmp = temp_beside(&path, if e.is_empty() { "tmp" } else { &e });
        Ok(OutFile { path, tmp, done: false })
    }

    /// Il lavoro è riuscito: il temporaneo prende il nome giusto.
    pub fn commit(mut self) -> crate::error::Result<PathBuf> {
        let ok = self.tmp.metadata().map(|m| m.len() > 0).unwrap_or(false);
        if !ok {
            return Err(crate::error::EngineError::new("il file creato è vuoto"));
        }
        // Su OneDrive e con l'antivirus il file può essere occupato per un attimo: si riprova
        let mut last = None;
        for _ in 0..8 {
            match std::fs::rename(&self.tmp, &self.path) {
                Ok(()) => {
                    last = None;
                    break;
                }
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(250));
                }
            }
        }
        if let Some(e) = last {
            return Err(e.into());
        }
        track_temp(&self.tmp, false);
        track_placeholder(&self.path, false);
        self.done = true;
        Ok(self.path.clone())
    }
}

impl Drop for OutFile {
    fn drop(&mut self) {
        if self.done {
            return;
        }
        let _ = std::fs::remove_file(&self.tmp);
        track_temp(&self.tmp, false);
        // Il nome riservato si toglie solo se è ancora vuoto (cioè nostro)
        if self.path.metadata().map(|m| m.len() == 0).unwrap_or(false) {
            let _ = std::fs::remove_file(&self.path);
        }
        track_placeholder(&self.path, false);
    }
}

/// Il nome senza estensione.
pub fn stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "file".into())
}

/// L'estensione in minuscolo («JPG» → «jpg»).
pub fn ext(p: &Path) -> String {
    p.extension().map(|s| s.to_string_lossy().to_ascii_lowercase()).unwrap_or_default()
}

/// File temporaneo accanto alla destinazione (stesso disco: alla fine basta rinominarlo).
/// Viene annotato: se l'app si chiude a metà, al prossimo avvio si cancella.
pub fn temp_beside(final_path: &Path, ext: &str) -> PathBuf {
    let dir = final_path.parent().unwrap_or(Path::new("."));
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let p = dir.join(format!(".orbitlr-{}-{n}.{ext}", std::process::id()));
    track_temp(&p, true);
    p
}

static REGISTRY: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

/// Dove annotare i file temporanei (nella cartella dei dati dell'app).
pub fn set_temp_registry(file: PathBuf) {
    *REGISTRY.lock().unwrap_or_else(|e| e.into_inner()) = Some(file);
}

/// Annota (o toglie dall'elenco) un file temporaneo.
pub fn track_temp(p: &Path, add: bool) {
    track_line(format!("T|{}", p.to_string_lossy()), add);
}

/// Annota un nome riservato (file vuoto): al riavvio si toglie se è rimasto vuoto.
fn track_placeholder(p: &Path, add: bool) {
    track_line(format!("R|{}", p.to_string_lossy()), add);
}

fn track_line(line: String, add: bool) {
    let guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(reg) = guard.as_ref() else { return };
    let mut list: Vec<String> = std::fs::read_to_string(reg).unwrap_or_default().lines().map(String::from).filter(|l| !l.is_empty()).collect();
    list.retain(|l| l != &line);
    if add {
        list.push(line);
    }
    let _ = std::fs::write(reg, list.join("\n"));
}

/// All'avvio: cancella i file temporanei rimasti da una chiusura a metà lavoro (solo i nostri, dal nome).
pub fn cleanup_leftovers() -> usize {
    let guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(reg) = guard.as_ref() else { return 0 };
    let mut n = 0;
    for l in std::fs::read_to_string(reg).unwrap_or_default().lines() {
        let (kind, path) = l.split_once('|').unwrap_or(("T", l));
        let p = Path::new(path);
        let gone = match kind {
            // Temporanei: solo i nostri, dal nome
            "T" => p.file_name().map(|f| f.to_string_lossy().starts_with(".orbitlr-")).unwrap_or(false) && p.is_file() && std::fs::remove_file(p).is_ok(),
            // Nomi riservati: solo se ancora vuoti
            _ => p.metadata().map(|m| m.is_file() && m.len() == 0).unwrap_or(false) && std::fs::remove_file(p).is_ok(),
        };
        if gone {
            n += 1;
        }
    }
    let _ = std::fs::remove_file(reg);
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nomi_sicuri() {
        assert_eq!(safe_name("a/b:c*?.mp4"), "a-b-c--.mp4");
        assert_eq!(safe_name("CON"), "file CON");
        assert_eq!(safe_name("com1.txt"), "file com1.txt");
        assert_eq!(safe_name("computer"), "computer");
        assert_eq!(safe_name("ciao. . "), "ciao");
        assert_eq!(safe_name("..nascosto"), "nascosto");
        assert_eq!(safe_name(""), "file");
        assert_eq!(safe_name("CONIN$"), "file CONIN$");
        let long = format!("{} (compresso)", "a".repeat(300));
        assert!(safe_name(&long).ends_with(" (compresso)") && safe_name(&long).chars().count() <= 180);
    }

    #[test]
    fn mai_sovrascrivere() {
        let d = std::env::temp_dir().join(format!("orbit-names-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let a = unique(&d, "Vacanze (compresso)", "mp4");
        assert_eq!(a.file_name().unwrap(), "Vacanze (compresso).mp4");
        assert!(a.exists(), "il nome è riservato subito");
        std::fs::write(&a, b"x").unwrap();
        let b = unique(&d, "Vacanze (compresso)", "mp4");
        assert_eq!(b.file_name().unwrap(), "Vacanze (compresso 2).mp4");
        std::fs::write(&b, b"x").unwrap();
        assert_eq!(unique(&d, "Vacanze (compresso)", "mp4").file_name().unwrap(), "Vacanze (compresso 3).mp4");
        std::fs::write(d.join("Foto.jpg"), b"x").unwrap();
        assert_eq!(unique(&d, "Foto", "jpg").file_name().unwrap(), "Foto (2).jpg");
        assert_eq!(unique(&d, "Foto (2)", "jpg").file_name().unwrap(), "Foto (3).jpg");
        assert_eq!(unique(&d, "x", "mp4\\..\\..\\y").file_name().unwrap(), "x.mp4y");
        let _ = std::fs::remove_dir_all(&d);
    }
}

// ───────────────────────── Le parole nei nomi dei file creati, nella lingua dell'app (come sul Mac)

static LANG_EN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// L'app dice in che lingua parla («en» = inglese, altro = italiano).
pub fn set_lang(lang: &str) {
    LANG_EN.store(lang.starts_with("en"), std::sync::atomic::Ordering::Relaxed);
}

/// «protetto» → «protected» quando l'app è in inglese.
pub fn tag(it: &str) -> String {
    if !LANG_EN.load(std::sync::atomic::Ordering::Relaxed) {
        return it.to_string();
    }
    let en = match it {
        "protetto" => "protected", "sbloccato" => "unlocked", "ruotato" => "rotated", "riordinato" => "reordered",
        "compresso" => "compressed", "taglio" => "trimmed", "più leggero" => "smaller", "più leggera" => "smaller",
        "senza metadati" => "no metadata", "senza sfondo" => "no background", "migliorata" => "enhanced",
        "trascrizione" => "transcript", "suoneria" => "ringtone", "voce" => "voice", "pagine" => "pages", "uniti" => "merged",
        "Compressi" => "Compressed", "Convertiti" => "Converted",
        "tagliato" => "trimmed", "senza pause" => "no pauses", "vocale" => "voice note", "logo nascosto" => "logo hidden",
        "ruotata" => "rotated", "testo" => "text", "senza audio" => "no audio", "sfondo bianco" => "white background",
        "voce pulita" => "clean voice", "con sottotitoli" => "with subtitles", "volume uniforme" => "even volume", "pagina" => "page", "Testo" => "Text", "Montaggio" => "Edit", "raddrizzato" => "straightened", "scatti" => "shots", "vettoriale" => "vector",
        other => other,
    };
    en.to_string()
}

#[cfg(test)]
mod tag_tests {
    #[test]
    fn italiano_di_base() {
        assert_eq!(super::tag("protetto"), "protetto");
    }
}
