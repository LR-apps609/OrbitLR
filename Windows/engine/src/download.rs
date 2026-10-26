//! Scaricare una volta sola i pezzi grandi (modello della voce, modelli dell'IA), controllando
//! misura e impronta. Mai bloccati per sempre: tempi massimi per collegarsi e per ogni lettura.

use crate::error::{EngineError, Result};
use crate::run::Cancel;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

static ONE: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub struct Item<'a> {
    pub url: &'a str,
    pub sha256: &'a str,
    pub bytes: u64,
    /// Per i messaggi: «il modello della voce», «il motore dell'IA»…
    pub what: &'a str,
}

pub fn ready(dest: &Path, item: &Item) -> bool {
    dest.metadata().map(|m| m.len() == item.bytes).unwrap_or(false)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Scarica `item` in `dest` (se non c'è già). `progress` tra 0 e 1.
pub fn fetch(item: &Item, dest: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    use sha2::{Digest, Sha256};
    // Due lavori che chiedono la stessa cosa insieme: si scarica una volta sola
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    if ready(dest, item) {
        return Ok(dest.to_path_buf());
    }
    std::fs::create_dir_all(dest.parent().unwrap_or(Path::new(".")))?;
    let part = dest.with_extension("parziale");
    struct Rm<'a>(&'a Path, bool);
    impl Drop for Rm<'_> {
        fn drop(&mut self) {
            if !self.1 {
                let _ = std::fs::remove_file(self.0);
            }
        }
    }
    let mut guard = Rm(&part, false);
    let secs = |n| Some(std::time::Duration::from_secs(n));
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .proxy(ureq::Proxy::try_from_env())
        .timeout_connect(secs(20))
        .timeout_recv_response(secs(30))
        .timeout_per_read(secs(60))
        .build()
        .into();
    let mut resp = agent
        .get(item.url)
        .call()
        .map_err(|e| EngineError::new(format!("non riesco a scaricare {} (serve internet solo questa volta): {e}", item.what)))?;
    let total = resp.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(item.bytes);
    let mut reader = resp.body_mut().as_reader();
    let mut file = std::fs::File::create(&part)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut got: u64 = 0;
    loop {
        if cancel.is_cancelled() {
            return Err(EngineError::cancelled());
        }
        let n = reader.read(&mut buf).map_err(|e| EngineError::new(format!("scaricamento interrotto: {e}")))?;
        if n == 0 {
            break;
        }
        if got + n as u64 > item.bytes + 1024 {
            return Err(EngineError::new(format!("{} scaricato non è quello giusto (troppo grande)", item.what)));
        }
        file.write_all(&buf[..n])?;
        hasher.update(&buf[..n]);
        got += n as u64;
        if total > 0 {
            progress((got as f64 / total as f64).min(0.999));
        }
    }
    file.flush()?;
    drop(file);
    if got != item.bytes || hex(&hasher.finalize()) != item.sha256 {
        return Err(EngineError::new(format!("{} scaricato non è quello giusto (impronta diversa): riprova più tardi", item.what)));
    }
    std::fs::rename(&part, dest)?;
    guard.1 = true;
    progress(1.0);
    Ok(dest.to_path_buf())
}
