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
        return PresetStore.shared.merged(Catalog.actions(for: k, exts: exts, mergeable: mergeable, count: targets.count), kind: k)
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
    var targetBytes: Int64 { targets.reduce(Int64(0)) { $0 + Job.size(of: $1) } }

    func add(_ urls: [URL]) {
        let all = PieController.expand(urls)
        let images = all.filter { Catalog.kind(of: $0).map { accepts.contains($0) } ?? false }
        let others = all.count - images.count
        var seen = Set(files.map { $0.path })
        let fresh = images.filter { seen.insert($0.path).inserted }
        let room = max(0, Self.maxFiles - files.count)
        files += fresh.prefix(room)
        if others > 0 {
            let what = accepts == [.img] ? "un’immagine" : (accepts == [.video] ? "un video" : "un documento")
            let whatMany = accepts == [.img] ? "immagini" : (accepts == [.video] ? "video" : "documenti")
            notice = others == 1 ? "1 file non è \(what): aprilo da Conversione." : "\(others) file non sono \(whatMany): aprili da Conversione."
        } else if fresh.count > room {
            notice = "Al massimo \(Self.maxFiles) file insieme."
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
        guard !t.isEmpty else { NSSound.beep(); return }
        var a = chosen
        var presetParam: String? = nil
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
        title: "Immagini", kind: .img, dropTitle: "Trascina qui le foto",
        dropSubtitle: "oppure clicca per sceglierle · JPG, PNG, HEIC, RAW, PSD, AVIF e altre · fino a \(KindTabModel.maxFiles) insieme",
        intro: "Converti, ridimensiona, togli lo sfondo e altro, su una o tante foto", noun: "foto", types: [.image])

    /// 3.0 · Gli strumenti veloci della scheda Video, nella stessa disposizione di Immagini e File.
    static let video = KindTabStyle(
        title: "Video", kind: .video, dropTitle: "Trascina qui i video",
        dropSubtitle: "oppure clicca per sceglierli · MP4, MOV, MKV, AVI e altri · fino a \(KindTabModel.maxFiles) insieme",
        intro: "Comprimi, taglia, fai una GIF e altro, su uno o tanti video", noun: "video", types: [.movie])

    static let files = KindTabStyle(
        title: "File", kind: .pdf, dropTitle: "Trascina qui PDF e documenti",
        dropSubtitle: "oppure clicca per sceglierli · PDF, Word, Excel, PowerPoint, testi · fino a \(KindTabModel.maxFiles) insieme",
        intro: "Unisci, comprimi, converti e proteggi PDF e documenti", noun: "file",
        types: [.pdf, .plainText, .rtf, .html, UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"),
                UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "pptx"), UTType(filenameExtension: "odt"),
                UTType(filenameExtension: "md"), UTType(filenameExtension: "wps"), UTType(filenameExtension: "wpd")].compactMap { $0 })
}

struct KindTabView: View {
    @ObservedObject var m: KindTabModel
    let style: KindTabStyle
    @State private var targeted = false
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
            ImagesInspector(m: m, tint: tint, noun: style.noun)
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
        .navigationTitle(style.title)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .help(m.files.isEmpty ? "" : (fem ? "Clic su una foto per sceglierla, ⌘-clic per sceglierne più di una" : "Clic su un file per sceglierlo, ⌘-clic per sceglierne più di uno"))
            }
            if style.kind == .video { VideoModeSwitch().padding(.leading, 8) }
            Spacer()
            if !m.files.isEmpty {
                if !m.selection.isEmpty {
                    Button(fem ? "Tutte" : "Tutti") { m.selection = []; m.refreshEstimates() }
                        .help(fem ? "Lavora su tutte le foto, non solo su quelle scelte" : "Lavora su tutti i file, non solo su quelli scelti")
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
        let size = ByteCountFormatter.string(fromByteCount: m.targetBytes, countStyle: .file)
        if m.selection.isEmpty { return "\(m.files.count) \(style.noun) · \(size)" }
        return "\(m.selection.count) di \(m.files.count) \(style.noun) " + (fem ? "scelte" : "scelti") + " · \(size)"
    }

    private var fem: Bool { style.noun == "foto" }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = style.types
        p.message = style.kind == .img ? "Scegli le foto" : (style.kind == .video ? "Scegli i video" : "Scegli i file")
        if p.runModal() == .OK { m.add(p.urls) }
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

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(tint)
                }
            }
            .frame(height: 104)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.brass : (hover ? tint.opacity(0.5) : .clear),
                                                                     lineWidth: selected ? 3 : 1.5))
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .bold))
                            .symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.black.opacity(0.6))
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
        .task(id: url.path) { ThumbCache.shared.image(for: url, side: 220) { image = $0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent + (selected ? ", scelta" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Il pannello a destra

private struct ImagesInspector: View {
    @ObservedObject var m: KindTabModel
    let tint: Color
    let noun: String
    @State private var hovered: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cosa vuoi fare?").font(.system(size: 15, weight: .bold))
                    Text(scope).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if m.kindCount > 1 {
                    // 2.8.2 · Tipi diversi insieme: si sceglie su quali lavorare
                    section("Tipi diversi") {
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
                if !m.formats.isEmpty { section("Converti in") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(m.formats) { a in formatButton(a) }
                    }
                } }
                ForEach(m.toolGroups) { g in
                    section(g.title) {
                        VStack(spacing: 2) {
                            ForEach(g.actions) { a in toolRow(a) }
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
        if m.files.isEmpty { return fem ? "Aggiungi delle foto per iniziare." : (noun == "video" ? "Aggiungi dei video per iniziare." : "Aggiungi dei file per iniziare.") }
        let n = m.targets.count
        if !m.selection.isEmpty { return n == 1 ? (fem ? "Sulla foto scelta" : "Sul \(noun) scelto") : (fem ? "Sulle \(n) foto scelte" : "Sui \(n) \(noun) scelti") }
        if n == 1 { return fem ? "Sulla foto" : (noun == "video" ? "Sul video" : "Sul file") }
        return fem ? "Su tutte le \(n) foto" : "Su tutti i \(n) \(noun)"
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
        .buttonStyle(.plain)
        .help(a.title + (a.hint.isEmpty ? "" : " · " + a.hint))
        .accessibilityLabel(a.title)
        .accessibilityValue(m.estimates[a.id].map { "peso previsto " + SizeEstimate.label($0).replacingOccurrences(of: "≈ ", with: "circa ") } ?? "")
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
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? a.id : (hovered == a.id ? nil : hovered) }
        .help(a.param != nil ? "Prima scegli le opzioni, poi parte" : "Parte subito")
    }
}
