use crate::error::{explain_ffmpeg, EngineError, Result};
use crate::tools::Tools;
use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// «Interrompi»: si può premere da un altro thread in qualsiasi momento.
#[derive(Clone, Default)]
pub struct Cancel(Arc<CancelInner>);

#[derive(Default)]
struct CancelInner {
    flag: AtomicBool,
    child: Mutex<Option<Child>>,
}

impl Cancel {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.flag.store(true, Ordering::SeqCst);
        if let Ok(mut c) = self.0.child.lock() {
            if let Some(ch) = c.as_mut() {
                let _ = ch.kill();
            }
        }
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.flag.load(Ordering::SeqCst)
    }
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() { Err(EngineError::cancelled()) } else { Ok(()) }
    }
}

/// Fa girare ffmpeg con gli argomenti dati (mai attraverso una shell: niente sorprese con nomi strani).
/// `duration` (secondi) serve per l'avanzamento: `progress` riceve valori tra 0 e 1.
pub fn ffmpeg(
    tools: &Tools,
    args: &[OsString],
    duration: f64,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
) -> Result<()> {
    ffmpeg_watched(tools, args, duration, cancel, progress, STALL, STALL_AT_END)
}

/// 2.0.1 · ffmpeg scrive l'avanzamento ogni mezzo secondo. Se per 5 minuti non dice più niente è bloccato
/// (un driver della scheda video, un disco o una rete che non risponde): si ferma e lo si dice, invece di
/// lasciare la barra ferma per sempre. Alla fine (oltre il 98%) si aspetta di più: «faststart» riscrive
/// tutto il file senza dire niente, e su un disco USB lento un file di qualche GB ci mette minuti.
const STALL: Duration = Duration::from_secs(300);
const STALL_AT_END: Duration = Duration::from_secs(1800);

pub(crate) fn ffmpeg_watched(
    tools: &Tools,
    args: &[OsString],
    duration: f64,
    cancel: &Cancel,
    progress: &mut dyn FnMut(f64),
    stall: Duration,
    stall_at_end: Duration,
) -> Result<()> {
    cancel.check()?;
    let mut cmd = tools.ffmpeg_cmd();
    cmd.args(["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]);
    cmd.args(args);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| EngineError::new(format!("non riesco ad avviare il motore video: {e}")))?;
    crate::tools::bind_to_app(&child);
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    *cancel.0.child.lock().unwrap() = Some(child);

    // L'errore si legge a parte, così ffmpeg non si blocca mai su un tubo pieno
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = e.read_to_string(&mut s);
        }
        s
    });

    // L'avanzamento si legge in un thread a parte: così ci si accorge anche quando ffmpeg tace
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let out_thread = stdout.map(|out| {
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(|l| l.ok()) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        })
    });
    let mut stalled = false;
    if out_thread.is_some() {
        let mut last = -1.0;
        let mut heard = Instant::now();
        loop {
            match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(line) => {
                    heard = Instant::now();
                    // out_time_us (e il vecchio out_time_ms) sono microsecondi
                    let v = line
                        .strip_prefix("out_time_us=")
                        .or_else(|| line.strip_prefix("out_time_ms="))
                        .and_then(|v| v.trim().parse::<f64>().ok());
                    if let Some(us) = v {
                        if duration > 0.0 {
                            let p = (us / 1e6 / duration).clamp(0.0, 0.999);
                            if p - last >= 0.005 {
                                last = p;
                                progress(p);
                            }
                        }
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if cancel.is_cancelled() {
                        break;
                    }
                    let limit = if last >= 0.98 { stall_at_end } else { stall };
                    if heard.elapsed() > limit {
                        stalled = true;
                        if let Ok(mut g) = cancel.0.child.lock() {
                            if let Some(ch) = g.as_mut() {
                                let _ = ch.kill();
                            }
                        }
                        break;
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    }

    // Aspetta la fine
    let status = loop {
        let mut guard = cancel.0.child.lock().unwrap();
        let ch = guard.as_mut().expect("processo presente");
        match ch.try_wait() {
            Ok(Some(st)) => {
                *guard = None;
                break st;
            }
            Ok(None) => {
                drop(guard);
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                *guard = None;
                return Err(EngineError::new(format!("il motore video non risponde: {e}")));
            }
        }
    };
    let err = err_thread.join().unwrap_or_default();
    if let Some(t) = out_thread {
        let _ = t.join();
    }
    if cancel.is_cancelled() {
        return Err(EngineError::cancelled());
    }
    if stalled {
        let min = (stall.as_secs() + 59) / 60;
        return Err(EngineError::new(format!("il motore video non risponde da {min} minut{}: l'ho fermato. Riprova; se succede ancora, riavvia il computer (può essere il driver della scheda video)", if min == 1 { "o" } else { "i" })));
    }
    if !status.success() {
        return Err(EngineError::new(explain_ffmpeg(&err)));
    }
    progress(1.0);
    Ok(())
}

/// Comodo per scrivere gli argomenti: `args!["-i", path, "-c", "copy"]`.
#[macro_export]
macro_rules! args {
    ($($x:expr),* $(,)?) => {{
        let v: Vec<std::ffi::OsString> = vec![$(std::ffi::OsString::from($x)),*];
        v
    }};
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2.0.1 · ffmpeg che resta zitto (qui aspetta un collegamento che non arriva mai) viene fermato con un messaggio,
    /// invece di lasciare il lavoro «in corso» per sempre.
    #[test]
    fn ffmpeg_bloccato_si_ferma_e_lo_dice() {
        let dir = std::env::var_os("ORBIT_MOTORI").map(std::path::PathBuf::from);
        let Some(tools) = Tools::locate(dir.as_deref()) else {
            eprintln!("ffmpeg non c'è: prova saltata");
            return;
        };
        let mut pc = tools.ffmpeg_cmd();
        pc.args(["-hide_banner", "-protocols"]);
        let protos = crate::tools::output_timeout(pc, 20).map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
        if !protos.lines().any(|l| l.trim() == "tcp") {
            eprintln!("questo ffmpeg non ha tcp: prova saltata");
            return;
        }
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let cancel = Cancel::new();
        let c2 = cancel.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let a = crate::args!["-f", "mpegts", "-listen", "1", "-i", format!("tcp://127.0.0.1:{port}"), "-f", "null", "-"];
            let r = ffmpeg_watched(&tools, &a, 10.0, &c2, &mut |_| {}, Duration::from_secs(3), Duration::from_secs(3));
            let _ = tx.send(r);
        });
        let r = rx.recv_timeout(Duration::from_secs(40));
        cancel.cancel();
        let e = r.expect("ffmpeg bloccato: il lavoro non è finito da solo").expect_err("doveva fermarsi con un errore");
        assert!(e.0.contains("non risponde"), "{e}");
        assert!(!e.is_cancelled());
    }
}
