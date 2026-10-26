//! «Manda al telefono», come sul Mac: il file creato si scarica sul telefono inquadrando un codice QR,
//! sulla stessa rete Wi-Fi. Un piccolo server sul computer, con un indirizzo segreto, per 15 minuti.
//! Niente passa da internet.

use crate::error::{EngineError, Result};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const LIFETIME: Duration = Duration::from_secs(15 * 60);

pub struct Share {
    pub url: String,
    pub svg: String,
    stop: Arc<AtomicBool>,
}

impl Share {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// L'indirizzo del computer nella rete di casa (senza mandare niente: si chiede solo la strada al sistema).
pub fn lan_ip() -> Option<std::net::IpAddr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.168.1.1:9").ok().or_else(|| s.connect("8.8.8.8:80").ok())?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

fn token() -> String {
    let mut b = [0u8; 12];
    if getrandom::fill(&mut b).is_err() {
        let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(1);
        b.copy_from_slice(&n.to_le_bytes()[..12]);
    }
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn url_escape(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// La pagina che si apre sul telefono: il nome del file e un grande pulsante per scaricarlo.
pub fn page(name: &str, size: u64, en: bool) -> String {
    let (title, button, hint) = if en {
        ("OrbitLR · download", "Download", if name.to_lowercase().ends_with(".m4r") { "iPhone: open the file in Files → Share → “Use as Ringtone” (or use GarageBand)." } else { "The file goes to your phone’s Downloads." })
    } else {
        ("OrbitLR · scarica", "Scarica", if name.to_lowercase().ends_with(".m4r") { "iPhone: apri il file in File → Condividi → «Usa come suoneria» (oppure con GarageBand)." } else { "Il file va nei Download del telefono." })
    };
    let mb = crate::actions::fmt_bytes(size);
    format!(
        "<!doctype html><html lang=\"{}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>{title}</title>\
<style>body{{font-family:system-ui,sans-serif;background:#f4f2ea;color:#2f3328;margin:0;padding:32px 20px;display:grid;gap:16px;justify-items:center;text-align:center}}\
.f{{font-weight:800;font-size:18px;word-break:break-all}}.s{{color:#6b6e5f}}a{{display:inline-block;background:#4a6b55;color:#fff;text-decoration:none;font-weight:800;font-size:18px;padding:14px 28px;border-radius:14px}}p{{max-width:420px;color:#6b6e5f}}</style></head>\
<body><div class=\"f\">{}</div><div class=\"s\">{mb}</div><a href=\"file/{}\" download>{button}</a><p>{hint}</p></body></html>",
        if en { "en" } else { "it" },
        html_escape(name),
        url_escape(name)
    )
}

fn respond(mut s: TcpStream, status: &str, ctype: &str, body: &[u8], extra: &str) {
    let head = format!("HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n", body.len());
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body);
}

fn serve_file(mut s: TcpStream, path: &Path, name: &str) {
    let Ok(mut f) = std::fs::File::open(path) else { return respond(s, "404 Not Found", "text/plain", b"", "") };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let ascii: String = name.chars().map(|c| if c.is_ascii() && c != '"' && c != '\\' { c } else { '_' }).collect();
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {len}\r\nContent-Disposition: attachment; filename=\"{ascii}\"; filename*=UTF-8''{}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        url_escape(name)
    );
    if s.write_all(head.as_bytes()).is_err() {
        return;
    }
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        match f.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if s.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }
}

/// Avvia la condivisione di `file`. `en`: la pagina sul telefono in inglese.
pub fn share(file: &Path, en: bool) -> Result<Share> {
    let meta = std::fs::metadata(file).map_err(|_| EngineError::new("il file non c'è più"))?;
    if !meta.is_file() {
        return Err(EngineError::new("il file non c'è più"));
    }
    let ip = lan_ip().ok_or_else(|| EngineError::new("il computer non è collegato a una rete: collegalo al Wi-Fi di casa, lo stesso del telefono"))?;
    let listener = TcpListener::bind("0.0.0.0:0").map_err(|e| EngineError::new(format!("non riesco ad aprire la condivisione: {e}")))?;
    let port = listener.local_addr().map_err(|e| EngineError::new(e.to_string()))?.port();
    listener.set_nonblocking(true).map_err(|e| EngineError::new(e.to_string()))?;
    let tok = token();
    let url = format!("http://{ip}:{port}/{tok}/");
    let svg = qr_svg(&url)?;
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let path: PathBuf = file.to_path_buf();
    let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "file".into());
    let size = meta.len();
    std::thread::Builder::new()
        .name("telefono".into())
        .spawn(move || {
            let until = Instant::now() + LIFETIME;
            while Instant::now() < until && !stop2.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((s, _)) => {
                        let _ = s.set_nonblocking(false);
                        let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
                        let mut line = String::new();
                        let mut r = BufReader::new(match s.try_clone() {
                            Ok(c) => c,
                            Err(_) => continue,
                        });
                        if r.read_line(&mut line).is_err() {
                            continue;
                        }
                        // Il resto delle intestazioni non serve
                        let mut h = String::new();
                        while r.read_line(&mut h).map(|n| n > 2).unwrap_or(false) {
                            h.clear();
                        }
                        let target = line.split_whitespace().nth(1).unwrap_or("");
                        let base = format!("/{tok}/");
                        if line.starts_with("GET ") && target == base {
                            respond(s, "200 OK", "text/html; charset=utf-8", page(&name, size, en).as_bytes(), "");
                        } else if line.starts_with("GET ") && target.starts_with(&format!("{base}file/")) {
                            serve_file(s, &path, &name);
                        } else {
                            respond(s, "404 Not Found", "text/plain", b"", "");
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(150)),
                    Err(_) => std::thread::sleep(Duration::from_millis(300)),
                }
            }
        })
        .map_err(|e| EngineError::new(e.to_string()))?;
    Ok(Share { url, svg, stop })
}

/// Il codice QR dell'indirizzo, come immagine SVG.
pub fn qr_svg(text: &str) -> Result<String> {
    let code = qrcode::QrCode::new(text.as_bytes()).map_err(|_| EngineError::new("non riesco a creare il codice QR"))?;
    Ok(code.render::<qrcode::render::svg::Color>().min_dimensions(220, 220).quiet_zone(true).build())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pagina_e_qr() {
        let p = page("canzone <1>.m4r", 1_200_000, false);
        assert!(p.contains("canzone &lt;1&gt;.m4r") && p.contains("Usa come suoneria") && p.contains("file/canzone%20%3C1%3E.m4r"));
        assert!(page("a.mp3", 10, true).contains("Download"));
        let svg = qr_svg("http://192.168.1.5:1234/abc/").unwrap();
        assert!(svg.starts_with("<?xml") || svg.contains("<svg"));
    }

    #[test]
    fn scarica_dal_server() {
        if lan_ip().is_none() {
            return; // nessuna rete qui
        }
        let d = std::env::temp_dir().join(format!("orbit-phone-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("prova.txt");
        std::fs::write(&f, b"ciao telefono").unwrap();
        let s = share(&f, false).unwrap();
        let url = s.url.replace("http://", "");
        let (host, rest) = url.split_once('/').unwrap();
        let get = |path: &str| -> String {
            let mut c = TcpStream::connect(host).unwrap();
            write!(c, "GET /{path} HTTP/1.1\r\nHost: {host}\r\n\r\n").unwrap();
            let mut out = String::new();
            c.read_to_string(&mut out).unwrap();
            out
        };
        let page = get(rest);
        assert!(page.contains("200 OK") && page.contains("prova.txt"));
        let file = get(&format!("{rest}file/prova.txt"));
        assert!(file.ends_with("ciao telefono"));
        assert!(get("altro/").contains("404"));
        s.stop();
    }
}
