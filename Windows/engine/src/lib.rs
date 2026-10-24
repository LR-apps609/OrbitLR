//! Il motore di OrbitLR per Windows.
//!
//! Tutto succede sul computer: ffmpeg (versione LGPL, incluso nell'app) per video e audio,
//! il crate `image` per le foto, `lopdf` per i PDF. Nessun file viene mai mandato su internet.
//! Il motore non sa niente della finestra: riceve un'azione, i file e le opzioni,
//! e restituisce i file creati. L'app lo chiama in un thread a parte.

pub mod actions;
pub mod audio;
pub mod editor;
pub mod error;
pub mod images;
pub mod look;
pub mod meta;
pub mod names;
pub mod pdf;
pub mod probe;
pub mod run;
pub mod speech;
pub mod tools;
pub mod video;

pub use actions::{run_action, Ctx, Output};
pub use error::EngineError;
pub use probe::{probe, FileInfo, Kind};
pub use run::Cancel;
pub use tools::Tools;
