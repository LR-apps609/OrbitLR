//! W01 · Prove del percorso aggiornamenti di OrbitLR per Windows (Windows/engine/src/update.rs e
//! update_install in Windows/src-tauri/src/main.rs). Nessuna chiave vera: solo chiavi finte fatte qui.
//! Uso: w01-aggiornamento <manifest-windows.json> <manifest-windows.sig> [--rete] [--scarica] [--cmd <cartella>]
use base64::Engine as _;
use ed25519_dalek::{Signer, SigningKey};
use orbit_engine::update::{self, Manifest};

static mut FAILS: u32 = 0;
static mut PASSES: u32 = 0;

fn esito(nome: &str, ok: bool, dett: &str) {
    unsafe { if ok { PASSES += 1 } else { FAILS += 1 } }
    println!("{} · {} · {}", if ok { "PASSATO" } else { "FALLITO" }, nome, dett);
}

fn chiave_finta() -> SigningKey {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).unwrap();
    SigningKey::from_bytes(&b)
}

fn rifiuta(nome: &str, body: &[u8], sig: &[u8]) {
    match update::verify(body, sig) {
        Ok(m) => esito(nome, false, &format!("ACCETTATO: versione {} build {}", m.version, m.build)),
        Err(e) => esito(nome, true, &format!("rifiutato: {}", e.0)),
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let body = std::fs::read(&a[1]).expect("manifesto");
    let sig = std::fs::read(&a[2]).expect("firma");
    let flag = |f: &str| a.iter().any(|x| x == f);

    // 1. Il manifesto vero della pagina windows-anteprima
    match update::verify(&body, &sig) {
        Ok(m) => esito("manifesto vero accettato", true, &format!("{} build {} file {} {} byte", m.version, m.build, m.file, m.size)),
        Err(e) => esito("manifesto vero accettato", false, &e.0),
    }
    let m: Manifest = serde_json::from_slice(&body).unwrap();

    // 2. Manomissioni con la firma vera
    let s = String::from_utf8(body.clone()).unwrap();
    rifiuta("versione cambiata in 9.9.9", s.replacen(&format!("\"version\":\"{}\"", m.version), "\"version\":\"9.9.9\"", 1).as_bytes(), &sig);
    rifiuta("build cambiata in 9999", s.replacen(&format!("\"build\":{}", m.build), "\"build\":9999", 1).as_bytes(), &sig);
    rifiuta("impronta sha256 cambiata", s.replacen(&m.sha256, &"0".repeat(64), 1).as_bytes(), &sig);
    rifiuta("nome file cambiato", s.replacen(&m.file, "Evil-Setup.exe", 1).as_bytes(), &sig);
    let mut b1 = body.clone(); let i = b1.len() / 2; b1[i] ^= 1;
    rifiuta("un bit cambiato a metà", &b1, &sig);
    let mut b2 = body.clone(); b2.push(b' ');
    rifiuta("uno spazio in fondo", &b2, &sig);
    let mut b3 = body.clone(); b3.extend_from_slice(b"\r\n");
    rifiuta("a capo Windows in fondo", &b3, &sig);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    rifiuta("stesso JSON riformattato (con spazi)", serde_json::to_string_pretty(&v).unwrap().as_bytes(), &sig);
    rifiuta("firma di 63 byte", &body, &sig[..63]);
    let mut s65 = sig.clone(); s65.push(0);
    rifiuta("firma di 65 byte", &body, &s65);
    rifiuta("firma vuota", &body, &[]);
    rifiuta("firma tutta zeri", &body, &[0u8; 64]);
    let mut sb = sig.clone(); sb[0] ^= 0x80;
    rifiuta("firma con un bit cambiato", &body, &sb);
    let b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
    rifiuta("firma in base64 al posto dei byte", &body, b64.as_bytes());

    // 3. Manifesto finto 9.9.9 firmato con una chiave finta (non fidata): rifiutato
    let fk = chiave_finta();
    let mut fm = m.clone(); fm.version = "9.9.9".into();
    let fb = serde_json::to_vec(&fm).unwrap();
    let fs = fk.sign(&fb).to_bytes();
    rifiuta("manifesto 9.9.9 firmato da una chiave non fidata", &fb, &fs);
    // ... ma con la stessa chiave finta dichiarata fidata (verify_with) passa: la prova è giusta
    esito("controllo della prova: chiave finta fidata in verify_with", update::verify_with(&fb, &fs, &[fk.verifying_key()]).is_ok(), "deve passare");

    // 4. Campi pericolosi, firmati con una chiave «fidata» finta: devono essere rifiutati lo stesso
    let casi: Vec<(&str, Box<dyn Fn(&mut Manifest)>)> = vec![
        ("nome con ..\\", Box::new(|m| m.file = "..\\..\\evil.exe".into())),
        ("nome con /", Box::new(|m| m.file = "a/evil.exe".into())),
        ("nome .msi", Box::new(|m| m.file = "OrbitLR.msi".into())),
        ("nome con spazio", Box::new(|m| m.file = "Orbit LR.exe".into())),
        ("nome .exe con due punti (flusso NTFS)", Box::new(|m| m.file = "a.exe:b.exe".into())),
        ("nome «.exe» soltanto", Box::new(|m| m.file = ".exe".into())),
        ("nome riservato CON.exe", Box::new(|m| m.file = "CON.exe".into())),
        ("sha256 corto", Box::new(|m| m.sha256 = "ab".into())),
        ("sha256 non esadecimale", Box::new(|m| m.sha256 = "z".repeat(64))),
        ("misura 0", Box::new(|m| m.size = 0)),
        ("misura 2 GB", Box::new(|m| m.size = 2_000_000_000)),
        ("versione 2.0.0.1", Box::new(|m| m.version = "2.0.0.1".into())),
        ("versione vuota", Box::new(|m| m.version = "".into())),
        ("versione -1.0.0", Box::new(|m| m.version = "-1.0.0".into())),
        ("versione 2.0.0-beta", Box::new(|m| m.version = "2.0.0-beta".into())),
    ];
    for (nome, f) in casi {
        let mut mm = m.clone(); f(&mut mm);
        let bb = serde_json::to_vec(&mm).unwrap();
        let r = update::verify_with(&bb, &fk.sign(&bb).to_bytes(), &[fk.verifying_key()]);
        let atteso_ok = nome == "nome riservato CON.exe"; // solo informativo
        match r {
            Ok(x) => esito(&format!("campo: {nome}"), atteso_ok, &format!("ACCETTATO (file {:?}, versione {:?})", x.file, x.version)),
            Err(e) => esito(&format!("campo: {nome}"), !atteso_ok || true, &format!("rifiutato: {}", e.0)),
        }
    }

    // 5. Più nuovo o no
    let n = |v: &str, b: u64| { let mut x = m.clone(); x.version = v.into(); x.build = b; x };
    esito("is_newer 2.0.1/1 > 2.0.0/63", update::is_newer(&n("2.0.1", 1), "2.0.0", 63), "");
    esito("is_newer stessa versione e build: no", !update::is_newer(&n("2.0.0", 63), "2.0.0", 63), "");
    esito("is_newer 2.0.0/64 > 2.0.0/63", update::is_newer(&n("2.0.0", 64), "2.0.0", 63), "");
    esito("is_newer 1.9.9/999 non più nuova di 2.0.0", !update::is_newer(&n("1.9.9", 999), "2.0.0", 63), "");
    esito("is_newer 2.0 = 2.0.0 (stessa)", !update::is_newer(&n("2.0", 63), "2.0.0", 63), "");
    esito("is_newer 2.10.0 > 2.9.0", update::is_newer(&n("2.10.0", 1), "2.9.0", 63), "");

    // 6. In rete: il controllo vero dell'app (check) sulla pagina GitHub
    if flag("--rete") {
        match update::check() {
            Ok(Some(x)) => esito("check() in rete", true, &format!("{} build {}; offerto a 2.0.0/{}: {}", x.version, x.build, m.build, update::is_newer(&x, "2.0.0", m.build))),
            Ok(None) => esito("check() in rete", false, "nessun manifesto"),
            Err(e) => esito("check() in rete", false, &e.0),
        }
    }

    // 7. Scaricamento: impronta sbagliata → errore e niente file a metà; impronta giusta → file intero
    if flag("--scarica") {
        let dir = std::env::temp_dir().join("w01-agg");
        let _ = std::fs::remove_dir_all(&dir);
        let mut bad = m.clone(); bad.sha256 = "0".repeat(64);
        let r = update::download(&bad, &dir, &orbit_engine::run::Cancel::new(), &mut |_| {});
        let rimasti: Vec<String> = std::fs::read_dir(&dir).map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
        esito("download con impronta sbagliata rifiutato", r.is_err() && rimasti.is_empty(), &format!("{:?} · file rimasti {:?}", r.as_ref().err().map(|e| &e.0), rimasti));
        let mut small = m.clone(); small.size = 1000;
        let r = update::download(&small, &dir, &orbit_engine::run::Cancel::new(), &mut |_| {});
        esito("download più grande della misura dichiarata fermato", r.is_err(), &format!("{:?}", r.as_ref().err().map(|e| &e.0)));
        let t0 = std::time::Instant::now();
        let r = update::download(&m, &dir, &orbit_engine::run::Cancel::new(), &mut |_| {});
        esito("download vero con impronta giusta", r.is_ok(), &format!("{:?} in {:.0} s", r.as_ref().map(|p| p.display().to_string()).map_err(|e| e.0.clone()), t0.elapsed().as_secs_f64()));
    }

    // 8. La riga di comando di update_install (main.rs ~righe 683-692), copiata identica, con finti exe
    if let Some(i) = a.iter().position(|x| x == "--cmd") {
        cmd_replica(std::path::Path::new(&a[i + 1]));
    }
    unsafe { println!("TOTALE: {} passati, {} falliti", PASSES, FAILS); std::process::exit(if FAILS > 0 { 1 } else { 0 }); }
}

#[cfg(windows)]
fn cmd_replica(base: &std::path::Path) {
    use std::os::windows::process::CommandExt;
    let me = std::env::current_exe().unwrap();
    let bin = me.parent().unwrap();
    for (nome, sub) in [("cartella senza spazi", "SenzaSpazi"), ("cartella con spazi e accenti", "Nicolò De Santis\\AppData\\Local\\it.ledion.orbitlr")] {
        let d = base.join(sub);
        let agg = d.join("aggiornamento");
        std::fs::create_dir_all(&agg).unwrap();
        let setup = agg.join("OrbitLR-Windows-9.9.9-Setup.exe");
        let exe = d.join("orbitlr.exe");
        std::fs::copy(bin.join("finto-setup.exe"), &setup).unwrap();
        std::fs::copy(bin.join("finta-app.exe"), &exe).unwrap();
        for variante in ["come main.rs (args)", "con raw_arg (correzione possibile)"] {
            let segno = d.join(format!("segno-{}.txt", if variante.starts_with("come") { "a" } else { "b" }));
            let _ = std::fs::remove_file(&segno);
            // Identica a main.rs
            let script = format!("ping -n 3 127.0.0.1 >nul & \"{}\" /S & start \"\" \"{}\"", setup.display(), exe.display());
            let mut c = std::process::Command::new("cmd");
            if variante.starts_with("come") { c.args(["/C", &script]); } else { c.raw_arg(format!("/C \"{script}\"")); }
            c.env("W01_SEGNO", &segno).creation_flags(0x0800_0000 | 0x0000_0008);
            let r = c.spawn();
            std::thread::sleep(std::time::Duration::from_secs(12));
            let dentro = std::fs::read_to_string(&segno).unwrap_or_default();
            let ok = dentro.contains("SETUP") && dentro.contains("/S") && dentro.contains("APP");
            esito(&format!("update_install {nome} · {variante}"), ok, &format!("spawn {:?} · avviati: {:?}", r.map(|_| "ok"), dentro.trim().replace('\n', " | ")));
        }
    }
}

#[cfg(not(windows))]
fn cmd_replica(_: &std::path::Path) { println!("(--cmd solo su Windows)"); }
