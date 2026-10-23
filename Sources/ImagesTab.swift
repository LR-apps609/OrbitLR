import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.8 · Scheda Immagini (layout A): le foto a sinistra, a destra il
//  pannello con tutto quello che si può fare, con il peso previsto.
//  Si lavora su tutte le foto o solo su quelle scelte.
// ════════════════════════════════════════════════════════════════════

final class ImagesTabModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var files: [URL] = []
    @Published var selection: Set<URL> = []
    @Published var pending: PendingParam? = nil
    @Published var lastJob: Job? = nil
    @Published private(set) var estimates: [String: Int64] = [:]
    @Published var notice: String? = nil
    private var estimateTask: Task<Void, Never>?

    static let maxFiles = 200

    /// Le foto su cui si lavora: quelle scelte, altrimenti tutte.
    var targets: [URL] { selection.isEmpty ? files : files.filter { selection.contains($0) } }

    var actions: [Action] {
        let exts = Set(targets.map { Catalog.norm($0.pathExtension) })
        return PresetStore.shared.merged(Catalog.actions(for: .img, exts: exts, mergeable: targets.count, count: targets.count), kind: .img)
    }

    /// I formati in cui convertire (in cima al pannello) e il resto (gli strumenti).
    var formats: [Action] { actions.filter { $0.id.hasPrefix("to:") } }
    var tools: [Action] { actions.filter { !$0.id.hasPrefix("to:") } }

    func add(_ urls: [URL]) {
        let all = PieController.expand(urls)
        let images = all.filter { Catalog.kind(of: $0) == .img }
        let others = all.count - images.count
        var seen = Set(files.map { $0.path })
        let fresh = images.filter { seen.insert($0.path).inserted }
        let room = max(0, Self.maxFiles - files.count)
        files += fresh.prefix(room)
        if others > 0 {
            notice = others == 1 ? "1 file non è un'immagine: aprilo da Conversione." : "\(others) file non sono immagini: aprili da Conversione."
        } else if fresh.count > room {
            notice = "Al massimo \(Self.maxFiles) foto insieme."
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
        guard !t.isEmpty else { return }
        estimateTask = Task.detached(priority: .utility) { [weak self] in
            let e = await SizeEstimate.estimates(actions: acts, files: t, kind: .img)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.estimates = e }
        }
    }
}

// MARK: - La scheda

struct ImagesTabView: View {
    @ObservedObject var m: ImagesTabModel
    @State private var targeted = false
    private let tint = Theme.color(.img)
    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 10)]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if m.files.isEmpty {
                    MediaDropZone(kind: .img, title: "Trascina qui le foto",
                                  subtitle: "oppure clicca per sceglierle · JPG, PNG, HEIC, RAW e altre · fino a \(ImagesTabModel.maxFiles) insieme",
                                  targeted: targeted) { choose() }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(m.files, id: \.self) { u in
                                ImageTile(url: u, selected: m.selection.contains(u), tint: tint,
                                          tap: { extend in m.toggle(u, extend: extend) },
                                          remove: { withAnimation(.easeOut(duration: 0.15)) { m.remove(u) } })
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                if let n = m.notice {
                    Label(n, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let job = m.lastJob { JobStrip(job: job) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            ImagesInspector(m: m, tint: tint)
                .frame(width: 300)
        }
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in m.add(urls) }
            return true
        }
        .sheet(item: $m.pending) { p in
            ParamView(kind: p.kind, action: p.action, files: p.files) { v in m.confirm(p, value: v) }
        }
        .navigationTitle("Immagini")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Immagini").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !m.files.isEmpty {
                if !m.selection.isEmpty {
                    Button("Tutte") { m.selection = []; m.refreshEstimates() }
                        .help("Lavora su tutte le foto, non solo su quelle scelte")
                }
                Button("Aggiungi…") { choose() }
                Button { m.clear() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .help("Togli tutte le foto dalla scheda (i file restano dove sono)")
                    .accessibilityLabel("Togli tutte le foto")
            }
        }
    }

    private var subtitle: String {
        if m.files.isEmpty { return "Converti, ridimensiona, togli lo sfondo e altro, su una o tante foto" }
        if m.selection.isEmpty { return "\(m.files.count) foto · clicca per sceglierne alcune, ⌘-clic per sceglierne più di una" }
        return "\(m.selection.count) di \(m.files.count) foto scelte"
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.image]
        p.message = "Scegli le foto"
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
    @ObservedObject var m: ImagesTabModel
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.targets.isEmpty ? "Cosa vuoi fare?" : (m.targets.count == 1 ? "Su 1 foto" : "Su \(m.targets.count) foto"))
                        .font(.system(size: 15, weight: .bold))
                    Text(m.targets.isEmpty ? "Aggiungi delle foto per iniziare." : "Ora: " + ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                section("Converti in") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(m.formats) { a in formatButton(a) }
                    }
                }
                section("Strumenti") {
                    VStack(spacing: 4) {
                        ForEach(m.tools) { a in toolRow(a) }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.card.opacity(0.5))
        .disabled(m.files.isEmpty)
        .opacity(m.files.isEmpty ? 0.55 : 1)
    }

    private var currentBytes: Int64 { m.targets.reduce(Int64(0)) { $0 + Job.size(of: $1) } }

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
                    Text(a.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if !a.hint.isEmpty {
                        Text(a.hint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if a.param != nil {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(a.param != nil ? "Si aprono le opzioni prima di iniziare" : "Parte subito")
    }
}
