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

    /// 5.1 · Elimina con «Annulla» e ⌘Z: l'azione torna al suo posto.
    func deleteUndoably(_ p: Preset) {
        guard let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        let old = presets[i]
        delete(old)
        UndoToast.shared.post(String(localized: "Eliminata «\(old.name)»."), at: .shortcuts) { [weak self] in self?.restore(old, at: i) }
    }

    /// 5.1 · Rimette un'azione eliminata; il tasto torna solo se nel frattempo nessun'altra l'ha preso.
    func restore(_ p: Preset, at index: Int) {
        guard !presets.contains(where: { $0.id == p.id }) else { return }
        var p = p
        if let k = p.hotkey, presets.contains(where: { $0.hotkey == k }) { p.hotkey = nil }
        presets.insert(p, at: min(max(0, index), presets.count))
    }

    /// 5.1 · Le regole automatiche che usano questa azione (senza di lei smetterebbero di funzionare).
    static func rules(using p: Preset, in rules: [WatchRule]) -> [WatchRule] {
        rules.filter { $0.actionId == "preset:" + p.id.uuidString }
    }

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
                UndoToastBar(place: .shortcuts)          // 5.1
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
            Button(role: .destructive) { askDelete() } label: { Image(systemName: "trash") }
                .help("Elimina la scorciatoia").accessibilityLabel("Elimina la scorciatoia")
        }
        .padding(12)
        .card(radius: 12)
        .onAppear { name = preset.name }
    }

    /// 5.1 · Se una regola automatica usa questa azione, prima lo dice; poi si elimina con «Annulla».
    private func askDelete() {
        let p = preset
        let users = PresetStore.rules(using: p, in: WatchStore.shared.rules)
        guard !users.isEmpty else { store.deleteUndoably(p); return }
        let a = NSAlert()
        a.messageText = String(localized: "Eliminare «\(p.name)»?")
        a.informativeText = users.count == 1
            ? String(localized: "La regola «\(users[0].folderURL.lastPathComponent)» usa questa azione e smetterà di funzionare.")
            : String(localized: "\(users.count) regole automatiche usano questa azione e smetteranno di funzionare.")
        a.addButton(withTitle: String(localized: "Elimina"))
        a.addButton(withTitle: String(localized: "Annulla"))
        Sheet.confirmDestructive(a) { ok in if ok { PresetStore.shared.deleteUndoably(p) } }
    }
}

// MARK: - 5.1 · Al sicuro: eliminazioni annullabili e avvisi distruttivi

/// 5.1 · Dove compare la riga «Annulla»: nel punto in cui hai eliminato.
enum UndoPlace: Equatable { case shortcuts, automation, history, drawer, pieOrder }

/// 5.1 · Dopo un'eliminazione: una riga «Eliminata «Nome».» con «Annulla» per qualche secondo,
/// e ⌘Z nella finestra. Ogni elemento si rimette una volta sola, da qualunque delle due strade.
final class UndoToast: ObservableObject, @unchecked Sendable {
    static let shared = UndoToast()
    static let seconds: Double = 6

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let place: UndoPlace
        let text: String
    }

    /// Il bersaglio di ⌘Z, uno per eliminazione: «Annulla» nella riga toglie anche il suo ⌘Z.
    private final class Token {}

    @Published private(set) var item: Item? = nil
    private var restores: [UUID: () -> Void] = [:]
    private var tokens: [UUID: (Token, UndoManager?)] = [:]
    private var hide: DispatchWorkItem? = nil

    /// Registra l'eliminazione; `restore` rimette com'era. Senza `undoManager` usa quello della finestra.
    func post(_ text: String, at place: UndoPlace, undoManager: UndoManager? = nil, restore: @escaping () -> Void) {
        let it = Item(place: place, text: text)
        restores[it.id] = restore
        let token = Token()
        let um = undoManager ?? Self.windowUndoManager()
        tokens[it.id] = (token, um)
        um?.registerUndo(withTarget: token) { [weak self] _ in self?.perform(it.id) }
        item = it
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.item?.id == it.id else { return }
            self.item = nil
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds, execute: w)
    }

    /// «Annulla» nella riga: rimette l'elemento e toglie il ⌘Z che non serve più.
    func undo(_ id: UUID) {
        if let pair = tokens[id] { pair.1?.removeAllActions(withTarget: pair.0) }
        tokens[id] = nil
        perform(id)
    }

    /// Si può ancora rimettere? (per i test)
    func canRestore(_ id: UUID) -> Bool { restores[id] != nil }

    private func perform(_ id: UUID) {
        guard let r = restores.removeValue(forKey: id) else { return }
        r()
        if item?.id == id { item = nil }
    }

    /// La finestra del foglio aperto (es. «Personalizza il menu a torta»), altrimenti la finestra principale.
    private static func windowUndoManager() -> UndoManager? {
        if let k = NSApp?.keyWindow, k.sheetParent != nil { return k.undoManager }
        return AppState.shared.mainWindow?.undoManager ?? NSApp?.keyWindow?.undoManager
    }
}

/// 5.1 · La riga «Eliminata «Nome».  Annulla», nel punto dove è avvenuta l'eliminazione.
struct UndoToastBar: View {
    let place: UndoPlace
    @ObservedObject private var center = UndoToast.shared

    var body: some View {
        Group {
            if let it = center.item, it.place == place {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(it.text).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(String(localized: "undo.toast", defaultValue: "Annulla", comment: "Pulsante nella riga dopo un'eliminazione: rimette com'era")) {
                        center.undo(it.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.accent)
                    .help("Rimette com’era (anche con ⌘Z)")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .card(radius: 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.quick, value: center.item)
    }
}

extension Sheet {
    /// 5.1 · Avviso con il primo pulsante distruttivo: «Annulla» (il secondo) è il predefinito, con ↩ ed Esc.
    static func confirmDestructive(_ a: NSAlert, then: @escaping (Bool) -> Void) {
        let b = a.buttons
        let cancel: NSButton? = b.count >= 2 ? b[1] : nil
        if let cancel {
            b[0].hasDestructiveAction = true
            b[0].keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        // Un pulsante ha un solo tasto: Esc su «Annulla» si aggiunge qui, finché l'avviso è aperto
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, let cancel, let w = cancel.window, w.isKeyWindow else { return e }
            cancel.performClick(nil)
            return nil
        }
        confirm(a) { ok in
            if let monitor { NSEvent.removeMonitor(monitor) }
            then(ok)
        }
    }
}
