import Foundation
import AppKit
import SwiftUI
import Network
import CoreImage

// ════════════════════════════════════════════════════════════════════
//  2.9.5 · Manda all'iPhone.
//  Sotto la suoneria appena creata: AirDrop, oppure un codice QR da
//  inquadrare con l'iPhone (stessa rete Wi-Fi). Sull'iPhone, con iOS 26:
//  apri il file → Condividi → «Usa come suoneria».
//  Il file parte come .m4a (stesso contenuto della .m4r), il formato che
//  l'iPhone riconosce sempre come audio.
// ════════════════════════════════════════════════════════════════════

enum SendToPhone {
    /// Copia da mandare: stesso audio, estensione .m4a. Resta nella cartella di supporto, non tra i tuoi file.
    static func shareCopy(of file: URL) throws -> URL {
        let dir = Paths.support.appendingPathComponent("Da mandare", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " (suoneria)", with: "")
        let out = dir.appendingPathComponent(name + ".m4a")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: file, to: out)
        return out
    }

    static func airDrop(_ file: URL) {
        guard let copy = try? shareCopy(of: file),
              let s = NSSharingService(named: .sendViaAirDrop) else { NSSound.beep(); return }
        s.perform(withItems: [copy])
    }

    /// L'indirizzo del Mac nella rete di casa (Wi-Fi o cavo), es. 192.168.1.23.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(a.ifa_flags) & IFF_UP) != 0, (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: a.ifa_name), String(cString: host)))
        }
        // Prima en0 (di solito il Wi-Fi), poi le altre reti private
        let priv = found.filter { $0.1.hasPrefix("192.168.") || $0.1.hasPrefix("10.") || $0.1.hasPrefix("172.") }
        return (priv.first { $0.0 == "en0" } ?? priv.first ?? found.first)?.1
    }

    static func qrImage(_ text: String, side: CGFloat = 220) -> NSImage? {
        let f = CIFilter(name: "CIQRCodeGenerator")
        f?.setValue(Data(text.utf8), forKey: "inputMessage")
        f?.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f?.outputImage else { return nil }
        let k = side / out.extent.width
        let big = out.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = Media.ci.createCGImage(big, from: big.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}

/// Un piccolo server sulla rete di casa che offre un solo file per qualche minuto.
/// L'indirizzo ha un codice casuale: senza il QR non si indovina.
final class PhoneShare: ObservableObject, @unchecked Sendable {
    @Published private(set) var url: String? = nil
    @Published private(set) var error: String? = nil
    @Published private(set) var downloaded = false
    private var listener: NWListener?
    private var file: URL?
    /// 3.5.2 · 128 bit casuali: impossibile da indovinare
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let queue = DispatchQueue(label: "orbitlr.phoneshare")
    private var stopTimer: DispatchWorkItem?

    /// Per quanto resta acceso (poi si spegne da solo).
    static let lifetime: TimeInterval = 10 * 60

    func start(_ original: URL) {
        stop()
        error = nil
        downloaded = false
        guard let copy = try? SendToPhone.shareCopy(of: original) else { error = "Non riesco a preparare il file"; return }
        guard let ip = SendToPhone.localAddress() else { error = "Il Mac non è collegato a una rete Wi-Fi"; return }
        file = copy
        do {
            // 3.5.2 · In ascolto solo sull'indirizzo della rete di casa, non su tutte le reti del Mac
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    let port = l.port?.rawValue ?? 0
                    DispatchQueue.main.async { self.url = "http://\(ip):\(port)/\(self.token)/" }
                case .failed:
                    DispatchQueue.main.async { self.error = "Non riesco ad aprire la condivisione"; self.url = nil }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
            let w = DispatchWorkItem { [weak self] in self?.stop() }
            stopTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: w)
        } catch {
            self.error = "Non riesco ad aprire la condivisione"
        }
    }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        listener?.cancel()
        listener = nil
        url = nil
        // 3.5.2 · La copia preparata per l'iPhone non resta sul Mac
        if let f = file, f.path.hasPrefix(Paths.support.path) { try? FileManager.default.removeItem(at: f) }
        file = nil
    }

    deinit { listener?.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.respond(to: path, on: c)
        }
    }

    private func respond(to path: String, on c: NWConnection) {
        guard let file, path == "/\(token)" || path.hasPrefix("/\(token)/") else {
            send(c, status: "404 Not Found", type: "text/plain; charset=utf-8", body: Data("Non trovato".utf8))
            return
        }
        let name = file.lastPathComponent
        if path.hasSuffix("/file.m4a") {
            guard let body = try? Data(contentsOf: file) else {
                send(c, status: "404 Not Found", type: "text/plain; charset=utf-8", body: Data("Non trovato".utf8)); return
            }
            let ascii = name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "suoneria.m4a"
            send(c, status: "200 OK", type: "audio/mp4",
                 extra: "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\n", body: body)
            DispatchQueue.main.async {
                self.downloaded = true
                // 3.5.2 · Scaricata: la condivisione si spegne da sola poco dopo (un minuto per riprovare)
                self.stopTimer?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.stop() }
                self.stopTimer = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
            }
        } else {
            send(c, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page(name: name, link: "/\(token)/file.m4a").utf8))
        }
    }

    private func send(_ c: NWConnection, status: String, type: String, extra: String = "", body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += extra + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// La pagina che si apre sull'iPhone: un pulsante e i due passaggi.
    static func page(name: String, link: String) -> String {
        let safe = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html lang="it"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Suoneria da OrbitLR</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;background:#F3EDDF;color:#3A3126;margin:0;padding:28px 22px}
        h1{font-size:22px;margin:0 0 4px}.n{color:#7d7366;font-size:14px;margin-bottom:22px;word-break:break-word}
        a.b{display:block;text-align:center;background:#5E7F63;color:#fff;text-decoration:none;font-weight:600;
        font-size:17px;padding:15px;border-radius:14px}
        ol{background:#fffaf0;border-radius:14px;padding:16px 16px 16px 36px;margin-top:22px;line-height:1.55;font-size:15px}
        .f{margin-top:18px;font-size:12px;color:#9a8f80}
        </style></head><body>
        <h1>La tua suoneria</h1><div class="n">\(safe)</div>
        <a class="b" href="\(link)">Scarica la suoneria</a>
        <ol><li>Tocca <b>Scarica</b>: il file va in <b>File → Download</b>.</li>
        <li>Aprilo, tocca <b>Condividi</b> e scegli <b>Usa come suoneria</b> (in fondo all'elenco o in «Altro»).</li>
        <li>La trovi in <b>Impostazioni → Suoni</b>.</li></ol>
        <div class="f">Serve iOS 26 o più recente. Con iOS precedenti: collega l'iPhone al Mac e trascina il file .m4r nel Finder.</div>
        </body></html>
        """
    }
}

// MARK: - Sotto la suoneria pronta

struct SendToPhoneStrip: View {
    @ObservedObject var job: Job
    @StateObject private var share = PhoneShare()
    @State private var showQR = false

    private var file: URL? { job.outputs.first { $0.pathExtension.lowercased() == "m4r" } }

    var body: some View {
        if job.action.id == "ringtone", job.state == .done, let file {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Manda all’iPhone").font(.system(size: 12.5, weight: .semibold))
                        Text("Poi sull’iPhone: apri il file → Condividi → «Usa come suoneria» (iOS 26)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { SendToPhone.airDrop(file) } label: { Label("AirDrop", systemImage: "dot.radiowaves.left.and.right") }
                        .help("Manda la suoneria all’iPhone con AirDrop")
                    Button {
                        if share.url == nil { share.start(file) }
                        showQR = true
                    } label: { Label("Codice QR", systemImage: "qrcode") }
                    .help("Inquadralo con la fotocamera dell’iPhone (stessa rete Wi-Fi)")
                    .popover(isPresented: $showQR, arrowEdge: .top) { qrPopover }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .card(radius: 12)
            .onDisappear { share.stop() }
        }
    }

    private var qrPopover: some View {
        VStack(spacing: 12) {
            Text("Inquadra con l’iPhone").font(.headline)
            if let u = share.url, let img = SendToPhone.qrImage(u) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
                    .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                if share.downloaded {
                    Label("Scaricata sull’iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        .font(.system(size: 12, weight: .semibold))
                }
            } else if let e = share.error {
                Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).frame(width: 220, height: 220)
            } else {
                ProgressView().frame(width: 220, height: 220)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Apri la Fotocamera e inquadra il codice").font(.system(size: 11.5))
                Text("2. Tocca «Scarica la suoneria»").font(.system(size: 11.5))
                Text("3. Apri il file → Condividi → «Usa come suoneria»").font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)
            Text("Mac e iPhone sulla stessa rete Wi-Fi · resta attivo 10 minuti")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 280)
    }
}
