//! «Audio Downloader» e «Video Downloader», come sul Mac: incolli un link, OrbitLR scarica l'audio (M4A)
//! o il video (MP4 fino a 1080p) con yt-dlp (licenza Unlicense), scaricato dal sito ufficiale la prima volta
//! e controllato con l'elenco ufficiale delle impronte. Si aggiorna da solo ogni 14 giorni.
//! I siti protetti (DRM: Netflix, Spotify…) non si scaricano e non si aggira la protezione.

use crate::error::{EngineError, Result};
use crate::run::Cancel;
use crate::tools::Tools;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BASE: &str = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/";
const EXE: &str = if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp" };
const ASSET: &str = if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp" };
/// Oltre questa misura il file scaricato non può essere yt-dlp.
const MAX_BYTES: u64 = 80_000_000;
const REFRESH_SECS: u64 = 14 * 24 * 3600;

static ONE: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Audio,
    Video,
    VideoBest,
}

impl Mode {
    pub fn parse(s: &str) -> Mode {
        match s {
            "video" => Mode::Video,
            "videoBest" | "best" => Mode::VideoBest,
            _ => Mode::Audio,
        }
    }
}

pub fn exe_path(data_dir: &Path) -> PathBuf {
    data_dir.join("motori").join(EXE)
}

/// Un link valido: http/https, senza spazi, con un dominio vero.
pub fn link_from(text: &str) -> Option<String> {
    let t = text.trim();
    if t.is_empty() || t.contains(char::is_whitespace) {
        return None;
    }
    let lower = t.to_lowercase();
    let rest = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://"))?;
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit('@').next().unwrap_or(host).split(':').next().unwrap_or("");
    if host.contains('.') && !host.starts_with('.') && !host.ends_with('.') { Some(t.to_string()) } else { None }
}

pub fn format_args(mode: Mode) -> Vec<&'static str> {
    match mode {
        Mode::Audio => vec!["-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", "--audio-quality", "0"],
        Mode::Video => vec![
            "-f",
            "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b",
            "--merge-output-format",
            "mp4",
        ],
        Mode::VideoBest => vec!["-f", "bv*+ba/b", "-S", "res,vcodec:h264,acodec:m4a", "--merge-output-format", "mp4/mkv"],
    }
}

/// Un messaggio chiaro dagli errori di yt-dlp (in inglese).
pub fn friendly(stderr: &str, video: bool) -> String {
    let s = stderr.to_lowercase();
    if s.contains("drm") {
        return "Questo sito protegge i suoi contenuti (DRM): non si possono scaricare.".into();
    }
    if s.contains("unsupported url") {
        return if video { "Da questo link non so prendere il video. Prova con il link diretto del video.".into() } else { "Da questo link non so prendere l’audio. Prova con il link diretto della canzone.".into() };
    }
    if s.contains("private") || s.contains("sign in") || s.contains("login") || s.contains("members") {
        return "Il contenuto è privato o richiede l’accesso: non si può scaricare.".into();
    }
    if s.contains("not available") || s.contains("unavailable") || s.contains("removed") {
        return "Il contenuto non è più disponibile.".into();
    }
    if s.contains("403") || s.contains("429") {
        return "Il sito ha rifiutato la richiesta. Riprova tra un po’: intanto aggiorno il motore.".into();
    }
    if s.contains("unable to download") || s.contains("network") || s.contains("timed out") || s.contains("resolve") {
        return "Non riesco a collegarmi: controlla internet e riprova.".into();
    }
    if video { "Non sono riuscito a scaricare il video da questo link.".into() } else { "Non sono riuscito a scaricare l’audio da questo link.".into() }
}

/// L'impronta del file nell'elenco ufficiale («impronta  nome»).
pub fn expected_hash(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut it = l.split_whitespace();
        let h = it.next()?;
        let n = it.next()?.trim_start_matches('*');
        (n == name && h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit())).then(|| h.to_lowercase())
    })
}

/// La percentuale da una riga di yt-dlp («[download]  45.3% of …»).
pub fn percent(line: &str) -> Option<f64> {
    let l = line.trim();
    if !l.starts_with("[download]") {
        return None;
    }
    let p = l.split_whitespace().find(|w| w.ends_with('%'))?;
    p.trim_end_matches('%').parse::<f64>().ok().map(|v| (v / 100.0).clamp(0.0, 1.0))
}

fn agent() -> ureq::Agent {
    let secs = |n| Some(std::time::Duration::from_secs(n));
    ureq::Agent::config_builder()
        .proxy(ureq::Proxy::try_from_env())
        .timeout_connect(secs(20))
        .timeout_recv_response(secs(30))
        .timeout_per_read(secs(60))
        .build()
        .into()
}

fn needs_refresh(exe: &Path) -> bool {
    match exe.metadata().and_then(|m| m.modified()) {
        Ok(t) => t.elapsed().map(|d| d.as_secs() > REFRESH_SECS).unwrap_or(false),
        Err(_) => true,
    }
}

/// yt-dlp pronto (scaricato o aggiornato se serve). Se l'aggiornamento non riesce, si usa quello che c'è.
pub fn ensure(data_dir: &Path, force: bool, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    use sha2::{Digest, Sha256};
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    let exe = exe_path(data_dir);
    let have = exe.is_file();
    if have && !force && !needs_refresh(&exe) {
        return Ok(exe);
    }
    let mut attempt = || -> Result<()> {
        let ag = agent();
        let sums = ag
            .get(&format!("{BASE}SHA2-256SUMS"))
            .call()
            .and_then(|mut r| r.body_mut().read_to_string())
            .map_err(|e| EngineError::new(format!("non riesco a scaricare il motore del downloader (serve internet): {e}")))?;
        let want = expected_hash(&sums, ASSET).ok_or_else(|| EngineError::new("l’elenco ufficiale delle impronte non contiene il motore del downloader"))?;
        let mut resp = ag
            .get(&format!("{BASE}{ASSET}"))
            .call()
            .map_err(|e| EngineError::new(format!("non riesco a scaricare il motore del downloader (serve internet): {e}")))?;
        let total = resp.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(20_000_000);
        std::fs::create_dir_all(exe.parent().unwrap_or(Path::new(".")))?;
        let part = exe.with_extension("parziale");
        let mut file = std::fs::File::create(&part)?;
        let mut reader = resp.body_mut().as_reader();
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 256 * 1024];
        let mut got = 0u64;
        let res = (|| -> Result<()> {
            loop {
                if cancel.is_cancelled() {
                    return Err(EngineError::cancelled());
                }
                let n = reader.read(&mut buf).map_err(|e| EngineError::new(format!("scaricamento interrotto: {e}")))?;
                if n == 0 {
                    break;
                }
                got += n as u64;
                if got > MAX_BYTES {
                    return Err(EngineError::new("il motore del downloader scaricato non è quello giusto (troppo grande)"));
                }
                file.write_all(&buf[..n])?;
                hasher.update(&buf[..n]);
                progress((got as f64 / total.max(1) as f64).min(0.999));
            }
            file.flush()?;
            let h: String = hasher.finalize_reset().iter().map(|b| format!("{b:02x}")).collect();
            if h != want {
                return Err(EngineError::new("il motore del downloader scaricato non è quello giusto (impronta diversa): riprova più tardi"));
            }
            Ok(())
        })();
        drop(file);
        if let Err(e) = res {
            let _ = std::fs::remove_file(&part);
            return Err(e);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755));
        }
        let _ = std::fs::remove_file(&exe);
        std::fs::rename(&part, &exe)?;
        Ok(())
    };
    match attempt() {
        Ok(()) => {
            progress(1.0);
            Ok(exe)
        }
        Err(e) if e.is_cancelled() => Err(e),
        // Aggiornamento non riuscito ma il motore c'è: si va avanti con quello
        Err(_) if have => Ok(exe),
        Err(e) => Err(e),
    }
}

/// Scarica dal link dentro `folder`. Restituisce il file creato.
pub fn download(exe: &Path, tools: Option<&Tools>, link: &str, mode: Mode, folder: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    let link = link_from(link).ok_or_else(|| EngineError::new("questo non sembra un link: copialo intero, con https://"))?;
    let work = std::env::temp_dir().join(format!("orbitlr-link-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)));
    std::fs::create_dir_all(&work)?;
    struct Rm(PathBuf);
    impl Drop for Rm {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _rm = Rm(work.clone());
    let mut cmd = Command::new(exe);
    cmd.args(["--no-playlist", "--no-warnings", "--newline", "--progress", "--no-mtime", "--no-part", "--encoding", "utf-8"]);
    cmd.args(format_args(mode));
    cmd.arg("-o").arg(work.join("%(title).120B.%(ext)s"));
    cmd.args(["--print", "after_move:filepath"]);
    if let Some(t) = tools {
        if let Some(d) = t.ffmpeg.parent() {
            cmd.arg("--ffmpeg-location").arg(d);
        }
    }
    cmd.arg("--").arg(&link);
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    cmd.env("PYTHONIOENCODING", "utf-8");
    let mut child = crate::tools::quiet(cmd).spawn().map_err(|e| EngineError::new(format!("il downloader non parte: {e}")))?;
    crate::tools::bind_to_app(&child);
    let stderr = child.stderr.take();
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = e.read_to_string(&mut s);
        }
        s
    });
    let stdout = child.stdout.take().ok_or_else(|| EngineError::new("il downloader non risponde"))?;
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let out_thread = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(|l| l.ok()) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut last_path: Option<String> = None;
    // Audio: scarica, poi converte; video: due pezzi (immagine e suono), poi unisce
    let mut pass = 0usize;
    let mut last_p = 0.0f64;
    loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::cancelled());
        }
        match rx.recv_timeout(std::time::Duration::from_millis(200)) {
            Ok(line) => {
                if let Some(p) = percent(&line) {
                    if p + 0.2 < last_p {
                        pass += 1;
                    }
                    last_p = p;
                    let share = if mode == Mode::Audio { 0.9 } else { 0.45 };
                    progress(((pass.min(1) as f64) * share + p * share).min(0.95));
                } else if !line.starts_with('[') && !line.trim().is_empty() {
                    last_path = Some(line.trim().to_string());
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let status = child.wait()?;
    let _ = out_thread.join();
    let err = err_thread.join().unwrap_or_default();
    let video = mode != Mode::Audio;
    if !status.success() {
        return Err(EngineError::new(friendly(&err, video)));
    }
    let made = last_path
        .map(PathBuf::from)
        .filter(|p| p.is_file())
        .or_else(|| std::fs::read_dir(&work).ok()?.filter_map(|e| e.ok().map(|e| e.path())).find(|p| p.is_file()))
        .ok_or_else(|| EngineError::new(friendly(&err, video)))?;
    let name = made.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "download".into());
    let stem = Path::new(&name).file_stem().map(|s| crate::names::safe_name(&s.to_string_lossy())).unwrap_or_else(|| "download".into());
    let ext = made.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| if video { "mp4".into() } else { "m4a".into() });
    std::fs::create_dir_all(folder)?;
    let dest = crate::names::unique(folder, &stem, &ext);
    if std::fs::rename(&made, &dest).is_err() {
        std::fs::copy(&made, &dest)?;
    }
    progress(1.0);
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_validi() {
        assert!(link_from("https://www.youtube.com/watch?v=abc").is_some());
        assert!(link_from("  https://youtu.be/abc  ").is_some());
        assert!(link_from("ciao mondo").is_none());
        assert!(link_from("ftp://x.com/a").is_none());
        assert!(link_from("https://localhost/a").is_none());
    }

    #[test]
    fn impronte_e_percentuali() {
        let sums = "aaaa  yt-dlp\nabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  yt-dlp.exe\n";
        assert_eq!(expected_hash(sums, "yt-dlp.exe").as_deref(), Some("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"));
        assert!(expected_hash(sums, "yt-dlp").is_none());
        assert!((percent("[download]  45.3% of   3.21MiB at  1.2MiB/s ETA 00:02").unwrap() - 0.453).abs() < 1e-9);
        assert_eq!(percent("[ExtractAudio] Destination: x.m4a"), None);
    }

    #[test]
    fn messaggi_chiari() {
        assert!(friendly("ERROR: This video is DRM protected", true).contains("DRM"));
        assert!(friendly("ERROR: Unsupported URL: https://x", false).contains("audio"));
        assert!(friendly("ERROR: Unsupported URL: https://x", true).contains("video"));
    }
}
