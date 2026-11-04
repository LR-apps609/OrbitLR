import Foundation
import AppKit
import Metal

// ════════════════════════════════════════════════════════════════════
//  6.0.3 «Rapporti» · Il guardiano: se qualcosa va storto se ne accorge da solo, senza «Segnala».
//  • La finestra non risponde per più di ~4 secondi (un thread in sottofondo «bussa» al principale).
//  • Un lavoro (o il suo motore) resta fermo troppo a lungo, senza nessun avanzamento.
//  • L'app si è chiusa di colpo (il file «in-corso» scritto all'avvio non è stato tolto all'uscita).
//  Ogni evento va nel registro dell'app. Al prossimo avvio si chiede se salvare il rapporto sulla Scrivania.
//  A riposo costa quasi niente: un controllo ogni 2 secondi, con margine lasciato a macOS per accorparlo.
// ════════════════════════════════════════════════════════════════════

/// Il controllo «la finestra risponde?», senza orologio proprio (così i test possono dargli i tempi).
struct HangDetector {
    let limit: Double
    private(set) var sentAt: Double? = nil
    private var reported = false

    init(limit: Double) { self.limit = limit }

    enum Event: Equatable { case none, hang(Double), recovered(Double) }

    /// Un giro del guardiano. `sendPing` vero: bisogna bussare al thread principale.
    mutating func tick(now: Double) -> (sendPing: Bool, event: Event) {
        guard let s = sentAt else { sentAt = now; return (true, .none) }
        let age = now - s
        if age > limit && !reported { reported = true; return (false, .hang(age)) }
        return (false, .none)
    }

    /// Il thread principale ha risposto.
    mutating func answered(now: Double) -> Event {
        guard let s = sentAt else { return .none }
        sentAt = nil
        if reported { reported = false; return .recovered(now - s) }
        return .none
    }
}

/// Lavori che non avanzano: la loro «firma» (avanzamento, stato, file fatti) non cambia da troppo tempo.
struct StallTracker {
    let limit: Double
    private var seen: [UUID: (sig: String, since: Double, logged: Bool)] = [:]

    init(limit: Double) { self.limit = limit }

    /// Vero solo la prima volta che il lavoro risulta fermo da più di `limit` secondi.
    mutating func update(_ id: UUID, sig: String, now: Double) -> Bool {
        guard let old = seen[id], old.sig == sig else { seen[id] = (sig, now, false); return false }
        if !old.logged && now - old.since > limit { seen[id] = (sig, old.since, true); return true }
        return false
    }

    mutating func keepOnly(_ ids: Set<UUID>) { seen = seen.filter { ids.contains($0.key) } }
}

/// 6.0.3 · Cosa sta facendo il thread principale adesso (per sapere dove si è bloccato).
/// Si scrive solo attorno alle operazioni che toccano il disco; la legge il guardiano quando la finestra non risponde.
enum MainActivity {
    private static let lock = NSLock()
    private static var stack: [String] = []

    static var current: String { lock.lock(); defer { lock.unlock() }; return stack.last ?? "" }

    @discardableResult
    static func during<T>(_ what: String, _ work: () throws -> T) rethrows -> T {
        lock.lock(); stack.append(what); lock.unlock()
        defer { lock.lock(); _ = stack.popLast(); lock.unlock() }
        return try work()
    }
}

final class Watchdog: @unchecked Sendable {
    static let shared = Watchdog()

    let dir: URL
    let interval: Double
    private let log: (String, String) -> Void
    private let queue = DispatchQueue(label: "it.ledion.OrbitLR.guardiano", qos: .utility)
    private let lock = NSLock()
    private var detector: HangDetector
    private var stalls: StallTracker
    private var timer: DispatchSourceTimer?
    private var doing = ""
    private var sentinelDoing = ""
    private var launchInfo = ""
    private(set) var ticks = 0
    /// I motori usati in questa sessione (macOS, motore classico…).
    private(set) var enginesUsed: Set<String> = []
    /// Com'è partita questa volta: primo avvio, aggiornata da…, normale.
    private(set) var launchKind = ""

    init(dir: URL = Paths.support, interval: Double = 2, hangLimit: Double = 4, stallLimit: Double = 15 * 60,
         log: @escaping (String, String) -> Void = AppLog.write) {
        self.dir = dir
        self.interval = interval
        self.detector = HangDetector(limit: hangLimit)
        self.stalls = StallTracker(limit: stallLimit)
        self.log = log
    }

    var sentinel: URL { dir.appendingPathComponent("in-corso.txt") }
    var pendingFile: URL { dir.appendingPathComponent("problema.txt") }
    /// L'ultimo problema già visto (per «Segnala»).
    var lastProblemFile: URL { dir.appendingPathComponent("ultimo-problema.txt") }

    static var uptime: Double { ProcessInfo.processInfo.systemUptime }      // si ferma quando il Mac dorme
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
    }

    // MARK: Avvio e uscita

    /// All'avvio: se il file «in-corso» c'è ancora, l'ultima volta l'app non si è chiusa bene.
    func launch(previousVersion: String?, firstLaunch: Bool, start: Bool = true) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        if firstLaunch { launchKind = "primo avvio" }
        else if let p = previousVersion, !p.isEmpty, p != current { launchKind = "aggiornata dalla \(p)" }
        else { launchKind = "avvio normale" }
        if let old = try? String(contentsOf: sentinel, encoding: .utf8) {
            log("guardiano", "l’ultima volta OrbitLR si è chiusa di colpo (non con Esci)")
            addProblem("OrbitLR si è chiusa all’improvviso (o è stata chiusa a forza)", detail: old)
        }
        launchInfo = "avviata: \(Self.stamp()) · OrbitLR \(BugReport.version) · \(launchKind)"
        writeSentinel()
        if start { self.start() }
    }

    /// Uscita normale (Esci, ⌘Q, spegnimento): niente rapporto la prossima volta.
    func cleanExit() {
        stop()
        try? FileManager.default.removeItem(at: sentinel)
    }

    private func writeSentinel() {
        lock.lock(); let text = launchInfo + "\nstava facendo: " + (doing.isEmpty ? "-" : doing) + "\n"; lock.unlock()
        try? text.write(to: sentinel, atomically: true, encoding: .utf8)
    }

    // MARK: Il controllo periodico

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        lock.lock()
        ticks += 1
        let (send, event) = detector.tick(now: Self.uptime)
        let what = doing
        lock.unlock()
        if send { DispatchQueue.main.async { [weak self] in self?.pong() } }
        if case .hang(let age) = event {
            let during = MainActivity.current
            let text = "La finestra non risponde da \(Int(age)) secondi" + (during.isEmpty ? "" : " · durante: \(during)")
            log("guardiano", text + " · stava facendo: \(what)")
            addProblem(text, detail: "stava facendo: \(what)\n\(launchInfo)")
        }
    }

    /// Sul thread principale: ha risposto. Si guarda anche cosa sta facendo l'app (costa pochissimo).
    private func pong() {
        lock.lock(); let event = detector.answered(now: Self.uptime); lock.unlock()
        if case .recovered(let s) = event { log("guardiano", "la finestra è tornata a rispondere dopo \(Int(s)) secondi") }
        sample()
    }

    /// Scheda aperta e lavori in corso; i lavori che non cambiano da troppo tempo finiscono nel registro.
    func sample(now: Double = Watchdog.uptime) {
        let app = AppState.shared
        var tab = app.selection?.rawValue ?? "-"
        if app.selection == .video { tab += " (\(app.videoMode.rawValue))" }
        let running = QueueStore.shared.jobs.filter { $0.state == .running }
        var parts = ["scheda: \(tab)", "lavori in corso: \(running.count)"]
        for j in running.prefix(3) {
            let exts = Set(j.files.map { $0.pathExtension.lowercased() }).sorted().joined(separator: ",")
            parts.append("\(j.action.id) (\(j.native ? "macOS" : "motore classico"), \(j.files.count) file \(exts))")
        }
        let text = parts.joined(separator: " · ")
        var stalled: [Job] = []
        lock.lock()
        for j in running where stalls.update(j.id, sig: Self.signature(j), now: now) { stalled.append(j) }
        stalls.keepOnly(Set(running.map { $0.id }))
        doing = text
        let changed = text != sentinelDoing
        if changed { sentinelDoing = text }
        lock.unlock()
        for j in stalled {
            let m = "il lavoro «\(j.action.id)» (\(j.native ? "macOS" : "motore classico")) non avanza da più di \(Int(stalls.limit / 60)) minuti · \(j.status)"
            log("guardiano", m)
            addProblem("Un lavoro è rimasto fermo", detail: m)
        }
        if changed { queue.async { [weak self] in self?.writeSentinel() } }
    }

    static func signature(_ j: Job) -> String {
        "\(j.progress)|\(j.status)|\(j.outputs.count)|\(j.failures.count)|\(j.notes.count)"
    }

    // MARK: Problemi da riferire

    func addProblem(_ title: String, detail: String) {
        let block = "• \(Self.stamp()) · \(title)\n" + detail.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n"
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: pendingFile) {
            h.seekToEndOfFile(); h.write(Data(block.utf8)); try? h.close()
        } else {
            try? block.write(to: pendingFile, atomically: true, encoding: .utf8)
        }
    }

    /// I problemi non ancora riferiti (nil se non ce ne sono).
    var pending: String? {
        guard let t = try? String(contentsOf: pendingFile, encoding: .utf8), !t.isEmpty else { return nil }
        return t
    }

    /// Dopo la domanda (qualunque risposta): i problemi passano tra quelli già visti e non si chiede più.
    func settlePending() {
        guard let t = pending else { return }
        try? t.write(to: lastProblemFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: pendingFile)
    }

    var lastProblem: String? { try? String(contentsOf: lastProblemFile, encoding: .utf8) }

    // MARK: Ultimo errore e motori usati

    static let lastErrorKey = "watchdog.lastError"

    func noteFinished(_ job: Job, defaults: UserDefaults = .standard) {
        let engine = job.action.id == "rename" ? "rinomina" : (job.native ? "macOS" : "motore classico (ffmpeg e altri)")
        lock.lock(); enginesUsed.insert(engine); lock.unlock()
        guard job.state == .failed else { return }
        let why = job.failures.first ?? job.status
        let text = "\(Self.stamp()) · \(job.action.id) (\(engine)): \(why)"
        defaults.set(text, forKey: Self.lastErrorKey)
        log("lavoro", "non riuscito: \(job.action.id) · \(why)")
    }

    static func lastError(_ defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: lastErrorKey) }

    var doingNow: String { lock.lock(); defer { lock.unlock() }; return doing }
}

// MARK: - Togliere il nome dell'utente dai percorsi

enum Redact {
    /// «/Users/mario/Desktop/…» → «/Users/***/Desktop/…», anche con spazi nel nome e nei link file://.
    static func userPaths(_ text: String, home: String = Paths.home.path) -> String {
        var t = text
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if h.count > 1 {
            var forms = [h]
            if let enc = h.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), enc != h { forms.append(enc) }
            for f in forms {
                t = t.replacingOccurrences(of: f + "/", with: "/Users/***/", options: .caseInsensitive)
                if let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: f) + "(?![^/\\s])",
                                                     options: .caseInsensitive) {
                    t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "/Users/***")
                }
            }
        }
        // Tutti gli altri utenti: prima i nomi seguiti da «/» (possono avere spazi), poi quelli in fondo a un percorso
        let patterns = ["/Users/(?!\\*\\*\\*/)(?!Shared/)[^/\\n\\t\"'«»<>]{1,64}?/",
                        "/Users/(?!\\*\\*\\*)(?!Shared\\b)[^/\\s\"'«»<>]+"]
        for (i, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                            withTemplate: i == 0 ? "/Users/***/" : "/Users/***")
        }
        return t
    }
}

// MARK: - Le informazioni sul Mac

enum SystemInfo {
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

    /// «1440×900 punti («sembra»), scala 2× → 2880×1800 pixel»
    static func screenLine(points: CGSize, scale: CGFloat) -> String {
        let s = scale == scale.rounded() ? "\(Int(scale))" : String(format: "%.1f", scale)
        return "\(Int(points.width))×\(Int(points.height)) punti («sembra»), scala \(s)× → \(Int(points.width * scale))×\(Int(points.height * scale)) pixel"
    }

    /// La scheda grafica (si chiede una volta sola: crearla costa qualche millisecondo).
    static let gpu: String = {
        MTLCreateSystemDefaultDevice()?.name ?? "nessuna con Metal (Mac virtuale o grafica non supportata)"
    }()

    static func folderInICloud(_ dir: FileManager.SearchPathDirectory) -> String {
        guard let u = FileManager.default.urls(for: dir, in: .userDomainMask).first else { return "?" }
        // Si guarda solo la cartella, mai il suo contenuto (niente richieste di permesso)
        let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey])
        return v?.isUbiquitousItem == true ? "sì (iCloud Drive)" : "no"
    }

    /// Le righe del rapporto, già pronte.
    static func lines() -> [String] {
        var out: [String] = []
        let p = ProcessInfo.processInfo
        out.append("OrbitLR \(BugReport.version)")
        out.append("macOS \(p.operatingSystemVersionString)")
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let rosetta = sysctlInt("sysctl.proc_translated") == 1
        let appleChip = sysctlInt("hw.optional.arm64") == 1
        out.append("Mac: \(sysctlString("hw.model")) · \(sysctlString("machdep.cpu.brand_string")) · \(appleChip ? "Apple Silicon" : "Intel")")
        out.append("App in esecuzione come \(arch)\(rosetta ? " con Rosetta" : "") · \(p.processorCount) core")
        out.append("Memoria (RAM): \(gb(Int64(p.physicalMemory)))")
        let free = (try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        out.append("Spazio libero sul disco: \(free.map { gb($0) } ?? "?")")
        let screens = NSScreen.screens
        out.append("Schermi: \(screens.count)")
        for (i, s) in screens.enumerated() {
            out.append("  \(i + 1). " + screenLine(points: s.frame.size, scale: s.backingScaleFactor)
                       + (s == NSScreen.main ? " · principale" : ""))
        }
        out.append("Scheda grafica: \(gpu)")
        let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.maximumFractionDigits = 2
        out.append("Lingua: OrbitLR in \(AppLanguage.active) · Mac in \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        out.append("Regione: \(Locale.current.identifier) · numeri: \(nf.string(from: 1234.5) ?? "?")")
        let motori = Paths.motori.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?.sorted().joined(separator: ", ")
        out.append("Motori dentro l’app: \(motori ?? "nessuno")")
        out.append("Componenti: " + Installer.shared.components.map { "\($0.name): \($0.installed ? "sì" : "no")" }.joined(separator: ", "))
        let used = Watchdog.shared.enginesUsed.sorted().joined(separator: ", ")
        out.append("Motori usati in questa sessione: \(used.isEmpty ? "nessuno" : used)")
        out.append("Scrivania in iCloud: \(folderInICloud(.desktopDirectory)) · Documenti in iCloud: \(folderInICloud(.documentDirectory))")
        let kind = Watchdog.shared.launchKind
        out.append("Questo avvio: \(kind.isEmpty ? "?" : kind)")
        let doing = Watchdog.shared.doingNow
        out.append("Adesso: \(doing.isEmpty ? "scheda: \(AppState.shared.selection?.rawValue ?? "-")" : doing)")
        return out
    }
}

// MARK: - Il rapporto e la domanda al prossimo avvio

enum ProblemReport {
    /// Il testo completo: cosa è successo, il Mac, l'app, l'ultimo errore e le ultime righe del registro. Senza nomi.
    static func text(problems: String, hangReport: String? = nil) -> String {
        let intro = String(localized: "Puoi mandare questo file con WhatsApp o per email. Non contiene i nomi dei tuoi file.")
        var t = """
        \(intro)

        COSA È SUCCESSO
        \(problems.isEmpty ? "(niente di registrato)" : problems)

        ULTIMO ERRORE
        \(Watchdog.lastError() ?? "(nessuno)")

        """
        if let h = hangReport { t += "\nRAPPORTO DI macOS (inizio)\n\(h)\n" }
        t += "\nINFORMAZIONI\n" + BugReport.diagnostics()
        return BugReport.anonymize(t, names: [])
    }

    /// Il rapporto di macOS più recente su un blocco o una chiusura di OrbitLR (solo l'inizio, che dice dove).
    static func latestSystemReport(maxLines: Int = 120) -> String? {
        guard let u = BugReport.systemReportURLs().first, let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return u.lastPathComponent + "\n" + t.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
    }

    /// Dove salvarlo: la Scrivania; se non si può, Download; altrimenti la cartella Inizio.
    static func save(_ text: String, now: Date = Date()) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let name = String(localized: "Rapporto OrbitLR") + " \(f.string(from: now)).txt"
        let fm = FileManager.default
        let places = [fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
                      fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, Paths.home].compactMap { $0 }
        for dir in places {
            let u = dir.appendingPathComponent(name)
            if (try? text.write(to: u, atomically: true, encoding: .utf8)) != nil { return u }
        }
        return nil
    }

    /// Al prossimo avvio dopo un problema: una domanda sola, quando la schedina di avvio se n'è andata.
    static func askIfNeeded(attempt: Int = 0) {
        guard Watchdog.shared.pending != nil else { return }
        if WelcomeController.shared.isShowing || Updater.shared.busy || LaunchGate.holding {
            if attempt < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { askIfNeeded(attempt: attempt + 1) } }
            return
        }
        let problems = Watchdog.shared.pending ?? ""
        let a = NSAlert()
        a.messageText = String(localized: "L’ultima volta qualcosa è andato storto. Vuoi mandarmi il rapporto?")
        a.informativeText = String(localized: "Salvo sulla Scrivania un file di testo con le informazioni sul Mac e su OrbitLR, senza i nomi dei tuoi file. Puoi mandarlo con WhatsApp o per email.")
        a.addButton(withTitle: String(localized: "Salva il rapporto sulla Scrivania"))
        a.addButton(withTitle: String(localized: "Non ora"))
        NSApp.activate()
        let wantsSave = a.runModal() == .alertFirstButtonReturn
        Watchdog.shared.settlePending()
        AppLog.write("guardiano", wantsSave ? "rapporto: salvato" : "rapporto: non ora")
        guard wantsSave else { return }
        let text = Self.text(problems: problems, hangReport: latestSystemReport())
        if let u = save(text) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}

// MARK: - Cartelle e pesi senza bloccare la finestra

/// 6.0.3 · Un lavoro sul disco fatto in sottofondo: chi lo chiede aspetta al massimo `timeout` secondi
/// e riceve quello che è stato trovato fino a lì. Una cartella enorme, di rete o in iCloud non ancora scaricata
/// non può più fermare la finestra (prima la torta restava bloccata finché macOS non finiva).
final class BoundedWalk<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var stop = false

    private func emit(_ x: T) { lock.lock(); if !stop { items.append(x) }; lock.unlock() }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }

    static func collect(timeout: Double,
                        _ work: @escaping (_ emit: (T) -> Void, _ stopped: () -> Bool) -> Void) -> (items: [T], complete: Bool) {
        let box = BoundedWalk<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work({ box.emit($0) }, { box.stopped })
            done.signal()
        }
        let complete = done.wait(timeout: .now() + timeout) == .success
        box.lock.lock(); box.stop = true; let out = box.items; box.lock.unlock()
        return (out, complete)
    }
}
