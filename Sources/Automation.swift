import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Cartelle automatiche (punto 1)
//  Ogni cartella ha una regola: «le immagini che arrivano qui → convertile in JPG».
//  OrbitLR controlla le cartelle ogni pochi secondi; quando un file nuovo ha finito di copiarsi
//  (il peso non cambia più), lo elabora e mette il risultato in una sottocartella o dove hai scelto.
//  Funziona finché OrbitLR è aperta, anche solo nella barra dei menu.
// ════════════════════════════════════════════════════════════════════

struct WatchRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var folder: String
    var kind: String              // Kind.rawValue
    var actionId: String          // es. "to:jpg", "vcompress", oppure "preset:<uuid>"
    var param: String
    var output: String = "sub"    // sub = sottocartella «Convertiti» · fixed = outputPath
    var outputPath: String = ""
    var enabled = true
    var processed = 0
    var lastRun: Date? = nil

    var folderURL: URL { URL(fileURLWithPath: folder) }
    var fileKind: Kind? { Kind(rawValue: kind) }

    /// Dove finiscono i file creati. Mai la cartella sorvegliata stessa, altrimenti i risultati verrebbero rielaborati.
    var outputURL: URL {
        if output == "fixed", !outputPath.isEmpty, outputPath != folder { return URL(fileURLWithPath: outputPath) }
        return folderURL.appendingPathComponent("Convertiti")
    }

    /// L'azione vera e il suo parametro (anche se la regola usa un preset).
    func resolved() -> (Action, String)? {
        guard let k = fileKind else { return nil }
        if actionId.hasPrefix("preset:"), let uuid = UUID(uuidString: String(actionId.dropFirst(7))),
           let p = PresetStore.shared.presets.first(where: { $0.id == uuid }),
           let a = Catalog.action(id: p.actionId, kind: k) {
            return (a, p.param)
        }
        guard let a = Catalog.action(id: actionId, kind: k) else { return nil }
        return (a, param)
    }

    var summary: String {
        let k = fileKind?.label ?? kind
        if actionId.hasPrefix("preset:"), let uuid = UUID(uuidString: String(actionId.dropFirst(7))),
           let p = PresetStore.shared.presets.first(where: { $0.id == uuid }) {
            return "\(k) → ★ \(p.name)"
        }
        let title = fileKind.flatMap { Catalog.action(id: actionId, kind: $0)?.title } ?? actionId
        return param.isEmpty ? "\(k) → \(title)"
            : "\(k) → " + PresetStore.describe(actionId: actionId, param: param, kind: fileKind)
    }
}

final class WatchStore: ObservableObject, @unchecked Sendable {
    static let shared = WatchStore()

    @Published var rules: [WatchRule] = [] { didSet { save() } }

    private var url: URL { Paths.support.appendingPathComponent("watch.json") }
    private var seenURL: URL { Paths.support.appendingPathComponent("watch-seen.json") }
    /// File già visti per ogni regola (percorso → data di modifica): non vengono rielaborati, nemmeno dopo un riavvio.
    private var seen: [String: [String: Double]] = [:]
    /// File appena comparsi, in attesa che finiscano di copiarsi: percorso → (peso, data di modifica).
    private var settling: [String: (Int64, Double)] = [:]
    private var timer: Timer?
    private var scanning = false

    init() {
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([WatchRule].self, from: d) { rules = r }
        if let d = try? Data(contentsOf: seenURL), let s = try? JSONDecoder().decode([String: [String: Double]].self, from: d) { seen = s }
    }

    /// Avvia la sorveglianza (all'avvio dell'app).
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()
    }

    func add(_ rule: WatchRule, includeExisting: Bool) {
        var r = rule
        if !includeExisting {
            // I file già presenti non si toccano: solo quelli che arriveranno da adesso
            var s: [String: Double] = [:]
            for f in Self.candidates(in: r.folderURL, kind: r.fileKind) { s[f.path] = Self.mtime(f) }
            seen[r.id.uuidString] = s
            saveSeen()
        }
        r.enabled = true
        rules.append(r)
        scan()
    }

    func remove(_ rule: WatchRule) {
        rules.removeAll { $0.id == rule.id }
        seen[rule.id.uuidString] = nil
        saveSeen()
    }

    func toggle(_ rule: WatchRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].enabled.toggle()
        if rules[i].enabled { scan() }
    }

    // MARK: Sorveglianza

    private func scan() {
        guard !scanning else { return }
        let active = rules.filter { $0.enabled }
        guard !active.isEmpty else { return }
        scanning = true
        let seenNow = seen
        let settlingNow = settling
        DispatchQueue.global(qos: .utility).async {
            var ready: [(WatchRule, [URL])] = []
            var newSettling: [String: (Int64, Double)] = [:]
            for r in active {
                var batch: [URL] = []
                let known = seenNow[r.id.uuidString] ?? [:]
                for f in Self.candidates(in: r.folderURL, kind: r.fileKind) {
                    let m = Self.mtime(f)
                    if let k = known[f.path], abs(k - m) < 0.5 { continue }      // già elaborato (e non cambiato)
                    let size = Job.size(of: f)
                    // Pronto solo se peso e data non cambiano tra due controlli (il file ha finito di copiarsi)
                    if let prev = settlingNow[f.path], prev.0 == size, abs(prev.1 - m) < 0.01, size > 0 {
                        batch.append(f)
                    } else {
                        newSettling[f.path] = (size, m)
                    }
                }
                if !batch.isEmpty { ready.append((r, batch)) }
            }
            DispatchQueue.main.async {
                self.settling = newSettling
                self.scanning = false
                for (r, files) in ready { self.process(r, files) }
            }
        }
    }

    private func process(_ rule: WatchRule, _ files: [URL]) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }), rules[i].enabled,
              let res = rule.resolved() else { return }
        let action = res.0, param = res.1
        var s = seen[rule.id.uuidString] ?? [:]
        for f in files { s[f.path] = Self.mtime(f) }
        // 3.5.2 · L'elenco dei file già visti non cresce per sempre: via quelli che non ci sono più
        if s.count > 200 { s = s.filter { FileManager.default.fileExists(atPath: $0.key) } }
        seen[rule.id.uuidString] = s
        saveSeen()
        let out = rule.outputURL
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        QueueStore.shared.enqueue(files: files, action: action, param: param, dest: out)
        rules[i].processed += files.count
        rules[i].lastRun = Date()
    }

    /// I file della cartella (solo il primo livello, niente nascosti né sottocartelle) del tipo giusto.
    static func candidates(in folder: URL, kind: Kind?) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return items.filter { u in
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            return kind == nil || Catalog.kind(of: u) == kind
        }
    }

    static func mtime(_ u: URL) -> Double {
        ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            .timeIntervalSince1970
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(rules) { try? d.write(to: url, options: .atomic) }
    }

    private func saveSeen() {
        if let d = try? JSONEncoder().encode(seen) { try? d.write(to: seenURL, options: .atomic) }
    }
}

// MARK: - Pagina «Cartelle automatiche»

struct AutomationView: View {
    @ObservedObject var store = WatchStore.shared
    @State private var creating = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Cartelle automatiche",
                           subtitle: "Quello che arriva in queste cartelle viene elaborato da solo.",
                           color: SidebarItem.automation.color) {
                    Button { creating = true } label: { Label("Nuova cartella automatica", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                if store.rules.isEmpty {
                    EmptyState(symbol: "folder.badge.gearshape", color: SidebarItem.automation.color,
                               title: "Nessuna cartella automatica",
                               text: "Ad esempio: tutto quello che metti in «Da comprimere» diventa più leggero, da solo. Scegli una cartella, il tipo di file e cosa farne.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.rules) { r in WatchRow(rule: r) }
                        }
                        .padding(.bottom, 12)
                    }
                    Label("Le cartelle funzionano finché OrbitLR è aperta, anche solo nella barra dei menu. Per averle sempre attive: Opzioni → «Apri OrbitLR all’accesso».",
                          systemImage: "info.circle")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $creating) { NewWatchView { creating = false } }
        .navigationTitle("Cartelle automatiche")
    }
}

struct WatchRow: View {
    let rule: WatchRule
    @ObservedObject var store = WatchStore.shared

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: rule.folder)).resizable().frame(width: 40, height: 40)
                KindBadge(kind: rule.fileKind, size: 18).offset(x: 4, y: 4)
            }
            .opacity(rule.enabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.folderURL.lastPathComponent).font(.system(size: 13, weight: .semibold))
                Text(rule.summary).font(.system(size: 12)).foregroundStyle(Theme.color(rule.fileKind))
                Text("Risultati in: " + (rule.outputURL.path.replacingOccurrences(of: Paths.home.path, with: "~")))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(rule.enabled ? Theme.green : Color.secondary).frame(width: 7, height: 7)
                    Text(rule.enabled ? "Attiva" : "In pausa").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(rule.enabled ? Theme.green : .secondary)
                }
                Text(rule.processed == 1 ? "1 file elaborato" : "\(rule.processed) file elaborati")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if let d = rule.lastRun {
                    Text("Ultimo: " + d.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in store.toggle(rule) }))
                .toggleStyle(.switch).labelsHidden()
                .help(rule.enabled ? "Metti in pausa" : "Riattiva")
            Menu {
                Button("Apri la cartella") { NSWorkspace.shared.open(rule.folderURL) }
                Button("Apri i risultati") { NSWorkspace.shared.open(rule.outputURL) }
                Divider()
                Button("Elimina la regola", role: .destructive) { store.remove(rule) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(14)
        .card(radius: 12)
    }
}

/// Le scelte per le azioni con opzioni, le stesse delle manopole del pannello.
enum ParamChoices {
    static func options(for k: ParamKind) -> [KnobOption<String>]? {
        switch k {
        case .resize: return [
            KnobOption(value: "web", short: "Web", label: "Per il web (1600 px, JPG leggero)"),
            KnobOption(value: "1280", short: "1280", label: "Lato lungo 1280 px"),
            KnobOption(value: "1920", short: "1920", label: "Lato lungo 1920 px"),
            KnobOption(value: "3840", short: "4K", label: "Lato lungo 3840 px (4K)"),
            KnobOption(value: "half", short: "50%", label: "Metà (50%)")]
        case .icompress: return [
            KnobOption(value: "best", short: "Uguale", label: "Stessa qualità, meno peso"),
            KnobOption(value: "1000", short: "1 MB", label: "Sotto 1 MB"),
            KnobOption(value: "500", short: "500 KB", label: "Sotto 500 KB"),
            KnobOption(value: "200", short: "200 KB", label: "Sotto 200 KB (moduli online)"),
            KnobOption(value: "100", short: "100 KB", label: "Sotto 100 KB"),
            KnobOption(value: "50", short: "50 KB", label: "Sotto 50 KB (documenti, visti)"),
            KnobOption(value: "20", short: "20 KB", label: "Sotto 20 KB")]
        case .pdfcompress: return [
            KnobOption(value: "light", short: "Leggera", label: "Leggera (qualità di stampa)"),
            KnobOption(value: "medium", short: "Media", label: "Media (consigliata)"),
            KnobOption(value: "strong", short: "Forte", label: "Forte (file più piccolo possibile)")]
        case .vcompress: return [
            // 3.6 · Prima la qualità: «stessa qualità» non rovina niente; i pesi servono per i limiti delle app
            KnobOption(value: "best", short: "Uguale", label: "Stessa qualità, meno peso"),
            KnobOption(value: "9", short: "Discord", label: "Discord (sotto 10 MB)"),
            KnobOption(value: "15", short: "WhatsApp", label: "WhatsApp (sotto 16 MB)"),
            KnobOption(value: "24", short: "Email", label: "Email (sotto 25 MB)"),
            KnobOption(value: "50", short: "50", label: "50 MB"),
            KnobOption(value: "100", short: "100", label: "100 MB")]
        case .vresize: return [
            KnobOption(value: "480", short: "480p", label: "480p (leggero)"), KnobOption(value: "720", short: "720p", label: "720p (HD)"),
            KnobOption(value: "1080", short: "1080p", label: "1080p (Full HD)"),
            KnobOption(value: "hevc", short: "HEVC", label: "HEVC: stessa risoluzione, file più piccolo")]
        case .speed: return [
            KnobOption(value: "0.5", short: "0,5×", label: "0,5× (metà)"), KnobOption(value: "0.75", short: "0,75×", label: "0,75×"),
            KnobOption(value: "1.25", short: "1,25×", label: "1,25×"), KnobOption(value: "1.5", short: "1,5×", label: "1,5×"),
            KnobOption(value: "2", short: "2×", label: "2× (doppia)")]
        case .rotate: return [
            KnobOption(value: "270", short: "↺ 90°", label: "90° a sinistra"), KnobOption(value: "180", short: "180°", label: "180°"),
            KnobOption(value: "90", short: "↻ 90°", label: "90° a destra")]
        case .removebg: return [
            KnobOption(value: "transparent", short: "Trasp.", label: "Sfondo trasparente (PNG)"),
            KnobOption(value: "crop", short: "Ritaglio", label: "Trasparente e ritagliato sul soggetto (PNG)"),
            KnobOption(value: "white", short: "Bianco", label: "Sfondo bianco (JPG)")]
        case .straighten: return [
            KnobOption(value: "color-jpg", short: "JPG", label: "A colori, JPG"),
            KnobOption(value: "bw-jpg", short: "JPG b/n", label: "Bianco e nero, JPG"),
            KnobOption(value: "color-pdf", short: "PDF", label: "A colori, PDF"),
            KnobOption(value: "bw-pdf", short: "PDF b/n", label: "Bianco e nero, PDF")]
        case .upscale: return [
            KnobOption(value: "2", short: "2×", label: "2× (il doppio)"),
            KnobOption(value: "4", short: "4×", label: "4× (quattro volte)")]
        case .social: return [
            KnobOption(value: "9x16", short: "9:16", label: "9:16 · Reels, TikTok, Storie"),
            KnobOption(value: "1x1", short: "1:1", label: "1:1 · Post"),
            KnobOption(value: "4x5", short: "4:5", label: "4:5 · Feed verticale"),
            KnobOption(value: "16x9", short: "16:9", label: "16:9 · YouTube")]
        case .stack: return [
            KnobOption(value: "1", short: "1×", label: "Stessa dimensione, meno rumore"),
            KnobOption(value: "2", short: "2×", label: "2×, più dettagli")]
        case .aienhance: return [
            KnobOption(value: "b0-1", short: "Fedele", label: "Fedele · stessa dimensione"),
            KnobOption(value: "b0-2", short: "F 2×", label: "Fedele · 2×"),
            KnobOption(value: "b0-4", short: "F 4×", label: "Fedele · 4×"),
            KnobOption(value: "b30-2", short: "30% 2×", label: "Fedele con un po’ di nitidezza · 2×"),
            KnobOption(value: "b100-2", short: "N 2×", label: "Più nitido · 2×"),
            KnobOption(value: "b100-4", short: "N 4×", label: "Più nitido · 4×")]
        default: return nil
        }
    }

    static func defaultValue(for k: ParamKind) -> String {
        switch k {
        case .resize: return "1920"
        case .icompress: return "best"
        case .pdfcompress: return "medium"
        case .vcompress: return "best"
        case .vresize: return "1080"
        case .speed: return "1.5"
        case .rotate: return "90"
        case .removebg: return "transparent"
        case .straighten: return "color-jpg"
        case .upscale: return "2"
        case .aienhance: return "b0-2"
        case .stack: return "2"
        case .social: return "9x16"
        default: return ""
        }
    }
}

/// «Nuova cartella automatica»: cartella, tipo di file, cosa farne, dove mettere i risultati.
struct NewWatchView: View {
    let done: () -> Void
    @State private var folder: URL? = nil
    @State private var kind: Kind = .img
    @State private var actionId = ""
    @State private var param = ""
    @State private var output = "sub"
    @State private var outputPath = ""
    @State private var includeExisting = false

    private let kinds: [Kind] = [.img, .pdf, .video, .audio, .doc, .sheet, .slide, .text]
    /// Azioni adatte a lavorare da sole (niente che chieda di scegliere pagine, tagli o password).
    private static let excluded: Set<String> = ["rename", "merge", "cut", "gifcut", "extract", "reorder", "protect", "unprotect", "subembed",
                                                "ringtone", "vmerge", "amerge", "music",
                                                "pdfedit", "redact", "hidemark"]

    private var actions: [Action] {
        let base = Catalog.actions(for: kind, exts: [], mergeable: 0).filter { !Self.excluded.contains($0.id) }
        let presets = PresetStore.shared.presets(for: kind).map { PresetStore.shared.action(for: $0) }
        return presets + base
    }
    private var chosen: Action? { actions.first { $0.id == actionId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 22)).foregroundStyle(SidebarItem.automation.color)
                Text("Nuova cartella automatica").font(.system(size: 17, weight: .bold))
            }

            // 1. Cartella
            step("1", "Quale cartella") {
                HStack {
                    Text(folder?.path.replacingOccurrences(of: Paths.home.path, with: "~") ?? "Nessuna cartella scelta")
                        .foregroundStyle(folder == nil ? .secondary : Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Scegli…") { folder = chooseFolder(prompt: "Sorveglia") ?? folder }
                }
            }

            // 2. Tipo di file
            step("2", "Quali file") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                    ForEach(kinds, id: \.self) { k in
                        Button { kind = k } label: {
                            HStack(spacing: 4) {
                                Image(systemName: Theme.symbol(k)).font(.system(size: 10, weight: .bold))
                                Text(k.label).font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1).fixedSize()
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(kind == k ? Color.white : Theme.color(k))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Capsule().fill(kind == k ? AnyShapeStyle(Theme.color(k).gradient) : AnyShapeStyle(Theme.color(k).opacity(0.14))))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 3. Azione
            step("3", "Cosa farne") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Azione", selection: $actionId) {
                        ForEach(actions) { a in
                            Label(a.title, systemImage: a.symbol).tag(a.id)
                        }
                    }
                    .labelsHidden()
                    if let pk = chosen?.param, let opts = ParamChoices.options(for: pk) {
                        Knob(title: "Opzione", options: opts, selection: $param, tint: Theme.color(kind), size: 90)
                    }
                }
            }

            // 4. Risultati
            step("4", "Dove mettere i risultati") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $output) {
                        Text("In una sottocartella «Convertiti»").tag("sub")
                        Text("In una cartella a scelta").tag("fixed")
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if output == "fixed" {
                        HStack {
                            Text(outputPath.isEmpty ? "Nessuna cartella scelta" : outputPath.replacingOccurrences(of: Paths.home.path, with: "~"))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Scegli…") { outputPath = chooseFolder(prompt: "Scegli")?.path ?? outputPath }
                        }
                    }
                    Toggle("Elabora anche i file già presenti nella cartella", isOn: $includeExisting)
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.brass)
            }

            HStack {
                Spacer()
                Button("Annulla") { done() }.keyboardShortcut(.cancelAction)
                Button("Crea") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(warning != nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.cream)
        .onAppear { pickFirstAction() }
        .onChange(of: kind) { _, _ in pickFirstAction() }
        .onChange(of: actionId) { _, _ in
            if let pk = chosen?.param { param = ParamChoices.defaultValue(for: pk) } else { param = "" }
        }
    }

    private var warning: String? {
        guard let f = folder else { return "Scegli la cartella da sorvegliare." }
        if chosen == nil { return "Scegli cosa fare con i file." }
        if output == "fixed" && outputPath.isEmpty { return "Scegli la cartella per i risultati." }
        if output == "fixed" && outputPath == f.path { return "I risultati devono andare in un’altra cartella, non in quella sorvegliata." }
        if WatchStore.shared.rules.contains(where: { $0.folder == f.path && $0.kind == kind.rawValue }) {
            return "Per questa cartella c’è già una regola per questo tipo di file."
        }
        return nil
    }

    private func pickFirstAction() {
        actionId = Catalog.suggested(for: kind, exts: []) ?? actions.first?.id ?? ""
        if !actions.contains(where: { $0.id == actionId }) { actionId = actions.first?.id ?? "" }
    }

    private func step<C: View>(_ n: String, _ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.ivory)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
            }
        }
    }

    private func chooseFolder(prompt: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.url : nil
    }

    private func create() {
        guard let f = folder, chosen != nil else { return }
        let rule = WatchRule(folder: f.path, kind: kind.rawValue, actionId: actionId, param: param,
                             output: output, outputPath: outputPath)
        WatchStore.shared.add(rule, includeExisting: includeExisting)
        done()
    }
}
