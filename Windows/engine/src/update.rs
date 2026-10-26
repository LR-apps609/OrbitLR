//! Aggiornamenti automatici, come sul Mac: GitHub pubblica un manifesto firmato (Ed25519, la stessa chiave
//! degli aggiornamenti per Mac) con versione, build e impronta dell'installatore. OrbitLR scarica
//! l'installatore solo se la firma è valida e l'impronta coincide; poi lo avvia in silenzio e si riapre.

use crate::error::{EngineError, Result};
use crate::run::Cancel;
use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// Le chiavi pubbliche di cui OrbitLR si fida: la principale (GitHub) e quella di riserva (offline).
pub const TRUSTED_KEYS: [&str; 2] = ["xOzQ8TT6IqdlLtj8FQnyLAelvSBtXehmmkPAArIsVis=", "Nr/1zqg8DjVw1zAVnbZbHPHNya+soZ83wNB9zLhCung="];

pub const BASE: &str = "https://github.com/LR-apps609/OrbitLR/releases/download/windows-anteprima/";
pub const MANIFEST: &str = "manifest-windows.json";
pub const SIGNATURE: &str = "manifest-windows.sig";
/// Un installatore più grande di così non è il nostro.
const MAX_BYTES: u64 = 1_500_000_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Manifest {
    pub version: String,
    pub build: u64,
    /// Nome del file dell'installatore nella stessa pagina di GitHub
    pub file: String,
    pub sha256: String,
    pub size: u64,
    #[serde(default)]
    pub notes: String,
}

fn keys() -> Vec<VerifyingKey> {
    TRUSTED_KEYS
        .iter()
        .filter_map(|k| base64::engine::general_purpose::STANDARD.decode(k).ok())
        .filter_map(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
        .filter_map(|b| VerifyingKey::from_bytes(&b).ok())
        .collect()
}

/// Il manifesto, solo se la firma è di una chiave fidata e i campi sono sensati.
pub fn verify(manifest: &[u8], sig: &[u8]) -> Result<Manifest> {
    verify_with(manifest, sig, &keys())
}

pub fn verify_with(manifest: &[u8], sig: &[u8], keys: &[VerifyingKey]) -> Result<Manifest> {
    let sig = <[u8; 64]>::try_from(sig).map_err(|_| EngineError::new("firma dell'aggiornamento non valida"))?;
    let sig = Signature::from_bytes(&sig);
    if !keys.iter().any(|k| k.verify(manifest, &sig).is_ok()) {
        return Err(EngineError::new("l'aggiornamento non è firmato da OrbitLR: non lo installo"));
    }
    let m: Manifest = serde_json::from_slice(manifest).map_err(|_| EngineError::new("manifesto dell'aggiornamento non valido"))?;
    let name_ok = !m.file.is_empty() && m.file.len() < 120 && m.file.ends_with(".exe") && m.file.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    let hash_ok = m.sha256.len() == 64 && m.sha256.chars().all(|c| c.is_ascii_hexdigit());
    if !name_ok || !hash_ok || m.size == 0 || m.size > MAX_BYTES || version_parts(&m.version).is_none() {
        return Err(EngineError::new("manifesto dell'aggiornamento non valido"));
    }
    Ok(m)
}

fn version_parts(v: &str) -> Option<[u64; 3]> {
    let mut out = [0u64; 3];
    let parts: Vec<&str> = v.split('.').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    for (i, p) in parts.iter().enumerate() {
        out[i] = p.parse().ok()?;
    }
    Some(out)
}

/// Il manifesto è più nuovo della versione che c'è (prima la versione, a parità la build).
pub fn is_newer(m: &Manifest, version: &str, build: u64) -> bool {
    match (version_parts(&m.version), version_parts(version)) {
        (Some(a), Some(b)) if a != b => a > b,
        (Some(_), Some(_)) => m.build > build,
        _ => false,
    }
}

fn agent() -> ureq::Agent {
    let secs = |n| Some(std::time::Duration::from_secs(n));
    ureq::Agent::config_builder()
        .proxy(ureq::Proxy::try_from_env())
        .timeout_connect(secs(15))
        .timeout_recv_response(secs(30))
        .timeout_per_read(secs(60))
        .build()
        .into()
}

fn get_small(ag: &ureq::Agent, url: &str, max: u64) -> Result<Vec<u8>> {
    let mut resp = ag.get(url).call().map_err(|e| EngineError::new(format!("non riesco a controllare gli aggiornamenti: {e}")))?;
    let mut v = Vec::new();
    resp.body_mut().as_reader().take(max).read_to_end(&mut v).map_err(|e| EngineError::new(format!("aggiornamento interrotto: {e}")))?;
    Ok(v)
}

/// Il manifesto firmato più recente (`None` se la pagina non ne ha ancora uno).
pub fn check() -> Result<Option<Manifest>> {
    let ag = agent();
    let m = match get_small(&ag, &format!("{BASE}{MANIFEST}"), 64 * 1024) {
        Ok(m) => m,
        Err(e) if e.0.contains("404") => return Ok(None),
        Err(e) => return Err(e),
    };
    let s = get_small(&ag, &format!("{BASE}{SIGNATURE}"), 1024)?;
    verify(&m, &s).map(Some)
}

/// Scarica l'installatore in `dir`, controllando misura e impronta.
pub fn download(m: &Manifest, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    use sha2::{Digest, Sha256};
    std::fs::create_dir_all(dir)?;
    let dest = dir.join(&m.file);
    let part = dir.join(format!("{}.parziale", m.file));
    let mut resp = agent()
        .get(&format!("{BASE}{}", m.file))
        .call()
        .map_err(|e| EngineError::new(format!("non riesco a scaricare l'aggiornamento: {e}")))?;
    let mut reader = resp.body_mut().as_reader();
    let mut file = std::fs::File::create(&part)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut got = 0u64;
    let r = (|| -> Result<()> {
        loop {
            if cancel.is_cancelled() {
                return Err(EngineError::cancelled());
            }
            let n = reader.read(&mut buf).map_err(|e| EngineError::new(format!("aggiornamento interrotto: {e}")))?;
            if n == 0 {
                break;
            }
            got += n as u64;
            if got > m.size {
                return Err(EngineError::new("l'aggiornamento scaricato non è quello giusto (troppo grande)"));
            }
            file.write_all(&buf[..n])?;
            hasher.update(&buf[..n]);
            progress((got as f64 / m.size as f64).min(0.999));
        }
        file.flush()?;
        let h: String = hasher.finalize_reset().iter().map(|b| format!("{b:02x}")).collect();
        if got != m.size || h != m.sha256.to_lowercase() {
            return Err(EngineError::new("l'aggiornamento scaricato non è quello giusto (impronta diversa): riprova più tardi"));
        }
        Ok(())
    })();
    drop(file);
    if let Err(e) = r {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    let _ = std::fs::remove_file(&dest);
    std::fs::rename(&part, &dest)?;
    progress(1.0);
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn man(v: &str, b: u64) -> Manifest {
        Manifest { version: v.into(), build: b, file: "OrbitLR-Windows-0.2.0-Setup.exe".into(), sha256: "a".repeat(64), size: 1000, notes: String::new() }
    }

    #[test]
    fn firma_valida_e_falsa() {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let body = serde_json::to_vec(&man("0.2.0", 5)).unwrap();
        let sig = sk.sign(&body).to_bytes();
        let ok = verify_with(&body, &sig, &[sk.verifying_key()]).unwrap();
        assert_eq!(ok.version, "0.2.0");
        // Una sola cifra cambiata: rifiutato
        let mut bad = body.clone();
        bad[5] ^= 1;
        assert!(verify_with(&bad, &sig, &[sk.verifying_key()]).is_err());
        // Firmato da un'altra chiave: rifiutato con le chiavi vere
        assert!(verify(&body, &sig).is_err());
    }

    #[test]
    fn nomi_pericolosi_rifiutati() {
        let sk = SigningKey::from_bytes(&[9u8; 32]);
        let mut m = man("0.2.0", 1);
        m.file = "..\\..\\evil.exe".into();
        let body = serde_json::to_vec(&m).unwrap();
        assert!(verify_with(&body, &sk.sign(&body).to_bytes(), &[sk.verifying_key()]).is_err());
    }

    #[test]
    fn piu_nuovo() {
        assert!(is_newer(&man("0.2.0", 1), "0.1.0", 99));
        assert!(is_newer(&man("0.1.0", 12), "0.1.0", 11));
        assert!(!is_newer(&man("0.1.0", 11), "0.1.0", 11));
        assert!(!is_newer(&man("0.1.9", 50), "0.2.0", 1));
        assert!(TRUSTED_KEYS.len() == 2 && keys().len() == 2);
    }
}
