import Foundation
import AppKit
import AVFoundation
import UserNotifications

final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    /// 3.5.2 · Azioni il cui parametro è una password: mai in cronologia, mai tra gli argomenti
    static let secretActions: Set<String> = ["protect", "unprotect"]
    enum State { case waiting, running, done, failed, cancelled }

    let id = UUID()
    let files: [URL]
    let action: Action
    let param: String
    let created = Date()

    @Published var state: State = .waiting
    @Published var progress: Double = -1          // -1 = in corso senza percentuale
    @Published var status = String(localized: "In attesa")
    @Published var outputs: [URL] = []
    /// Ogni errore entra già tradotto in una frase chiara con la soluzione (FriendlyError).
    @Published var failures: [String] = [] {
        didSet {
            // 4.1.7 · Si traducono solo gli errori nuovi (prima: tutti a ogni aggiunta, lentissimo con migliaia di file)
            let start = failures.count >= oldValue.count && Array(failures.prefix(oldValue.count)) == oldValue ? oldValue.count : 0
            guard start < failures.count else { return }
            var changed = false
            var f = failures
            for i in start..<f.count {
                let t = EngineText.localized(FriendlyError.text(f[i]))      // 4.2 · anche i messaggi del motore in inglese
                if t != f[i] { f[i] = t; changed = true }
            }
            if changed { failures = f }
        }
    }
    @Published var notes: [String] = []
    @Published var info = ""

    var process: Process?
    var cancelRequested = false
    /// 3.2 · Cosa fare quando il lavoro finisce bene (il passo successivo di una ricetta).
    var then: ((Job) -> Void)? = nil
    var renames: [[String]]? = nil      // per «Rinomina in serie»: coppie [vecchio, nuovo], per poter annullare
    var exportSession: AVAssetExportSession?   // conversioni fatte da macOS, per poterle annullare
    var native = false
    var forceClassic = false                   // «Riprova con il motore classico»
    @Published var missing: [String] = []      // programmi mancanti segnalati dal motore
    /// Cartella di destinazione solo per questo lavoro (es. cartelle automatiche); altrimenti valgono le Opzioni.
    var destOverride: URL? = nil
    /// 3.9.2 · Lo segue la nuvoletta della torta: niente notifica di macOS doppia
    var quietNotify = false
    var startedAt: Date? = nil
    /// Secondi previsti, in base a quanto ci hanno messo lavori simili su questo Mac.
    var expectedSeconds: Double = 0
    /// Avanzamento stimato, quando il motore non dice la percentuale: la barra si riempie comunque.
    @Published var estimate: Double = 0
    let beforeBytes: Int64

    init(files: [URL], action: Action, param: String) {
        self.files = files
        self.action = action
        self.param = param
        self.beforeBytes = files.filter { Catalog.kind(of: $0) != .sub }.reduce(Int64(0)) { $0 + Job.size(of: $1) }
    }

    var kind: Kind? { mainFiles.first.flatMap { Catalog.kind(of: $0) } }

    /// L'avanzamento da mostrare: quello vero se il motore lo dice, altrimenti la stima.
    /// 5.1 · «circa 2 min», calcolato da quanto si è fatto finora. Nil se è troppo presto per dirlo.
    var remainingText: String? {
        guard state == .running, let s = startedAt else { return nil }
        let p = shownProgress, el = Date().timeIntervalSince(s)
        guard p > 0.05, p < 0.995, el > 4 else { return nil }
        let left = el / p * (1 - p)
        if left < 50 { return String(localized: "meno di un minuto") }
        let m = Int((left / 60).rounded())
        if m < 60 { return String(localized: "circa \(m) min") }
        let h = Int(left / 3600), mm = Int(left.truncatingRemainder(dividingBy: 3600) / 60)
        return String(localized: "circa \(h) h \(mm) min")
    }

    /// Stato con il tempo rimasto, per le righe dei lavori in corso.
    var statusWithTime: String {
        guard let r = remainingText else { return status }
        return status + " · " + r
    }

    var shownProgress: Double {
        switch state {
        case .waiting: return 0
        case .done: return 1
        // Motori di macOS: la percentuale è precisa. Motore classico: spesso dice solo «file 1 di 3»,
        // quindi si usa la stima a tempo, senza mai tornare indietro rispetto a quanto detto dal motore.
        case .running: return native && progress >= 0 ? progress : max(progress, estimate)
        case .failed, .cancelled: return max(0, progress >= 0 ? progress : estimate)
        }
    }
    /// 4.1.7 · Calcolato una volta a lavoro finito (prima: una lettura del disco per file a ogni ridisegno)
    private var afterCache: (count: Int, bytes: Int64)? = nil
    var afterBytes: Int64 {
        if state == .done || state == .failed || state == .cancelled, let c = afterCache, c.count == outputs.count { return c.bytes }
        let b = outputs.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        if state == .done || state == .failed || state == .cancelled { afterCache = (outputs.count, b) }
        return b
    }

    /// File «veri» (esclusi i .srt passati solo come supporto per i sottotitoli).
    var mainFiles: [URL] { files.filter { Catalog.kind(of: $0) != .sub } }

    var title: String {
        let f = mainFiles
        return f.count == 1 ? f[0].lastPathComponent : String(localized: "\(f.count) file")
    }

    /// 3.1 · Il guadagno in parole: «da 48 MB a 9 MB · −81%». Vuoto se non c'è niente di utile da dire.
    var gainText: String {
        guard state == .done, !outputs.isEmpty else { return "" }       // 4.1.7 · niente letture del disco prima della fine
        return Job.gain(before: beforeBytes, after: afterBytes, done: true)
    }

    static func gain(before: Int64, after: Int64, done: Bool) -> String {
        guard done, before > 0, after > 0 else { return "" }
        let a = Fmt.bytes(before), b = Fmt.bytes(after)
        let pct = Int((Double(before - after) / Double(before) * 100).rounded())
        if pct >= 5 { return String(localized: "da \(a) a \(b) · −\(pct)%") }
        if pct <= -5 { return String(localized: "da \(a) a \(b)") }
        return b
    }

    var sizeText: String {
        guard beforeBytes > 0 else { return "" }
        if state == .done, !outputs.isEmpty {
            return Fmt.bytes(beforeBytes) + " → " + Fmt.bytes(afterBytes)
        }
        return Fmt.bytes(beforeBytes)
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

/// Quanto ci mette questo Mac: secondi per MB, per ogni azione e tipo di file, imparati dai lavori finiti.
/// Serve a riempire la barra in modo realistico quando il motore non dice la percentuale.
enum Estimator {
    private static func key(_ job: Job) -> String { "speed.\(job.action.id).\(job.kind?.rawValue ?? "x")" }

    private static func overhead(_ job: Job) -> Double {
        switch job.kind {
        case .doc?, .sheet?, .slide?, .text?: return 4      // LibreOffice ci mette un po' a partire
        default: return 1.5
        }
    }

    private static func defaultSpeed(_ job: Job) -> Double {
        let id = job.action.id
        if id == "transcribe" { return job.kind == .video ? 3 : 8 }
        if id == "searchable" { return job.kind == .pdf ? 3 : 2 }
        if id == "removebg" || id == "upscale" { return 1.2 }
        if id == "aienhance" { return 40 }
        if id == "stack" { return 1.5 }
        if id == "straighten" { return 0.8 }
        if id == "vcompress" || id == "vresize" { return 2 }
        switch job.kind {
        case .video?: return 1.2
        case .audio?: return 0.4
        case .img?: return 0.15
        case .pdf?: return id == "pdftext" ? 3 : 0.4
        default: return 2
        }
    }

    static func expected(for job: Job) -> Double {
        let mb = max(0.05, Double(job.beforeBytes) / 1_000_000)
        let speed = UserDefaults.standard.object(forKey: key(job)) as? Double ?? defaultSpeed(job)
        return overhead(job) + speed * mb
    }

    static func learn(from job: Job) {
        guard let s = job.startedAt, job.beforeBytes > 0 else { return }
        let mb = max(0.05, Double(job.beforeBytes) / 1_000_000)
        let measured = max(0.005, (Date().timeIntervalSince(s) - overhead(job)) / mb)
        let old = UserDefaults.standard.object(forKey: key(job)) as? Double
        UserDefaults.standard.set(old.map { $0 * 0.5 + measured * 0.5 } ?? measured, forKey: key(job))
    }
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let title: String
    let action: String
    let outputs: [String]
    var undone = false
    var kind: String? = nil
    var before: Int64? = nil
    var after: Int64? = nil
    var renames: [[String]]? = nil
    /// 3.2 · Per le ricette: che azione era, con quali opzioni, su quali file.
    var actionId: String? = nil
    var param: String? = nil
    var inputs: [String]? = nil
}

/// 2.7 · Le statistiche del mese per la Cronologia: quanti file, quanto spazio risparmiato, l'azione preferita.
struct MonthStats: Equatable {
    var files = 0
    var saved: Int64 = 0
    var topAction: String? = nil

    static func of(_ history: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> MonthStats {
        var st = MonthStats()
        var counts: [String: Int] = [:]
        for e in history where !e.undone && calendar.isDate(e.date, equalTo: now, toGranularity: .month) {
            st.files += e.outputs.count
            if let b = e.before, let a = e.after, b > a { st.saved += b - a }
            counts[e.action, default: 0] += 1
        }
        st.topAction = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        return st
    }
}

final class QueueStore: ObservableObject, @unchecked Sendable {
    static let shared = QueueStore()

    @Published var jobs: [Job] = []
    @Published var history: [HistoryEntry] = []

    private let maxParallel = 2

    var isBusy: Bool { jobs.contains { $0.state == .running } }
    var runningJobs: [Job] { jobs.filter { $0.state == .running } }

    init() { loadHistory() }

    // MARK: - Coda

    @discardableResult
    func enqueue(files: [URL], action: Action, param: String, classic: Bool = false, dest: URL? = nil) -> Job {
        let job = Job(files: files, action: action, param: param)
        job.forceClassic = classic
        job.destOverride = dest
        jobs.insert(job, at: 0)
        startNext()
        return job
    }

    func cancel(_ job: Job) {
        job.cancelRequested = true
        job.exportSession?.cancelExport()
        if let p = job.process, p.isRunning { p.terminate() }   // lo script si ferma in modo pulito
        else if job.state == .waiting { job.state = .cancelled; job.status = String(localized: "Interrotto"); objectWillChange.send() }
    }

    func retry(_ job: Job) {
        enqueue(files: job.files, action: job.action, param: job.param, dest: job.destOverride)
    }

    /// Aggiunge alla Cronologia un lavoro fatto fuori dalla Coda (es. «Compila e firma»).
    func record(title: String, action: String, outputs: [URL], kind: Kind?, before: Int64) {
        let after = outputs.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        history.insert(HistoryEntry(date: Date(), title: title, action: action, outputs: outputs.map { $0.path },
                                    kind: kind?.rawValue, before: before, after: after), at: 0)
        saveHistory()
        Sounds.done()
    }

    /// Aggiorna le stime dei lavori senza percentuale (chiamata più volte al secondo mentre si lavora).
    func tickEstimates() {
        let now = Date()
        for j in jobs where j.state == .running && !(j.native && j.progress >= 0) {
            guard let s = j.startedAt else { continue }
            let x = now.timeIntervalSince(s) / max(j.expectedSeconds, 1)
            // Lineare fino all'85% del tempo previsto, poi rallenta senza mai arrivare in fondo
            let f = x < 0.85 ? x : 0.85 + 0.12 * (1 - exp(-(x - 0.85) * 3))
            let v = min(0.97, f)
            if abs(v - j.estimate) > 0.002 { j.estimate = v }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    private func startNext() {
        while jobs.filter({ $0.state == .running }).count < maxParallel,
              let next = jobs.last(where: { $0.state == .waiting }) {
            run(next)
        }
    }

    private func run(_ job: Job) {
        job.state = .running
        job.status = String(localized: "Avvio…")
        job.startedAt = Date()
        job.expectedSeconds = Estimator.expected(for: job)
        job.estimate = 0
        MenuBarIcon.shared.wake()
        objectWillChange.send()
        if job.action.id == "rename" { runRename(job); return }
        if !job.forceClassic && NativeEngine.supports(job) { runNative(job); return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 3.5.2 · Le password non passano tra gli argomenti (che altri programmi possono leggere)
        let secret = Job.secretActions.contains(job.action.id)
        p.arguments = [Paths.script.path, "--run", job.action.id, secret ? "-" : job.param] + job.files.map { $0.path }
        var extra: [String: String] = [:]
        if let d = job.destOverride { extra["LR_DESTPATH"] = d.path }
        if secret { extra["LR_SECRET"] = job.param }
        p.environment = Paths.engineEnvironment(extra)          // 3.8 · con i motori dell'app
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        job.process = p

        var buffer = Data()
        let bufferLock = NSLock()          // 4.1.4 · il tubo e la fine del processo arrivano da thread diversi
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            bufferLock.lock(); defer { bufferLock.unlock() }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    DispatchQueue.main.async { self?.handle(line, for: job) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            // 4.1.4 · Le ultime righe (OUT, FAIL, OK) possono essere ancora nel tubo: si leggono prima di chiudere
            bufferLock.lock()
            buffer.append(out.fileHandleForReading.readDataToEndOfFile())
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                if let line = String(data: buffer.subdata(in: buffer.startIndex..<nl), encoding: .utf8) { lines.append(line) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { lines.append(line) }
            buffer = Data()
            bufferLock.unlock()
            DispatchQueue.main.async {
                for l in lines { self?.handle(l, for: job) }
                self?.verifyThenFinish(job, code: proc.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            job.failures.append(String(localized: "Non riesco ad avviare il motore di conversione"))
            finish(job, code: -1)
        }
    }

    /// Conversioni fatte da macOS: immagini, MP4/MOV, M4A. Nessun programma esterno.
    private func runNative(_ job: Job) {
        job.native = true
        job.status = String(localized: "Con i motori di macOS…")
        let files = job.mainFiles
        if Media.multi.contains(job.action.id) {
            // «Unisci i video» / «Unisci gli audio»: tutti i file insieme, un solo risultato
            job.status = String(localized: "Unisco i file…")
            Task.detached(priority: .userInitiated) {
                do {
                    let dir = job.destOverride ?? Destination.dir(for: files[0])
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let out = try await Media.runMulti(job: job, files: files, dir: dir) { p in
                        DispatchQueue.main.async { job.progress = min(1, max(0, p)) }
                    }
                    await MainActor.run { job.outputs.append(out) }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { if msg != "annullato" { job.failures.append(msg) } }
                }
                await MainActor.run { self.verifyThenFinish(job, code: 0) }
            }
            return
        }
        if job.action.id == "stack" {
            // «Unisci più scatti»: tutti i file insieme danno un solo risultato
            job.status = String(localized: "Allineo e unisco gli scatti…")
            Task {
                do {
                    let dir = job.destOverride ?? Destination.dir(for: files[0])
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let out = try await Stacker.run(files: files, param: job.param, dir: dir) { p in
                        DispatchQueue.main.async { job.progress = min(1, max(0, p)) }
                    }
                    await MainActor.run { job.outputs.append(out) }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { job.failures.append(msg) }
                }
                await MainActor.run { self.verifyThenFinish(job, code: 0) }
            }
            return
        }
        Task {
            for (i, f) in files.enumerated() {
                if job.cancelRequested { break }
                await MainActor.run { job.status = files.count > 1 ? "\(i + 1)/\(files.count) · \(f.lastPathComponent)" : String(localized: "Con i motori di macOS…") }
                do {
                    let out = try await NativeEngine.run(job: job, file: f) { p in
                        DispatchQueue.main.async { job.progress = (Double(i) + min(1, max(0, p))) / Double(max(files.count, 1)) }
                    }
                    await MainActor.run { job.outputs.append(out) }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { if msg != "annullato" { job.failures.append("\(f.lastPathComponent): \(msg)") } }
                }
            }
            await MainActor.run { self.verifyThenFinish(job, code: 0) }
        }
    }

    /// Prima di dire «fatto», controlla che i file creati siano validi. Quelli rotti vanno nel Cestino.
    private func verifyThenFinish(_ job: Job, code: Int32) {
        guard !job.outputs.isEmpty, job.renames == nil else { finish(job, code: code); return }
        job.status = String(localized: "Controllo il risultato…")
        let outs = job.outputs
        Task {
            var bad: [(URL, String)] = []
            for u in outs { if let p = await Verifier.problem(u) { bad.append((u, p)) } }
            let found = bad
            await MainActor.run {
                for (u, p) in found {
                    job.failures.append("\(u.lastPathComponent): \(p)")
                    job.outputs.removeAll { $0 == u }
                    try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                }
                self.finish(job, code: code)
            }
        }
    }

    /// Opzione «Conserva le date originali»: il file creato ha le stesse date dell'originale.
    private func keepDates(_ job: Job) {
        guard UserDefaults.standard.object(forKey: "keepDates") as? Bool ?? true, job.renames == nil else { return }
        let fm = FileManager.default
        for out in job.outputs {
            let name = out.lastPathComponent
            let src = job.mainFiles.first { name.hasPrefix($0.deletingPathExtension().lastPathComponent) }
                ?? (job.mainFiles.count == 1 ? job.mainFiles[0] : nil)
            guard let s = src, let a = try? fm.attributesOfItem(atPath: s.path) else { continue }
            var set: [FileAttributeKey: Any] = [:]
            if let c = a[.creationDate] { set[.creationDate] = c }
            if let m = a[.modificationDate] { set[.modificationDate] = m }
            if !set.isEmpty { try? fm.setAttributes(set, ofItemAtPath: out.path) }
        }
    }

    /// «Rinomina in serie»: lo fa direttamente l'app, senza motore esterno.
    private func runRename(_ job: Job) {
        let parts = job.param.components(separatedBy: "|")
        let base = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "File"
        let first = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        let digits = parts.count > 2 ? (Int(parts[2]) ?? 3) : 3
        let fm = FileManager.default
        let files = job.mainFiles.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var pairs: [[String]] = []
        for (i, f) in files.enumerated() {
            let number = String(format: "%0\(digits)d", first + i)
            let ext = f.pathExtension.isEmpty ? "" : "." + f.pathExtension
            let dir = f.deletingLastPathComponent()
            var target = dir.appendingPathComponent("\(base) \(number)\(ext)")
            var k = 1
            while fm.fileExists(atPath: target.path) && target.standardizedFileURL != f.standardizedFileURL {
                target = dir.appendingPathComponent("\(base) \(number) (\(k))\(ext)")
                k += 1
            }
            if target.standardizedFileURL == f.standardizedFileURL { job.outputs.append(f); continue }
            do {
                try fm.moveItem(at: f, to: target)
                job.outputs.append(target)
                pairs.append([f.path, target.path])
            } catch {
                job.failures.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
            job.progress = Double(i + 1) / Double(max(files.count, 1))
        }
        job.renames = pairs
        finish(job, code: 0)
    }

    private func handle(_ line: String, for job: Job) {
        let f = line.components(separatedBy: "\t")
        guard let tag = f.first else { return }
        func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
        switch tag {
        case "P":
            let v = Double(field(1)) ?? -1
            job.progress = v < 0 ? -1 : min(1, v)
            let text = field(2)
            if !text.isEmpty { job.status = EngineText.localized(text) }
        case "OUT":
            // 3.5.2 · Solo percorsi veri e completi di file che esistono (mai righe inventate da un nome di file)
            let path = field(1)
            if path.hasPrefix("/"), !path.contains("\n"), FileManager.default.fileExists(atPath: path) {
                job.outputs.append(URL(fileURLWithPath: path))
            }
        case "OK":
            if !field(2).isEmpty { job.info = field(2) }
        case "NOTE":
            job.notes.append(EngineText.localized(field(2)))
        case "FAIL":
            let name = field(1) == "-" ? "" : URL(fileURLWithPath: field(1)).lastPathComponent + ": "
            job.failures.append(name + field(2))
        case "MISSING":
            job.missing.append(field(1))
            let tool = field(2).components(separatedBy: ":").first ?? field(1)
            job.failures.append(String(localized: "Manca \(tool) — vedi Componenti"))
        default:
            break
        }
        objectWillChange.send()
    }

    private func finish(_ job: Job, code: Int32) {
        guard job.state == .running || job.state == .waiting else { return }
        job.process = nil
        if job.cancelRequested {
            job.state = .cancelled
            job.status = job.outputs.isEmpty ? String(localized: "Interrotto") : String(localized: "Interrotto (alcuni file sono pronti)")
        } else if !job.outputs.isEmpty {
            job.state = .done
            job.status = job.failures.isEmpty ? (job.native ? String(localized: "Completato con macOS · verificato") : String(localized: "Completato · verificato")) : String(localized: "Completato in parte")
        } else if !job.notes.isEmpty && job.failures.isEmpty {
            job.state = .done
            job.status = job.notes.first ?? String(localized: "Niente da fare")
        } else {
            job.state = .failed
            job.status = job.failures.first.map { String(localized: "Non riuscito · \($0)") } ?? String(localized: "Non riuscito")
        }
        job.progress = job.state == .done ? 1 : job.progress
        if job.state == .done, job.failures.isEmpty { Estimator.learn(from: job) }
        if !job.outputs.isEmpty {
            history.insert(HistoryEntry(date: Date(), title: job.title, action: job.action.title,
                                        outputs: job.outputs.map { $0.path }, kind: job.kind?.rawValue,
                                        before: job.renames == nil ? job.beforeBytes : nil,
                                        after: job.renames == nil ? job.afterBytes : nil,
                                        renames: job.renames, actionId: job.action.id,
                                        param: Job.secretActions.contains(job.action.id) ? "" : job.param,   // 3.5.2 · mai password in cronologia
                                        inputs: job.mainFiles.map { $0.path }), at: 0)
            if history.count > 300 { history.removeLast(history.count - 300) }
            saveHistory()
        }
        keepDates(job)
        trashOriginalsIfWanted(job)
        if job.state == .done { Sounds.done() } else if job.state == .failed { Sounds.fail() }
        // 3.2 · Ricette: il passo dopo parte dal file appena creato
        if job.state == .done, let next = job.then { job.then = nil; DispatchQueue.main.async { next(job) } }
        notify(job)
        objectWillChange.send()
        startNext()
    }

    /// Opzione «Dopo la conversione: sposta l'originale nel Cestino».
    /// Solo per le azioni che producono una versione completa del file (mai per «estrai pagine», sottotitoli, ecc.).
    private func trashOriginalsIfWanted(_ job: Job) {
        guard UserDefaults.standard.string(forKey: "original") == "trash",
              job.state == .done, job.failures.isEmpty, !job.outputs.isEmpty else { return }
        let id = job.action.id
        let replaces = id.hasPrefix("to:") || ["resize", "strip", "pdfcompress", "vcompress", "normalize", "voiceclean"].contains(id)
        guard replaces, job.notes.isEmpty else { return }       // 4.1.4 · un file saltato («già compresso»…) non si tocca
        for f in job.mainFiles {
            let kind = Catalog.kind(of: f)
            // 4.1.4 · Mai per le conversioni che tengono solo una parte: audio o GIF da un video, immagini da un PDF
            if kind == .video, ["to:mp3", "to:m4a", "to:wav", "to:gif", "to:aac", "to:flac"].contains(id) { continue }
            if kind == .pdf, ["to:png", "to:jpg", "to:jpeg", "to:heic", "to:webp", "to:tiff"].contains(id) { continue }
            // Solo se c'è davvero un file creato da questo originale (stesso nome di partenza)
            let stem = f.deletingPathExtension().lastPathComponent
            let made = job.outputs.contains { o in
                o.path != f.path && FileManager.default.fileExists(atPath: o.path) && o.deletingPathExtension().lastPathComponent.hasPrefix(stem)
            }
            if made { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) }
        }
    }

    /// Spazio risparmiato nel mese corrente con compressioni e conversioni (escluse quelle annullate).
    var savedThisMonth: Int64 {
        let cal = Calendar.current
        let now = Date()
        return history.reduce(Int64(0)) { sum, e in
            guard !e.undone, let b = e.before, let a = e.after, b > a,
                  cal.isDate(e.date, equalTo: now, toGranularity: .month) else { return sum }
            return sum + (b - a)
        }
    }

    // MARK: - Soluzioni agli errori

    func apply(_ fix: Fix, to job: Job) {
        switch fix {
        case .install(let ids):
            AppState.shared.selection = .components
            let list = Installer.shared.all.filter { ids.contains($0.id) && !$0.installed }
            if !list.isEmpty { Installer.shared.install(list, id: list.count == 1 ? list[0].id : "all") }
        case .retryParam(_, let value):
            enqueue(files: job.files, action: job.action, param: value)
        case .unlock:
            guard let f = job.mainFiles.first, let a = Catalog.tools["unprotect"] else { return }
            ParamController.shared.ask(.unlock, action: a, files: [f], at: NSEvent.mouseLocation) { [weak self] v in
                if let v { self?.enqueue(files: [f], action: a, param: v) }
            }
        case .icloud:
            job.status = String(localized: "Scarico da iCloud…")
            for f in job.mainFiles { try? FileManager.default.startDownloadingUbiquitousItem(at: f) }
            waitForDownload(job, attempts: 0)
        case .classic:
            enqueue(files: job.files, action: job.action, param: job.param, classic: true)
        case .retry:
            retry(job)
        case .storage:
            if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(u) }
        case .otherFolder:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private func waitForDownload(_ job: Job, attempts: Int) {
        let ready = job.mainFiles.allSatisfy { f in
            let v = try? f.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            return v?.ubiquitousItemDownloadingStatus == nil || v?.ubiquitousItemDownloadingStatus == .current
        }
        if ready || attempts > 600 { retry(job); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.waitForDownload(job, attempts: attempts + 1) }
    }

    // MARK: - Notifiche

    private func notify(_ job: Job) {
        guard job.state != .cancelled, !job.quietNotify else { return }
        let c = UNMutableNotificationContent()
        if job.state == .done {
            c.title = job.outputs.count == 1 ? String(localized: "Creato «\(job.outputs[0].lastPathComponent)»") : (job.outputs.isEmpty ? job.title : String(localized: "\(job.outputs.count) file pronti"))
            var body = job.action.title
            if !job.info.isEmpty { body += " · " + job.info }
            if !job.failures.isEmpty { body += " · " + String(localized: "\(job.failures.count) non riusciti") }
            if job.outputs.isEmpty, let n = job.notes.first { body = n }
            c.body = body
            if let first = job.outputs.first { c.userInfo = ["path": first.path] }
            c.categoryIdentifier = "DONE"
        } else {
            c.title = String(localized: "Non riuscito: \(job.title)")
            c.body = job.failures.first ?? String(localized: "Apri OrbitLR per i dettagli")
        }
        let req = UNNotificationRequest(identifier: job.id.uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Cronologia

    func undo(_ entry: HistoryEntry) {
        if let pairs = entry.renames {
            // Rinomina: rimette i nomi di prima
            for pair in pairs.reversed() where pair.count == 2 {
                try? FileManager.default.moveItem(at: URL(fileURLWithPath: pair[1]), to: URL(fileURLWithPath: pair[0]))
            }
        } else {
            for p in entry.outputs {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
        }
        if let i = history.firstIndex(where: { $0.id == entry.id }) {
            history[i].undone = true
            saveHistory()
        }
    }

    /// 2.7.2 · Toglie la voce dalla Cronologia. I file restano dove sono.
    func forget(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    /// 2.7.2 · Svuota la Cronologia. I file restano dove sono.
    func forgetAll() {
        history.removeAll()
        saveHistory()
        // 3.5.2 · Con la cronologia se ne vanno anche le miniature dei file (possono mostrare documenti privati)
        ThumbCache.shared.forgetAll()
    }

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func loadHistory() {
        guard let d = try? Data(contentsOf: Paths.history) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        history = (try? dec.decode([HistoryEntry].self, from: d)) ?? []
    }

    private func saveHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? enc.encode(history) { try? d.write(to: Paths.history, options: .atomic) }
    }

}


/// Un pulsante che risolve il problema, mostrato accanto all'errore.
enum Fix: Equatable {
    case install([String])
    case retryParam(String, String)     // etichetta, nuovo parametro
    case unlock
    case icloud
    case classic
    case retry
    /// 2.7.5 · Disco pieno: apre «Spazio di archiviazione» di macOS.
    case storage
    /// 2.7.5 · Cartella dove non si può scrivere: apre le Opzioni per sceglierne un'altra.
    case otherFolder

    var label: String {
        switch self {
        case .install: return String(localized: "Installa")
        case .retryParam(let l, _): return l
        case .unlock: return String(localized: "Inserisci la password")
        case .icloud: return String(localized: "Scarica e riprova")
        case .classic: return String(localized: "Riprova con l’altro motore")
        case .retry: return String(localized: "Riprova")
        case .storage: return String(localized: "Libera spazio")
        case .otherFolder: return String(localized: "Scegli un’altra cartella")
        }
    }

    var symbol: String {
        switch self {
        case .install: return "arrow.down.circle.fill"
        case .retryParam: return "arrow.clockwise.circle.fill"
        case .unlock: return "lock.open.fill"
        case .icloud: return "icloud.and.arrow.down.fill"
        case .classic: return "gearshape.2.fill"
        case .retry: return "arrow.clockwise"
        case .storage: return "internaldrive"
        case .otherFolder: return "folder.badge.gearshape"
        }
    }

    /// Sceglie la soluzione più utile leggendo il motivo dell'errore.
    static func best(for job: Job) -> Fix? {
        guard job.state == .failed || (job.state == .done && !job.failures.isEmpty) else { return nil }
        let text = job.failures.joined(separator: " ").lowercased()
        let toolMap = ["soffice": "soffice", "pandoc": "pandoc", "ffmpeg": "ffmpeg", "ffprobe": "ffmpeg",
                       "gs": "gs", "whisper": "whisper", "magick": "magick", "exiftool": "exiftool"]
        let ids = Array(Set(job.missing.compactMap { toolMap[$0] }))
        if !ids.isEmpty { return .install(ids) }
        // 4.2 · I testi si confrontano in italiano e nella lingua dell'app
        func says(_ it: String, _ shown: String) -> Bool { text.contains(it) || text.contains(shown.lowercased()) }
        if job.action.id == "vcompress", says("troppo lungo", "too long") || says("farlo stare", "get it under"), let mb = Int(job.param) {
            return .retryParam(String(localized: "Prova con \(mb * 2) MB"), String(mb * 2))
        }
        if says("spazio su disco esaurito", String(localized: "Spazio su disco esaurito: libera un po’ di spazio e riprova.")) { return .storage }
        if says("non può scrivere in quella cartella",
                String(localized: "OrbitLR non può scrivere in quella cartella: spostala altrove o scegli un’altra cartella nelle Opzioni.")) { return .otherFolder }
        if text.contains("password") && job.kind == .pdf && job.action.id != "unprotect" { return .unlock }
        if text.contains("icloud") { return .icloud }
        // Gli strumenti che esistono solo con i motori di macOS non hanno un «altro motore»
        if job.native && !Tools.ids.contains(job.action.id) && !Media.ids.contains(job.action.id) { return .classic }
        return .retry
    }
}
