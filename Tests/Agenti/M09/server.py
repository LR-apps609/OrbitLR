#!/usr/bin/env python3
"""M09 · Server locale per provare il Downloader di OrbitLR con file generati (nessun contenuto protetto).
Uso: server.py <cartella-con-video.mp4> <porta>
  /video.mp4            il file intero
  /lento/video.mp4      lo stesso file, mandato piano (64 KB ogni 0,25 s): per staccare la rete a metà
  /muto.html            una pagina senza video
  /lungo.html           pagina con un <video> e un titolo lunghissimo con emoji
  /mancante.mp4         404
"""
import http.server, os, sys, time, html

ROOT = sys.argv[1]
PORT = int(sys.argv[2])
TITLE = ("Prova di un titolo davvero molto lungo con emoji 🎬🎵🔥🇮🇹 e accenti àèìòù " * 4).strip() + " 😀"

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): sys.stderr.write("srv: " + (a[0] % a[1:]) + "\n")
    def send_file(self, slow):
        p = os.path.join(ROOT, "video.mp4"); n = os.path.getsize(p)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4"); self.send_header("Content-Length", str(n))
        self.send_header("Accept-Ranges", "none"); self.end_headers()
        if self.command == "HEAD": return
        with open(p, "rb") as f:
            while True:
                b = f.read(65536 if slow else 1 << 20)
                if not b: break
                self.wfile.write(b); self.wfile.flush()
                if slow: time.sleep(0.25)
    def page(self, body):
        b = body.encode("utf-8")
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        if self.command != "HEAD": self.wfile.write(b)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/video.mp4": return self.send_file(False)
        if path == "/lento/video.mp4": return self.send_file(True)
        if path == "/muto.html":
            return self.page("<!doctype html><html><head><title>Pagina senza video</title></head><body><p>Qui non c'è nessun video.</p></body></html>")
        if path == "/lungo.html":
            t = html.escape(TITLE)
            return self.page(f'<!doctype html><html><head><meta charset="utf-8"><title>{t}</title>'
                             f'<meta property="og:title" content="{t}"></head><body>'
                             f'<video controls src="http://127.0.0.1:{PORT}/video.mp4"></video></body></html>')
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

http.server.ThreadingHTTPServer.allow_reuse_address = True
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
