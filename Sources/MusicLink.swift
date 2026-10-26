import SwiftUI
import AppKit
import CryptoKit
import AVFoundation

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
            if FileManager.default.fileExists(atPath: exe.path) {
                _ = try FileManager.default.replaceItemAt(exe, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: exe)        // la prima volta non c'è niente da sostituire
            }
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
        // Netflix, Disney+, Prime Video, Spotify…: contenuti cifrati, non si scaricano (e non si aggira la protezione)
        if s.contains("drm") { return "Questo sito protegge i suoi contenuti (DRM): non si possono scaricare." }
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

    /// 4.1.3 · Come scaricare: solo l'audio (M4A), il video in MP4 fino a 1080p (si apre ovunque),
    /// o il video alla massima qualità che c'è (anche 4K, a volte in formati da convertire).
    enum Mode: String { case audio, video, videoBest }

    static func formatArgs(_ mode: Mode) -> [String] {
        switch mode {
        case .audio:
            return ["-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", "--audio-quality", "0"]
        case .video:
            return ["-f", "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b",
                    "--merge-output-format", "mp4"]
        case .videoBest:
            return ["-f", "bv*+ba/b", "-S", "res,vcodec:h264,acodec:m4a", "--merge-output-format", "mp4/mkv"]
        }
    }

    /// Scarica dal link dentro `folder` (audio M4A o video). Restituisce il file.
    static func download(_ link: URL, to folder: URL, job: LinkJob, mode: Mode = .audio) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let p = Process()
        p.executableURL = exe
        var args = ["--no-playlist", "--no-warnings", "--newline", "--progress", "--no-mtime", "--no-part"]
            + formatArgs(mode)
            + ["-o", work.appendingPathComponent("%(title).120B.%(ext)s").path, "--print", "after_move:filepath"]
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
            guard !d.isEmpty else { return }
            // 4.1.4 · Righe intere: un blocco letto può fermarsi a metà riga
            for line in collected.feed(d, isErr: isErr) {
                if let v = percent(in: line) { Task { @MainActor in job.progress = v } }
                collected.add(line, isErr: isErr)
            }
        }
        out.fileHandleForReading.readabilityHandler = { handle($0, false) }
        err.fileHandleForReading.readabilityHandler = { handle($0, true) }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        try p.run()
        await MainActor.run { job.process = p }
        // «Interrompi» premuto mentre partiva
        if await job.cancelled { p.terminate(); p.waitUntilExit(); throw CancellationError() }
        let start = Date()
        while p.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(start) > 900 {
                p.terminate()
                p.waitUntilExit()
                throw Failure(message: "Ci mette troppo: riprova più tardi.")
            }
        }
        // 4.1.4 · Quello che è rimasto nei tubi dopo la fine (l'ultima riga è proprio il file scaricato)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        for (h, isErr) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
            for line in collected.feed(h.readDataToEndOfFile(), isErr: isErr, flush: true) { collected.add(line, isErr: isErr) }
        }
        if await job.cancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            let e = collected.errors
            if e.contains("403") || e.contains("429") { try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: exe.path) }
            throw Failure(message: friendly(e))
        }
        // Il file: quello stampato da yt-dlp, altrimenti l'unico nella cartella di lavoro
        let printed = collected.lines.reversed().first { $0.hasPrefix(work.path) && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        let made = printed ?? (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first
        guard let made, FileManager.default.fileExists(atPath: made.path) else { throw Failure(message: "Non ho trovato l’audio scaricato.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = made.lastPathComponent
        // Un video in un formato che il Mac non apre da solo (VP9, AV1 su Mac vecchi): con l'estensione .mkv
        // OrbitLR lo riconosce e lo prepara in MP4 aprendolo nella scheda Video
        if mode != .audio, !(try await AVURLAsset(url: made).load(.isPlayable)) {
            name = (name as NSString).deletingPathExtension + ".mkv"
        }
        let dest = uniqueURL(in: folder, name: name)
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
        private var partial: [Bool: Data] = [:]

        /// I nuovi dati di un tubo → le righe complete (il pezzo finale senza «a capo» aspetta il prossimo blocco).
        func feed(_ d: Data, isErr: Bool, flush: Bool = false) -> [String] {
            lock.lock(); defer { lock.unlock() }
            var buf = (partial[isErr] ?? Data()) + d
            var lines: [String] = []
            while let i = buf.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                if !line.isEmpty { lines.append(line) }
                buf = Data(buf[buf.index(after: i)...])
            }
            if flush, !buf.isEmpty { lines.append(String(decoding: buf, as: UTF8.self)); buf = Data() }
            partial[isErr] = buf
            return lines
        }
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
    /// 4.1.3 · Video (scheda Video) o solo audio (scheda Audio)
    var video = false
    /// 4.1.6 · Il link scritto nella barra in alto: la finestrella parte subito con quello
    var initial = ""
    let onDone: (URL) -> Void
    let close: () -> Void
    @State private var text = ""
    @State private var best = false
    @StateObject private var job = LinkJob()

    private var link: URL? { MusicLink.link(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video ? "Video Downloader" : "Audio Downloader").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Funziona con migliaia di siti · incolla il link").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextField(video ? "Incolla qui il link del video" : "Incolla qui il link della canzone", text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(job.running)
                .onSubmit { if link != nil { start() } }
            if video {
                Picker("Qualità", selection: $best) {
                    Text("MP4 fino a 1080p · si apre ovunque").tag(false)
                    Text("Massima qualità (anche 4K)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(job.running)
                if best {
                    Text("Il 4K spesso arriva in un formato che il Mac non apre da solo: OrbitLR lo converte in MP4, e ci vuole più tempo.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if job.running {
                ProgressBar(value: job.progress > 0 ? job.progress : -1, tint: Theme.color(.audio))
                Text(job.status).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let e = job.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(video ? "Solo contenuti che hai il diritto di scaricare: tuoi, liberi o con il permesso di chi li ha creati. Il video arriva in Download e si apre qui, pronto da tagliare, comprimere o montare."
                       : "Solo contenuti che hai il diritto di scaricare: tuoi, liberi o con il permesso di chi li ha creati. L’audio arriva in Download e si apre qui, pronto per suoneria, taglio e conversione.")
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
            if MusicLink.link(from: initial) != nil {
                text = initial.trimmingCharacters(in: .whitespacesAndNewlines)
                start()
            } else if let s = NSPasteboard.general.string(forType: .string), MusicLink.link(from: s) != nil {
                // Un link già copiato: si propone da solo
                text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
                if job.cancelled { throw CancellationError() }
                let mode: MusicLink.Mode = video ? (best ? .videoBest : .video) : .audio
                await MainActor.run { job.status = video ? "Scarico il video…" : "Scarico l’audio…"; job.progress = 0 }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Paths.home
                let file = try await MusicLink.download(link, to: downloads, job: job, mode: mode)
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

/// 4.1.5 · Sotto lo spazio vuoto di Audio e Video: «oppure incolla un link → Audio/Video Downloader».
struct DownloaderRow: View {
    let video: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.color(video ? .video : .audio))
                Text("oppure incolla un link →").foregroundStyle(.secondary)
                Text(video ? "Video Downloader" : "Audio Downloader").fontWeight(.semibold)
                Text("· funziona con migliaia di siti").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.ink.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// 4.1.6 · In alto a destra in Audio e Video: «Audio/Video Downloader» ben visibile, il campo per il link e «Scarica».
struct DownloaderBar: View {
    let video: Bool
    let go: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var tint: Color { Theme.color(video ? .video : .audio) }
    private var ok: Bool { MusicLink.link(from: text) != nil }

    var body: some View {
        // Finestra stretta: l'etichetta si accorcia, il campo per il link resta
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
            // Finestra molto stretta: solo il pulsante, che apre la finestrella per il link
            Button { go("") } label: {
                Label(video ? "Video Downloader" : "Audio Downloader", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(tint))
            }
            .buttonStyle(.plain)
            .fixedSize()
            // 4.1.7 · Ancora più stretta (tanti pulsanti accanto): solo l'icona colorata
            Button { go("") } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(6).background(Circle().fill(tint))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(video ? "Video Downloader · incolla un link" : "Audio Downloader · incolla un link")
        }
    }

    private func bar(full: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if full {
                    Label(video ? "Video Downloader" : "Audio Downloader", systemImage: "arrow.down.circle.fill")
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
            }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(tint)
                .fixedSize()
                .help(video ? "Video Downloader" : "Audio Downloader")
            TextField("Incolla un link · funziona con migliaia di siti", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(minWidth: full ? 230 : 150, idealWidth: 290, maxWidth: 320)
                .onSubmit { submit() }
            Button(action: submit) {
                Text("Scarica").font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(ok ? .white : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ok ? tint : Theme.ink.opacity(0.08))
            }
            .buttonStyle(.plain)
            .help("Scarica dal link (oppure premi Invio)")
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(focused ? 0.9 : 0.55), lineWidth: 1.5))
        .shadow(color: tint.opacity(0.25), radius: 6, y: 1)
        .accessibilityElement(children: .contain)
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        go(t)               // con un link valido parte subito; altrimenti si apre la finestrella per incollarlo
        if MusicLink.link(from: t) != nil { text = "" }
    }
}
