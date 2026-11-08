//! 2.0.1 · Il passaggio all'installatore gira davvero con cmd.exe (solo su Windows, nella compilazione automatica):
//! al posto dell'installatore e di OrbitLR due file .cmd innocui, in una cartella con spazi e lettere non latine.
#![cfg(windows)]

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("orbit aggiornamento {name} Привет 你好 {}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Un .cmd che scrive i suoi argomenti in `segno` e poi esce con `code` (finto installatore, chiamato e atteso).
fn script(at: &Path, segno: &str, code: i32) -> PathBuf {
    std::fs::write(at, format!("@echo off\r\necho %* > \"%~dp0{segno}\"\r\nexit /b {code}\r\n")).unwrap();
    at.to_path_buf()
}

/// Finta OrbitLR, aperta con «start»: deve chiudere del tutto la sua finestra di cmd (`exit`, non `exit /b`),
/// altrimenti resta un cmd aperto per sempre e la prova automatica non finisce.
fn finta_app(at: &Path, segno: &str) -> PathBuf {
    std::fs::write(at, format!("@echo off\r\necho %* > \"%~dp0{segno}\"\r\nexit\r\n")).unwrap();
    at.to_path_buf()
}

fn wait_for(p: &Path, secs: u64) -> Option<String> {
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(secs) {
        if let Ok(s) = std::fs::read_to_string(p) {
            if !s.trim().is_empty() {
                return Some(s);
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

#[test]
fn installatore_riuscito_poi_orbitlr_si_riapre() {
    let d = dir("ok");
    let setup = script(&d.join("OrbitLR Setup.cmd"), "installato.txt", 0);
    let exe = finta_app(&d.join("orbitlr finta.cmd"), "riaperta.txt");
    let st = orbit_engine::update::handoff(&setup, &exe, 0).status().unwrap();
    assert!(st.success(), "cmd: {st:?}");
    assert!(wait_for(&d.join("installato.txt"), 20).expect("l'installatore non è partito").contains("/S"));
    let args = wait_for(&d.join("riaperta.txt"), 20).expect("OrbitLR non si è riaperta");
    assert!(!args.contains(orbit_engine::update::FAILED_ARG), "{args}");
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn installatore_non_riuscito_orbitlr_si_riapre_e_lo_dice() {
    let d = dir("errore");
    let setup = script(&d.join("OrbitLR Setup.cmd"), "installato.txt", 2);
    let exe = finta_app(&d.join("orbitlr finta.cmd"), "riaperta.txt");
    let _ = orbit_engine::update::handoff(&setup, &exe, 0).status().unwrap();
    assert!(wait_for(&d.join("installato.txt"), 20).is_some(), "l'installatore non è partito");
    let args = wait_for(&d.join("riaperta.txt"), 20).expect("OrbitLR non si è riaperta");
    assert!(args.contains(orbit_engine::update::FAILED_ARG), "{args}");
    let _ = std::fs::remove_dir_all(&d);
}
