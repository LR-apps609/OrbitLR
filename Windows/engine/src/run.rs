use crate::error::{explain_ffmpeg, EngineError, Result};
use crate::tools::Tools;
use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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

    if let Some(out) = stdout {
        let mut last = -1.0;
        for line in BufReader::new(out).lines().map_while(|l| l.ok()) {
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
    if cancel.is_cancelled() {
        return Err(EngineError::cancelled());
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
