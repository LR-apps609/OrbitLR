import AppKit
import SwiftUI

final class ParamController: @unchecked Sendable {
    static let shared = ParamController()
    private var panel: NSPanel?
    private var callback: ((String?) -> Void)?

    func ask(_ kind: ParamKind, action: Action, files: [URL], at point: NSPoint, done: @escaping (String?) -> Void) {
        close(nil)
        callback = done
        let isTrim = kind == .cut || kind == .gifcut
        let view: AnyView
        if isTrim, let url = files.first(where: { Catalog.kind(of: $0) != .sub }) {
            view = AnyView(TrimEditorView(url: url, mode: kind, onDone: { [weak self] v in self?.close(v) }))
        } else {
            view = AnyView(ParamView(kind: kind, action: action, files: files,
                                     onDone: { [weak self] v in self?.close(v) }))
        }
        let host = NSHostingView(rootView: view.background(Theme.cream))
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.contentView = host
        p.setContentSize(host.fittingSize)
        var origin = NSPoint(x: point.x - p.frame.width / 2, y: point.y - p.frame.height / 2)
        if let vf = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - p.frame.width)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - p.frame.height)
        }
        p.setFrameOrigin(origin)
        if isTrim { p.center() }
        WindowClose.once(p) { [weak self] in
            if self?.panel === p { self?.panel = nil; let cb = self?.callback; self?.callback = nil; cb?(nil) }
        }
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    private func close(_ value: String?) {
        let cb = callback
        callback = nil
        let p = panel
        panel = nil
        p?.orderOut(nil)
        cb?(value)
    }
}

/// "45", "1:30", "1:02:30,5" → secondi
func parseTime(_ s: String) -> Double? {
    let t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
    guard !t.isEmpty else { return nil }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }
    var total = 0.0
    for p in parts {
        guard let v = Double(p), v >= 0 else { return nil }
        total = total * 60 + v
    }
    return total
}

struct ParamView: View {
    let kind: ParamKind
    let action: Action
    let files: [URL]
    let onDone: (String?) -> Void

    @State var resize = "1920"
    @State var level = "medium"
    @State var mb = "25"
    @State var customMB = ""
    @State var start = "0:00"
    @State var end = ""
    @State var pages = "1"
    @State var vres = "1080"
    @State var speed = "1.5"
    @State var degrees = "90"
    @State var order = ""
    @State var password = ""
    @State var password2 = ""
    @State var baseName = ""
    @State var startNumber = "1"
    @State var digits = 3
    @State var error = ""
    @State var savePreset = false
    @State var choice = ""          // manopole delle azioni della 2.5 (sfondo, raddrizza, ingrandisci, scatti)
    @State var aiSize = "2"         // Migliora con IA: dimensione
    @State var aiStrength = "0"     // Migliora con IA: quanto «Più nitido» mescolare (0 = tutto Fedele)
    @State var presetName = ""

    private var presetable: Bool { [.resize, .pdfcompress, .vcompress, .vresize, .speed, .rotate, .removebg, .straighten, .upscale, .aienhance, .stack].contains(kind) }

    private var fileKind: Kind? { files.first.flatMap { Catalog.kind(of: $0) } }
    private var tint: Color { Theme.color(fileKind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                KindBadge(kind: fileKind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) file")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            content
            if presetable {
                if UserDefaults.standard.string(forKey: "controlStyle") == "knob" {
                    note("Gira la manopola trascinandola, con la rotellina o con le frecce. Un clic passa alla posizione successiva.")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            if presetable {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Salva come preset", isOn: $savePreset)
                    if savePreset {
                        TextField("Nome del preset, es. «Instagram»", text: $presetName)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.parchment.opacity(0.4)))
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.color(.pdf))
            }
            HStack {
                Spacer()
                Button("Annulla") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(tint)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 380)
        .onAppear {
            if kind == .gifcut { end = "0:05" }
            if kind == .rename { baseName = Self.suggestedBase(files) }
            if [.removebg, .straighten, .upscale, .stack].contains(kind) { choice = ParamChoices.defaultValue(for: kind) }
        }
    }

    private var toolTitle: String {
        switch kind {
        case .removebg: return "Risultato"
        case .straighten: return "Come salvarlo"
        case .stack: return "Risultato"
        default: return "Quanto"
        }
    }

    private var toolNote: String {
        switch kind {
        case .removebg: return "Funziona meglio con persone, animali e oggetti ben distinti dallo sfondo."
        case .straighten: return "OrbitLR trova il foglio nella foto, corregge la prospettiva e lo pulisce come una scansione."
        case .stack: return "Seleziona 3–10 foto della stessa scena (una raffica va benissimo) oppure un video breve: OrbitLR le allinea e le unisce. I dettagli vengono dagli scatti veri."
        default: return "Contorni nitidi con la tecnologia di Apple. Non inventa dettagli che non ci sono."
        }
    }

    private var confirmTitle: String {
        switch kind {
        case .resize: return "Ridimensiona"
        case .pdfcompress, .vcompress: return "Comprimi"
        case .cut: return "Taglia"
        case .gifcut: return "Crea la GIF"
        case .extract: return "Estrai"
        case .vresize: return "Converti"
        case .speed: return "Cambia velocità"
        case .rotate: return "Ruota"
        case .reorder: return "Riordina"
        case .password: return "Proteggi"
        case .unlock: return "Sblocca"
        case .rename: return "Rinomina"
        case .removebg: return "Rimuovi lo sfondo"
        case .straighten: return "Raddrizza"
        case .upscale: return "Ingrandisci"
        case .aienhance: return "Migliora"
        case .stack: return "Unisci"
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .resize:
            Knob(title: "Nuova dimensione", options: [
                KnobOption(value: "web", short: "Web", label: "Per il web (1600 px, JPG leggero)"),
                KnobOption(value: "1280", short: "1280", label: "Lato lungo 1280 px"),
                KnobOption(value: "1920", short: "1920", label: "Lato lungo 1920 px"),
                KnobOption(value: "3840", short: "4K", label: "Lato lungo 3840 px (4K)"),
                KnobOption(value: "half", short: "50%", label: "Metà (50%)"),
            ], selection: $resize, tint: tint)
            note("Le foto più piccole della misura scelta non vengono ingrandite.")
        case .pdfcompress:
            Knob(title: "Compressione", options: [
                KnobOption(value: "light", short: "Leggera", label: "Leggera (qualità di stampa)"),
                KnobOption(value: "medium", short: "Media", label: "Media (consigliata)"),
                KnobOption(value: "strong", short: "Forte", label: "Forte (file più piccolo possibile)"),
            ], selection: $level, tint: tint)
        case .vcompress:
            Knob(title: "Peso massimo", options: [
                KnobOption(value: "8", short: "8", label: "8 MB"),
                KnobOption(value: "16", short: "16", label: "16 MB"),
                KnobOption(value: "25", short: "25", label: "25 MB (email)"),
                KnobOption(value: "50", short: "50", label: "50 MB"),
                KnobOption(value: "100", short: "100", label: "100 MB"),
                KnobOption(value: "custom", short: "Altro", label: "Un altro peso, a scelta"),
            ], selection: $mb, tint: tint)
            if mb == "custom" {
                HStack {
                    TextField("MB", text: $customMB).frame(width: 80)
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            note("Risoluzione e qualità vengono scelte da sole per stare sotto il peso indicato.")
        case .cut, .gifcut:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inizio").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0:00", text: $start).frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fine").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("fino alla fine", text: $end).frame(width: 110)
                }
            }
        case .extract:
            TextField("1-3, 5, 8-", text: $pages)
            note("Esempi: 2 · 1-3 · 1,4,7-9 · 5- (dalla 5 alla fine)")
        case .vresize:
            Knob(title: "Risoluzione", options: [
                KnobOption(value: "480", short: "480p", label: "480p (leggero)"),
                KnobOption(value: "720", short: "720p", label: "720p (HD)"),
                KnobOption(value: "1080", short: "1080p", label: "1080p (Full HD)"),
                KnobOption(value: "hevc", short: "HEVC", label: "HEVC: stessa risoluzione, file più piccolo"),
            ], selection: $vres, tint: tint)
            note("Vale anche per i video verticali. I video più piccoli non vengono ingranditi.")
        case .speed:
            Knob(title: "Velocità", options: [
                KnobOption(value: "0.5", short: "0,5×", label: "0,5× (metà)"),
                KnobOption(value: "0.75", short: "0,75×", label: "0,75×"),
                KnobOption(value: "1.25", short: "1,25×", label: "1,25×"),
                KnobOption(value: "1.5", short: "1,5×", label: "1,5×"),
                KnobOption(value: "2", short: "2×", label: "2× (doppia)"),
            ], selection: $speed, tint: tint)
            note("La voce mantiene il suo tono, anche più veloce o più lenta.")
        case .rotate:
            Knob(title: "Ruota tutte le pagine", options: [
                KnobOption(value: "270", short: "↺ 90°", label: "90° a sinistra"),
                KnobOption(value: "180", short: "180°", label: "180°"),
                KnobOption(value: "90", short: "↻ 90°", label: "90° a destra"),
            ], selection: $degrees, tint: tint)
        case .reorder:
            HStack {
                TextField("es. 3,1,2 oppure 5-1", text: $order)
                Button("Al contrario") { onDone("reverse") }
            }
            note("Le pagine non indicate restano in fondo, nel loro ordine.")
        case .password:
            SecureField("Password", text: $password)
            SecureField("Ripeti la password", text: $password2)
            note("Senza questa password il PDF non si potrà aprire: conservala bene.")
        case .unlock:
            SecureField("Password attuale", text: $password)
        case .aienhance:
            HStack(alignment: .top, spacing: 8) {
                Knob(title: "Dimensione", options: [
                    KnobOption(value: "1", short: "1×", label: "Stessa dimensione"),
                    KnobOption(value: "2", short: "2×", label: "Il doppio"),
                    KnobOption(value: "4", short: "4×", label: "Quattro volte"),
                ], selection: $aiSize, tint: tint, size: 86)
                Knob(title: "Intensità", options: [
                    KnobOption(value: "0", short: "0", label: "Fedele: non inventa"),
                    KnobOption(value: "25", short: "25", label: "Fedele, un po’ più incisivo"),
                    KnobOption(value: "50", short: "50", label: "Metà e metà"),
                    KnobOption(value: "75", short: "75", label: "Quasi tutto Più nitido"),
                    KnobOption(value: "100", short: "100", label: "Più nitido: ricostruisce texture"),
                ], selection: $aiStrength, tint: tint, size: 86)
            }
            note("Intensità 0 = Fedele: pulisce e rende nitido senza inventare. Più sali, più il risultato è incisivo, ma il modello ricostruisce texture che nella foto non c’erano. Tra 1 e 99 si usano tutti e due i modelli (tempo doppio).")
        case .removebg, .straighten, .upscale, .stack:
            Knob(title: toolTitle, options: ParamChoices.options(for: kind) ?? [], selection: $choice, tint: tint)
            note(toolNote)
        case .rename:
            TextField("Nome", text: $baseName)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Da").foregroundStyle(.secondary)
                    TextField("1", text: $startNumber).frame(width: 56)
                }
                Picker("Cifre", selection: $digits) {
                    Text("1").tag(1); Text("01").tag(2); Text("001").tag(3); Text("0001").tag(4)
                }
                .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(previewNames, id: \.self) { n in
                    Text(n).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.parchment.opacity(0.5)))
            note("I file vengono rinominati in ordine di nome. Si può annullare dalla Cronologia.")
        }
    }

    private var previewNames: [String] {
        let sorted = files.filter { Catalog.kind(of: $0) != .sub }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let n0 = Int(startNumber) ?? 1
        let base = baseName.trimmingCharacters(in: .whitespaces).isEmpty ? "File" : baseName.trimmingCharacters(in: .whitespaces)
        var out = sorted.prefix(3).enumerated().map { i, f in
            "\(f.lastPathComponent)  →  \(base) \(String(format: "%0\(digits)d", n0 + i))" + (f.pathExtension.isEmpty ? "" : ".\(f.pathExtension)")
        }
        if sorted.count > 3 { out.append("… e altri \(sorted.count - 3)") }
        return out
    }

    static func suggestedBase(_ files: [URL]) -> String {
        guard let f = files.first else { return "" }
        var b = f.deletingPathExtension().lastPathComponent
        while let last = b.last, last.isNumber || last == " " || last == "_" || last == "-" { b.removeLast() }
        return b.isEmpty ? "File" : b
    }

    private func confirm() {
        error = ""
        switch kind {
        case .resize: finish(resize)
        case .pdfcompress: finish(level)
        case .vcompress:
            if mb == "custom" {
                let v = customMB.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "mb", with: "")
                guard let n = Int(v), n >= 1 else { error = "Scrivi un numero intero, ad esempio 25."; return }
                finish(String(n))
            } else { finish(mb) }
        case .cut, .gifcut:
            guard let s = parseTime(start) else { error = "Inizio non valido. Esempi: 45 · 1:30"; return }
            if end.trimmingCharacters(in: .whitespaces).isEmpty {
                finish(String(format: "%.3f|", s))
            } else {
                guard let e = parseTime(end), e > s else { error = "La fine deve essere dopo l’inizio."; return }
                finish(String(format: "%.3f|%.3f", s, e))
            }
        case .extract:
            let v = pages.replacingOccurrences(of: " ", with: "")
            guard v.range(of: #"^[0-9]+(-[0-9]*)?(,[0-9]+(-[0-9]*)?)*$"#, options: .regularExpression) != nil else {
                error = "Formato non valido. Esempi: 2 · 1-3 · 1,4,7-9"; return
            }
            finish(v)
        case .vresize: finish(vres)
        case .speed: finish(speed)
        case .rotate: finish(degrees)
        case .reorder:
            let v = order.replacingOccurrences(of: " ", with: "")
            if v == "reverse" { finish(v); return }
            guard v.range(of: #"^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$"#, options: .regularExpression) != nil else {
                error = "Formato non valido. Esempi: 3,1,2 · 5-1"; return
            }
            finish(v)
        case .password:
            guard !password.isEmpty else { error = "Scrivi una password."; return }
            guard password == password2 else { error = "Le due password non coincidono."; return }
            finish(password)
        case .unlock:
            guard !password.isEmpty else { error = "Scrivi la password del PDF."; return }
            finish(password)
        case .aienhance:
            finish("b\(aiStrength)-\(aiSize)")
        case .removebg, .straighten, .upscale, .stack:
            finish(choice.isEmpty ? ParamChoices.defaultValue(for: kind) : choice)
        case .rename:
            let base = baseName.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty, !base.contains("/"), !base.contains(":") else { error = "Scrivi un nome valido (senza / o :)."; return }
            guard let n = Int(startNumber), n >= 0 else { error = "Il numero iniziale deve essere un numero intero."; return }
            finish("\(base)|\(n)|\(digits)")
        }
    }

    /// Conferma: se richiesto salva anche il preset, poi avvia.
    private func finish(_ value: String?) {
        if let v = value, savePreset, presetable, let k = fileKind {
            PresetStore.shared.add(name: presetName, kind: k, action: action, param: v)
        }
        onDone(value)
    }
}
