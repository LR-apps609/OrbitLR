import Foundation
import AppKit
import SwiftUI

/// Doppio clic su «OrbitLR x.y.orbitlr»: l'app si costruisce e si installa da sola, senza Terminale.
/// Durante l'aggiornamento resta aperta solo la schedina con l'animazione, la stima del tempo e la barra;
/// quando la barra è piena, OrbitLR si riapre aggiornata.
final class Updater: ObservableObject, @unchecked Sendable {
    static let shared = Updater()
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    enum Stage: Int {
        case prepare, project, compile, install, done

        var text: String {
            switch self {
            case .prepare: return "Preparo i file…"
            case .project: return "Controllo la firma…"
            case .compile: return "Preparo la nuova versione…"
            case .install: return "Installo…"
            case .done: return "Fatto! Riapro OrbitLR…"
            }
        }
    }

    /// Quanto pesa ogni fase sulla barra (la compilazione è quasi tutto il lavoro).
    static let weights: [Double] = [0.04, 0.08, 0.83, 0.05]
    /// Durate di partenza, in secondi, finché questo Mac non ne ha misurate di sue.
    static let defaultTimes: [Double] = [3, 10, 95, 3]

    @Published var stage: Stage = .prepare
    @Published var stageStart = Date()
    @Published var lines: [String] = []
    @Published var error: String? = nil
    @Published var busy = false
    @Published var fromVersion = ""
    @Published var toVersion = ""
    /// Durate attese per fase: quelle misurate all'ultimo aggiornamento su questo Mac.
    @Published var expected: [Double] = Updater.defaultTimes
    private var measured: [Double] = []
    /// Installazione dell'app già pronta: i suoi tempi non vanno a sporcare quelli della compilazione.
    private var fast = false
    private var window: NSWindow?
    private var hidden: [NSWindow] = []

    /// 3.5.2 · Cartella di lavoro privata, nuova a ogni aggiornamento
    private var work = FileManager.default.temporaryDirectory
    /// Registro completo dell'ultima compilazione (errori e avvisi), utile per le segnalazioni.
    static let buildLog = Paths.home.appendingPathComponent("Library/Logs/OrbitLR-aggiornamento.log")

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// `confirmed`: l'utente ha già detto sì (da «Controlla aggiornamenti»), niente seconda domanda.
    /// `expectedVersion`: la versione annunciata da GitHub, che deve coincidere con quella firmata.
    func open(_ file: URL, confirmed: Bool = false, expectedVersion: String? = nil) {
        guard !busy else { window?.makeKeyAndOrderFront(nil); return }
        // Da subito «occupato»: se l'app si è appena aperta per questo aggiornamento, la finestra principale non compare
        busy = true
        let current = (version: currentVersion, build: currentBuild)
        // 3.5.2 · I controlli (estrazione, firma, impronta) in sottofondo: la finestra non si blocca mai
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try UpdatePackage.prepare(file, current: current, expectedVersion: expectedVersion) }
            DispatchQueue.main.async { self.verified(result, confirmed: confirmed) }
        }
    }

    private func verified(_ result: Result<UpdatePackage.Prepared, Error>, confirmed: Bool) {
        let ready: UpdatePackage.Prepared
        switch result {
        case .success(let r): ready = r
        case .failure(let e):
            busy = false
            LaunchGate.release()
            alert((e as? UpdatePackage.Failure)?.message ?? UpdatePackage.Failure.badManifest.message)
            return
        }
        work = ready.work
        let manifest = ready.manifest
        loadTimes()

        // 2.8.1 · Solo le novità rispetto alla versione che hai (dal manifesto firmato)
        let items = News.items(since: currentVersion, in: manifest.news, maxVersions: 8)
        let newsText = items.map { "• " + $0 }.joined(separator: "\n\n")
        if !confirmed {
            let a = NSAlert()
            a.messageText = "Installare OrbitLR \(manifest.version)?"
            a.informativeText = "Versione attuale: \(currentVersion). Aggiornamento firmato da OrbitLR e controllato.\n\nOrbitLR si chiuderà e si riaprirà da sola, già aggiornata. Ci vogliono pochi secondi."
            // 2.8.7 · Le novità in un riquadro che scorre: la finestra resta piccola e i pulsanti sempre visibili
            if !newsText.isEmpty { a.accessoryView = Self.scrollingText(newsText) }
            a.addButton(withTitle: "Installa")
            a.addButton(withTitle: "Annulla")
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else {
                try? FileManager.default.removeItem(at: ready.work)       // niente file lasciati in giro
                busy = false
                LaunchGate.release()
                return
            }
        }
        fromVersion = currentVersion
        toVersion = manifest.version
        closeEverythingElse()
        showWindow()
        installVerified(ready.app)
    }

    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// 2.8.7 · Un testo lungo in un riquadro di misura fissa, con la barra per scorrere.
    static func scrollingText(_ text: String, width: CGFloat = 380, height: CGFloat = 220) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 4, height: height))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = .systemFont(ofSize: 12)
        tv.string = text
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        return scroll
    }

    // MARK: - Avanzamento realistico

    /// Da 0 a 1. Si basa sui tempi misurati l'ultima volta su questo Mac; se una fase dura più del previsto,
    /// la barra rallenta senza arrivare in fondo: è piena solo quando il lavoro è davvero finito.
    func progress(at now: Date) -> Double {
        if stage == .done { return 1 }
        let i = stage.rawValue
        let before = Self.weights.prefix(i).reduce(0, +)
        let x = now.timeIntervalSince(stageStart) / max(expected[i], 1)
        let f = x < 0.85 ? x : 0.85 + 0.12 * (1 - exp(-(x - 0.85) * 4))
        return min(0.99, before + Self.weights[i] * f)
    }

    /// Secondi che mancano, secondo la stima.
    func remaining(at now: Date) -> Double {
        if stage == .done { return 0 }
        let i = stage.rawValue
        let rest = expected.suffix(from: i + 1).reduce(0, +)
        return max(0, expected[i] - now.timeIntervalSince(stageStart)) + rest
    }

    private func loadTimes() {
        if let t = UserDefaults.standard.array(forKey: "updateTimes") as? [Double], t.count == Self.defaultTimes.count {
            expected = t
        } else {
            expected = Self.defaultTimes
        }
    }

    /// Passa alla fase successiva e misura quanto è durata quella appena finita.
    private func enter(_ s: Stage) {
        let now = Date()
        DispatchQueue.main.async {
            if self.stage != .done { self.measured.append(max(1, now.timeIntervalSince(self.stageStart))) }
            self.stage = s
            self.stageStart = now
            if s == .done, !self.fast, self.measured.count == Self.defaultTimes.count {
                UserDefaults.standard.set(self.measured, forKey: "updateTimes")
            }
        }
    }

    // MARK: - Installazione (solo app firmate e verificate)

    /// 3.5.2 · Niente più compilazione dal pacchetto: si installa solo l'app firmata e controllata.
    private func installVerified(_ app: URL) {
        busy = true
        error = nil
        lines = []
        measured = []
        fast = true
        expected = [1, 1, 1, 3]
        stage = .prepare
        stageStart = Date()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            enter(.project)
            let exe = app.appendingPathComponent("Contents/MacOS/OrbitLR").path
            let archOK = shOut("/usr/bin/lipo", ["-archs", exe]).contains(shOut("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines))
            // L'integrità del pacchetto dell'app (nessun file cambiato dopo la firma del codice)
            let signOK = sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
            guard archOK, signOK else {
                return fail(archOK ? "L'app dentro l'aggiornamento non è integra: non la installo." : "Questo aggiornamento non è adatto a questo Mac.")
            }
            enter(.compile)
            install(app)
        }
    }

    /// Prepara l'app nuova accanto a quella attuale, poi chiude OrbitLR e uno script la sostituisce e la riapre.
    private func install(_ built: URL) {
        enter(.install)
        // L'app nuova viene preparata accanto: quella attuale resta intatta finché non è tutto pronto
        let staged = work.appendingPathComponent("OrbitLR.app")
        try? FileManager.default.removeItem(at: staged)
        if sh("/usr/bin/ditto", [built.path, staged.path]) != 0 { return fail("Non riesco a preparare l’installazione.") }
        // La copia compilata non deve risultare come una seconda OrbitLR
        _ = sh(Self.lsregister, ["-u", built.path])
        Thread.sleep(forTimeInterval: 0.5)

        enter(.done)
        // La barra si riempie; poi OrbitLR si chiude e uno script la sostituisce e la riapre
        Thread.sleep(forTimeInterval: 1.4)
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        # La versione attuale si mette da parte: se la nuova non si copia, torna al suo posto (mai senza app)
        OLD="$HOME/Library/Caches/OrbitLR-precedente.app"
        rm -rf "$OLD"; mv /Applications/OrbitLR.app "$OLD" 2>/dev/null
        if mv \(q(staged.path)) /Applications/OrbitLR.app; then
          rm -rf "$OLD"
        else
          rm -rf /Applications/OrbitLR.app; mv "$OLD" /Applications/OrbitLR.app; open /Applications/OrbitLR.app; exit 1
        fi
        xattr -dr com.apple.quarantine /Applications/OrbitLR.app 2>/dev/null
        \(Self.lsregister) -f /Applications/OrbitLR.app >/dev/null 2>&1
        /System/Library/CoreServices/pbs -update >/dev/null 2>&1
        rm -rf \(q(work.path))
        open /Applications/OrbitLR.app
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Finestre

    /// Durante l'aggiornamento resta solo la schedina: menu, finestra principale e pannelli spariscono.
    private func closeEverythingElse() {
        PieController.shared.close()
        LaunchGate.holding = true          // anche le finestre che macOS aprisse dopo restano nascoste
        hidden = NSApp.windows.filter { $0 !== window && $0.isVisible }
        hidden.forEach { $0.orderOut(nil) }
    }

    private func showWindow() {
        let size = NSSize(width: 460, height: 430)
        let host = NSHostingView(rootView: UpdateView(updater: self))
        host.frame.size = size
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Dopo un errore: chiude la schedina e rimette le finestre com'erano.
    func closeAfterError() {
        window?.orderOut(nil)
        window = nil
        error = nil
        LaunchGate.release()
        hidden.forEach { $0.alphaValue = 1; $0.makeKeyAndOrderFront(nil) }
        hidden = []
    }

    // MARK: - Utilità

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func fail(_ s: String) {
        // 3.5.2 · La cartella di lavoro dell'aggiornamento non resta sul disco
        if work.lastPathComponent.hasPrefix("OrbitLR-aggiornamento-") { try? FileManager.default.removeItem(at: work) }
        DispatchQueue.main.async {
            let errs = self.lines.filter { $0.contains("error:") }.prefix(8).joined(separator: "\n")
            self.error = s + (errs.isEmpty ? "" : "\n\n" + errs)
            self.busy = false
        }
    }

    private func alert(_ s: String) {
        let a = NSAlert()
        a.messageText = s
        a.runModal()
    }

    private func shOut(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    @discardableResult
    private func sh(_ exe: String, _ args: [String], env path: String? = nil, log: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var file: FileHandle? = nil
        if log {
            try? FileManager.default.createDirectory(at: Self.buildLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.buildLog.path, contents: nil)
            file = try? FileHandle(forWritingTo: Self.buildLog)
            let out = file
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                out?.write(d)
                guard let t = String(data: d, encoding: .utf8) else { return }
                let new = t.split(separator: "\n").map(String.init)
                DispatchQueue.main.async {
                    self?.lines.append(contentsOf: new)
                    if (self?.lines.count ?? 0) > 300 { self?.lines.removeFirst(100) }
                }
            }
        }
        do { try p.run() } catch { return -1 }
        if !log { _ = pipe.fileHandleForReading.readDataToEndOfFile() }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        try? file?.close()
        return p.terminationStatus
    }
}

// MARK: - Schedina dell'aggiornamento

struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 14) {
            BrandAnimation(size: CGSize(width: 300, height: 170))
                .padding(.top, 22)

            VStack(spacing: 4) {
                Text(updater.error == nil ? "Aggiorno OrbitLR" : "Aggiornamento non riuscito")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                if !updater.toVersion.isEmpty {
                    Text("\(updater.fromVersion)  →  \(updater.toVersion)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brass)
                }
            }

            if let e = updater.error {
                ScrollView {
                    Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color(.pdf))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                HStack {
                    Button("Copia i dettagli") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e + "\n\n" + updater.lines.suffix(60).joined(separator: "\n"), forType: .string)
                    }
                    Spacer()
                    Button("Chiudi") { updater.closeAfterError() }.keyboardShortcut(.defaultAction)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                    let p = updater.progress(at: tl.date)
                    let left = updater.remaining(at: tl.date)
                    VStack(spacing: 8) {
                        ProgressBar(value: p, tint: updater.stage == .done ? Theme.green : Theme.accent, height: 10)
                        HStack {
                            Text(updater.stage.text).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(timeText(p: p, left: left))
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Text(updater.lines.last ?? " ")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .frame(width: 460, height: 430)
        .background(GlowBackground(tint: Theme.accent))
        .foregroundStyle(Theme.ink)
    }

    private func timeText(p: Double, left: Double) -> String {
        if updater.stage == .done { return "100%" }
        let pct = "\(Int((p * 100).rounded(.down)))%"
        if left < 1 { return pct + " · quasi finito…" }
        return pct + " · " + roughDuration(left)
    }
}
