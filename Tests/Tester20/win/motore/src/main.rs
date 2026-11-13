//! Tester20 · Windows · il motore vero di OrbitLR chiamato come lo chiama l'app (Windows/src-tauri/src/main.rs),
//! per le parti che senza clic nella finestra non si raggiungono: aggiornamento (scarica, «Interrompi», «Riprova»,
//! passaggio all'installatore), «Al telefono» (server di condivisione), lavori con il messaggio d'errore esatto,
//! scaricamento da link. Ogni risultato è una riga `T20|{json}`.
use orbit_engine::{run_action, update, Cancel, Ctx, Tools};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Instant;

fn out(v: Value) {
    println!("T20|{}", v);
}

fn files_in(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir).map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default()
}

fn sha256(p: &Path) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    use std::io::Read;
    let mut f = std::fs::File::open(p).unwrap();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).unwrap_or(0);
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let cmd = a.get(1).map(String::as_str).unwrap_or("");
    match cmd {
        // Il controllo dell'aggiornamento (update_check)
        "controlla" => {
            let t0 = Instant::now();
            let r = update::check();
            out(json!({"passo": "controlla", "ok": r.is_ok(), "secondi": t0.elapsed().as_secs_f64(),
                "versione": r.as_ref().ok().and_then(|m| m.as_ref().map(|m| format!("{} build {}", m.version, m.build))),
                "errore": r.as_ref().err().map(|e| e.0.clone())}));
        }
        // Scarica l'aggiornamento come update_install: «Interrompi» al 20%, poi «Riprova» fino in fondo
        "aggiorna" => {
            let dir = PathBuf::from(&a[2]);
            let _ = std::fs::remove_dir_all(&dir);
            let t0 = Instant::now();
            let m = match update::check() {
                Ok(Some(m)) => m,
                other => {
                    out(json!({"passo": "controlla", "ok": false, "errore": format!("{:?}", other.err().map(|e| e.0))}));
                    return;
                }
            };
            out(json!({"passo": "controlla", "ok": true, "secondi": t0.elapsed().as_secs_f64(), "versione": m.version, "build": m.build, "file": m.file, "misura": m.size}));
            out(json!({"passo": "offerta a una versione più vecchia (2.0.0)", "ok": update::is_newer(&m, "2.0.0", 1)}));
            out(json!({"passo": "non offerta a sé stessa", "ok": !update::is_newer(&m, &m.version, m.build)}));
            // «Interrompi» al 20%
            let cancel = Cancel::new();
            let c2 = cancel.clone();
            let mut seen = 0.0f64;
            let t1 = Instant::now();
            let r = update::download(&m, &dir, &cancel, &mut |p| {
                seen = p;
                if p >= 0.2 {
                    c2.cancel();
                }
            });
            let left = files_in(&dir);
            out(json!({"passo": "interrompi", "ok": r.as_ref().err().map(|e| e.is_cancelled()).unwrap_or(false) && left.is_empty(),
                "fermato_a": seen, "secondi": t1.elapsed().as_secs_f64(), "errore": r.as_ref().err().map(|e| e.0.clone()), "file_rimasti": left}));
            // «Riprova»
            let t2 = Instant::now();
            let r = update::download(&m, &dir, &Cancel::new(), &mut |_| {});
            match r {
                Ok(p) => {
                    let h = sha256(&p);
                    let size = std::fs::metadata(&p).map(|x| x.len()).unwrap_or(0);
                    out(json!({"passo": "riprova", "ok": h == m.sha256.to_lowercase() && size == m.size, "secondi": t2.elapsed().as_secs_f64(), "file": p.display().to_string(), "sha256": h, "misura": size, "file_nella_cartella": files_in(&dir)}));
                }
                Err(e) => out(json!({"passo": "riprova", "ok": false, "errore": e.0})),
            }
        }
        // Il passaggio all'installatore (update_install, dopo lo scaricamento): cmd aspetta, installa /S, riapre OrbitLR
        "passaggio" => {
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let r = update::handoff(Path::new(&a[2]), Path::new(&a[3]), 2).creation_flags(0x0800_0000 | 0x0000_0008).spawn();
                out(json!({"passo": "passaggio", "ok": r.is_ok(), "riga": update::handoff_script(Path::new(&a[2]), Path::new(&a[3]), 2), "errore": r.err().map(|e| e.to_string())}));
            }
        }
        // «Al telefono»: il server di condivisione per un file (phone_share), acceso per N secondi
        "condividi" => {
            let secs: u64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(120);
            match orbit_engine::phone::share(Path::new(&a[2]), false) {
                Ok(s) => {
                    out(json!({"passo": "condividi", "ok": true, "url": s.url, "svg_byte": s.svg.len()}));
                    use std::io::Write;
                    let _ = std::io::stdout().flush();
                    std::thread::sleep(std::time::Duration::from_secs(secs));
                    s.stop();
                }
                Err(e) => out(json!({"passo": "condividi", "ok": false, "errore": e.0})),
            }
        }
        // Un lavoro come start_job: lavoro <azione> <parametro json> <motori> <dati> <file...>
        "lavoro" => {
            let action = &a[2];
            let param: Value = serde_json::from_str(&a[3]).unwrap_or(Value::Null);
            let ctx = Ctx { tools: Tools::locate(Some(Path::new(&a[4]))), out_dir: None, data_dir: Some(PathBuf::from(&a[5])) };
            let files: Vec<PathBuf> = a[6..].iter().map(PathBuf::from).collect();
            let t0 = Instant::now();
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_action(&ctx, action, &files, &param, &Cancel::new(), &mut |_| {})));
            match r {
                Ok(Ok(o)) => out(json!({"passo": "lavoro", "azione": action, "ok": true, "secondi": t0.elapsed().as_secs_f64(), "uscite": o})),
                Ok(Err(e)) => out(json!({"passo": "lavoro", "azione": action, "ok": false, "secondi": t0.elapsed().as_secs_f64(), "errore": e.0})),
                Err(_) => out(json!({"passo": "lavoro", "azione": action, "ok": false, "secondi": t0.elapsed().as_secs_f64(), "errore": "PANICO nel motore"})),
            }
        }
        // Audio/Video Downloader come start_job("link"): link <url> <dati> <cartella> <motori>
        "link" => {
            let data = PathBuf::from(&a[3]);
            let dir = PathBuf::from(&a[4]);
            let tools = Tools::locate(Some(Path::new(&a[5])));
            let cancel = Cancel::new();
            let t0 = Instant::now();
            let r = orbit_engine::linkdl::ensure(&data, false, &cancel, &mut |_| {}).and_then(|exe| {
                orbit_engine::linkdl::download(&exe, tools.as_ref(), &a[2], orbit_engine::linkdl::Mode::parse("audio"), &dir, &cancel, &mut |_| {})
            });
            out(json!({"passo": "link", "ok": r.is_ok(), "secondi": t0.elapsed().as_secs_f64(), "file": r.as_ref().ok().map(|p| p.display().to_string()), "errore": r.as_ref().err().map(|e| e.0.clone()), "dati": files_in(&data)}));
        }
        _ => {
            eprintln!("uso: t20-motore controlla | aggiorna <cartella> | passaggio <setup> <exe> | condividi <file> [secondi] | lavoro <azione> <param> <motori> <dati> <file...> | link <url> <dati> <cartella> <motori>");
            std::process::exit(2);
        }
    }
}
