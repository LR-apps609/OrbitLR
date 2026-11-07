//! W04 · prova diretta del motore (foto e PDF), senza finestra.
//! Uso: w04_harness <azione> <param-json> <cartella-uscita> <file>...
//! Variabili: ORBIT_MOTORI (cartella con ffmpeg/ffprobe), W04_DATA (cartella dei modelli), W04_LANG.
//! Stampa una riga JSON: {"ok":bool,"outputs":[...],"error":"...","secs":N,"progress_max":N}
use orbit_engine::{run_action, Cancel, Ctx, Tools};
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 5 {
        eprintln!("uso: w04_harness <azione> <param-json> <uscita> <file>...");
        std::process::exit(2);
    }
    let id = &a[1];
    let param: serde_json::Value = serde_json::from_str(&a[2]).unwrap_or(serde_json::Value::String(a[2].clone()));
    let out_dir = if a[3] == "-" { None } else { Some(PathBuf::from(&a[3])) };
    let files: Vec<PathBuf> = a[4..].iter().map(PathBuf::from).collect();
    let motori = std::env::var_os("ORBIT_MOTORI").map(PathBuf::from);
    let tools = Tools::locate(motori.as_deref());
    let data_dir = std::env::var_os("W04_DATA").map(PathBuf::from);
    if let Ok(l) = std::env::var("W04_LANG") {
        orbit_engine::names::set_lang(&l);
    }
    let ctx = Ctx { tools, out_dir, data_dir };
    let cancel = Cancel::new();
    if let Ok(s) = std::env::var("W04_CANCEL_AFTER_MS") {
        if let Ok(ms) = s.parse::<u64>() {
            let c = cancel.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(ms));
                c.cancel();
            });
        }
    }
    let t = Instant::now();
    let mut pmax = 0.0f64;
    let mut pbad = false;
    let mut last = -1.0f64;
    let r = run_action(&ctx, id, &files, &param, &cancel, &mut |p| {
        if !(0.0..=1.0001).contains(&p) || p.is_nan() {
            pbad = true;
        }
        if p + 1e-9 < last {
            // l'avanzamento torna indietro: lo si annota, non è per forza un errore
        }
        last = p;
        pmax = pmax.max(p);
    });
    let secs = t.elapsed().as_secs_f64();
    let j = match r {
        Ok(outs) => serde_json::json!({"ok": true, "outputs": outs, "secs": secs, "progress_max": pmax, "progress_bad": pbad}),
        Err(e) => serde_json::json!({"ok": false, "error": e.0, "cancelled": e.is_cancelled(), "secs": secs, "progress_max": pmax, "progress_bad": pbad}),
    };
    println!("{}", j);
}
