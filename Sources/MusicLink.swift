import SwiftUI
import AppKit
import CryptoKit

// ════════════════════════════════════════════════════════════════════
//  4.1 · «Da un link…» nella scheda Audio: incolli il link di una canzone, arriva nella scheda come
//  un file normale (suoneria, taglio, conversione…). Discreto: non è una funzione in vetrina.
//
//  Il motore è yt-dlp (licenza Unlicense, libero), NON incluso nell'app: si scarica la prima volta dal
//  sito ufficiale, con l'impronta controllata, e si rinnova da solo ogni due settimane (i siti cambiano
//  spesso). La conversione in M4A la fa l'ffmpeg che è già dentro OrbitLR.
//  Solo contenuti che si ha il diritto di scaricare: lo dice anche la finestra.
// ════════════════════════════════════════════════════════════════════

enum MusicLink {
    static let base = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
    static let asset = "yt-dlp_macos"
    static var dir: URL { Paths.support.appendingPathComponent("bin", isDirectory: true) }
    static var exe: URL { dir.appendingPathComponent("yt-dlp") }
    /// Ogni quanto si rinnova il motore.
    static let refreshAfter: TimeInterval = 14 * 86_400

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Un link vero (http o https), anche con spazi o a capo intorno.
    static func link(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              let h = u.host, h.contains(".") else { return nil }
        return u
    }

    static var installed: Bool { FileManager.default.isExecutableFile(atPath: exe.path) }

    static var needsRefresh: Bool {
        guard let d = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return true }
        return Date().timeIntervalSince(d) > refreshAfter
    }

    /// L'impronta del file nell'elenco ufficiale («impronta  nome»).
    static func expectedHash(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == name, parts[0].count == 64 { return String(parts[0]).lowercased() }
        }
        return nil
    }

    /// Scarica (o rinnova) il motore. Se il rinnovo non riesce, si continua con quello che c'è.
    static func ensureEngine(progress: @escaping @Sendable (String) -> Void) async throws {
        if installed && !needsRefresh { return }
        let hadOne = installed
        do {
            progress(hadOne ? "Aggiorno il motore per i link…" : "Scarico il motore per i link (circa 35 MB, solo la prima volta)…")
            let (sumsData, _) = try await URLSession.shared.data(from: URL(string: base + "SHA2-256SUMS")!)
            guard let sums = String(data: sumsData, encoding: .utf8), let want = expectedHash(in: sums, for: asset) else {
                throw Failure(message: "non riesco a controllare il motore per i link")
            }
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: base + asset)!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "non riesco a scaricare il motore per i link") }
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                try? FileManager.default.removeItem(at: tmp)
                throw Failure(message: "il motore scaricato non è quello ufficiale (impronta diversa): non lo uso")
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let staged = dir.appendingPathComponent("yt-dlp.nuovo")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: tmp, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            _ = try FileManager.default.replaceItemAt(exe, withItemAt: staged)
        } catch {
            if hadOne { return }            // il rinnovo può aspettare: si usa quello che c'è
            throw (error as? Failure) ?? Failure(message: "serve internet per scaricare il motore la prima volta")
        }
    }

    /// «[download]  42.3% of …» → 0,423
    static func percent(in line: String) -> Double? {
        guard line.contains("[download]"), let r = line.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        return Double(line[r].dropLast()).map { min(1, $0 / 100) }
    }

    /// Dagli errori di yt-dlp a una frase che si capisce.
    static func friendly(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("unsupported url") { return "Da questo link non so prendere l’audio. Prova con il link diretto della canzone." }
        if s.contains("private") || s.contains("sign in") || s.contains("login") || s.contains("members") {
            return "Il contenuto è privato o richiede l’accesso: non si può scaricare."
        }
        if s.contains("not available") || s.contains("unavailable") || s.contains("removed") { return "Il contenuto non è più disponibile." }
        if s.contains("403") || s.contains("429") { return "Il sito ha rifiutato la richiesta. Riprova tra un po’: intanto aggiorno il motore." }
        if s.contains("unable to download") || s.contains("network") || s.contains("timed out") || s.contains("resolve") {
            return "Non riesco a collegarmi: controlla internet e riprova."
        }
        return "Non sono riuscito a scaricare l’audio da questo link."
    }

    /// Scarica l'audio del link in M4A dentro `folder`. Restituisce il file.
    static func download(_ link: URL, to folder: URL, job: LinkJob) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let p = Process()
        p.executableURL = exe
        var args = ["--no-playlist", "--no-warnings", "--newline", "--progress", "--no-mtime", "--no-part",
                    "-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", "--audio-quality", "0",
                    "-o", work.appendingPathComponent("%(title).120B.%(ext)s").path,
                    "--print", "after_move:filepath"]
        if let m = Paths.motori { args += ["--ffmpeg-location", m.path] }
        args += ["--", link.absoluteString]
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let collected = Collected()
        let handle: @Sendable (FileHandle, Bool) -> Void = { h, isErr in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(whereSeparator: \.isNewline).map(String.init) {
                if let v = percent(in: line) { Task { @MainActor in job.progress = v } }
                collected.add(line, isErr: isErr)
            }
        }
        out.fileHandleForReading.readabilityHandler = { handle($0, false) }
        err.fileHandleForReading.readabilityHandler = { handle($0, true) }
        try p.run()
        await MainActor.run { job.process = p }
        let start = Date()
        while p.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(start) > 900 { p.terminate(); throw Failure(message: "Ci mette troppo: riprova più tardi.") }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if await job.cancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            let e = collected.errors
            if e.contains("403") || e.contains("429") { try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: exe.path) }
            throw Failure(message: friendly(e))
        }
        // Il file: quello stampato da yt-dlp, altrimenti l'unico nella cartella di lavoro
        let printed = collected.lines.reversed().first { $0.hasPrefix(work.path) }.map { URL(fileURLWithPath: $0) }
        let made = printed ?? (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first
        guard let made, FileManager.default.fileExists(atPath: made.path) else { throw Failure(message: "Non ho trovato l’audio scaricato.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = uniqueURL(in: folder, name: made.lastPathComponent)
        try FileManager.default.moveItem(at: made, to: dest)
        return dest
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var u = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = folder.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return u
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [String] = []
        private var err = ""
        func add(_ l: String, isErr: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isErr { err += l + "\n"; if err.count > 8000 { err = String(err.suffix(8000)) } } else { out.append(l); if out.count > 200 { out.removeFirst() } }
        }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return out }
        var errors: String { lock.lock(); defer { lock.unlock() }; return err }
    }
}

/// Lo stato di uno scaricamento, per la finestra.
@MainActor
final class LinkJob: ObservableObject {
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var running = false
    @Published var error: String? = nil
    var process: Process?
    var cancelled = false

    func cancel() {
        cancelled = true
        process?.terminate()
    }
}

/// La finestrella «Da un link…».
struct LinkSheet: View {
    let onDone: (URL) -> Void
    let close: () -> Void
    @State private var text = ""
    @StateObject private var job = LinkJob()

    private var link: URL? { MusicLink.link(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio da un link").font(.system(size: 17, weight: .bold, design: .rounded))
            TextField("Incolla qui il link della canzone", text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(job.running)
                .onSubmit { if link != nil { start() } }
            if job.running {
                ProgressBar(value: job.progress > 0 ? job.progress : -1, tint: Theme.color(.audio))
                Text(job.status).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let e = job.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Solo contenuti che hai il diritto di scaricare: tuoi, liberi o con il permesso di chi li ha creati. L’audio arriva in Download e si apre qui, pronto per suoneria, taglio e conversione.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(job.running ? "Interrompi" : "Annulla") { if job.running { job.cancel() } else { close() } }
                Button("Scarica") { start() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(link == nil || job.running)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // Un link già copiato: si propone da solo
            if let s = NSPasteboard.general.string(forType: .string), MusicLink.link(from: s) != nil { text = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func start() {
        guard let link else { return }
        job.error = nil
        job.running = true
        job.cancelled = false
        job.progress = 0
        job.status = "Preparo…"
        let job = self.job
        Task {
            do {
                try await MusicLink.ensureEngine { s in Task { @MainActor in job.status = s } }
                await MainActor.run { job.status = "Scarico l’audio…"; job.progress = 0 }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Paths.home
                let file = try await MusicLink.download(link, to: downloads, job: job)
                await MainActor.run {
                    job.running = false
                    Sounds.drop()
                    onDone(file)
                    close()
                }
            } catch is CancellationError {
                await MainActor.run { job.running = false }
            } catch {
                await MainActor.run {
                    job.running = false
                    if !job.cancelled { job.error = error.localizedDescription }
                }
            }
        }
    }
}
