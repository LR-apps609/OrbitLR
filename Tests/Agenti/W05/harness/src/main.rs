//! W05 · Prove del motore di OrbitLR per Windows (video e audio) con percorsi difficili:
//! lettere non latine ed emoji, percorsi oltre 260 caratteri, cartelle «OneDrive» con spazi e parentesi,
//! percorsi di rete (\\localhost\D$\...), cartelle in sola lettura, TEMP con lettere non latine.
//! Ogni lavoro gira in un processo a parte con un tempo massimo di 5 minuti (oltre: «bloccato»).
//!
//! Uso:  w05 suite        (configurato con le variabili W05_*)
//!       w05 one <spec>   (un solo lavoro, chiamato dalla suite)

use orbit_engine::{probe, run_action, Cancel, Ctx, Tools};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const LIMIT: Duration = Duration::from_secs(300);

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("one") => one(Path::new(&a[2])),
        Some("suite") => suite(),
        _ => {
            eprintln!("uso: w05 suite | w05 one <spec.json>");
            std::process::exit(2);
        }
    }
}

fn tools() -> Tools {
    let dir = std::env::var_os("ORBIT_MOTORI").map(PathBuf::from);
    Tools::locate(dir.as_deref()).expect("serve ffmpeg")
}

// ───────────────────────────── un lavoro ─────────────────────────────

fn one(spec_path: &Path) {
    let spec: Value = serde_json::from_slice(&std::fs::read(spec_path).unwrap()).unwrap();
    let result_path = PathBuf::from(spec["result"].as_str().unwrap());
    let t0 = Instant::now();
    let mut pmax: f64 = -1.0;
    let mut pbad: Vec<f64> = Vec::new();
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Vec<String>, String> {
        let t = tools();
        let files: Vec<PathBuf> = spec["files"].as_array().unwrap().iter().map(|v| PathBuf::from(v.as_str().unwrap())).collect();
        let out_dir = spec["out_dir"].as_str().map(PathBuf::from);
        let data_dir = spec["data_dir"].as_str().map(PathBuf::from);
        let mut prog = |p: f64| {
            if !(0.0..=1.0).contains(&p) || p.is_nan() {
                pbad.push(p);
            }
            if p > pmax {
                pmax = p;
            }
        };
        match spec["mode"].as_str().unwrap_or("action") {
            "transcribe" => {
                let exe = PathBuf::from(spec["exe"].as_str().unwrap());
                let model = PathBuf::from(spec["model"].as_str().unwrap());
                let f = &files[0];
                let info = probe(Some(&t), f).map_err(|e| e.0)?;
                let dir = out_dir.unwrap_or_else(|| f.parent().map(Path::to_path_buf).unwrap_or_default());
                let outs = orbit_engine::whisper::transcribe_files(&t, &exe, &model, f, &info, spec["lang"].as_str().unwrap_or("en"), &dir, &Cancel::new(), &mut prog)
                    .map_err(|e| e.0)?;
                Ok(outs.iter().map(|p| p.to_string_lossy().to_string()).collect())
            }
            _ => {
                let ctx = Ctx { tools: Some(t), out_dir, data_dir };
                let o = run_action(&ctx, spec["action"].as_str().unwrap(), &files, &spec["param"], &Cancel::new(), &mut prog).map_err(|e| e.0)?;
                Ok(o.into_iter().map(|o| o.path).collect())
            }
        }
    }));
    let secs = t0.elapsed().as_secs_f64();
    let v = match r {
        Ok(Ok(outs)) => json!({"ok": true, "outputs": outs, "secs": secs, "pmax": pmax, "pbad": pbad}),
        Ok(Err(e)) => json!({"ok": false, "error": e, "secs": secs, "pmax": pmax, "pbad": pbad}),
        Err(p) => {
            let m = p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
            json!({"ok": false, "panic": true, "error": format!("PANIC: {m}"), "secs": secs})
        }
    };
    std::fs::write(&result_path, serde_json::to_vec_pretty(&v).unwrap()).unwrap();
}

// ───────────────────────────── la suite ─────────────────────────────

struct Loc {
    name: String,
    /// Il percorso che si dà al motore (per «unc» è \\localhost\D$\...)
    dir: PathBuf,
    /// Il percorso locale dove si creano i file
    local: PathBuf,
    prefix: String,
    out_dir: Option<PathBuf>,
    temp: Option<PathBuf>,
    data_dir: Option<PathBuf>,
    model: Option<PathBuf>,
    expect_fail: bool,
    subset: bool,
    readonly: bool,
}

#[derive(Clone, Default)]
struct Exp {
    dur: Option<(f64, f64)>,
    audio: Option<bool>,
    video: Option<bool>,
    wh: Option<(u32, u32)>,
    h: Option<u32>,
    text: bool,
    min_out: usize,
}

struct Job {
    label: &'static str,
    action: &'static str,
    inputs: Vec<&'static str>,
    param: Value,
    exp: Exp,
    mode: &'static str,
    core: bool,
}

fn e_av(d: f64) -> Exp {
    Exp { dur: Some((d, 0.35)), audio: Some(true), video: Some(true), min_out: 1, ..Default::default() }
}
fn e_a(d: f64) -> Exp {
    Exp { dur: Some((d, 0.35)), audio: Some(true), video: Some(false), min_out: 1, ..Default::default() }
}

fn jobs() -> Vec<Job> {
    let j = |label, action, inputs: Vec<&'static str>, param: Value, exp: Exp, core| Job { label, action, inputs, param, exp, mode: "action", core };
    let mut v = vec![
        // ── Video (clip.mp4: 4 s, 640×360, con audio)
        j("v to:mkv", "to:mkv", vec!["clip"], Value::Null, e_av(4.0), false),
        j("v to:mov", "to:mov", vec!["clip"], Value::Null, e_av(4.0), false),
        j("v to:webm", "to:webm", vec!["clip"], Value::Null, e_av(4.0), true),
        j("v to:avi", "to:avi", vec!["clip"], Value::Null, e_av(4.0), false),
        j("v to:mp4 (da mkv)", "to:mp4", vec!["subs"], Value::Null, e_av(4.0), false),
        j("v to:gif", "to:gif", vec!["clip"], Value::Null, Exp { video: Some(true), audio: Some(false), min_out: 1, ..Default::default() }, false),
        j("v to:mp3", "to:mp3", vec!["clip"], Value::Null, e_a(4.0), true),
        j("v to:m4a", "to:m4a", vec!["clip"], Value::Null, e_a(4.0), false),
        j("v to:wav", "to:wav", vec!["clip"], Value::Null, e_a(4.0), false),
        j("v to:flac", "to:flac", vec!["clip"], Value::Null, e_a(4.0), false),
        j("v to:opus", "to:opus", vec!["clip"], Value::Null, e_a(4.0), false),
        j("vcompress best", "vcompress", vec!["clip"], json!("best"), e_av(4.0), true),
        j("vcompress 0,3 MB", "vcompress", vec!["clip"], json!(0.3), e_av(4.0), false),
        j("vresize 240", "vresize", vec!["clip"], json!("240"), Exp { h: Some(240), ..e_av(4.0) }, false),
        j("vresize hevc", "vresize", vec!["clip"], json!("hevc"), e_av(4.0), false),
        j("cut 1-3", "cut", vec!["clip"], json!({"start": 1.0, "end": 3.0}), Exp { dur: Some((2.0, 1.1)), ..e_av(2.0) }, true),
        j("cut preciso 1-3", "cut", vec!["clip"], json!({"start": 1.0, "end": 3.0, "precise": true}), Exp { dur: Some((2.0, 0.15)), ..e_av(2.0) }, false),
        j("cut solo audio", "cut", vec!["clip"], json!({"start": 1.0, "end": 3.0, "audio": true}), Exp { dur: Some((2.0, 0.15)), ..e_a(2.0) }, false),
        j("gifcut 0-1,5", "gifcut", vec!["clip"], json!({"start": 0, "end": 1.5}), Exp { video: Some(true), audio: Some(false), min_out: 1, ..Default::default() }, false),
        j("speed 2x", "speed", vec!["clip"], json!(2), e_av(2.0), false),
        j("speed 0,5x", "speed", vec!["clip"], json!(0.5), Exp { dur: Some((8.0, 0.4)), ..e_av(8.0) }, false),
        j("social 9x16", "social", vec!["clip"], json!("9x16"), Exp { wh: Some((1080, 1920)), ..e_av(4.0) }, true),
        j("social 9x16 persone", "social", vec!["clip"], json!("9x16|1"), Exp { wh: Some((1080, 1920)), ..e_av(4.0) }, true),
        j("social 1x1", "social", vec!["clip"], json!("1x1"), e_av(4.0), false),
        j("mute", "mute", vec!["clip"], Value::Null, Exp { audio: Some(false), ..e_av(4.0) }, true),
        j("rotate 90", "rotate", vec!["clip"], json!(90), Exp { wh: Some((360, 640)), ..e_av(4.0) }, false),
        j("strip (video)", "strip", vec!["clip"], Value::Null, e_av(4.0), false),
        j("voiceclean (video)", "voiceclean", vec!["clip"], Value::Null, e_av(4.0), false),
        j("normalize (video)", "normalize", vec!["clip"], Value::Null, Exp { dur: Some((4.0, 0.35)), audio: Some(true), min_out: 1, ..Default::default() }, false),
        j("subextract", "subextract", vec!["subs"], Value::Null, Exp { text: true, min_out: 1, ..Default::default() }, true),
        j("subembed", "subembed", vec!["clip"], Value::Null, e_av(4.0), true),
        j("hidemark (video)", "hidemark", vec!["clip"], json!({"zones": [{"x": 0.1, "y": 0.1, "w": 0.3, "h": 0.2}], "mode": "blur"}), e_av(4.0), false),
        j("vmerge clip+muto", "vmerge", vec!["clip", "muto"], Value::Null, Exp { dur: Some((6.0, 0.4)), ..e_av(6.0) }, true),
        // ── Audio (voce.wav: 6 s, tono-silenzio-tono)
        j("a to:mp3", "to:mp3", vec!["voce"], Value::Null, e_a(6.0), true),
        j("a to:m4a", "to:m4a", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:flac", "to:flac", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:ogg", "to:ogg", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:opus", "to:opus", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:aiff", "to:aiff", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:m4r", "to:m4r", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a to:aac", "to:aac", vec!["voce"], Value::Null, Exp { dur: Some((6.0, 0.5)), ..e_a(6.0) }, false),
        j("a to:wav (da m4a)", "to:wav", vec!["voce_m4a"], Value::Null, e_a(6.0), false),
        j("a normalize", "normalize", vec!["voce"], Value::Null, e_a(6.0), true),
        j("a voiceclean", "voiceclean", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a silence", "silence", vec!["voce"], Value::Null, Exp { dur: Some((4.0, 1.4)), ..e_a(4.0) }, false),
        j("a whatsapp", "whatsapp", vec!["voce"], Value::Null, e_a(6.0), false),
        j("a ringtone 0-4", "ringtone", vec!["voce"], json!({"start": 0, "end": 4}), Exp { dur: Some((4.0, 0.3)), ..e_a(4.0) }, false),
        j("a cut 1-3", "cut", vec!["voce"], json!({"start": 1, "end": 3}), Exp { dur: Some((2.0, 0.15)), ..e_a(2.0) }, false),
        j("a speed 1,5x", "speed", vec!["voce"], json!(1.5), Exp { dur: Some((4.0, 0.3)), ..e_a(4.0) }, false),
        j("amerge wav+m4a", "amerge", vec!["voce", "voce_m4a"], Value::Null, Exp { dur: Some((12.0, 0.4)), ..e_a(12.0) }, true),
        // ── Montaggio (progetto con musica e testo)
        j("vproject montaggio", "vproject", vec!["clip"], json!("PROJECT"), Exp { dur: Some((5.0, 0.4)), audio: Some(true), video: Some(true), min_out: 1, ..Default::default() }, true),
    ];
    v.push(Job { label: "trascrivi (whisper)", action: "transcribe", inputs: vec!["parla"], param: Value::Null, exp: Exp { text: true, min_out: 2, ..Default::default() }, mode: "transcribe", core: true });
    v
}

/// I file di partenza: chiave → nome base
const FIX: &[(&str, &str)] = &[
    ("clip", "clip.mp4"),
    ("clip2", "clip2.mp4"),
    ("muto", "muto.mp4"),
    ("subs", "sottotitoli.mkv"),
    ("srt", "clip.srt"),
    ("voce", "voce.wav"),
    ("voce_m4a", "voce.m4a"),
    ("parla", "parla.wav"),
    ("logo", "logo.png"),
];

fn ff(t: &Tools, args: &[String]) {
    let o = t.ffmpeg_cmd().args(["-hide_banner", "-loglevel", "error", "-y"]).args(args).output().unwrap();
    assert!(o.status.success(), "ffmpeg {:?}: {}", args, String::from_utf8_lossy(&o.stderr));
}

fn s(p: &Path) -> String {
    p.to_string_lossy().to_string()
}

fn make_fixtures(t: &Tools, src: &Path) {
    std::fs::create_dir_all(src).unwrap();
    let enc = &orbit_engine::video::candidates(t, orbit_engine::video::Codec::H264)[0];
    let ea: Vec<String> = orbit_engine::video::encoder_args(enc, 4_000_000).into_iter().map(|x| x.to_string_lossy().to_string()).collect();
    let mk = |name: &str, secs: u32, audio: bool| {
        let mut a: Vec<String> = vec!["-f".into(), "lavfi".into(), "-i".into(), format!("testsrc2=size=640x360:rate=30:duration={secs},noise=alls=12:allf=t")];
        if audio {
            a.extend(["-f".into(), "lavfi".into(), "-i".into(), format!("sine=frequency=440:duration={secs}")]);
        }
        a.extend(ea.clone());
        if audio {
            a.extend(["-c:a".into(), "aac".into(), "-b:a".into(), "128k".into(), "-shortest".into()]);
        }
        a.push(s(&src.join(name)));
        ff(t, &a);
    };
    mk("clip.mp4", 4, true);
    mk("clip2.mp4", 2, true);
    mk("muto.mp4", 2, false);
    let srt = "1\n00:00:00,500 --> 00:00:02,000\nCiao, привет, 你好, مرحبا 🎬\n\n2\n00:00:02,200 --> 00:00:03,800\nSeconda riga\n\n";
    std::fs::write(src.join("clip.srt"), srt).unwrap();
    ff(t, &[ "-i".into(), s(&src.join("clip.mp4")), "-i".into(), s(&src.join("clip.srt")), "-map".into(), "0".into(), "-map".into(), "1".into(), "-c".into(), "copy".into(), "-c:s".into(), "srt".into(), s(&src.join("sottotitoli.mkv"))]);
    ff(t, &["-f".into(), "lavfi".into(), "-i".into(), "sine=f=330:d=2".into(), "-f".into(), "lavfi".into(), "-i".into(), "anullsrc=r=44100:cl=mono:d=2".into(), "-f".into(), "lavfi".into(), "-i".into(), "sine=f=550:d=2".into(),
        "-filter_complex".into(), "[0:a]aresample=44100[a];[1:a]aresample=44100[b];[2:a]aresample=44100[c];[a][b][c]concat=n=3:v=0:a=1".into(), s(&src.join("voce.wav"))]);
    ff(t, &["-i".into(), s(&src.join("voce.wav")), "-c:a".into(), "aac".into(), "-b:a".into(), "128k".into(), s(&src.join("voce.m4a"))]);
    ff(t, &["-f".into(), "lavfi".into(), "-i".into(), "color=c=white@0.7:s=1280x720,format=rgba".into(), "-frames:v".into(), "1".into(), s(&src.join("logo.png"))]);
    // Una voce vera (sintesi di Windows), per la trascrizione
    if cfg!(windows) {
        let wav = src.join("parla.wav");
        let st = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", "Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.SetOutputToWaveFile($env:W); $s.Speak('Good morning. This is a test of the transcription in OrbitLR. The weather is nice today.'); $s.Dispose()"])
            .env("W", &wav)
            .status()
            .unwrap();
        assert!(st.success());
    } else if let Some(p) = std::env::var_os("W05_SPEECH") {
        std::fs::copy(p, src.join("parla.wav")).unwrap();
    }
}

/// D:\a\b → \\localhost\D$\a\b
fn to_unc(p: &Path) -> PathBuf {
    let st = s(p);
    let b = st.as_bytes();
    if b.len() > 2 && b[1] == b':' {
        PathBuf::from(format!(r"\\localhost\{}${}", &st[..1], &st[2..]))
    } else {
        p.to_path_buf()
    }
}

fn deny_write(dir: &Path) -> String {
    if cfg!(windows) {
        // Nessuno (nemmeno un amministratore) può creare file o cartelle qui; leggere sì
        let o = std::process::Command::new("icacls").arg(dir).args(["/deny", "*S-1-1-0:(WD,AD)"]).output().unwrap();
        format!("icacls: {} {}", o.status, String::from_utf8_lossy(&o.stdout).trim())
    } else {
        let o = std::process::Command::new("chmod").arg("555").arg(dir).output().unwrap();
        format!("chmod 555: {}", o.status)
    }
}

fn can_write(dir: &Path) -> bool {
    let p = dir.join("prova-scrittura.tmp");
    let ok = std::fs::write(&p, b"x").is_ok();
    let _ = std::fs::remove_file(&p);
    ok
}

fn snapshot(dir: &Path) -> Vec<(String, u64)> {
    let mut v: Vec<(String, u64)> = std::fs::read_dir(dir)
        .map(|r| r.flatten().map(|e| (e.file_name().to_string_lossy().to_string(), e.metadata().map(|m| m.len()).unwrap_or(0))).collect())
        .unwrap_or_default();
    v.sort();
    v
}

fn env_path(k: &str) -> Option<PathBuf> {
    std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn suite() {
    let t = tools();
    let work = env_path("W05_WORK").unwrap_or_else(|| std::env::temp_dir().join("w05"));
    let report = env_path("W05_REPORT").unwrap_or_else(|| work.join("report"));
    let tag = std::env::var("W05_TAG").unwrap_or_else(|_| "base".into());
    let want: Vec<String> = std::env::var("W05_LOCS").unwrap_or_else(|_| "ascii,unicode,onedrive,long,unc,ro_out,ro_in,temp_unicode,model_unicode".into()).split(',').map(|x| x.trim().to_string()).collect();
    let only: Vec<String> = std::env::var("W05_ONLY").unwrap_or_default().split(',').filter(|x| !x.is_empty()).map(|x| x.to_string()).collect();
    let exe = env_path("ORBIT_WHISPER");
    let model = env_path("ORBIT_WHISPER_MODEL");
    std::fs::create_dir_all(&report).unwrap();
    let src = work.join("src");
    if !src.join("voce.m4a").is_file() {
        make_fixtures(&t, &src);
    }
    let specs = work.join("specs");
    let verify = work.join("verify");
    std::fs::create_dir_all(&specs).unwrap();
    std::fs::create_dir_all(&verify).unwrap();
    let writable_out = work.join("uscita_scrivibile");
    std::fs::create_dir_all(&writable_out).unwrap();

    let uni = "Тест 测试 اختبار 🎬 ";
    let hostile = work.join("Видео 视频 فيديو 🎬");
    let mut locs: Vec<Loc> = Vec::new();
    let base = |name: &str, dir: PathBuf, prefix: &str| Loc {
        name: name.into(),
        local: dir.clone(),
        dir,
        prefix: prefix.into(),
        out_dir: None,
        temp: None,
        data_dir: None,
        model: None,
        expect_fail: false,
        subset: false,
        readonly: false,
    };
    for w in &want {
        match w.as_str() {
            "ascii" => locs.push(base("ascii", work.join("ascii"), "")),
            "unicode" => locs.push(base("unicode", hostile.join("Каталог 目录 مجلد 😀"), uni)),
            "onedrive" => locs.push(base("onedrive", work.join("OneDrive - Contoso (Personale)").join("Documenti (2024)").join("Video & Foto [vacanze]"), "Gita al lago (1) ")),
            "long" => {
                let mut d = work.join("lungo");
                while s(&d).chars().count() < 250 {
                    d = d.join("cartella_con_un_nome_molto_lungo_0123456789");
                }
                locs.push(base("long", d, "nome di file lungo per superare i 260 caratteri "));
            }
            "unc" => {
                let mut l = base("unc", PathBuf::new(), "");
                l.local = work.join("rete");
                l.dir = to_unc(&l.local);
                locs.push(l);
            }
            "unc_unicode" => {
                let mut l = base("unc_unicode", PathBuf::new(), uni);
                l.local = hostile.join("rete");
                l.dir = to_unc(&l.local);
                locs.push(l);
            }
            "ro_out" => {
                let mut l = base("ro_out", work.join("sola lettura"), "");
                l.expect_fail = true;
                l.subset = true;
                l.readonly = true;
                locs.push(l);
            }
            "ro_in" => {
                let mut l = base("ro_in", work.join("sola lettura 2"), "");
                l.out_dir = Some(writable_out.clone());
                l.subset = true;
                l.readonly = true;
                locs.push(l);
            }
            "temp_unicode" => {
                let mut l = base("temp_unicode", work.join("ascii_temp"), "");
                let tdir = hostile.join("Temp Пользователь 用户");
                std::fs::create_dir_all(&tdir).unwrap();
                l.temp = Some(tdir);
                l.subset = true;
                locs.push(l);
            }
            "model_unicode" => {
                // Come un utente Windows con il nome in cirillico: modello in C:\Users\Иван\AppData\Local\...
                let mut l = base("model_unicode", work.join("ascii_modello"), "");
                let dd = hostile.join("Users").join("Иван Петров").join("AppData").join("Local").join("OrbitLR");
                l.data_dir = Some(dd);
                l.subset = true;
                locs.push(l);
            }
            _ => {}
        }
    }

    let jobs = jobs();
    let mut results = std::fs::OpenOptions::new().create(true).append(true).open(report.join(format!("risultati-{tag}.jsonl"))).unwrap();
    let mut summary = String::new();
    let mut env_notes = String::new();
    let mut n = 0usize;
    let (mut passed, mut failed) = (0usize, 0usize);

    for loc in &locs {
        std::fs::create_dir_all(&loc.local).unwrap();
        for (k, f) in FIX {
            let from = src.join(f);
            if from.is_file() {
                let to = loc.local.join(format!("{}{}", loc.prefix, f));
                if !to.is_file() {
                    std::fs::copy(&from, &to).unwrap_or_else(|e| panic!("copia {k} in {}: {e}", s(&to)));
                }
            }
        }
        // modello della voce nella cartella dei dati con lettere non latine
        let mut loc_model = model.clone();
        if let (Some(dd), Some(m)) = (&loc.data_dir, &model) {
            let p = orbit_engine::whisper::model_path(dd);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            if !p.is_file() {
                std::fs::copy(m, &p).unwrap();
            }
            loc_model = Some(p);
        }
        if loc.readonly && can_write(&loc.local) {
            let r = deny_write(&loc.local);
            env_notes.push_str(&format!("- {}: {r}; scrivibile dopo: {}\n", loc.name, can_write(&loc.local)));
        }
        env_notes.push_str(&format!("- {}: `{}` ({} caratteri){}{}\n", loc.name, s(&loc.dir), s(&loc.dir).chars().count(),
            loc.temp.as_ref().map(|t| format!(", TEMP=`{}`", s(t))).unwrap_or_default(),
            loc.data_dir.as_ref().map(|t| format!(", dati=`{}`", s(t))).unwrap_or_default()));
        let out_target = loc.out_dir.clone().unwrap_or_else(|| loc.local.clone());

        for job in &jobs {
            if loc.subset && !job.core {
                continue;
            }
            if loc.name == "model_unicode" && job.mode != "transcribe" {
                continue;
            }
            if !only.is_empty() && !only.iter().any(|o| o == job.label) {
                continue;
            }
            n += 1;
            let files: Vec<PathBuf> = job.inputs.iter().map(|k| loc.dir.join(format!("{}{}", loc.prefix, FIX.iter().find(|(kk, _)| kk == k).unwrap().1))).collect();
            if job.mode == "transcribe" && (exe.is_none() || loc_model.is_none() || !src.join("parla.wav").is_file()) {
                let line = json!({"tag": tag, "loc": loc.name, "job": job.label, "esito": "SALTATO", "motivo": "manca whisper o la voce"});
                writeln!(results, "{line}").unwrap();
                continue;
            }
            let param = if job.param == json!("PROJECT") {
                let clip = s(&files[0]);
                let clip2 = s(&loc.dir.join(format!("{}clip2.mp4", loc.prefix)));
                let song = s(&loc.dir.join(format!("{}voce.wav", loc.prefix)));
                let png = s(&loc.dir.join(format!("{}logo.png", loc.prefix)));
                json!({"name": format!("{}Montaggio", loc.prefix), "clips": [
                        {"path": clip, "in_point": 0.5, "out_point": 3.5, "fx": {"zoom": "in", "fade_in": 0.3}},
                        {"path": clip2, "in_point": 0.0, "out_point": 2.0, "transition": {"kind": "black", "duration": 0.5}}],
                    "music": {"path": song, "volume": 0.6, "fade_in": 0.5, "fade_out": 0.5, "duck": true, "looped": true},
                    "overlays": [{"png": png, "start": 0.5, "end": 2.5, "fade_in": 0.2, "fade_out": 0.2}],
                    "resolution": 720, "fps": 30.0, "original_volume": 1.0})
            } else {
                job.param.clone()
            };
            let spec_path = specs.join(format!("{tag}-{n}.json"));
            let res_path = specs.join(format!("{tag}-{n}.result.json"));
            let _ = std::fs::remove_file(&res_path);
            let spec = json!({"mode": job.mode, "action": job.action, "files": files.iter().map(|p| s(p)).collect::<Vec<_>>(), "param": param,
                "out_dir": loc.out_dir.as_ref().map(|p| s(p)), "data_dir": loc.data_dir.as_ref().map(|p| s(p)), "result": s(&res_path),
                "exe": exe.as_ref().map(|p| s(p)), "model": loc_model.as_ref().map(|p| s(p)), "lang": "en"});
            std::fs::write(&spec_path, serde_json::to_vec_pretty(&spec).unwrap()).unwrap();

            let before = snapshot(&out_target);
            let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
            cmd.arg("one").arg(&spec_path);
            if let Some(td) = &loc.temp {
                cmd.env("TEMP", td).env("TMP", td).env("TMPDIR", td);
            }
            let t0 = Instant::now();
            let mut child = cmd.spawn().unwrap();
            let mut hang = false;
            let status = loop {
                if let Some(st) = child.try_wait().unwrap() {
                    break Some(st);
                }
                if t0.elapsed() > LIMIT {
                    hang = true;
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(100));
            };
            let wall = t0.elapsed().as_secs_f64();
            let res: Value = std::fs::read(&res_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(json!({}));
            let after = snapshot(&out_target);
            let new_files: Vec<(String, u64)> = after.iter().filter(|x| !before.iter().any(|b| b.0 == x.0)).cloned().collect();
            let outs: Vec<String> = res["outputs"].as_array().map(|a| a.iter().map(|v| v.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
            // avanzi: file nuovi che non sono risultati (temporanei «.orbitlr-», nomi riservati vuoti)
            let leftovers: Vec<String> = new_files
                .iter()
                .filter(|(nm, sz)| !outs.iter().any(|o| Path::new(o).file_name().map(|f| f.to_string_lossy() == *nm).unwrap_or(false)) && (nm.starts_with(".orbitlr-") || *sz == 0))
                .map(|(nm, sz)| format!("{nm} ({sz} B)"))
                .collect();

            let mut problems: Vec<String> = Vec::new();
            let mut checks: Vec<Value> = Vec::new();
            let ok = res["ok"].as_bool().unwrap_or(false);
            if hang {
                problems.push(format!("BLOCCATO: oltre {} s, fermato", LIMIT.as_secs()));
            } else if res.get("ok").is_none() {
                problems.push(format!("il processo è finito senza risultato (uscita {:?})", status.and_then(|s| s.code())));
            } else if loc.expect_fail {
                if ok {
                    problems.push(format!("doveva fallire (cartella in sola lettura) ma dice riuscito: {:?}", outs));
                }
            } else if !ok {
                problems.push(format!("errore: {}", res["error"].as_str().unwrap_or("?")));
            } else {
                if outs.len() < job.exp.min_out {
                    problems.push(format!("attesi almeno {} file, avuti {}", job.exp.min_out, outs.len()));
                }
                for (i, o) in outs.iter().enumerate() {
                    let op = Path::new(o);
                    let mut c = json!({"file": o});
                    // il file deve stare nella cartella giusta
                    let parent_ok = op.parent().map(|p| s(p).to_lowercase() == s(&loc.out_dir.clone().unwrap_or(loc.dir.clone())).to_lowercase()).unwrap_or(false);
                    if !parent_ok && job.mode != "transcribe" {
                        problems.push(format!("file fuori posto: {o}"));
                    }
                    if !loc.prefix.is_empty() && !op.file_name().map(|f| f.to_string_lossy().contains(loc.prefix.trim())).unwrap_or(false) && !["vproject", "vmerge", "amerge"].contains(&job.action) {
                        problems.push(format!("il nome ha perso le lettere originali: {o}"));
                    }
                    let meta = std::fs::metadata(op);
                    let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
                    c["size"] = json!(size);
                    if meta.is_err() {
                        problems.push(format!("il file risultato non esiste: {o}"));
                        checks.push(c);
                        continue;
                    }
                    if size == 0 {
                        problems.push(format!("file vuoto: {o}"));
                    }
                    let ext = op.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                    let copy = verify.join(format!("{tag}-{n}-{i}.{ext}"));
                    if let Err(e) = std::fs::copy(op, &copy) {
                        problems.push(format!("non riesco a copiare il risultato per controllarlo: {e}"));
                        checks.push(c);
                        continue;
                    }
                    if ["srt", "txt"].contains(&ext.as_str()) {
                        let txt = std::fs::read_to_string(&copy).unwrap_or_default();
                        c["text"] = json!(txt.chars().take(300).collect::<String>());
                        if job.mode == "transcribe" {
                            if ext == "txt" && !txt.to_lowercase().contains("test") {
                                problems.push(format!("trascrizione senza «test»: {}", txt.trim()));
                            }
                            if ext == "srt" && !txt.contains("-->") {
                                problems.push("sottotitoli senza tempi".into());
                            }
                        } else if !txt.contains("-->") || !txt.contains("привет") || !txt.contains("🎬") {
                            problems.push(format!("sottotitoli estratti sbagliati: {}", txt.trim()));
                        }
                    } else if ext != "png" {
                        match probe(Some(&t), &copy) {
                            Ok(i) => {
                                c["dur"] = json!(i.duration);
                                c["audio"] = json!(i.has_audio);
                                c["video"] = json!(i.has_video);
                                c["wh"] = json!([i.width, i.height]);
                                c["vcodec"] = json!(i.video_codec);
                                c["acodec"] = json!(i.audio_codec);
                                let e = &job.exp;
                                if let Some((d, tol)) = e.dur {
                                    if (i.duration - d).abs() > tol {
                                        problems.push(format!("durata {:.2} s, attesa {d} ± {tol}", i.duration));
                                    }
                                }
                                if let Some(a) = e.audio {
                                    if i.has_audio != a {
                                        problems.push(format!("audio presente = {}, atteso {a}", i.has_audio));
                                    }
                                }
                                if let Some(v) = e.video {
                                    if i.has_video != v {
                                        problems.push(format!("video presente = {}, atteso {v}", i.has_video));
                                    }
                                }
                                if let Some(wh) = e.wh {
                                    if (i.width, i.height) != wh {
                                        problems.push(format!("misura {}x{}, attesa {}x{}", i.width, i.height, wh.0, wh.1));
                                    }
                                }
                                if let Some(h) = e.h {
                                    if i.height != h {
                                        problems.push(format!("altezza {}, attesa {h}", i.height));
                                    }
                                }
                            }
                            Err(e) => problems.push(format!("il risultato non si legge: {}", e.0)),
                        }
                    }
                    checks.push(c);
                    let _ = std::fs::remove_file(&copy);
                }
            }
            if let Some(b) = res["pbad"].as_array() {
                if !b.is_empty() {
                    problems.push(format!("avanzamento fuori scala: {:?}", b.iter().take(5).collect::<Vec<_>>()));
                }
            }
            if !leftovers.is_empty() {
                problems.push(format!("avanzi nella cartella: {}", leftovers.join(", ")));
            }
            let esito = if problems.is_empty() { "OK" } else if hang { "BLOCCATO" } else { "FALLITO" };
            if problems.is_empty() {
                passed += 1;
            } else {
                failed += 1;
            }
            let line = json!({"tag": tag, "loc": loc.name, "job": job.label, "action": job.action, "esito": esito, "secs": wall,
                "errore": res["error"], "outputs": outs, "controlli": checks, "problemi": problems, "pmax": res["pmax"], "atteso_errore": loc.expect_fail});
            writeln!(results, "{line}").unwrap();
            let msg = if loc.expect_fail && ok == false { format!(" | messaggio: {}", res["error"].as_str().unwrap_or("")) } else { String::new() };
            let row = format!("| {} | {} | {} | {:.1} s | {}{} |\n", loc.name, job.label, esito, wall, problems.join("; ").replace('|', "/"), msg.replace('|', "/"));
            print!("{row}");
            std::io::stdout().flush().ok();
            summary.push_str(&row);
            // Pulizia: i risultati riusciti si tolgono (spazio e nomi)
            if !loc.readonly || loc.out_dir.is_some() {
                for o in &outs {
                    let _ = std::fs::remove_file(o);
                }
            }
        }
    }
    let head = format!("# W05 · {tag}\n\nLavori: {n} · riusciti: {passed} · con problemi: {failed}\n\n## Cartelle\n{env_notes}\n| cartella | lavoro | esito | tempo | problemi |\n|---|---|---|---|---|\n");
    std::fs::write(report.join(format!("riassunto-{tag}.md")), head + &summary).unwrap();
    println!("FINE {tag}: {n} lavori, {passed} ok, {failed} con problemi");
}
