//! orbit-vector: la stessa vettorializzazione di OrbitLR per Windows, da riga di comando (la usa l'app per Mac).
//! uso: orbit-vector <immagine> <uscita.svg> [--mode auto|logo|bw|photo] [--detail 1|2|3] [--transparent] [--upscaled <immagine 4×>]
//!      orbit-vector <immagine> <uscita.zip> --pack [--name <nome>] [--root <cartella>] [--en]: il pacchetto logo
//! Sul canale d'errore scrive «PROGRESS 0.42» mentre lavora; alla fine stampa una riga JSON con il riassunto.

use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut pos = vec![];
    let mut o = vettore::Opts::default();
    let mut up: Option<String> = None;
    // «Pacchetto logo»: l'uscita è uno ZIP (SVG, PDF, EPS, PNG, un colore, icone)
    let mut pack = false;
    let mut name: Option<String> = None;
    let mut root: Option<String> = None;
    let mut en = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--mode" => {
                i += 1;
                o.mode = vettore::Mode::parse(args.get(i).map(|s| s.as_str()).unwrap_or("auto"));
            }
            "--detail" => {
                i += 1;
                o.detail = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(2);
            }
            "--transparent" => o.transparent = true,
            "--flat" => o.gradients = false,
            "--precise" => o.precise = true,
            "--extreme" => {
                o.precise = true;
                o.extreme = true;
            }
            "--seconds" => {
                i += 1;
                o.extreme_secs = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(300);
            }
            "--threads" => {
                i += 1;
                o.threads = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(0);
            }
            "--pack" => pack = true,
            "--en" => en = true,
            "--name" => {
                i += 1;
                name = args.get(i).cloned();
            }
            "--root" => {
                i += 1;
                root = args.get(i).cloned();
            }
            "--upscaled" => {
                i += 1;
                up = args.get(i).cloned();
            }
            a => pos.push(a.to_string()),
        }
        i += 1;
    }
    if pos.len() != 2 {
        eprintln!("uso: orbit-vector <immagine> <uscita.svg> [--mode auto|logo|bw|photo] [--detail 1|2|3] [--transparent] [--upscaled <immagine>]");
        std::process::exit(2);
    }
    if pack {
        // un logo: senza sfondo e con il ricalco di precisione (le foto restano come sono)
        o.precise = true;
        if o.mode != vettore::Mode::Photo {
            o.transparent = true;
        }
    }
    let img = match image::open(&pos[0]) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("ERROR non riesco ad aprire l'immagine: {e}");
            std::process::exit(1);
        }
    };
    let upimg = up.and_then(|p| image::open(p).ok());
    let mut last = -1.0;
    let res = vettore::vectorize(&img, upimg.as_ref(), &o, &mut |p| {
        if p - last >= 0.02 || p >= 1.0 {
            last = p;
            eprintln!("PROGRESS {p:.3}");
        }
    }, &|| false);
    match res {
        Ok(out) => {
            let data = if pack {
                let stem = name.clone().unwrap_or_else(|| std::path::Path::new(&pos[0]).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "logo".into()));
                let r = root.clone().unwrap_or_else(|| stem.clone());
                out.pack_zip(&stem, &r, en)
            } else {
                out.svg.clone().into_bytes()
            };
            if let Err(e) = std::fs::write(&pos[1], &data) {
                eprintln!("ERROR non riesco a salvare: {e}");
                std::process::exit(1);
            }
            let _ = writeln!(std::io::stdout(), "{{\"mode\":\"{}\",\"colors\":{},\"shapes\":{}}}", out.mode.name(), out.colors, out.shapes);
        }
        Err(e) => {
            eprintln!("ERROR {e}");
            std::process::exit(1);
        }
    }
}
