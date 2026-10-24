//! Cartelle automatiche: OrbitLR guarda alcune cartelle e lavora da sola i file nuovi che ci arrivano
//! (le foto HEIC scaricate diventano JPG, i video in «Da comprimere» si alleggeriscono…).
//!
//! Solo i file arrivati DOPO l'attivazione: quelli già presenti non si toccano. Un file si lavora quando
//! smette di crescere (due controlli di fila con lo stesso peso e la stessa data), così un download
//! o una copia a metà non viene mai preso.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Rule {
    pub id: String,
    /// "foto", "video" o "pdf"
    pub kind: String,
    pub path: PathBuf,
    /// L'opzione dell'azione (per i video il peso: "best", "15"…; per i PDF il livello)
    #[serde(default)]
    pub param: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn yes() -> bool {
    true
}

/// Cosa fa ogni tipo di cartella.
pub struct Preset {
    pub name: &'static str,
    pub exts: &'static [&'static str],
    pub action: &'static str,
    pub default_param: &'static str,
    /// Dove vanno i risultati: una sottocartella (che non viene guardata), o None = accanto all'originale
    pub subfolder: Option<&'static str>,
}

pub fn preset(kind: &str) -> Option<Preset> {
    Some(match kind {
        "foto" => Preset { name: "Foto in JPG", exts: &["heic", "heif", "webp", "avif"], action: "to:jpg", default_param: "", subfolder: None },
        "video" => Preset { name: "Comprimi i video", exts: &["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv"], action: "vcompress", default_param: "best", subfolder: Some("Compressi") },
        "pdf" => Preset { name: "Comprimi i PDF", exts: &["pdf"], action: "pdfcompress", default_param: "medium", subfolder: Some("Compressi") },
        _ => return None,
    })
}

impl Rule {
    /// Il parametro da dare all'azione (controllato: solo valori conosciuti).
    pub fn action_param(&self) -> Value {
        let p = self.param.as_str();
        let ok = match self.kind.as_str() {
            "video" => ["best", "9", "15", "18", "50", "100"].contains(&p),
            "pdf" => ["light", "medium", "strong"].contains(&p),
            _ => false,
        };
        match preset(&self.kind) {
            Some(pr) if !pr.default_param.is_empty() => Value::String(if ok { p.to_string() } else { pr.default_param.to_string() }),
            _ => Value::Null,
        }
    }

    /// Dove mettere i risultati.
    pub fn out_dir(&self) -> Option<PathBuf> {
        preset(&self.kind).and_then(|p| p.subfolder).map(|s| self.path.join(s))
    }
}

/// Le regole salvate: si scartano quelle non valide (tipo sconosciuto, percorso non assoluto).
pub fn load(file: &Path) -> Vec<Rule> {
    let Ok(text) = std::fs::read_to_string(file) else { return vec![] };
    let rules: Vec<Rule> = serde_json::from_str(&text).unwrap_or_default();
    sanitize(rules)
}

pub fn sanitize(rules: Vec<Rule>) -> Vec<Rule> {
    let mut seen = std::collections::HashSet::new();
    rules
        .into_iter()
        .filter(|r| preset(&r.kind).is_some() && r.path.is_absolute() && !r.id.is_empty() && r.id.len() <= 40)
        .filter(|r| seen.insert(r.id.clone()))
        .take(20)
        .collect()
}

pub fn save(file: &Path, rules: &[Rule]) -> std::io::Result<()> {
    if let Some(d) = file.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = file.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(rules).unwrap_or_default())?;
    std::fs::rename(tmp, file)
}

type Sig = (u64, Option<SystemTime>);

#[derive(Default)]
struct RuleState {
    path: PathBuf,
    kind: String,
    known: HashMap<PathBuf, Sig>,
    pending: HashMap<PathBuf, Sig>,
}

/// Ricorda cosa c'era nelle cartelle a ogni controllo.
#[derive(Default)]
pub struct Watcher {
    states: HashMap<String, RuleState>,
}

fn listing(dir: &Path, exts: &[&str]) -> HashMap<PathBuf, Sig> {
    let mut out = HashMap::new();
    let Ok(rd) = std::fs::read_dir(dir) else { return out };
    for e in rd.flatten().take(20_000) {
        let name = e.file_name().to_string_lossy().to_string();
        // Nascosti, file temporanei di Office e i file a metà di OrbitLR
        if name.starts_with('.') || name.starts_with("~$") || name.contains(".orbitlr-") {
            continue;
        }
        let Ok(md) = e.metadata() else { continue };
        if !md.is_file() {
            continue;
        }
        let ext = crate::names::ext(&e.path());
        if !exts.contains(&ext.as_str()) {
            continue;
        }
        out.insert(e.path(), (md.len(), md.modified().ok()));
    }
    out
}

impl Watcher {
    /// Un controllo: restituisce i file nuovi e pronti, con la regola che li prende.
    pub fn scan(&mut self, rules: &[Rule]) -> Vec<(Rule, PathBuf)> {
        let mut ready = Vec::new();
        self.states.retain(|id, _| rules.iter().any(|r| &r.id == id && r.enabled));
        for r in rules.iter().filter(|r| r.enabled) {
            let Some(p) = preset(&r.kind) else { continue };
            let now = listing(&r.path, p.exts);
            let st = self.states.entry(r.id.clone()).or_default();
            if st.path != r.path || st.kind != r.kind {
                // Regola nuova (o cambiata): quello che c'è già non si tocca
                *st = RuleState { path: r.path.clone(), kind: r.kind.clone(), known: now, pending: HashMap::new() };
                continue;
            }
            st.known.retain(|f, _| now.contains_key(f));
            st.pending.retain(|f, _| now.contains_key(f));
            let mut files: Vec<_> = now.into_iter().collect();
            files.sort_by(|a, b| a.0.cmp(&b.0));
            for (f, sig) in files {
                if st.known.get(&f) == Some(&sig) {
                    continue;
                }
                if sig.0 > 0 && st.pending.get(&f) == Some(&sig) {
                    st.pending.remove(&f);
                    st.known.insert(f.clone(), sig);
                    ready.push((r.clone(), f));
                } else {
                    st.pending.insert(f, sig);
                }
            }
        }
        ready
    }

    /// Un file creato da OrbitLR stessa dentro una cartella guardata: non va ripreso.
    pub fn mark_known(&mut self, file: &Path) {
        let Ok(md) = std::fs::metadata(file) else { return };
        for st in self.states.values_mut() {
            if file.parent() == Some(st.path.as_path()) {
                st.known.insert(file.to_path_buf(), (md.len(), md.modified().ok()));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("orbit-watch-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn rule(kind: &str, path: &Path) -> Rule {
        Rule { id: format!("r{kind}"), kind: kind.into(), path: path.into(), param: String::new(), enabled: true }
    }

    #[test]
    fn solo_i_file_nuovi_e_finiti() {
        let d = dir("foto");
        std::fs::write(d.join("vecchia.heic"), b"gia qui").unwrap();
        let rules = vec![rule("foto", &d)];
        let mut w = Watcher::default();
        assert!(w.scan(&rules).is_empty(), "il primo controllo prende solo nota");
        assert!(w.scan(&rules).is_empty(), "i file già presenti non si toccano");

        std::fs::write(d.join("nuova.heic"), b"arrivata").unwrap();
        std::fs::write(d.join("nota.txt"), b"altro tipo").unwrap();
        std::fs::write(d.join(".orbitlr-1-2.heic"), b"a meta").unwrap();
        std::fs::write(d.join("vuota.webp"), b"").unwrap();
        assert!(w.scan(&rules).is_empty(), "appena arrivata: si aspetta che smetta di crescere");
        let got = w.scan(&rules);
        assert_eq!(got.len(), 1, "{got:?}");
        assert!(got[0].1.ends_with("nuova.heic"));
        assert!(w.scan(&rules).is_empty(), "una volta sola");

        // Un file che sta ancora crescendo aspetta
        std::fs::write(d.join("download.webp"), b"12").unwrap();
        assert!(w.scan(&rules).is_empty());
        std::fs::write(d.join("download.webp"), b"1234").unwrap();
        assert!(w.scan(&rules).is_empty(), "è cresciuto: si aspetta ancora");
        assert_eq!(w.scan(&rules).len(), 1);

        // Spenta la regola e riaccesa: si riparte da zero, senza riprendere niente
        let mut off = rules.clone();
        off[0].enabled = false;
        assert!(w.scan(&off).is_empty());
        assert!(w.scan(&rules).is_empty());
        assert!(w.scan(&rules).is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn regole_controllate() {
        let base = std::env::temp_dir();
        let mut v = rule("video", &base);
        assert_eq!(v.action_param(), Value::String("best".into()));
        v.param = "15".into();
        assert_eq!(v.action_param(), Value::String("15".into()));
        v.param = "../../x".into();
        assert_eq!(v.action_param(), Value::String("best".into()), "valori sconosciuti → quello normale");
        assert_eq!(v.out_dir(), Some(base.join("Compressi")));
        assert_eq!(rule("foto", &base).out_dir(), None);
        let bad = vec![rule("boh", &base), Rule { path: "relativo".into(), ..rule("pdf", &base) }, rule("pdf", &base), rule("pdf", &base)];
        let ok = sanitize(bad);
        assert_eq!(ok.len(), 1, "solo una regola valida, senza doppioni");

        let d = dir("salva");
        let f = d.join("cartelle.json");
        save(&f, &ok).unwrap();
        assert_eq!(load(&f), ok);
        let _ = std::fs::remove_dir_all(&d);
    }
}
