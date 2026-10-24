//! Prove vere: file creati al momento con ffmpeg, lavorati dal motore, controllati con ffprobe.
//! Girano su Linux (qui) e su Windows (GitHub), con l'ffmpeg che si trova.

use orbit_engine::{probe, run_action, Cancel, Ctx, Tools};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn tools() -> Tools {
    static T: OnceLock<Tools> = OnceLock::new();
    T.get_or_init(|| {
        let dir = std::env::var_os("ORBIT_MOTORI").map(PathBuf::from);
        Tools::locate(dir.as_deref()).expect("serve ffmpeg per le prove")
    })
    .clone()
}

fn work() -> PathBuf {
    static D: OnceLock<PathBuf> = OnceLock::new();
    D.get_or_init(|| {
        let d = std::env::temp_dir().join(format!("orbit-prove-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    })
    .clone()
}

fn ff(args: &[&str]) {
    let st = tools().ffmpeg_cmd().args(["-hide_banner", "-loglevel", "error", "-y"]).args(args).status().unwrap();
    assert!(st.success(), "ffmpeg {:?}", args);
}

/// Video di prova con movimento e un tono (il rumore lo rende difficile da comprimere, come i video veri).
static FIXTURES: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn fixture_video(name: &str, w: u32, h: u32, secs: u32, audio: bool) -> PathBuf {
    let _g = FIXTURES.lock().unwrap_or_else(|e| e.into_inner());
    let p = work().join(name);
    if p.exists() {
        return p;
    }
    let tmp = work().join(format!("tmp-{name}"));
    let src = format!("testsrc2=size={w}x{h}:rate=30:duration={secs},noise=alls=12:allf=t");
    let tone = format!("sine=frequency=440:duration={secs}");
    let enc: Vec<String> = orbit_engine::video::encoder_args(&orbit_engine::video::candidates(&tools(), orbit_engine::video::Codec::H264)[0], 6_000_000)
        .into_iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    let mut a: Vec<String> = vec!["-f".into(), "lavfi".into(), "-i".into(), src];
    if audio {
        a.extend(["-f".into(), "lavfi".into(), "-i".into(), tone]);
    }
    a.extend(enc);
    if audio {
        a.extend(["-c:a".into(), "aac".into(), "-b:a".into(), "192k".into(), "-shortest".into()]);
    }
    a.push(tmp.to_string_lossy().to_string());
    let r: Vec<&str> = a.iter().map(String::as_str).collect();
    ff(&r);
    std::fs::rename(&tmp, &p).unwrap();
    p
}

fn fixture_audio(name: &str) -> PathBuf {
    let _g = FIXTURES.lock().unwrap_or_else(|e| e.into_inner());
    let p = work().join(name);
    if !p.exists() {
        // 2 s di tono, 2 s di silenzio, 2 s di tono
        let pl = p.to_string_lossy().to_string();
        ff(&["-f", "lavfi", "-i", "sine=f=330:d=2", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=2", "-f", "lavfi", "-i", "sine=f=550:d=2",
             "-filter_complex", "[0:a]aresample=44100[a];[1:a]aresample=44100[b];[2:a]aresample=44100[c];[a][b][c]concat=n=3:v=0:a=1", &pl]);
    }
    p
}

fn fixture_photo(name: &str, w: u32, h: u32) -> PathBuf {
    let _g = FIXTURES.lock().unwrap_or_else(|e| e.into_inner());
    let p = work().join(name);
    if !p.exists() {
        let img = image::RgbImage::from_fn(w, h, |x, y| image::Rgb([(x * 255 / w) as u8, (y * 255 / h) as u8, ((x ^ y) & 255) as u8]));
        img.save(&p).unwrap();
    }
    p
}

fn ctx() -> Ctx {
    Ctx { tools: Some(tools()), out_dir: Some(work().join("out")) }
}

fn act(id: &str, files: &[&Path], param: Value) -> Result<Vec<PathBuf>, String> {
    let files: Vec<PathBuf> = files.iter().map(|p| p.to_path_buf()).collect();
    let mut last = 0.0;
    let r = run_action(&ctx(), id, &files, &param, &Cancel::new(), &mut |p| {
        assert!(p >= 0.0 && p <= 1.0, "avanzamento fuori scala: {p}");
        last = p;
    });
    r.map(|o| o.into_iter().map(|o| PathBuf::from(o.path)).collect()).map_err(|e| e.0)
}

fn info(p: &Path) -> orbit_engine::FileInfo {
    probe(Some(&tools()), p).unwrap()
}

fn size(p: &Path) -> u64 {
    std::fs::metadata(p).unwrap().len()
}

#[test]
fn comprimi_stessa_qualita() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let out = act("vcompress", &[&v], json!("best")).unwrap();
    let i = info(&out[0]);
    assert_eq!((i.width, i.height), (1280, 720), "stessa misura");
    assert!(size(&out[0]) < size(&v), "più leggero: {} → {}", size(&v), size(&out[0]));
    assert!(i.has_audio);
    assert!((i.duration - 6.0).abs() < 0.3);
}

#[test]
fn comprimi_a_peso_preciso() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let out = act("vcompress", &[&v], json!(0.6)).unwrap();
    assert!(size(&out[0]) <= 600_000, "sotto 0,6 MB: {}", size(&out[0]));
    assert!(info(&out[0]).has_video);
}

#[test]
fn comprimi_verticale_resta_verticale() {
    let v = fixture_video("verticale.mp4", 720, 1280, 4, true);
    let out = act("vcompress", &[&v], json!(0.5)).unwrap();
    let i = info(&out[0]);
    assert!(i.height > i.width, "{}x{}", i.width, i.height);
    assert!(size(&out[0]) <= 500_000);
}

#[test]
fn comprimi_gia_leggero_lo_dice() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let e = act("vcompress", &[&v], json!(50)).unwrap_err();
    assert!(e.contains("non serve comprimerlo"), "{e}");
}

#[test]
fn taglia_senza_perdita() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let out = act("cut", &[&v], json!({"start": 1.0, "end": 4.0})).unwrap();
    let i = info(&out[0]);
    assert!((i.duration - 3.0).abs() < 1.1, "durata {}", i.duration);
    assert!(out[0].file_name().unwrap().to_string_lossy().contains("(tagliato"));
}

#[test]
fn taglia_preciso() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let out = act("cut", &[&v], json!({"start": 1.5, "end": 3.5, "precise": true})).unwrap();
    assert!((info(&out[0]).duration - 2.0).abs() < 0.15);
}

#[test]
fn converti_video() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let mkv = act("to:mkv", &[&v], Value::Null).unwrap();
    assert_eq!(info(&mkv[0]).video_codec, info(&v).video_codec, "stessa codifica: copiato senza perdita");
    let mp3 = act("to:mp3", &[&v], Value::Null).unwrap();
    let i = info(&mp3[0]);
    assert!(i.has_audio && !i.has_video);
    let small = fixture_video("piccolo.mp4", 320, 240, 2, true);
    let webm = act("to:webm", &[&small], Value::Null).unwrap();
    assert_eq!(info(&webm[0]).video_codec, "vp9");
    let gif = act("gifcut", &[&small], json!({"start": 0, "end": 1.5})).unwrap();
    assert!(size(&gif[0]) > 1000);
}

#[test]
fn formato_social_e_velocita() {
    let v = fixture_video("piccolo.mp4", 320, 240, 2, true);
    let s = act("social", &[&v], json!("9x16")).unwrap();
    let i = info(&s[0]);
    assert_eq!((i.width, i.height), (1080, 1920));
    let f = act("speed", &[&v], json!(2)).unwrap();
    assert!((info(&f[0]).duration - 1.0).abs() < 0.2, "{}", info(&f[0]).duration);
}

#[test]
fn risoluzione_e_audio_del_video() {
    let v = fixture_video("grande.mp4", 1280, 720, 6, true);
    let r = act("vresize", &[&v], json!("480")).unwrap();
    assert_eq!(info(&r[0]).height, 480);
    let n = act("voiceclean", &[&v], Value::Null).unwrap();
    let i = info(&n[0]);
    assert_eq!(i.video_codec, info(&v).video_codec, "il video non si ricodifica");
    assert!(i.has_audio);
    let m = act("mute", &[&v], Value::Null).unwrap();
    assert!(!info(&m[0]).has_audio);
}

#[test]
fn unisci_video_anche_senza_audio() {
    let a = fixture_video("piccolo.mp4", 320, 240, 2, true);
    let b = fixture_video("muto.mp4", 640, 480, 2, false);
    let out = act("vmerge", &[&a, &b], Value::Null).unwrap();
    let i = info(&out[0]);
    assert!((i.duration - 4.0).abs() < 0.3, "{}", i.duration);
    assert_eq!((i.width, i.height), (320, 240));
    assert!(i.has_audio);
}

#[test]
fn audio_strumenti() {
    let a = fixture_audio("voce.wav");
    let mp3 = act("to:mp3", &[&a], Value::Null).unwrap();
    assert_eq!(info(&mp3[0]).audio_codec, "mp3");
    let ring = act("ringtone", &[&a], json!({"start": 0, "end": 40})).unwrap();
    let r = info(&ring[0]);
    assert!(r.duration <= 30.1 && r.duration > 5.0, "{}", r.duration);
    assert_eq!(ring[0].extension().unwrap(), "m4r");
    let s = act("silence", &[&a], Value::Null).unwrap();
    assert!(info(&s[0]).duration < 5.5, "pause tolte: {}", info(&s[0]).duration);
    let c = act("cut", &[&a], json!({"start": 1, "end": 3})).unwrap();
    assert!((info(&c[0]).duration - 2.0).abs() < 0.1);
    let w = act("whatsapp", &[&a], Value::Null).unwrap();
    assert_eq!(info(&w[0]).audio_codec, "opus");
    let m = act("amerge", &[&a, &mp3[0]], Value::Null).unwrap();
    assert!((info(&m[0]).duration - 12.0).abs() < 0.3);
    let v = act("voiceclean", &[&a], Value::Null).unwrap();
    assert!(info(&v[0]).has_audio);
}

#[test]
fn foto_comprimi_e_converti() {
    let p = fixture_photo("foto.png", 1600, 1200);
    let small = act("icompress", &[&p], json!(80)).unwrap();
    assert!(size(&small[0]) <= 80_000, "{}", size(&small[0]));
    let best = act("icompress", &[&p], json!("best")).unwrap();
    assert!(size(&best[0]) < size(&p));
    for to in ["jpg", "webp", "bmp", "tiff", "ico", "gif", "pdf"] {
        let o = act(&format!("to:{to}"), &[&p], Value::Null).unwrap_or_else(|e| panic!("{to}: {e}"));
        assert!(size(&o[0]) > 100, "{to}");
    }
    let r = act("resize", &[&p], json!("50%")).unwrap();
    assert_eq!(image::image_dimensions(&r[0]).unwrap(), (800, 600));
    let r2 = act("resize", &[&p], json!("400")).unwrap();
    assert_eq!(image::image_dimensions(&r2[0]).unwrap(), (400, 300));
    let rot = act("rotate", &[&p], json!(90)).unwrap();
    assert_eq!(image::image_dimensions(&rot[0]).unwrap(), (1200, 1600));
}

#[test]
fn foto_in_un_pdf_e_pdf() {
    let a = fixture_photo("pagina1.jpg", 800, 1100);
    let b = fixture_photo("pagina2.jpg", 1100, 800);
    let pdf = act("merge", &[&a, &b], Value::Null).unwrap();
    assert_eq!(orbit_engine::pdf::page_count(&pdf[0]).unwrap(), 2);
    let both = act("pdfmerge", &[&pdf[0], &pdf[0]], Value::Null).unwrap();
    assert_eq!(orbit_engine::pdf::page_count(&both[0]).unwrap(), 4);
    let parts = act("split", &[&both[0]], Value::Null).unwrap();
    assert_eq!(parts.len(), 4);
    let ex = act("extract", &[&both[0]], json!("2-3")).unwrap();
    assert_eq!(orbit_engine::pdf::page_count(&ex[0]).unwrap(), 2);
}

#[test]
fn interrompi() {
    let v = fixture_video("lungo.mp4", 1280, 720, 20, true);
    let c = Cancel::new();
    let c2 = c.clone();
    let t = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(400));
        c2.cancel();
    });
    let r = run_action(&ctx(), "vresize", &[v], &json!("360"), &c, &mut |_| {});
    t.join().unwrap();
    assert!(r.unwrap_err().is_cancelled());
    // Niente file a metà
    let left: Vec<_> = std::fs::read_dir(work().join("out")).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().starts_with("lungo (360p)")).collect();
    assert!(left.is_empty(), "file a metà rimasto");
}

#[test]
fn nomi_mai_sovrascritti() {
    let p = fixture_photo("doppio.png", 100, 100);
    let a = act("to:jpg", &[&p], Value::Null).unwrap();
    let b = act("to:jpg", &[&p], Value::Null).unwrap();
    assert_ne!(a[0], b[0]);
}

#[test]
fn montaggio_completo() {
    use orbit_engine::editor::{export, Clip, Effects, Music, Overlay, Project, Transition};
    use orbit_engine::look::Look;
    let a = fixture_video("grande.mp4", 1280, 720, 6, true);
    let b = fixture_video("verticale.mp4", 720, 1280, 4, true);
    let song = fixture_audio("voce.wav");
    // Un testo già disegnato (PNG trasparente grande come il video)
    let png = work().join("testo.png");
    let mut t = image::RgbaImage::new(1280, 720);
    for x in 400..880 { for y in 600..660 { t.put_pixel(x, y, image::Rgba([255, 255, 255, 230])); } }
    t.save(&png).unwrap();
    let p = Project {
        name: "Gita".into(),
        clips: vec![
            Clip { path: a.to_string_lossy().into(), in_point: 1.0, out_point: 5.0, look: Some(Look { preset: "vintage".into(), amount: 1.0, ..Default::default() }), fx: Some(Effects { zoom: "in".into(), fade_in: 0.5, ..Default::default() }), ..Default::default() },
            Clip { path: b.to_string_lossy().into(), in_point: 0.0, out_point: 4.0, transition: Some(Transition { kind: "black".into(), duration: 0.6 }), fx: Some(Effects { speed: 2.0, flip_h: true, ..Default::default() }), muted: true, ..Default::default() },
            Clip { path: a.to_string_lossy().into(), in_point: 0.0, out_point: 2.0, look: Some(Look { preset: "dream".into(), amount: 1.0, brightness: 0.2, vignette: 0.5, ..Default::default() }), ..Default::default() },
        ],
        music: Some(Music { path: song.to_string_lossy().into(), volume: 0.7, fade_in: 1.0, fade_out: 1.0, duck: true, looped: true, ..Default::default() }),
        overlays: vec![Overlay { png: png.to_string_lossy().into(), start: 0.5, end: 3.0, fade_in: 0.3, fade_out: 0.3, slide: 40.0, ..Default::default() }],
        resolution: 720,
        fps: 30.0,
        original_volume: 1.0,
        ..Default::default()
    };
    let dir = work().join("out");
    std::fs::create_dir_all(&dir).unwrap();
    let out = export(&tools(), &p, &dir, &Cancel::new(), &mut |_| {}).unwrap_or_else(|e| panic!("{e}"));
    let i = info(&out);
    // 4 s + 2 s (4 s a 2×) + 2 s = 8 s; le transizioni non tolgono tempo
    assert!((i.duration - 8.0).abs() < 0.25, "durata {}", i.duration);
    assert_eq!((i.width, i.height), (1280, 720));
    assert!(i.has_audio);
}

/// Solo dove ci sono motore e modello della voce (su Windows nella compilazione automatica).
#[test]
fn trascrivi_una_voce() {
    let (Some(exe), Some(model)) = (std::env::var_os("ORBIT_WHISPER"), std::env::var_os("ORBIT_WHISPER_MODEL")) else { return };
    // Una voce di Windows legge una frase (in inglese: la voce italiana non c'è sui computer di prova)
    let wav = work().join("voce-sintetica.wav");
    let st = std::process::Command::new("powershell")
        .args(["-NoProfile", "-Command", "Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.SetOutputToWaveFile($env:W); $s.Speak('Good morning. This is a test of the transcription in OrbitLR.'); $s.Dispose()"])
        .env("W", &wav)
        .status()
        .unwrap();
    assert!(st.success());
    let info = info(&wav);
    let dir = work().join("out");
    std::fs::create_dir_all(&dir).unwrap();
    let outs = orbit_engine::whisper::transcribe_files(&tools(), std::path::Path::new(&exe), std::path::Path::new(&model), &wav, &info, "en", &dir, &Cancel::new(), &mut |_| {}).unwrap_or_else(|e| panic!("{e}"));
    let text = std::fs::read_to_string(&outs[0]).unwrap().to_lowercase();
    assert!(text.contains("test") && text.contains("transcription"), "{text}");
    let srt = std::fs::read_to_string(&outs[1]).unwrap();
    assert!(srt.contains("-->"));
}

#[test]
fn nascondi_un_logo() {
    let p = fixture_photo("logo-foto.png", 800, 600);
    let zones = json!({"zones": [{"x": 0.7, "y": 0.05, "w": 0.25, "h": 0.15}], "mode": "pixel", "strength": 0.8});
    let out = act("hidemark", &[&p], zones.clone()).unwrap();
    let a = image::open(&p).unwrap().to_rgb8();
    let b = image::open(&out[0]).unwrap().to_rgb8();
    assert_eq!(a.dimensions(), b.dimensions());
    // Fuori dalla zona uguale, dentro cambiata
    assert_eq!(a.get_pixel(100, 400), b.get_pixel(100, 400));
    let changed = (580..780).step_by(7).any(|x| a.get_pixel(x, 50) != b.get_pixel(x, 50));
    assert!(changed);
    let v = fixture_video("piccolo.mp4", 320, 240, 2, true);
    let o = act("hidemark", &[&v], json!({"zones": [{"x": 0.1, "y": 0.1, "w": 0.3, "h": 0.2}], "mode": "blur"})).unwrap();
    let i = info(&o[0]);
    assert_eq!((i.width, i.height), (320, 240));
    assert!(i.has_audio);
}

#[test]
fn montaggio_taglio_poi_transizione_e_tanti_sottotitoli() {
    use orbit_engine::editor::{export, Clip, Frame, Overlay, Project, Transition};
    let a = fixture_video("piccolo.mp4", 320, 240, 2, true);
    let b = fixture_video("muto.mp4", 640, 480, 2, false);
    // Prima un taglio netto, poi una transizione (prima falliva: basi dei tempi diverse)
    let clips = vec![
        Clip { path: a.to_string_lossy().into(), out_point: 2.0, ..Default::default() },
        Clip { path: b.to_string_lossy().into(), out_point: 2.0, ..Default::default() },
        Clip { path: a.to_string_lossy().into(), out_point: 2.0, transition: Some(Transition { kind: "fade".into(), duration: 0.5 }), ..Default::default() },
    ];
    // Tante parole: una sequenza per riga e tanti testi singoli (il grafo va in un file)
    let mut overlays = Vec::new();
    let mut frames = Vec::new();
    for i in 0..6 {
        let png = work().join(format!("parola-{i}.png"));
        let mut t = image::RgbaImage::new(320, 240);
        for x in (40 + i * 30)..(60 + i * 30) { for y in 200..220 { t.put_pixel(x as u32, y, image::Rgba([250, 200, 90, 255])); } }
        t.save(&png).unwrap();
        frames.push(Frame { png: png.to_string_lossy().into(), duration: 0.3 });
    }
    overlays.push(Overlay { frames, start: 0.5, end: 2.3, fade_in: 0.2, fade_out: 0.2, ..Default::default() });
    let single = work().join("parola-0.png").to_string_lossy().to_string();
    for k in 0..150 {
        let s = (k as f64) * 0.035;
        overlays.push(Overlay { png: single.clone(), start: s, end: s + 0.2, ..Default::default() });
    }
    let p = Project { name: "Molti testi".into(), clips, overlays, resolution: 240, fps: 25.0, original_volume: 1.0, ..Default::default() };
    let dir = work().join("out");
    std::fs::create_dir_all(&dir).unwrap();
    let out = export(&tools(), &p, &dir, &Cancel::new(), &mut |_| {}).unwrap_or_else(|e| panic!("{e}"));
    let i = info(&out);
    assert!((i.duration - 6.0).abs() < 0.25, "durata {}", i.duration);
}

#[test]
fn comprimi_pdf() {
    // Un PDF di 3 pagine con foto grandi e pesanti (come una scansione)
    let mut pages = Vec::new();
    for k in 0..3u32 {
        let img = image::RgbImage::from_fn(2480, 3508, |x, y| {
            let n = ((x * 7919 + y * 104729 + k * 31) % 251) as u8;
            image::Rgb([((x / 9) as u8).wrapping_add(n / 8), ((y / 13) as u8).wrapping_add(n / 6), n])
        });
        let mut buf = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 95).encode_image(&img).unwrap();
        pages.push((buf, 2480, 3508));
    }
    let src = work().join("scansione.pdf");
    orbit_engine::pdf::images_to_pdf(&pages, &src).unwrap();
    let out = act("pdfcompress", &[&src], json!("medium")).unwrap();
    assert_eq!(orbit_engine::pdf::page_count(&out[0]).unwrap(), 3);
    assert!(size(&out[0]) < size(&src) / 3, "{} → {}", size(&src), size(&out[0]));
    // Un PDF già leggero lo dice
    let e = act("pdfcompress", &[&out[0]], json!("light")).unwrap_err();
    assert!(e.contains("già compresso"), "{e}");
}
