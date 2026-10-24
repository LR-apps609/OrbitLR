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
        out = out.chars().take(180).collect();
    }
    let upper = out.to_ascii_uppercase();
    let stem = upper.split('.').next().unwrap_or("");
    let reserved = ["CON", "PRN", "AUX", "NUL"].contains(&stem)
        || ((stem.starts_with("COM") || stem.starts_with("LPT")) && stem.len() == 4 && stem.as_bytes()[3].is_ascii_digit());
    if out.is_empty() || reserved {
        out = format!("file {out}").trim().to_string();
    }
    out
}

/// «Vacanze (compresso).mp4», e se c'è già «Vacanze (compresso 2).mp4»: mai sovrascrivere niente.
pub fn unique(dir: &Path, base: &str, ext: &str) -> PathBuf {
    let base = safe_name(base);
    let ext = ext.trim_start_matches('.');
    let make = |b: &str| if ext.is_empty() { dir.join(b) } else { dir.join(format!("{b}.{ext}")) };
    let first = make(&base);
    if !first.exists() {
        return first;
    }
    // «Vacanze (compresso)» → «Vacanze (compresso 2)»
    let (head, tail) = match base.strip_suffix(')').and_then(|b| b.rfind(" (").map(|i| (b[..i].to_string(), b[i + 2..].to_string()))) {
        Some((h, t)) => (h, Some(t)),
        None => (base.clone(), None),
    };
    for n in 2..10_000 {
        let cand = match &tail {
            Some(t) => format!("{head} ({t} {n})"),
            None => format!("{head} ({n})"),
        };
        let p = make(&cand);
        if !p.exists() {
            return p;
        }
    }
    make(&format!("{base} {}", std::process::id()))
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
    let guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(reg) = guard.as_ref() else { return };
    let mut list: Vec<String> = std::fs::read_to_string(reg).unwrap_or_default().lines().map(String::from).filter(|l| !l.is_empty()).collect();
    let s = p.to_string_lossy().to_string();
    list.retain(|l| l != &s);
    if add {
        list.push(s);
    }
    let _ = std::fs::write(reg, list.join("\n"));
}

/// All'avvio: cancella i file temporanei rimasti da una chiusura a metà lavoro (solo i nostri, dal nome).
pub fn cleanup_leftovers() -> usize {
    let guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(reg) = guard.as_ref() else { return 0 };
    let mut n = 0;
    for l in std::fs::read_to_string(reg).unwrap_or_default().lines() {
        let p = Path::new(l);
        let ours = p.file_name().map(|f| f.to_string_lossy().starts_with(".orbitlr-")).unwrap_or(false);
        if ours && p.is_file() && std::fs::remove_file(p).is_ok() {
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
    }

    #[test]
    fn mai_sovrascrivere() {
        let d = std::env::temp_dir().join(format!("orbit-names-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let a = unique(&d, "Vacanze (compresso)", "mp4");
        assert_eq!(a.file_name().unwrap(), "Vacanze (compresso).mp4");
        std::fs::write(&a, b"x").unwrap();
        let b = unique(&d, "Vacanze (compresso)", "mp4");
        assert_eq!(b.file_name().unwrap(), "Vacanze (compresso 2).mp4");
        std::fs::write(&b, b"x").unwrap();
        assert_eq!(unique(&d, "Vacanze (compresso)", "mp4").file_name().unwrap(), "Vacanze (compresso 3).mp4");
        std::fs::write(d.join("Foto.jpg"), b"x").unwrap();
        assert_eq!(unique(&d, "Foto", "jpg").file_name().unwrap(), "Foto (2).jpg");
        let _ = std::fs::remove_dir_all(&d);
    }
}
