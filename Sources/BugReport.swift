import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  «Segnala bug»: email, categoria, descrizione, screenshot e (a scelta) le informazioni tecniche.
//  Prepara un'email in Mail con tutto allegato. Se Mail non è configurata, salva la segnalazione
//  in una cartella sulla Scrivania, pronta da inviare a mano.
// ════════════════════════════════════════════════════════════════════

enum BugReport {
    /// Chi riceve le segnalazioni.
    static let recipient = "ledion.proaccs@gmail.com"

    static let categories = ["Conversione", "Grafica", "Aggiornamento", "Siri e Comandi Rapidi",
                             "Cartelle automatiche", "Condividi", "Lentezza", "Altro"]

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Avvisi ed errori dell'ultimo aggiornamento compilato su questo Mac.
    static func buildWarnings() -> String {
        guard let t = try? String(contentsOf: Updater.buildLog, encoding: .utf8) else { return "(nessuna)" }
        let lines = t.split(separator: "\n").filter { $0.contains("warning:") || $0.contains("error:") }
        var seen = Set<Substring>()
        let unique = lines.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "(nessun avviso)" : unique.prefix(60).joined(separator: "\n")
    }

    /// Versione, macOS, Mac, componenti installati e le ultime righe del registro.
    static func diagnostics() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let comps = Installer.shared.components.map { "\($0.name): \($0.installed ? "sì" : "no")" }.joined(separator: ", ")
        let log = (try? String(contentsOf: Paths.log, encoding: .utf8))
            .map { $0.split(separator: "\n").suffix(80).joined(separator: "\n") } ?? "(registro vuoto)"
        let jobs = QueueStore.shared.jobs.prefix(10).map { j in
            "• \(j.action.title) · \(j.title) · \(j.status)" + (j.failures.isEmpty ? "" : " · " + j.failures.joined(separator: "; "))
        }.joined(separator: "\n")
        return """
        OrbitLR \(version)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac: \(String(cString: model)) · \(ProcessInfo.processInfo.processorCount) core
        Componenti: \(comps)

        Ultimi lavori:
        \(jobs.isEmpty ? "(nessuno)" : jobs)

        Tempi (3.4.1):
        \(Perf.report.isEmpty ? "(nessuna misura)" : Perf.report)

        Registro (ultime righe):
        \(log)

        Ultima compilazione (avvisi ed errori):
        \(buildWarnings())
        """
    }
}

struct BugReportView: View {
    let done: () -> Void

    @AppStorage("bugEmail") private var email = ""
    @State private var category = BugReport.categories[0]
    @State private var text = ""
    @State private var screenshots: [URL] = []
    @State private var includeTech = true
    @State private var message: String? = nil
    @State private var capturing = false

    private var emailOK: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty || (e.contains("@") && e.contains(".") && !e.contains(" "))
    }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && emailOK }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "ladybug.fill").font(.system(size: 22)).foregroundStyle(Theme.color(.pdf))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Segnala un bug").font(.system(size: 17, weight: .bold))
                    Text("Raccontami cosa è successo: più dettagli, più in fretta si sistema.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            field("La tua email (per risponderti)") {
                TextField("nome@esempio.it", text: $email)
                    .textFieldStyle(.roundedBorder)
                if !emailOK {
                    Text("Controlla l’indirizzo email.").font(.system(size: 11)).foregroundStyle(Theme.color(.pdf))
                }
            }

            field("Categoria") {
                Picker("", selection: $category) {
                    ForEach(BugReport.categories, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            field("Cosa è successo") {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ivory))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Cosa stavi facendo, cosa ti aspettavi e cosa è successo invece.")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }

            field("Screenshot") {
                HStack(spacing: 8) {
                    Button { capture() } label: { Label("Cattura una parte dello schermo", systemImage: "camera.viewfinder") }
                        .disabled(capturing)
                    Button { chooseImages() } label: { Label("Scegli un’immagine…", systemImage: "photo") }
                }
                if !screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(screenshots, id: \.self) { u in
                                ZStack(alignment: .topTrailing) {
                                    FileThumb(url: u, kind: .img, size: 56)
                                    Button { screenshots.removeAll { $0 == u } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                            .foregroundStyle(Theme.ink.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                    .help("Togli")
                                }
                            }
                        }
                        .padding(.top, 6).padding(.trailing, 8)
                    }
                }
            }

            Toggle("Allega le informazioni tecniche (versione, macOS, ultimi lavori, registro)", isOn: $includeTech)
                .font(.system(size: 12))

            if let message {
                Label(message, systemImage: "info.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.brass)
            }

            HStack {
                Text("Versione \(BugReport.version)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Annulla") { done() }.keyboardShortcut(.cancelAction)
                Button { send() } label: { Label("Prepara l’email", systemImage: "paperplane.fill") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canSend)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.cream)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in
                screenshots += urls.filter { Catalog.kind(of: $0) == .img && !screenshots.contains($0) }
            }
            return true
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    // MARK: Screenshot

    /// Selezione di una parte dello schermo, come ⇧⌘4. La finestra si nasconde un attimo per non finire nella foto.
    private func capture() {
        capturing = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitLR-bug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("Screenshot \(Int(Date().timeIntervalSince1970)).png")
        NSApp.hide(nil)                    // OrbitLR si toglie di mezzo durante la cattura
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.3)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", out.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate()
                capturing = false
                if FileManager.default.fileExists(atPath: out.path) { screenshots.append(out) }
            }
        }
    }

    private func chooseImages() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK { screenshots += p.urls.filter { !screenshots.contains($0) } }
    }

    // MARK: Invio

    private func send() {
        let firstLine: String = String(String(text.split(separator: "\n").first ?? "").prefix(60))
        let subject: String = "[OrbitLR \(BugReport.version)] \(category): \(firstLine)"
        let body = """
        Categoria: \(category)
        Email per la risposta: \(email.isEmpty ? "(non indicata)" : email)

        \(text)
        """
        var attachments: [URL] = screenshots
        if includeTech {
            let tech = FileManager.default.temporaryDirectory.appendingPathComponent("Informazioni tecniche OrbitLR.txt")
            try? BugReport.diagnostics().write(to: tech, atomically: true, encoding: .utf8)
            attachments.append(tech)
        }

        var items: [Any] = [body]
        items.append(contentsOf: attachments.map { $0 as Any })
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [BugReport.recipient]
            mail.subject = subject
            mail.perform(withItems: items)
            done()
            return
        }

        // Senza Mail: una cartella sulla Scrivania con tutto dentro
        let fm = FileManager.default
        let desk = fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? Paths.home
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let folder = desk.appendingPathComponent("Segnalazione OrbitLR \(f.string(from: Date()))")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = "A: \(BugReport.recipient)\nOggetto: \(subject)\n\n\(body)\n"
        try? note.write(to: folder.appendingPathComponent("Segnalazione.txt"), atomically: true, encoding: .utf8)
        for a in attachments { try? fm.copyItem(at: a, to: folder.appendingPathComponent(a.lastPathComponent)) }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        message = "Mail non è configurata: ho salvato la segnalazione sulla Scrivania. Inviala a \(BugReport.recipient)."
    }
}
