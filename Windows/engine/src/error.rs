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
