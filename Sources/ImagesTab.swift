import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.8 · Scheda Immagini (layout A): le foto a sinistra, a destra il
//  pannello con tutto quello che si può fare, con il peso previsto.
//  Si lavora su tutte le foto o solo su quelle scelte.
// ════════════════════════════════════════════════════════════════════

/// 2.8.2 · La stessa scheda serve a Immagini (solo foto) e a File (PDF, documenti, fogli, presentazioni, testi).
typealias ImagesTabModel = KindTabModel

final class KindTabModel: ObservableObject, @unchecked Sendable {
    /// I tipi di file che la scheda accetta.
    let accepts: [Kind]
    @Published private(set) var files: [URL] = []
    @Published var selection: Set<URL> = []
    @Published var pending: PendingParam? = nil
    @Published var lastJob: Job? = nil
    @Published private(set) var estimates: [String: Int64] = [:]
    @Published var notice: String? = nil
    private var estimateTask: Task<Void, Never>?

    static let maxFiles = 200

    init(accepts: [Kind] = [.img]) { self.accepts = accepts }

    /// I file su cui si lavora: quelli scelti, altrimenti tutti.
    var targets: [URL] { selection.isEmpty ? files : files.filter { selection.contains($0) } }

    /// Il tipo dei file su cui si lavora; nil se sono di tipi diversi (allora si chiede di sceglierne di un tipo solo).
    var kind: Kind? {
        let kinds = Set(targets.compactMap { Catalog.kind(of: $0) })
        return kinds.count == 1 ? kinds.first : nil
    }

    /// Quanti tipi diversi ci sono tra i file su cui si lavora.
    var kindCount: Int { Set(targets.compactMap { Catalog.kind(of: $0) }).count }

    var actions: [Action] {
        guard let k = kind else { return [] }
        let exts = Set(targets.map { Catalog.norm($0.pathExtension) })
        // «Unisci» mette insieme PDF e foto: conta i file che si possono unire
        let mergeable = targets.filter { [.pdf, .img].contains(Catalog.kind(of: $0)) }.count
        return RecipeStore.shared.merged(PresetStore.shared.merged(Catalog.actions(for: k, exts: exts, mergeable: mergeable, count: targets.count), kind: k), kind: k)
    }

    /// Seleziona solo i file di un tipo (quando ce ne sono di tipi diversi).
    func selectOnly(_ k: Kind) {
        selection = Set(files.filter { Catalog.kind(of: $0) == k })
        refreshEstimates()
    }

    /// I formati in cui convertire (in cima al pannello) e il resto (gli strumenti).
    var formats: [Action] { actions.filter { $0.id.hasPrefix("to:") } }
    var tools: [Action] { actions.filter { !$0.id.hasPrefix("to:") } }

    /// 3.0 · Gli strumenti divisi in pochi gruppi con un nome chiaro, nell'ordine di sempre.
    struct ToolGroup: Identifiable { let title: String; let actions: [Action]; var id: String { title } }

    var toolGroups: [ToolGroup] {
        let k = kind ?? .img
        var order: [String] = []
        var groups: [String: [Action]] = [:]
        for a in tools {
            let g = Catalog.toolGroup(a.id, kind: k)
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(a)
        }
        let fixed = Catalog.toolGroupOrder(kind: k)
        order.sort { (fixed.firstIndex(of: $0) ?? 99) < (fixed.firstIndex(of: $1) ?? 99) }
        return order.map { ToolGroup(title: $0, actions: groups[$0] ?? []) }
    }

    /// Il peso dei file su cui si lavora.
    /// 4.1.7 · Ricordato finché i file non cambiano (prima: una lettura del disco per file a ogni ridisegno)
    var targetBytes: Int64 {
        let t = targets
        if let c = bytesCache, c.files == t { return c.bytes }
        let b = t.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        bytesCache = (t, b)
        return b
    }
    private var bytesCache: (files: [URL], bytes: Int64)? = nil

    func add(_ urls: [URL]) {
        let all = PieController.expand(urls)
        let images = all.filter { Catalog.kind(of: $0).map { accepts.contains($0) } ?? false }
        let others = all.count - images.count
        var seen = Set(files.map { $0.path })
        let fresh = images.filter { seen.insert($0.path).inserted }
        let room = max(0, Self.maxFiles - files.count)
        files += fresh.prefix(room)
        if others > 0 {
            let what = accepts == [.img] ? String(localized: "un’immagine") : (accepts == [.video] ? String(localized: "un video") : String(localized: "un documento"))
            let whatMany = accepts == [.img] ? String(localized: "immagini") : (accepts == [.video] ? String(localized: "video") : String(localized: "documenti"))
            notice = others == 1 ? String(localized: "1 file non è \(what): aprilo da Converti.") : String(localized: "\(others) file non sono \(whatMany): aprili da Converti.")
        } else if fresh.count > room {
            notice = String(localized: "Al massimo \(Self.maxFiles) file insieme.")
        } else {
            notice = nil
        }
        refreshEstimates()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        selection.remove(url)
        refreshEstimates()
    }

    func clear() {
        files = []
        selection = []
        notice = nil
        lastJob = nil
        refreshEstimates()
    }

    func toggle(_ url: URL, extend: Bool) {
        if extend {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = selection == [url] ? [] : [url]
        }
        refreshEstimates()
    }

    func run(_ chosen: Action) {
        let t = targets
        guard !t.isEmpty else { notice = String(localized: "Aggiungi prima almeno un’immagine."); NSSound.beep(); return }
        var a = chosen
        var presetParam: String? = nil
        if let recipe = RecipeStore.shared.recipe(for: chosen) { lastJob = RecipeStore.shared.run(recipe, files: t); return }
        if let r = PresetStore.shared.resolve(chosen) { a = r.0; presetParam = r.1 }
        if Interactive.handles(a.id) { Interactive.open(a, files: t); return }
        if let p = presetParam {
            lastJob = QueueStore.shared.enqueue(files: t, action: a, param: p)
        } else if let pk = a.param {
            pending = PendingParam(kind: pk, action: a, files: t)
        } else {
            lastJob = QueueStore.shared.enqueue(files: t, action: a, param: "")
        }
    }

    func confirm(_ p: PendingParam, value: String?) {
        pending = nil
        if let v = value { lastJob = QueueStore.shared.enqueue(files: p.files, action: p.action, param: v) }
    }

    func refreshEstimates() {
        estimateTask?.cancel()
        estimates = [:]
        let t = targets, acts = formats
        guard !t.isEmpty, let k = kind else { return }
        estimateTask = Task.detached(priority: .utility) { [weak self] in
            let e = await SizeEstimate.estimates(actions: acts, files: t, kind: k)
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run { model.estimates = e }
        }
    }
}

// MARK: - La scheda

/// Testi e colori della scheda: Immagini o File.
struct KindTabStyle {
    let title: String
    let kind: Kind
    let dropTitle: String
    let dropSubtitle: String
    let intro: String
    let noun: String          // «foto» / «file»
    let types: [UTType]

    static let images = KindTabStyle(
        title: String(localized: "Immagini"), kind: .img, dropTitle: String(localized: "Trascina qui le foto"),
        dropSubtitle: String(localized: "oppure clicca per sceglierle · JPG, PNG, HEIC, RAW, PSD, AVIF e altre · fino a \(KindTabModel.maxFiles) insieme"),
        intro: String(localized: "Converti, ridimensiona, togli lo sfondo e altro, su una o tante foto"), noun: "foto", types: [.image])

    /// 3.0 · Gli strumenti veloci della scheda Video, nella stessa disposizione di Immagini e File.
    static let video = KindTabStyle(
        title: String(localized: "Video"), kind: .video, dropTitle: String(localized: "Trascina qui i video"),
        dropSubtitle: String(localized: "oppure clicca per sceglierli · MP4, MOV, MKV, AVI e altri · fino a \(KindTabModel.maxFiles) insieme"),
        intro: String(localized: "Comprimi, taglia, fai una GIF e altro, su uno o tanti video"), noun: "video", types: [.movie])

    static let files = KindTabStyle(
        title: String(localized: "PDF e documenti"), kind: .pdf, dropTitle: String(localized: "Trascina qui PDF e documenti"),
        dropSubtitle: String(localized: "oppure clicca per sceglierli · PDF, Word, Excel, PowerPoint, testi · fino a \(KindTabModel.maxFiles) insieme"),
        intro: String(localized: "Unisci, comprimi, converti e proteggi PDF e documenti"), noun: "file",
        types: [.pdf, .plainText, .rtf, .html, UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"),
                UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "pptx"), UTType(filenameExtension: "odt"),
                UTType(filenameExtension: "md"), UTType(filenameExtension: "wps"), UTType(filenameExtension: "wpd")].compactMap { $0 })
}

struct KindTabView: View {
    @ObservedObject var m: KindTabModel
    let style: KindTabStyle
    /// 5.0 · Semplice · Completo · (Editor), ricordato per ogni sezione
    @ObservedObject private var levels = LevelStore.shared
    private var level: ViewLevel { levels.level(style.kind) }
    @Environment(\.undoManager) private var undo
    @State private var targeted = false

    init(m: KindTabModel, style: KindTabStyle) {
        self.m = m
        self.style = style
    }

    /// L'interruttore: «Editor» apre l'editor della sezione (il montaggio, l'editor PDF) e non resta scelto.
    private var levelBinding: Binding<ViewLevel> {
        Binding(get: { level == .editor ? .complete : level }, set: { v in
            if v == .editor {
                if style.kind == .video {
                    VideoModeSwitch.openEditor(undo: undo)
                } else if style.kind == .pdf, let a = Catalog.action(id: "pdfedit", kind: .pdf) {
                    m.run(a)
                }
            } else {
                withAnimation(Motion.quick) { levels.set(style.kind, v) }
            }
        })
    }
    /// 4.1.3 · «Da un link…» (solo nella scheda Video)
    @State private var showLink = false
    @State private var linkText = ""
    private var tint: Color { Theme.color(style.kind) }
    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 10)]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if m.files.isEmpty {
                    MediaDropZone(kind: style.kind, title: style.dropTitle, subtitle: style.dropSubtitle,
                                  targeted: targeted) { choose() }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(m.files, id: \.self) { u in
                                ImageTile(url: u, selected: m.selection.contains(u), tint: Theme.color(Catalog.kind(of: u) ?? style.kind),
                                          tap: { extend in m.toggle(u, extend: extend) },
                                          remove: { withAnimation(Motion.quick) { m.remove(u) } })
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                if let n = m.notice {
                    Label(n, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if let job = m.lastJob { JobStrip(job: job) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            Group {
                if level == .complete {
                    ImagesInspector(m: m, tint: tint, noun: style.noun)
                } else {
                    SimplePanel(m: m, kind: style.kind, tint: tint) { withAnimation(Motion.quick) { levels.set(style.kind, .complete) } }
                }
            }
            .frame(width: 300)
        }
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in Sounds.drop(); m.add(urls) }
            return true
        }
        .sheet(item: $m.pending) { p in
            ParamView(kind: p.kind, action: p.action, files: p.files) { v in m.confirm(p, value: v) }
        }
        .sheet(isPresented: $showLink) {
            LinkSheet(video: true, initial: linkText, onDone: { file in m.add([file]) }, close: { showLink = false })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TitleAccent(color: Theme.color(style.kind)).padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(style.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .help(m.files.isEmpty ? "" : (fem ? String(localized: "Clic su una foto per sceglierla, ⌘-clic per sceglierne più di una") : String(localized: "Clic su un file per sceglierlo, ⌘-clic per sceglierne più di uno")))
                // 5.0 · L'interruttore sotto il titolo: la riga resta libera per il Downloader e i pulsanti
                Group {
                    if style.kind == .video {
                        VideoModeSwitch()          // lo stesso interruttore, con ⇧⌘E per il montaggio
                    } else {
                        LevelPicker(level: levelBinding, editorTitle: Levels.editorTitle(style.kind))
                    }
                }
                .padding(.top, 6)
            }
            .layoutPriority(1)          // 4.1.6 · prima il titolo; la barra del downloader prende lo spazio che resta
            Spacer()
            // 4.1.3 · Discreto, come nella scheda Audio
            if style.kind == .video {
                DownloaderBar(video: true) { t in linkText = t; showLink = true }
                    .help("Incolla il link di un video: arriva qui, pronto da tagliare, comprimere o montare")
            }
            if !m.files.isEmpty {
                if !m.selection.isEmpty {
                    Button(fem ? String(localized: "Tutte") : String(localized: "Tutti")) { m.selection = []; m.refreshEstimates() }
                        .help(fem ? String(localized: "Lavora su tutte le foto, non solo su quelle scelte") : String(localized: "Lavora su tutti i file, non solo su quelli scelti"))
                }
                Button("Aggiungi…") { choose() }
                Button { m.clear() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .help("Togli tutto dalla scheda (i file restano dove sono)")
                    .accessibilityLabel("Togli tutto dalla scheda")
            }
        }
    }

    /// 3.0 · «3 foto · 2,8 MB»: quanti e quanto pesano, niente istruzioni (sono nel suggerimento).
    private var subtitle: String {
        if m.files.isEmpty { return style.intro }
        let size = Fmt.bytes(m.targetBytes)
        // 4.2 · Un file solo: il nome al singolare (in inglese «1 photo», non «1 photos»)
        let noun = m.files.count == 1 ? Self.singular(style.noun) : String(localized: String.LocalizationValue(style.noun))
        if m.selection.isEmpty { return String(localized: "\(m.files.count) \(noun) · \(size)") }
        return fem ? String(localized: "\(m.selection.count) di \(m.files.count) \(noun) scelte · \(size)")
                   : String(localized: "\(m.selection.count) di \(m.files.count) \(noun) scelti · \(size)")
    }

    private var fem: Bool { style.noun == "foto" }

    static func singular(_ noun: String) -> String {
        switch noun {
        case "foto": return String(localized: "noun.photo", defaultValue: "foto")
        case "video": return String(localized: "noun.video", defaultValue: "video")
        default: return String(localized: "noun.file", defaultValue: "file")
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = style.types
        p.message = style.kind == .img ? String(localized: "Scegli le foto") : (style.kind == .video ? String(localized: "Scegli i video") : String(localized: "Scegli i file"))
        Sheet.choose(p) { urls in if !urls.isEmpty { m.add(urls) } }
    }
}

private struct ImageTile: View {
    let url: URL
    let selected: Bool
    let tint: Color
    let tap: (Bool) -> Void
    let remove: () -> Void
    @State private var image: NSImage? = nil
    @State private var hover = false

    init(url: URL, selected: Bool, tint: Color, tap: @escaping (Bool) -> Void, remove: @escaping () -> Void) {
        self.url = url; self.selected = selected; self.tint = tint; self.tap = tap; self.remove = remove
        _image = State(initialValue: ThumbCache.shared.cached(for: url, side: 220))     // 3.4.4 · subito, se già pronta
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(tint.opacity(0.6))
                }
            }
            .frame(height: 104)
            .animation(Motion.quick, value: image != nil)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.brass : (hover ? tint.opacity(0.5) : .clear),
                                                                     lineWidth: selected ? 3 : 1.5))
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .bold))
                            .symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.black.opacity(0.6))
                            .hitArea()                      // 5.2 · area di clic di almeno 24 pt
                    }
                    .buttonStyle(.plain).padding(5)
                    .help("Togli dalla scheda (il file resta dov’è)")
                    .accessibilityLabel("Togli dalla scheda")
                }
            }
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .bold))
                        .symbolRenderingMode(.palette).foregroundStyle(Color.white, Theme.brass).padding(5)
                }
            }
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Theme.ink : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)) }
        .onHover { hover = $0 }
        .fileDrag(url)
        .task(id: url.path) {
            let img = await ThumbCache.shared.image(for: url, side: 220)
            guard !Task.isCancelled else { return }
            if img !== image { image = img }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected ? String(localized: "\(url.lastPathComponent), scelta") : url.lastPathComponent)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Il pannello a destra

private struct ImagesInspector: View {
    @ObservedObject var m: KindTabModel
    let tint: Color
    let noun: String
    @State private var hovered: String? = nil
    /// Il gruppo aperto (nil: il primo; "": nessuno)
    @State private var open: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cosa vuoi fare?").font(.system(size: 15, weight: .bold))
                    Text(scope).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if m.kindCount > 1 {
                    // 2.8.2 · Tipi diversi insieme: si sceglie su quali lavorare
                    section(String(localized: "Tipi diversi")) {
                        Text("Ogni tipo di file ha le sue azioni. Scegli su quali lavorare:")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(kinds, id: \.self) { k in
                            Button { m.selectOnly(k) } label: {
                                Label("Solo \(k.label)", systemImage: Theme.symbol(k))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .tint(Theme.color(k))
                        }
                    }
                }
                if !m.formats.isEmpty { section(String(localized: "Converti in")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(m.formats) { a in formatButton(a) }
                    }
                } }
                // 5.0 · Completo: i gruppi si aprono uno alla volta (il primo aperto)
                ForEach(m.toolGroups) { g in
                    let isOpen = (open ?? m.toolGroups.first?.title) == g.title
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(Motion.quick) { open = isOpen ? "" : g.title }
                        } label: {
                            HStack(spacing: 6) {
                                SectionLabel(text: g.title)
                                Text("\(g.actions.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                Spacer()
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(g.title)
                        .accessibilityValue(isOpen ? String(localized: "aperto") : String(localized: "chiuso"))
                        if isOpen {
                            VStack(spacing: 2) {
                                ForEach(g.actions) { a in toolRow(a) }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.card.opacity(0.5))
        .disabled(m.files.isEmpty)
        .opacity(m.files.isEmpty ? 0.55 : 1)
    }

    private var currentBytes: Int64 { m.targetBytes }

    /// Su quali file si lavora, in parole.
    private var scope: String {
        let fem = noun == "foto"
        let shown = String(localized: String.LocalizationValue(noun))
        if m.files.isEmpty { return fem ? String(localized: "Aggiungi delle foto per iniziare.") : (noun == "video" ? String(localized: "Aggiungi dei video per iniziare.") : String(localized: "Aggiungi dei file per iniziare.")) }
        let n = m.targets.count
        if !m.selection.isEmpty { return n == 1 ? (fem ? String(localized: "Sulla foto scelta") : (noun == "video" ? String(localized: "Sul video scelto") : String(localized: "Sul file scelto"))) : (fem ? String(localized: "Sulle \(n) foto scelte") : String(localized: "Sui \(n) \(shown) scelti")) }
        if n == 1 { return fem ? String(localized: "Sulla foto") : (noun == "video" ? String(localized: "Sul video") : String(localized: "Sul file")) }
        return fem ? String(localized: "Su tutte le \(n) foto") : String(localized: "Su tutti i \(n) \(shown)")
    }

    private var kinds: [Kind] {
        var seen = Set<Kind>()
        return m.targets.compactMap { Catalog.kind(of: $0) }.filter { seen.insert($0).inserted }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            content()
        }
    }

    private func formatButton(_ a: Action) -> some View {
        Button { m.run(a) } label: {
            VStack(spacing: 3) {
                Text(a.short).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                if let b = m.estimates[a.id] {
                    Text(SizeEstimate.label(b)).font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .foregroundStyle(b < currentBytes ? Theme.green : Theme.brass)
                } else {
                    Text(" ").font(.system(size: 10))
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(Pressable())
        .help(a.title + (a.hint.isEmpty ? "" : " · " + a.hint))
        .accessibilityLabel(a.title)
        .accessibilityValue(m.estimates[a.id].map { b -> String in
            let s = SizeEstimate.label(b).replacingOccurrences(of: "≈ ", with: String(localized: "circa "))
            return String(localized: "peso previsto \(s)")
        } ?? "")
    }

    private func toolRow(_ a: Action) -> some View {
        Button { m.run(a) } label: {
            HStack(spacing: 10) {
                Image(systemName: a.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !a.hint.isEmpty {
                        // 3.0 · La spiegazione intera, mai tagliata
                        Text(a.hint).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if a.param != nil {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered == a.id ? tint.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovered = $0 ? a.id : (hovered == a.id ? nil : hovered) }
        .help(a.param != nil ? String(localized: "Prima scegli le opzioni, poi parte") : String(localized: "Parte subito"))
    }
}
