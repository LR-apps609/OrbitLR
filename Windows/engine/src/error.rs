use std::fmt;

/// Un errore da mostrare così com'è: in italiano, in parole semplici, senza codici.
#[derive(Debug, Clone, PartialEq)]
pub struct EngineError(pub String);

impl EngineError {
    pub fn new(s: impl Into<String>) -> Self {
        EngineError(s.into())
    }
    pub fn cancelled() -> Self {
        EngineError("interrotto".into())
    }
    pub fn is_cancelled(&self) -> bool {
        self.0 == "interrotto"
    }
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EngineError {}

impl From<std::io::Error> for EngineError {
    fn from(e: std::io::Error) -> Self {
        use std::io::ErrorKind::*;
        EngineError(match e.kind() {
            NotFound => "non trovo il file (spostato o cancellato?)".into(),
            PermissionDenied => "Windows non dà il permesso di leggere o scrivere in quella cartella".into(),
            StorageFull => "spazio su disco esaurito".into(),
            _ => format!("errore del disco: {e}"),
        })
    }
}

impl From<image::ImageError> for EngineError {
    fn from(e: image::ImageError) -> Self {
        match e {
            image::ImageError::Unsupported(_) => EngineError("formato di immagine non riconosciuto".into()),
            image::ImageError::Decoding(_) => EngineError("l'immagine sembra danneggiata".into()),
            image::ImageError::IoError(io) => io.into(),
            other => EngineError(format!("non riesco a lavorare l'immagine: {other}")),
        }
    }
}

pub type Result<T> = std::result::Result<T, EngineError>;

/// 2.0.2 · Perché un file scelto non si può usare: non c'è più, oppure Windows non lascia leggerlo
/// (prima ogni caso diventava «spostato o cancellato?», anche per un file protetto). None se è un file leggibile.
pub fn file_problem(path: &std::path::Path) -> Option<String> {
    let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
    match std::fs::metadata(path) {
        Ok(m) if m.is_file() => None,
        Ok(_) => Some(format!("«{name}» non è un file")),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Some(format!("Windows non dà il permesso di leggere «{name}»")),
        Err(_) => Some(format!("non trovo «{name}» (spostato o cancellato?)")),
    }
}

/// 2.0.2 · Un errore di rete detto in italiano, senza il testo tecnico in inglese di Windows
/// (prima: «io: An attempt was made to access a socket… (os error 10013)»).
pub fn net_reason(e: &dyn fmt::Display) -> String {
    let s = e.to_string();
    let l = s.to_lowercase();
    let has = |k: &str| l.contains(k);
    if has("10013") || has("forbidden by its access permissions") {
        "un firewall o un antivirus blocca la connessione di OrbitLR".into()
    } else if has("11001") || has("dns") || has("lookup") || has("no such host") || has("name or service not known") {
        "nessuna connessione a internet".into()
    } else if has("timed out") || has("timeout") || has("10060") {
        "la connessione è troppo lenta o si è interrotta".into()
    } else if has("10061") || has("refused") || has("10054") || has("reset") {
        "il server non risponde: riprova più tardi".into()
    } else if has("status code 404") || has("status 404") || has(": 404") {
        "il file non è più disponibile su internet".into()
    } else if has("certificate") || has("tls") || has("ssl") {
        "la connessione sicura non riesce (data e ora del computer giuste?)".into()
    } else {
        "problema di connessione a internet".into()
    }
}

/// Dalle ultime righe di ffmpeg a un motivo comprensibile (come `explain` del motore per Mac).
pub fn explain_ffmpeg(stderr: &str) -> String {
    let t = stderr;
    let has = |s: &str| t.contains(s);
    if has("No space left") || has("not enough space") {
        return "spazio su disco esaurito".into();
    }
    if has("Permission denied") || has("Access is denied") {
        return "Windows non dà il permesso di leggere o scrivere in quella cartella".into();
    }
    if has("Invalid data found") || has("moov atom not found") || has("could not find codec") || has("corrupt") {
        return "il file sembra danneggiato o in un formato non riconosciuto".into();
    }
    if has("does not contain any stream") || has("Output file is empty") || has("matches no streams") {
        return "nel file non c'è quello che serve (per esempio manca l'audio o il video)".into();
    }
    if has("No such file") {
        return "non trovo il file (spostato o cancellato?)".into();
    }
    if has("password") || has("encrypted") {
        return "il file è protetto da password".into();
    }
    // L'ultima riga che sembra un errore, ripulita
    let last = t
        .lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("frame=") && !l.starts_with("size="))
        .unwrap_or("errore sconosciuto");
    let clean: String = last.chars().take(200).collect();
    format!("il motore video si è fermato: {clean}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2.0.2 · Gli errori di rete di Windows diventano frasi in italiano, senza il testo tecnico.
    #[test]
    fn rete_in_italiano() {
        let fw = "io: An attempt was made to access a socket in a way forbidden by its access permissions. (os error 10013)";
        assert_eq!(net_reason(&fw), "un firewall o un antivirus blocca la connessione di OrbitLR");
        assert_eq!(net_reason(&"io: failed to lookup address information (os error 11001)"), "nessuna connessione a internet");
        assert_eq!(net_reason(&"timeout: global"), "la connessione è troppo lenta o si è interrotta");
        assert!(!net_reason(&"qualcosa di strano").contains("os error"));
    }

    /// 2.0.2 · Un file che non c'è e un file che c'è si distinguono.
    #[test]
    fn file_che_manca() {
        let d = std::env::temp_dir().join(format!("orbit-err-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("c'è.txt");
        std::fs::write(&f, b"x").unwrap();
        assert_eq!(file_problem(&f), None);
        assert!(file_problem(&d.join("manca.txt")).unwrap().contains("spostato o cancellato"));
        assert!(file_problem(&d).unwrap().contains("non è un file"));
        let _ = std::fs::remove_dir_all(&d);
    }
}
