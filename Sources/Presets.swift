import Foundation
import SwiftUI
import AppKit

/// Una combinazione salvata, es. «Instagram: lato lungo 1080 px» o «Email: video sotto 25 MB».
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: String          // Kind.rawValue
    var actionId: String      // es. "resize", "vcompress", "to:jpg"
    var param: String
    var hotkey: Int? = nil    // 1…9 → ⌃⌥1…9
}

final class PresetStore: ObservableObject, @unchecked Sendable {
    static let shared = PresetStore()
    private var url: URL { Paths.support.appendingPathComponent("presets.json") }

    @Published var presets: [Preset] = [] {
        didSet { save(); registerHotkeys() }
    }

    init() {
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([Preset].self, from: d) {
            presets = p
        }
    }

    func add(name: String, kind: Kind, action: Action, param: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        presets.append(Preset(name: clean.isEmpty ? action.title : clean, kind: kind.rawValue, actionId: action.id, param: param))
    }

    func delete(_ p: Preset) { presets.removeAll { $0.id == p.id } }

    func setHotkey(_ n: Int?, for p: Preset) {
        var list = presets
        if let n { for i in list.indices where list[i].hotkey == n { list[i].hotkey = nil } }   // un tasto, un preset
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i].hotkey = n }
        presets = list
    }

    func rename(_ p: Preset, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[i].name = name
    }

    func presets(for kind: Kind) -> [Preset] { presets.filter { $0.kind == kind.rawValue } }

    /// Lo spicchio che rappresenta il preset nel menu a torta.
    func action(for p: Preset) -> Action {
        Action(id: "preset:" + p.id.uuidString, short: p.name, title: p.name,
               hint: Self.describe(actionId: p.actionId, param: p.param, kind: Kind(rawValue: p.kind)),
               symbol: "star.circle.fill")
    }

    /// Da spicchio di preset ad azione vera + parametro già pronto.
    func resolve(_ a: Action) -> (Action, String)? {
        guard a.id.hasPrefix("preset:"), let uuid = UUID(uuidString: String(a.id.dropFirst(7))),
              let p = presets.first(where: { $0.id == uuid }), let k = Kind(rawValue: p.kind),
              let base = Catalog.action(id: p.actionId, kind: k) else { return nil }
        return (base, p.param)
    }

    /// Le azioni del menu con i preset inseriti dopo i primi 7 spicchi (le posizioni abituali non cambiano).
    func merged(_ base: [Action], kind: Kind) -> [Action] {
        let extra = presets(for: kind).map { action(for: $0) }
        guard !extra.isEmpty else { return base }
        var out = base
        out.insert(contentsOf: extra, at: min(7, out.count))
        return out
    }

    static func describe(actionId: String, param: String, kind: Kind?) -> String {
        let title = kind.flatMap { Catalog.action(id: actionId, kind: $0)?.title } ?? actionId
        switch actionId {
        case "resize":
            switch param {
            case "half": return String(localized: "\(title) · metà")
            case "web": return String(localized: "\(title) · per il web")
            default: return String(localized: "\(title) · \(param) px")
            }
        case "vcompress": return param == "best" ? String(localized: "\(title) · stessa qualità") : String(localized: "\(title) · max \(param) MB")
        case "pdfcompress": return "\(title) · " + (param == "light" ? String(localized: "leggera") : param == "strong" ? String(localized: "forte") : String(localized: "media"))
        case "vresize": return "\(title) · " + (param == "hevc" ? "HEVC" : "\(param)p")
        case "speed": return "\(title) · \(param.replacingOccurrences(of: ".", with: ","))×"
        case "rotate": return "\(title) · \(param)°"
        case "upscale": return "\(title) · \(param)×"
        case "aienhance":
            let p = AIEnhance.parse(param)
            let style: String = p.strength == 0 ? String(localized: "fedele") : (p.strength == 100 ? String(localized: "più nitido") : String(localized: "intensità \(p.strength)%"))
            let size: String = p.factor == 1 ? String(localized: "stessa dimensione") : "\(p.factor)×"
            return "\(title) · \(style), \(size)"
        case "stack": return "\(title) · " + (param == "1" ? String(localized: "meno rumore") : "2×")
        case "removebg":
            let how: String = param == "white" ? String(localized: "sfondo bianco") : (param == "crop" ? String(localized: "ritagliato") : String(localized: "trasparente"))
            return "\(title) · \(how)"
        case "straighten":
            let color: String = param.hasPrefix("bw") ? String(localized: "b/n") : String(localized: "colori")
            let format: String = param.hasSuffix("pdf") ? "PDF" : "JPG"
            return "\(title) · \(color), \(format)"
        default: return param.isEmpty ? title : "\(title) · \(param)"
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(presets) { try? d.write(to: url, options: .atomic) }
    }

    func registerHotkeys() {
        Hotkey.shared.registerPresets(presets.compactMap { $0.hotkey })
    }

    /// ⌃⌥1…9 sui file selezionati nel Finder: applica il preset senza aprire il menu.
    func run(hotkey n: Int) {
        guard let p = presets.first(where: { $0.hotkey == n }), let k = Kind(rawValue: p.kind),
              let base = Catalog.action(id: p.actionId, kind: k) else { NSSound.beep(); return }
        let files = FinderSelection.current().filter { Catalog.kind(of: $0) == k }
        guard !files.isEmpty else { NSSound.beep(); return }
        QueueStore.shared.enqueue(files: files, action: base, param: p.param)
    }
}

// MARK: - Pagina «Scorciatoie»

struct PresetsView: View {
    @ObservedObject var store = PresetStore.shared
    @State private var customizing = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: String(localized: "Le mie azioni"),
                           subtitle: String(localized: "Le azioni e le ricette che usi spesso, con le opzioni già scelte. Compaiono nel menu a torta del loro tipo di file."),
                           color: Theme.brass) {
                    Button { customizing = true } label: { Label("Personalizza il menu a torta", systemImage: "chart.pie") }
                }
                RecipesSection()
                if store.presets.isEmpty {
                    EmptyState(symbol: "star.circle", color: Theme.brass, title: String(localized: "Ancora nessuna azione salvata"),
                               text: String(localized: "Quando scegli un’azione con delle opzioni (ridimensiona, comprimi, velocità…), spunta «Salva tra le mie azioni». La ritroverai qui e nel menu a torta."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.presets) { p in PresetRow(preset: p) }
                        }
                        .padding(.bottom, 20)
                    }
                    Text("Assegna dei tasti: selezioni i file nel Finder, premi ⌃⌥ e il numero, e l’azione parte senza aprire il menu.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $customizing) { PieCustomizeView { customizing = false } }
        .navigationTitle("Le mie azioni")
    }
}

struct PresetRow: View {
    let preset: Preset
    @ObservedObject var store = PresetStore.shared
    @State var name = ""

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: Kind(rawValue: preset.kind), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Nome", text: $name, onCommit: { store.rename(preset, to: name) })
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                Text(PresetStore.describe(actionId: preset.actionId, param: preset.param, kind: Kind(rawValue: preset.kind)))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Tasti", selection: Binding(get: { preset.hotkey ?? 0 },
                                                     set: { store.setHotkey($0 == 0 ? nil : $0, for: preset) })) {
                Text("Nessuna").tag(0)
                ForEach(1...9, id: \.self) { n in Text("⌃⌥\(n)").tag(n) }
            }
            .frame(width: 190)
            Button(role: .destructive) { store.delete(preset) } label: { Image(systemName: "trash") }
                .help("Elimina la scorciatoia")
        }
        .padding(12)
        .card(radius: 12)
        .onAppear { name = preset.name }
    }
}
