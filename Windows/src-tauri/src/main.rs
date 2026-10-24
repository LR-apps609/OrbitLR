// OrbitLR per Windows: la finestra. Il lavoro vero lo fa `orbit_engine`, in thread a parte,
// così la finestra non si blocca mai; l'avanzamento arriva come eventi.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use base64::Engine as _;
use orbit_engine::{actions, probe, run_action, Cancel, Ctx, FileInfo, Tools};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager, State};

struct AppState {
    tools: Option<Tools>,
    /// whisper-cli.exe (dentro l'app) e cartella dei dati (dove va il modello)
    voice_exe: Option<PathBuf>,
    data_dir: PathBuf,
    /// Parole già trascritte (per i sottotitoli automatici del montaggio): percorso → frasi
    words_cache: Mutex<HashMap<String, Vec<orbit_engine::whisper::Segment>>>,
    jobs: Mutex<HashMap<String, Cancel>>,
    thumbs: Mutex<HashMap<String, String>>,
    /// Miniature in preparazione: al massimo 3 insieme (500 foto trascinate non bloccano il PC)
    thumb_slots: (Mutex<usize>, std::sync::Condvar),
    /// I file creati da OrbitLR: solo questi si possono aprire con un clic
    made: Mutex<std::collections::HashSet<String>>,
}

/// Aspetta un posto libero per una miniatura; lo restituisce quando si esce.
struct Slot<'a>(&'a (Mutex<usize>, std::sync::Condvar));
impl<'a> Slot<'a> {
    fn take(s: &'a (Mutex<usize>, std::sync::Condvar)) -> Slot<'a> {
        let mut n = s.0.lock().unwrap();
        while *n >= 3 {
            n = s.1.wait(n).unwrap();
        }
        *n += 1;
        Slot(s)
    }
}
impl Drop for Slot<'_> {
    fn drop(&mut self) {
        *self.0 .0.lock().unwrap() -= 1;
        self.0 .1.notify_one();
    }
}

type Shared = Arc<AppState>;

#[derive(Serialize)]
struct EngineStatus {
    ready: bool,
    version: String,
    h264: Vec<String>,
    hevc: Vec<String>,
}

/// Un percorso vero, di un file che esiste (niente percorsi di dispositivi o cartelle).
fn checked_file(p: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(p);
    let low = p.to_ascii_lowercase().replace('/', "\\");
    // Niente dispositivi, percorsi speciali di Windows o «pipe» di rete: solo file veri
    let device = low.starts_with(r"\\.\") || low.starts_with(r"\\?\") || low.contains("globalroot") || low.split('\\').nth(3) == Some("pipe");
    if !path.is_absolute() || device || p.contains('\0') {
        return Err("percorso non valido".into());
    }
    if !path.is_file() {
        return Err(format!("non trovo «{}» (spostato o cancellato?)", path.file_name().unwrap_or_default().to_string_lossy()));
    }
    Ok(path)
}

#[tauri::command]
async fn engine_status(state: State<'_, Shared>) -> Result<EngineStatus, String> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || match &st.tools {
        Some(t) => {
            let e = t.encoders();
            EngineStatus { ready: true, version: t.version(), h264: e.h264.clone(), hevc: e.hevc.clone() }
        }
        None => EngineStatus { ready: false, version: String::new(), h264: vec![], hevc: vec![] },
    })
    .await
    .map_err(|e| e.to_string())
}

#[derive(Serialize)]
struct Probed {
    ok: bool,
    info: Option<FileInfo>,
    error: Option<String>,
    path: String,
}

/// Legge i file trascinati. Le cartelle si aprono (un livello) e si prendono i file dentro.
#[tauri::command]
async fn probe_files(app: tauri::AppHandle, state: State<'_, Shared>, paths: Vec<String>) -> Result<Vec<Probed>, String> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut list: Vec<PathBuf> = Vec::new();
        for p in paths.iter().take(2000) {
            let pb = PathBuf::from(p);
            if pb.is_dir() {
                if let Ok(rd) = std::fs::read_dir(&pb) {
                    let mut inside: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_file()).collect();
                    inside.sort();
                    list.extend(inside.into_iter().filter(|p| !p.file_name().map(|n| n.to_string_lossy().starts_with('.')).unwrap_or(true)));
                }
            } else {
                list.push(pb);
            }
        }
        list.into_iter()
            .take(2000)
            .map(|p| {
                let path = p.to_string_lossy().to_string();
                match checked_file(&path).and_then(|f| probe(st.tools.as_ref(), &f).map_err(|e| e.0)) {
                    Ok(i) => {
                        // L'anteprima (video e audio nella finestra) può leggere solo i file aggiunti
                        let _ = app.asset_protocol_scope().allow_file(&p);
                        Probed { ok: true, info: Some(i), error: None, path }
                    }
                    Err(e) => Probed { ok: false, info: None, error: Some(e), path },
                }
            })
            .collect()
    })
    .await
    .map_err(|e| e.to_string())
}

/// Miniatura (JPEG in data URL), ricordata finché il file non cambia.
#[tauri::command]
async fn thumbnail(state: State<'_, Shared>, path: String, side: u32) -> Result<Option<String>, String> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let Ok(p) = checked_file(&path) else { return None };
        let mtime = std::fs::metadata(&p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
        let key = format!("{path}|{mtime}|{side}");
        if let Some(t) = st.thumbs.lock().unwrap().get(&key) {
            return Some(t.clone());
        }
        let side = side.clamp(48, 640);
        let _slot = Slot::take(&st.thumb_slots);
        let kind = orbit_engine::probe::kind_of_ext(&orbit_engine::names::ext(&p));
        let bytes = match kind {
            orbit_engine::Kind::Image => orbit_engine::images::thumbnail(st.tools.as_ref(), &p, side).ok(),
            orbit_engine::Kind::Video => {
                let t = st.tools.as_ref()?;
                let d = probe(Some(t), &p).map(|i| i.duration).unwrap_or(0.0);
                orbit_engine::video::thumbnail(t, &p, d, side).ok()
            }
            _ => None,
        }?;
        let url = format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes));
        let mut cache = st.thumbs.lock().unwrap();
        if cache.len() > 400 {
            cache.clear();
        }
        cache.insert(key, url.clone());
        Some(url)
    })
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
async fn waveform(state: State<'_, Shared>, path: String, points: usize) -> Result<Vec<f32>, String> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let p = checked_file(&path)?;
        let t = st.tools.as_ref().ok_or("manca il motore audio")?;
        let d = probe(Some(t), &p).map_err(|e| e.0)?.duration;
        orbit_engine::audio::waveform(t, &p, d, points).map_err(|e| e.0)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Clone, Serialize)]
struct JobEvent {
    id: String,
    /// «progress», «file», «done»
    kind: String,
    progress: f64,
    index: usize,
    outputs: Vec<actions::Output>,
    error: Option<String>,
    state: String,
}

/// Avvia un lavoro: per ogni file (o una volta sola per «unisci»). Torna subito; l'avanzamento arriva come eventi «job».
#[tauri::command]
fn start_job(app: tauri::AppHandle, state: State<'_, Shared>, id: String, action: String, files: Vec<String>, param: Value, out_dir: Option<String>) -> Result<(), String> {
    if files.is_empty() && action != "tts" {
        return Err("nessun file".into());
    }
    let files: Vec<PathBuf> = files.iter().map(|f| checked_file(f)).collect::<Result<_, _>>()?;
    let out_dir = match out_dir.filter(|s| !s.is_empty()) {
        Some(d) => {
            let p = PathBuf::from(&d);
            if !p.is_absolute() {
                return Err("cartella non valida".into());
            }
            std::fs::create_dir_all(&p).map_err(|_| "non riesco a creare la cartella di destinazione".to_string())?;
            Some(p)
        }
        None => None,
    };
    if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("lavoro non valido".into());
    }
    let cancel = Cancel::new();
    state.jobs.lock().unwrap().insert(id.clone(), cancel.clone());
    let st = state.inner().clone();
    std::thread::Builder::new()
        .name(format!("lavoro-{id}"))
        .spawn(move || {
            let ctx = Ctx { tools: st.tools.clone(), out_dir };
            let emit = |e: JobEvent| {
                let _ = app.emit("job", e);
            };
            // Testo in voce: nessun file di partenza, va in Download (o nella cartella scelta)
            if action == "tts" {
                let dir = ctx.out_dir.clone().or_else(|| app.path().download_dir().ok()).unwrap_or_else(std::env::temp_dir);
                let text = param["text"].as_str().unwrap_or("").to_string();
                let voice = param["voice"].as_str().filter(|v| !v.is_empty()).map(String::from);
                let rate = param["rate"].as_i64().unwrap_or(0) as i32;
                let r = match &ctx.tools {
                    Some(t) => orbit_engine::speech::speak(t, &text, voice.as_deref(), rate, &dir, &cancel, &mut |p| {
                        emit(JobEvent { id: id.clone(), kind: "progress".into(), progress: p, index: 0, outputs: vec![], error: None, state: "running".into() });
                    }),
                    None => Err(orbit_engine::EngineError::new("manca il motore audio")),
                };
                let state = match r {
                    Ok(p) => {
                        st.made.lock().unwrap().insert(p.to_string_lossy().to_string());
                        emit(JobEvent { id: id.clone(), kind: "file".into(), progress: 1.0, index: 0, outputs: vec![actions::Output::of(&p)], error: None, state: "running".into() });
                        "done"
                    }
                    Err(e) if e.is_cancelled() => "cancelled",
                    Err(e) => {
                        emit(JobEvent { id: id.clone(), kind: "file".into(), progress: 1.0, index: 0, outputs: vec![], error: Some(e.0), state: "running".into() });
                        "failed"
                    }
                };
                st.jobs.lock().unwrap().remove(&id);
                emit(JobEvent { id, kind: "done".into(), progress: 1.0, index: 1, outputs: vec![], error: None, state: state.into() });
                return;
            }
            // Trascrivi: prima (una volta sola) il modello, poi testo e sottotitoli
            if action == "transcribe" {
                let lang = param["lang"].as_str().unwrap_or("auto").to_string();
                let n = files.len();
                let (mut ok, mut failed) = (0, 0);
                let need_model = !orbit_engine::whisper::model_ready(&st.data_dir);
                for (i, f) in files.iter().enumerate() {
                    if cancel.is_cancelled() {
                        break;
                    }
                    let mut last = std::time::Instant::now();
                    let mut prog = |p: f64| {
                        if last.elapsed().as_millis() >= 150 || p >= 1.0 {
                            last = std::time::Instant::now();
                            emit(JobEvent { id: id.clone(), kind: "progress".into(), progress: (i as f64 + p) / n as f64, index: i, outputs: vec![], error: None, state: "running".into() });
                        }
                    };
                    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> orbit_engine::error::Result<Vec<PathBuf>> {
                        let t = st.tools.as_ref().ok_or_else(|| orbit_engine::EngineError::new("manca il motore audio"))?;
                        let exe = st.voice_exe.clone().ok_or_else(|| orbit_engine::EngineError::new("manca il motore della voce: reinstalla OrbitLR"))?;
                        let model = if need_model && i == 0 {
                            orbit_engine::whisper::download_model(&st.data_dir, &cancel, &mut |p| prog(p * 0.4))?
                        } else {
                            orbit_engine::whisper::model_path(&st.data_dir)
                        };
                        let off = if need_model && i == 0 { 0.4 } else { 0.0 };
                        let info = probe(Some(t), f)?;
                        let dir = ctx.out_dir.clone().unwrap_or_else(|| f.parent().map(Path::to_path_buf).unwrap_or_default());
                        orbit_engine::whisper::transcribe_files(t, &exe, &model, f, &info, &lang, &dir, &cancel, &mut |p| prog(off + p * (1.0 - off)))
                    }))
                    .unwrap_or_else(|_| Err(orbit_engine::EngineError::new("errore imprevisto: segnalalo con «Segnala», per favore")));
                    match r {
                        Ok(outs) => {
                            ok += 1;
                            let outs: Vec<actions::Output> = outs.iter().map(|p| actions::Output::of(p)).collect();
                            st.made.lock().unwrap().extend(outs.iter().map(|o| o.path.clone()));
                            emit(JobEvent { id: id.clone(), kind: "file".into(), progress: (i + 1) as f64 / n as f64, index: i, outputs: outs, error: None, state: "running".into() });
                        }
                        Err(e) if e.is_cancelled() => break,
                        Err(e) => {
                            failed += 1;
                            emit(JobEvent { id: id.clone(), kind: "file".into(), progress: (i + 1) as f64 / n as f64, index: i, outputs: vec![], error: Some(e.0), state: "running".into() });
                        }
                    }
                }
                let state = if cancel.is_cancelled() { "cancelled" } else if failed > 0 && ok == 0 { "failed" } else { "done" };
                st.jobs.lock().unwrap().remove(&id);
                emit(JobEvent { id, kind: "done".into(), progress: 1.0, index: n, outputs: vec![], error: None, state: state.into() });
                return;
            }
            let groups: Vec<Vec<PathBuf>> = if actions::is_multi(&action) || (action == "to:pdf" && files.len() > 1 && files.iter().all(|f| orbit_engine::probe::kind_of_ext(&orbit_engine::names::ext(f)) == orbit_engine::Kind::Image)) {
                vec![files.clone()]
            } else {
                files.iter().map(|f| vec![f.clone()]).collect()
            };
            let n = groups.len();
            let (mut ok, mut failed) = (0, 0);
            for (i, g) in groups.iter().enumerate() {
                if cancel.is_cancelled() {
                    break;
                }
                let mut last = std::time::Instant::now();
                let mut progress = |p: f64| {
                    if last.elapsed().as_millis() >= 120 || p >= 1.0 {
                        last = std::time::Instant::now();
                        emit(JobEvent { id: id.clone(), kind: "progress".into(), progress: (i as f64 + p) / n as f64, index: i, outputs: vec![], error: None, state: "running".into() });
                    }
                };
                // Un errore imprevisto non chiude l'app: il lavoro finisce come «non riuscito»
                let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_action(&ctx, &action, g, &param, &cancel, &mut progress)))
                    .unwrap_or_else(|_| Err(orbit_engine::EngineError::new("errore imprevisto: segnalalo con «Segnala», per favore")));
                match r {
                    Ok(outs) => {
                        ok += 1;
                        st.made.lock().unwrap().extend(outs.iter().map(|o| o.path.clone()));
                        emit(JobEvent { id: id.clone(), kind: "file".into(), progress: (i + 1) as f64 / n as f64, index: i, outputs: outs, error: None, state: "running".into() });
                    }
                    Err(e) if e.is_cancelled() => break,
                    Err(e) => {
                        failed += 1;
                        emit(JobEvent { id: id.clone(), kind: "file".into(), progress: (i + 1) as f64 / n as f64, index: i, outputs: vec![], error: Some(e.0), state: "running".into() });
                    }
                }
            }
            let state = if cancel.is_cancelled() { "cancelled" } else if failed > 0 && ok == 0 { "failed" } else { "done" };
            st.jobs.lock().unwrap().remove(&id);
            emit(JobEvent { id, kind: "done".into(), progress: 1.0, index: n, outputs: vec![], error: None, state: state.into() });
        })
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// «Interrompi e chiudi»: ferma tutto, cancella i file a metà, poi chiude.
#[tauri::command]
fn quit_now(app: tauri::AppHandle, state: State<'_, Shared>) {
    let jobs: Vec<Cancel> = state.jobs.lock().unwrap().values().cloned().collect();
    for c in &jobs {
        c.cancel();
    }
    // Un attimo per lasciare cancellare i file a metà
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !state.jobs.lock().unwrap().is_empty() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    app.exit(0);
}

#[tauri::command]
fn cancel_job(state: State<'_, Shared>, id: String) {
    if let Some(c) = state.jobs.lock().unwrap().get(&id) {
        c.cancel();
    }
}

#[tauri::command]
async fn voices() -> Result<Vec<orbit_engine::speech::Voice>, String> {
    tauri::async_runtime::spawn_blocking(|| orbit_engine::speech::voices().map_err(|e| e.0)).await.map_err(|e| e.to_string())?
}

/// Un testo del montaggio disegnato dalla finestra (PNG in base64): si salva nella cartella dell'app.
#[tauri::command]
fn save_overlay(app: tauri::AppHandle, png_base64: String) -> Result<String, String> {
    if png_base64.len() > 60_000_000 {
        return Err("immagine troppo grande".into());
    }
    let data = base64::engine::general_purpose::STANDARD.decode(png_base64.trim_start_matches("data:image/png;base64,")).map_err(|_| "immagine non valida".to_string())?;
    if !data.starts_with(&[137, 80, 78, 71]) {
        return Err("non è un PNG".into());
    }
    let dir = app.path().app_cache_dir().map_err(|e| e.to_string())?.join("testi");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let p = dir.join(format!("testo-{n}.png"));
    std::fs::write(&p, data).map_err(|e| e.to_string())?;
    Ok(p.to_string_lossy().to_string())
}

/// Apre un file creato da OrbitLR con il suo programma (solo quelli: niente .exe o .bat a caso).
#[tauri::command]
fn open_result(app: tauri::AppHandle, state: State<'_, Shared>, path: String) -> Result<(), String> {
    let known = state.made.lock().unwrap().contains(&path);
    let ext = orbit_engine::names::ext(Path::new(&path));
    const SAFE: &[&str] = &["jpg", "jpeg", "png", "webp", "avif", "bmp", "tiff", "tif", "gif", "ico", "pdf", "mp4", "mov", "m4v", "mkv", "webm", "avi",
        "mp3", "m4a", "m4r", "wav", "flac", "ogg", "opus", "aiff", "aac", "txt", "srt"];
    // Solo file creati da OrbitLR in questa sessione o, dalla cronologia, con un'estensione sicura
    let _ = known;
    if !SAFE.contains(&ext.as_str()) {
        return Err("questo file non si apre da qui".into());
    }
    checked_file(&path)?;
    use tauri_plugin_opener::OpenerExt;
    app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
}

/// Le parole dette in un file, con i tempi (per i sottotitoli automatici del montaggio).
/// L'avanzamento arriva come evento «voice-progress»; si interrompe con cancel_job("voce").
#[tauri::command]
async fn transcribe_words(app: tauri::AppHandle, state: State<'_, Shared>, path: String, lang: String, id: String) -> Result<Vec<orbit_engine::whisper::Segment>, String> {
    let st = state.inner().clone();
    let f = checked_file(&path)?;
    if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("lavoro non valido".into());
    }
    // Nella chiave anche la data del file: un file sostituito si riascolta
    let mtime = std::fs::metadata(&f).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let key = format!("{path}|{lang}|{mtime}");
    if let Some(c) = st.words_cache.lock().unwrap().get(&key) {
        return Ok(c.clone());
    }
    let cancel = Cancel::new();
    st.jobs.lock().unwrap().insert(id.clone(), cancel.clone());
    // Si toglie dai lavori in corso comunque vada
    struct Done(Shared, String);
    impl Drop for Done {
        fn drop(&mut self) {
            self.0.jobs.lock().unwrap().remove(&self.1);
        }
    }
    let _done = Done(st.clone(), id);
    let st2 = st.clone();
    let r = tauri::async_runtime::spawn_blocking(move || -> Result<Vec<orbit_engine::whisper::Segment>, String> {
        let t = st2.tools.as_ref().ok_or("manca il motore audio")?;
        let exe = st2.voice_exe.clone().ok_or("manca il motore della voce: reinstalla OrbitLR")?;
        let prog = |stage: &str, p: f64| {
            let _ = app.emit("voice-progress", serde_json::json!({ "stage": stage, "progress": p }));
        };
        let model = if orbit_engine::whisper::model_ready(&st2.data_dir) {
            orbit_engine::whisper::model_path(&st2.data_dir)
        } else {
            orbit_engine::whisper::download_model(&st2.data_dir, &cancel, &mut |p| prog("modello", p)).map_err(|e| e.0)?
        };
        let info = probe(Some(t), &f).map_err(|e| e.0)?;
        orbit_engine::whisper::transcribe(t, &exe, &model, &f, &info, &lang, &cancel, &mut |p| prog("ascolto", p)).map_err(|e| e.0)
    })
    .await
    .map_err(|e| e.to_string())?;
    let segs = r?;
    st.words_cache.lock().unwrap().insert(key, segs.clone());
    Ok(segs)
}

/// Esiste ancora? (per la cronologia)
#[tauri::command]
fn files_exist(paths: Vec<String>) -> Vec<bool> {
    paths.iter().map(|p| Path::new(p).is_file()).collect()
}

#[derive(Serialize)]
struct Startup {
    files: Vec<String>,
    /// Solo per le prove automatiche (variabili ORBIT_PROVA_*)
    tab: Option<String>,
    action: Option<String>,
    param: Option<String>,
}

/// I file con cui è stata aperta l'app («Apri con OrbitLR» da Esplora file) e, nelle prove automatiche,
/// cosa fare con loro.
#[tauri::command]
fn startup() -> Startup {
    let mut files: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with('-') && Path::new(a).exists()).collect();
    if let Ok(list) = std::env::var("ORBIT_PROVA_FILE") {
        files.extend(list.split(';').filter(|p| Path::new(p).is_file()).map(String::from));
    }
    let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    Startup { files, tab: var("ORBIT_PROVA_SCHEDA"), action: var("ORBIT_PROVA_AZIONE"), param: var("ORBIT_PROVA_PARAMETRO") }
}

#[derive(Serialize)]
struct Places {
    downloads: Option<String>,
    desktop: Option<String>,
    documents: Option<String>,
    pictures: Option<String>,
    videos: Option<String>,
    music: Option<String>,
}

#[tauri::command]
fn places(app: tauri::AppHandle) -> Places {
    let p = app.path();
    let s = |r: tauri::Result<PathBuf>| r.ok().map(|x| x.to_string_lossy().to_string());
    Places {
        downloads: s(p.download_dir()),
        desktop: s(p.desktop_dir()),
        documents: s(p.document_dir()),
        pictures: s(p.picture_dir()),
        videos: s(p.video_dir()),
        music: s(p.audio_dir()),
    }
}

fn main() {
    tauri::Builder::default()
        // Una sola OrbitLR: i file aperti dal clic destro arrivano nella finestra che c'è già
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let files: Vec<String> = argv.iter().skip(1).filter(|a| !a.starts_with('-') && Path::new(a).exists()).cloned().collect();
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
            if !files.is_empty() {
                let _ = app.emit("open-files", files);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // ffmpeg dentro l'app (cartella «motori» delle risorse); in sviluppo quello del computer
            let motori = app.path().resource_dir().ok().map(|d| d.join("motori"));
            let tools = Tools::locate(motori.as_deref());
            // I codificatori si provano subito, in sottofondo: al primo «Comprimi» sono già pronti
            if let Some(t) = tools.clone() {
                std::thread::spawn(move || {
                    let _ = t.encoders();
                });
            }
            // Testi disegnati per montaggi di più di un giorno fa: via
            if let Ok(cache) = app.path().app_cache_dir() {
                let dir = cache.join("testi");
                std::thread::spawn(move || {
                    if let Ok(rd) = std::fs::read_dir(&dir) {
                        for e in rd.flatten() {
                            let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).map(|d| d.as_secs() > 86_400).unwrap_or(false);
                            if old {
                                let _ = std::fs::remove_file(e.path());
                            }
                        }
                    }
                });
            }
            // File temporanei rimasti da una chiusura a metà lavoro: via
            if let Ok(data) = app.path().app_data_dir() {
                let _ = std::fs::create_dir_all(&data);
                orbit_engine::names::set_temp_registry(data.join("temporanei.txt"));
                std::thread::spawn(orbit_engine::names::cleanup_leftovers);
            }
            let res = app.path().resource_dir().ok();
            let voice_exe = res.map(|d| d.join("motori").join("voce").join(if cfg!(windows) { "whisper-cli.exe" } else { "whisper-cli" }))
                .filter(|p| p.is_file())
                .or_else(|| std::env::var_os("ORBIT_WHISPER").map(PathBuf::from).filter(|p| p.is_file()));
            // Il modello della voce (190 MB) nella cartella locale, non in quella che si sincronizza
            let data_dir = app.path().app_local_data_dir().unwrap_or_else(|_| std::env::temp_dir().join("OrbitLR"));
            app.manage(Arc::new(AppState {
                voice_exe,
                data_dir,
                words_cache: Mutex::new(HashMap::new()),
                tools,
                jobs: Mutex::new(HashMap::new()),
                thumbs: Mutex::new(HashMap::new()),
                thumb_slots: (Mutex::new(0), std::sync::Condvar::new()),
                made: Mutex::new(std::collections::HashSet::new()),
            }));
            Ok(())
        })
        .on_window_event(|window, event| {
            // Chiudendo la finestra con dei lavori in corso: prima si chiede
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let st = window.state::<Shared>();
                let busy = !st.jobs.lock().unwrap().is_empty();
                if busy {
                    api.prevent_close();
                    let _ = window.emit("close-requested", ());
                }
            }
        })
        .invoke_handler(tauri::generate_handler![engine_status, probe_files, thumbnail, waveform, start_job, cancel_job, files_exist, places, startup, quit_now, voices, save_overlay, open_result, transcribe_words])
        .run(tauri::generate_context!())
        .expect("OrbitLR non è riuscita ad avviarsi");
}
