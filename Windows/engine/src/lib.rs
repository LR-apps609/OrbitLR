//! Il motore di OrbitLR per Windows.
//!
//! Tutto succede sul computer: ffmpeg (versione LGPL, incluso nell'app) per video e audio,
//! il crate `image` per le foto, `lopdf` per i PDF. Nessun file viene mai mandato su internet.
//! Il motore non sa niente della finestra: riceve un'azione, i file e le opzioni,
//! e restituisce i file creati. L'app lo chiama in un thread a parte.

pub mod actions;
pub mod ai;
pub mod audio;
pub mod download;
pub mod editor;
pub mod error;
pub mod heif;
pub mod hide;
pub mod images;
pub mod inpaint;
pub mod linkdl;
pub mod look;
pub mod meta;
pub mod names;
pub mod office;
pub mod ocr;
pub mod pdf;
pub mod pdfedit;
pub mod phone;
pub mod pdfrender;
pub mod probe;
pub mod reframe;
pub mod run;
pub mod scan;
pub mod speech;
pub mod tools;
pub mod update;
pub mod vector;
pub mod video;
pub mod watch;
pub mod whisper;

pub use actions::{run_action, Ctx, Output};
pub use error::EngineError;
pub use probe::{probe, FileInfo, Kind};
pub use run::Cancel;
pub use tools::Tools;
