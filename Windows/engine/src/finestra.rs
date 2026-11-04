//! 2.0.1 · La finestra di OrbitLR entra sempre nello schermo, sopra la barra delle applicazioni.
//! Prima si apriva sempre a 1200×800: su un portatile 1920×1080 al 125% o 150%, o su 2560×1440 al 175% o 200%,
//! il fondo (Opzioni, Aiuto, Segnala) finiva sotto la barra e la barra del titolo poteva uscire in alto.
//! Tutte le misure sono in pixel logici (già divisi per la scala di Windows).

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fit {
    pub width: f64,
    pub height: f64,
    pub min_width: f64,
    pub min_height: f64,
}

/// La misura dell'interno della finestra: quella voluta (`want`), ridotta all'area utile dello schermo
/// (`work`, senza barra delle applicazioni) meno bordi e barra del titolo (`deco`). Mai sotto il minimo (`min`),
/// a meno che l'area utile sia più piccola del minimo: allora anche il minimo scende, così la finestra entra.
pub fn fit(want: (f64, f64), min: (f64, f64), work: (f64, f64), deco: (f64, f64)) -> Fit {
    let room_w = (work.0 - deco.0).max(200.0);
    let room_h = (work.1 - deco.1).max(200.0);
    let min_width = min.0.min(room_w);
    let min_height = min.1.min(room_h);
    Fit { width: want.0.min(room_w).max(min_width), height: want.1.min(room_h).max(min_height), min_width, min_height }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Windows 11: barra delle applicazioni 48, barra del titolo e bordi della finestra di Tauri circa 16×39.
    const TASKBAR: f64 = 48.0;
    const DECO: (f64, f64) = (16.0, 39.0);
    const SCHERMI: &[(f64, f64, f64)] = &[
        (1920.0, 1080.0, 1.0),
        (1920.0, 1080.0, 1.25),
        (1920.0, 1080.0, 1.5),
        (1920.0, 1080.0, 1.75),
        (1366.0, 768.0, 1.0),
        (1366.0, 768.0, 1.25),
        (2560.0, 1440.0, 1.0),
        (2560.0, 1440.0, 1.25),
        (2560.0, 1440.0, 1.5),
        (2560.0, 1440.0, 1.75),
        (2560.0, 1440.0, 2.0),
        (3840.0, 2160.0, 2.5),
    ];

    fn conf() -> serde_json::Value {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../src-tauri/tauri.conf.json");
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    #[test]
    fn la_finestra_entra_in_ogni_schermo() {
        let c = conf();
        let w = &c["app"]["windows"][0];
        let want = (w["width"].as_f64().unwrap(), w["height"].as_f64().unwrap());
        let min = (w["minWidth"].as_f64().unwrap(), w["minHeight"].as_f64().unwrap());
        // Tauri riduce la finestra all'area utile già quando la crea (niente salto visibile all'avvio)
        assert_eq!(w["preventOverflow"].as_bool(), Some(true), "manca preventOverflow nella finestra principale");
        for &(sw, sh, s) in SCHERMI {
            let work = (sw / s, sh / s - TASKBAR);
            let f = fit(want, min, work, DECO);
            assert!(f.width + DECO.0 <= work.0 + 0.5 && f.height + DECO.1 <= work.1 + 0.5, "{sw}×{sh} al {}%: {f:?} non entra in {work:?}", s * 100.0);
            // Mai più piccola del minimo, se lo schermo ha posto
            if work.0 - DECO.0 >= min.0 && work.1 - DECO.1 >= min.1 {
                assert!(f.width >= min.0 && f.height >= min.1, "{sw}×{sh} al {}%: {f:?} sotto il minimo", s * 100.0);
                assert_eq!((f.min_width, f.min_height), min);
            }
        }
    }

    #[test]
    fn schermo_grande_misura_voluta() {
        let f = fit((1200.0, 800.0), (940.0, 620.0), (2560.0, 1392.0), DECO);
        assert_eq!(f, Fit { width: 1200.0, height: 800.0, min_width: 940.0, min_height: 620.0 });
    }

    #[test]
    fn schermo_2560_al_175() {
        // 2560×1440 al 175%: area utile 1463×775 → interno alto 736, largo 1200
        let f = fit((1200.0, 800.0), (940.0, 620.0), (2560.0 / 1.75, 1440.0 / 1.75 - 48.0), DECO);
        assert_eq!(f.width, 1200.0);
        assert!((f.height - (1440.0 / 1.75 - 48.0 - 39.0)).abs() < 0.01, "{f:?}");
    }

    #[test]
    fn schermo_piu_piccolo_del_minimo() {
        // 1920×1080 al 175%: area utile 1097×569, meno del minimo 620 in altezza
        let f = fit((1200.0, 800.0), (940.0, 620.0), (1920.0 / 1.75, 1080.0 / 1.75 - 48.0), DECO);
        assert!(f.height + 39.0 <= 1080.0 / 1.75 - 48.0 + 0.01 && f.min_height < 620.0, "{f:?}");
        assert_eq!(f.min_width, 940.0);
    }
}
