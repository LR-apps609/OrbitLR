//! Word, Excel e PowerPoint con LibreOffice (facoltativo, gratuito): se è installato sul computer
//! si usa quello, senza finestre. Profilo tutto suo e blindato: niente macro, niente collegamenti
//! a file o indirizzi esterni (un documento scaricato non può far leggere altri file del PC).

use crate::error::{EngineError, Result};
use crate::names;
use crate::run::Cancel;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Il gruppo di un documento: decide in cosa si può convertire.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Group {
    Text,
    Sheet,
    Slides,
}

pub fn group(ext: &str) -> Option<Group> {
    Some(match ext.to_ascii_lowercase().as_str() {
        "docx" | "doc" | "odt" | "rtf" | "txt" | "wps" => Group::Text,
        "xlsx" | "xls" | "ods" | "csv" => Group::Sheet,
        "pptx" | "ppt" | "odp" => Group::Slides,
        _ => return None,
    })
}

/// I formati di arrivo, il più utile per primo.
pub fn targets(g: Group) -> &'static [&'static str] {
    match g {
        Group::Text => &["pdf", "docx", "odt", "txt", "rtf"],
        Group::Sheet => &["pdf", "xlsx", "ods", "csv"],
        Group::Slides => &["pdf", "pptx", "odp"],
    }
}

/// Il nome del filtro di LibreOffice per un formato di arrivo.
fn filter(g: Group, to: &str) -> String {
    match (g, to) {
        (_, "txt") => "txt:Text (encoded):UTF8".into(),
        (Group::Sheet, "csv") => "csv:Text - txt - csv (StarCalc):44,34,76".into(), // virgola, virgolette, UTF-8
        (Group::Text, "docx") => "docx:MS Word 2007 XML".into(),
        (Group::Sheet, "xlsx") => "xlsx:Calc MS Excel 2007 XML".into(),
        (Group::Slides, "pptx") => "pptx:Impress MS PowerPoint 2007 XML".into(),
        (_, x) => x.into(),
    }
}

/// soffice.exe, se LibreOffice è installato.
pub fn locate() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("ORBIT_SOFFICE").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(p);
    }
    #[cfg(windows)]
    {
        let mut roots: Vec<PathBuf> = Vec::new();
        for v in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
            if let Some(d) = std::env::var_os(v) {
                roots.push(PathBuf::from(d));
            }
        }
        if let Some(d) = std::env::var_os("LOCALAPPDATA") {
            roots.push(PathBuf::from(d).join("Programs"));
        }
        for r in roots {
            for name in ["LibreOffice", "LibreOffice 25", "LibreOffice 24", "LibreOffice 7"] {
                let p = r.join(name).join("program").join("soffice.exe");
                if p.is_file() {
                    return Some(p);
                }
            }
        }
        None
    }
    #[cfg(not(windows))]
    {
        for n in ["soffice", "libreoffice"] {
            if let Some(p) = std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(n)).find(|p| p.is_file())) {
                return Some(p);
            }
        }
        None
    }
}

const HARDEN: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!-- OrbitLR-sicurezza-1 -->
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
<item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
<item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
</oor:items>
"#;

/// Un indirizzo file:/// per il profilo (barre in avanti, spazi e caratteri strani codificati).
fn file_url(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    let mut out = String::from(if s.starts_with('/') { "file://" } else { "file:///" });
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' | b':' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Converte un documento. LibreOffice ci mette qualche secondo a partire.
pub fn convert(soffice: &Path, src: &Path, to: &str, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let ext = names::ext(src);
    let g = group(&ext).ok_or_else(|| EngineError::new("questo documento non lo so convertire"))?;
    if !targets(g).contains(&to) {
        return Err(EngineError::new(format!("non so convertire questo documento in {}", to.to_uppercase())));
    }
    if ext == to {
        return Err(EngineError::new(format!("il file è già {}", to.to_uppercase())));
    }
    progress(0.05);
    // Una cartella di lavoro tutta sua: profilo blindato e risultato
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let work = std::env::temp_dir().join(format!("orbitlr-office-{}-{n}", std::process::id()));
    struct Clean(PathBuf);
    impl Drop for Clean {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _clean = Clean(work.clone());
    let profile = work.join("profilo");
    let out = work.join("uscita");
    std::fs::create_dir_all(profile.join("user"))?;
    std::fs::create_dir_all(&out)?;
    std::fs::write(profile.join("user").join("registrymodifications.xcu"), HARDEN)?;
    // Il file di partenza copiato con un nome semplice: niente sorprese con accenti o nomi lunghi
    let input = work.join(format!("documento.{ext}"));
    std::fs::copy(src, &input)?;

    let mut cmd = crate::tools::quiet(std::process::Command::new(soffice));
    cmd.args(["--headless", "--invisible", "--norestore", "--nolockcheck", "--nodefault", "--nofirststartwizard"])
        .arg(format!("-env:UserInstallation={}", file_url(&profile)))
        .arg("--convert-to")
        .arg(filter(g, to))
        .arg("--outdir")
        .arg(&out)
        .arg(&input)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut child = cmd.spawn().map_err(|_| EngineError::new("LibreOffice non parte: prova a reinstallarlo"))?;
    crate::tools::bind_to_app(&child);
    let start = Instant::now();
    let limit = Duration::from_secs(300);
    loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::cancelled());
        }
        if let Some(st) = child.try_wait()? {
            if !st.success() {
                return Err(EngineError::new("LibreOffice non è riuscito a convertire il documento (forse è protetto da password o danneggiato)"));
            }
            break;
        }
        if start.elapsed() > limit {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::new("LibreOffice ci mette troppo: il documento è molto grande o danneggiato"));
        }
        // Avanzamento finto ma onesto: sale piano fino al 90%
        let t = start.elapsed().as_secs_f64();
        progress(0.05 + 0.85 * (1.0 - (-t / 8.0).exp()));
        std::thread::sleep(Duration::from_millis(150));
    }
    let made = out.join(format!("documento.{to}"));
    if !made.is_file() || std::fs::metadata(&made).map(|m| m.len()).unwrap_or(0) == 0 {
        return Err(EngineError::new("LibreOffice non ha creato il file: il documento potrebbe essere protetto o danneggiato"));
    }
    let of = names::OutFile::new(dir, &names::stem(src), to)?;
    std::fs::copy(&made, &of.tmp)?;
    let p = of.commit()?;
    progress(1.0);
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gruppi_e_filtri() {
        assert_eq!(group("DOCX"), Some(Group::Text));
        assert_eq!(group("csv"), Some(Group::Sheet));
        assert_eq!(group("ppt"), Some(Group::Slides));
        assert_eq!(group("mp4"), None);
        assert_eq!(filter(Group::Sheet, "csv"), "csv:Text - txt - csv (StarCalc):44,34,76");
        assert_eq!(filter(Group::Text, "pdf"), "pdf");
        assert!(file_url(Path::new(r"C:\Users\Anna Rossi\AppData\x")).starts_with("file:///C:/Users/Anna%20Rossi/"));
        assert_eq!(file_url(Path::new("/tmp/a b")), "file:///tmp/a%20b");
    }
}
