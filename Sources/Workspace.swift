import SwiftUI
import AppKit
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class AppState: ObservableObject, @unchecked Sendable {
    static let shared = AppState()
    @Published var selection: SidebarItem? = .workspace
    let workspace = Workspace()
    /// La finestra principale, per riportarla in primo piano senza aprirne una seconda.
    weak var mainWindow: NSWindow?
    @Published var showBugReport = false
}

/// Un gruppo di file dello stesso tipo, con il suo menu a torta.
final class FileGroup: ObservableObject, Identifiable {
    let id = UUID()
    let kind: Kind
    @Published var files: [URL]
    let pie = PieModel()
    init(kind: Kind, files: [URL]) { self.kind = kind; self.files = files }
}

struct PendingParam: Identifiable {
    let id = UUID()
    let kind: ParamKind
    let action: Action
    let files: [URL]
    var mainFile: URL? { files.first { Catalog.kind(of: $0) != .sub } }
}

final class Workspace: ObservableObject, @unchecked Sendable {
    static let maxKinds = 6
    static let maxPerKind = 100

    @Published var groups: [FileGroup] = []
    @Published var pending: PendingParam? = nil
    @Published var lastJob: Job? = nil
    @Published var notice: String? = nil
    @Published var preview: URL? = nil
    private var subs: [URL] = []
    private var closing: Set<UUID> = []      // menu che si stanno richiudendo dopo «Svuota»

    var single: FileGroup? { groups.count == 1 ? groups[0] : nil }
    var tint: Color { Theme.color(groups.count == 1 ? groups[0].kind : nil) }
    var allFiles: [URL] { groups.flatMap { $0.files } }

    /// Carica i file: stesso tipo → un solo menu grande; tipi diversi → un menu piccolo per tipo.
    func load(_ urls: [URL], append: Bool = false) {
        var byKind: [Kind: [URL]] = [:]
        var order: [Kind] = []
        if append {
            for g in groups where !closing.contains(g.id) { byKind[g.kind] = g.files; order.append(g.kind) }
        } else {
            subs = []
        }
        var skippedKinds = 0, skippedFiles = 0
        for f in PieController.expand(urls) {
            guard let k = Catalog.kind(of: f) else { continue }
            if k == .sub { if !subs.contains(f) { subs.append(f) }; continue }
            if byKind[k] == nil {
                if order.count >= Self.maxKinds { skippedKinds += 1; continue }
                order.append(k)
                byKind[k] = []
            }
            if byKind[k]!.contains(f) { continue }
            if byKind[k]!.count >= Self.maxPerKind { skippedFiles += 1; continue }
            byKind[k]!.append(f)
        }
        var msg: [String] = []
        if skippedKinds > 0 { msg.append("al massimo \(Self.maxKinds) tipi di file diversi alla volta") }
        if skippedFiles > 0 { msg.append("al massimo \(Self.maxPerKind) file dello stesso tipo") }
        notice = msg.isEmpty ? nil : "Ho tenuto " + msg.joined(separator: " e ") + ": gli altri non sono stati aggiunti."

        groups = order.compactMap { k in
            guard let f = byKind[k], !f.isEmpty else { return nil }
            return FileGroup(kind: k, files: f)
        }
        if !append { lastJob = nil }
        rebuildAll()
        if groups.isEmpty { NSSound.beep() }
    }

    func remove(_ file: URL, from group: FileGroup) {
        group.files.removeAll { $0 == file }
        if group.files.isEmpty { groups.removeAll { $0.id == group.id } }
        rebuildAll()
    }

    func removeGroup(_ group: FileGroup) {
        groups.removeAll { $0.id == group.id }
        rebuildAll()
    }

    /// Svuota: i menu si richiudono al centro, poi spariscono.
    func clear() {
        let ids = Set(groups.map { $0.id })
        closing.formUnion(ids)
        groups.forEach { $0.pie.shown = false }
        lastJob = nil
        notice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.groups.removeAll { ids.contains($0.id) }
            self.closing.subtract(ids)
        }
    }

    private var mergeable: Int {
        groups.filter { $0.kind == .pdf || $0.kind == .img }.reduce(0) { $0 + $1.files.count }
    }

    private func rebuildAll() {
        for g in groups { rebuild(g) }
        objectWillChange.send()
    }

    private func rebuild(_ gr: FileGroup) {
        let pie = gr.pie
        let exts = Set(gr.files.map { Catalog.norm($0.pathExtension) })
        let base = Catalog.actions(for: gr.kind, exts: exts, mergeable: mergeable)
        pie.setup(actions: PresetStore.shared.merged(base, kind: gr.kind))
        pie.tint = Theme.color(gr.kind)
        pie.suggestedId = Catalog.suggested(for: gr.kind, exts: exts)
        pie.lastId = UserDefaults.standard.string(forKey: "last_" + gr.kind.rawValue)
        pie.fileName = gr.files[0].lastPathComponent
        let bytes = gr.files.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        pie.subtitle = gr.files.count > 1 ? "e altri \(gr.files.count - 1) · \(size)" : size
        pie.icon = NSWorkspace.shared.icon(forFile: gr.files[0].path)
        pie.onClose = {}
        pie.onPick = { [weak self, weak gr] a in
            guard let self, let gr else { return }
            self.picked(a, in: gr)
        }
        loadThumbnail(gr.files[0], into: pie)
    }

    private func picked(_ chosen: Action, in gr: FileGroup) {
        var a = chosen
        var presetParam: String? = nil
        if let r = PresetStore.shared.resolve(chosen) { a = r.0; presetParam = r.1 }
        UserDefaults.standard.set(chosen.id, forKey: "last_" + gr.kind.rawValue)
        gr.pie.lastId = chosen.id
        var targets = gr.files + subs
        if Interactive.handles(a.id) { Interactive.open(a, files: gr.files); return }
        if a.id == "merge" {
            targets = groups.filter { $0.kind == .pdf || $0.kind == .img }.flatMap { $0.files }
        }
        if let p = presetParam {
            lastJob = QueueStore.shared.enqueue(files: targets, action: a, param: p)
        } else if let pk = a.param {
            pending = PendingParam(kind: pk, action: a, files: targets)
        } else {
            lastJob = QueueStore.shared.enqueue(files: targets, action: a, param: "")
        }
    }

    func confirm(_ p: PendingParam, value: String?) {
        pending = nil
        if let v = value { lastJob = QueueStore.shared.enqueue(files: p.files, action: p.action, param: v) }
    }

    func togglePreview() {
        preview = preview == nil ? groups.first?.files.first : nil
    }

    private func loadThumbnail(_ url: URL, into pie: PieModel) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240), scale: 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { pie.icon = img }
        }
    }
}

// MARK: - Vista

struct WorkspaceView: View {
    @ObservedObject var ws: Workspace
    @EnvironmentObject var app: AppState
    @State var targeted = false
    @State var hoverDrop = false

    var body: some View {
        ZStack {
            GlowBackground(tint: ws.groups.isEmpty ? Theme.accent : ws.tint)
            if ws.groups.isEmpty { empty } else { loaded }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in ws.load(urls, append: !ws.groups.isEmpty) }
            return true
        }
        .sheet(item: $ws.pending) { p in
            if (p.kind == .cut || p.kind == .gifcut), let url = p.mainFile {
                TrimEditorView(url: url, mode: p.kind) { v in ws.confirm(p, value: v) }
            } else {
                ParamView(kind: p.kind, action: p.action, files: p.files) { v in ws.confirm(p, value: v) }
            }
        }
        .quickLookPreview($ws.preview, in: ws.allFiles)
        .navigationTitle("Modifica e converti")
    }

    // Nessun file: grande area cliccabile
    private var empty: some View {
        Button(action: { choose(append: false) }) {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.16)).frame(width: 120, height: 120)
                    Circle().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1).frame(width: 120, height: 120)
                    Image(systemName: "plus").font(.system(size: 44, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .scaleEffect(hoverDrop || targeted ? 1.06 : 1)
                VStack(spacing: 6) {
                    Text(targeted ? "Rilascia per aprire" : "Trascina qui un file").font(.system(size: 22, weight: .bold))
                    Text("oppure clicca per sceglierlo · fino a \(Workspace.maxPerKind) file dello stesso tipo, o \(Workspace.maxKinds) tipi diversi")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach([Kind.pdf, .img, .video, .audio, .doc, .sheet], id: \.self) { k in
                        HStack(spacing: 5) {
                            Image(systemName: Theme.symbol(k)).font(.system(size: 10, weight: .bold))
                            Text(k.label).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.color(k))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.color(k).opacity(0.14)))
                    }
                }
            }
            .frame(maxWidth: 640, minHeight: 360)
            .frame(maxWidth: .infinity)
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.accent.opacity(targeted ? 0.14 : (hoverDrop ? 0.09 : 0.05))))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.accent.opacity(targeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoverDrop = $0 }
        .animation(.easeOut(duration: 0.15), value: hoverDrop)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .padding(40)
    }

    private var loaded: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if ws.groups.count > 1 {
                    Label("\(ws.groups.count) tipi di file · \(ws.allFiles.count) file", systemImage: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ws.togglePreview() } label: { Label("Anteprima", systemImage: "eye") }
                    .help("Anteprima del file (Spazio)")
                Button { choose(append: true) } label: { Label("Aggiungi file…", systemImage: "plus") }
                Button { ws.clear() } label: { Label("Svuota", systemImage: "xmark") }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if let n = ws.notice {
                Label(n, systemImage: "info.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.brass)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.brass.opacity(0.12)))
            }

            if let g = ws.single {
                SinglePie(ws: ws, group: g)
            } else {
                MultiPies(ws: ws)
            }

            statusBar
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .background(KeyCatcher { e in
            if e.keyCode == 49 { ws.togglePreview(); return true }          // Spazio = anteprima
            guard let g = ws.single else { return false }
            return PieKeys.handle(e, model: g.pie, close: { ws.clear() })
        })
    }

    @ViewBuilder private var statusBar: some View {
        if let job = ws.lastJob {
            JobStatusBar(job: job, openQueue: { app.selection = .queue },
                         onClose: { withAnimation(.easeOut(duration: 0.2)) { ws.lastJob = nil } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            HStack(spacing: 16) {
                hint("cursorarrow.motionlines", "Muovi il mouse verso un’azione")
                hint("hand.tap", "Clic per confermare")
                hint("space", "Spazio = anteprima")
                if ws.single != nil { hint("keyboard", "Tasti 1–8 · Invio = ultima scelta") }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func choose(append: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Apri"
        if panel.runModal() == .OK { ws.load(panel.urls, append: append) }
    }
}

/// Un solo tipo di file: menu grande al centro, X per togliere il file, elenco se sono più di uno.
struct SinglePie: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var group: FileGroup

    var body: some View {
        GeometryReader { g in
            let stripH: CGFloat = group.files.count > 1 ? 54 : 0
            let side = max(340, min(600, min(g.size.width - 80, g.size.height - 40 - stripH)))
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                PieView(model: group.pie, side: side,
                        removeHelp: group.files.count > 1 ? "Togli questo file" : "Togli il file",
                        onRemove: { ws.remove(group.files[0], from: group) })
                    .frame(width: side, height: side)
                Spacer(minLength: 0)
                if group.files.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(group.files, id: \.self) { f in
                                FileChip(url: f, tint: Theme.color(group.kind)) { ws.remove(f, from: group) }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .frame(height: stripH)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Più tipi di file: un menu piccolo per tipo, fino a 6.
struct MultiPies: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        GeometryReader { g in
            let cols = ws.groups.count <= 2 ? ws.groups.count : 3
            let rows = Int(ceil(Double(ws.groups.count) / Double(cols)))
            let side = max(230, min(340, min((g.size.width - 60) / CGFloat(cols) - 20,
                                             (g.size.height - 20) / CGFloat(rows) - 40)))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side + 20), spacing: 12), count: cols), spacing: 14) {
                    ForEach(ws.groups) { gr in
                        MiniPie(ws: ws, group: gr, side: side,
                        delay: Double(ws.groups.firstIndex { $0.id == gr.id } ?? 0) * 0.07)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }
}

struct MiniPie: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var group: FileGroup
    let side: CGFloat
    var delay: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            PieView(model: group.pie, side: side,
                    removeHelp: group.files.count > 1 ? "Togli questi \(group.files.count) file" : "Togli il file",
                    onRemove: { ws.removeGroup(group) }, delay: delay)
                .frame(width: side, height: side)
            HStack(spacing: 6) {
                Image(systemName: Theme.symbol(group.kind))
                Text(group.files.count > 1 ? "\(group.kind.label) · \(group.files.count) file" : group.kind.label)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.color(group.kind))
        }
    }
}

/// Nome del file con la X per toglierlo.
struct FileChip: View {
    let url: URL
    let tint: Color
    let onRemove: () -> Void
    @State var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    .foregroundStyle(hover ? Theme.color(.pdf) : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Togli questo file")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.ivory))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .onHover { hover = $0 }
    }
}

/// Avanzamento dell'ultima operazione avviata dalla finestra.
struct JobStatusBar: View {
    @ObservedObject var job: Job
    @EnvironmentObject var store: QueueStore
    let openQueue: () -> Void
    var onClose: (() -> Void)? = nil
    @State private var hoverClose = false

    var body: some View {
        HStack(spacing: 14) {
            FileThumb(url: job.outputs.first ?? job.mainFiles.first, kind: job.kind, size: 38)
                .fileDrag(job.outputs.first)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.action.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    SavedBadge(job: job)
                    Text(job.status).font(.system(size: 12)).foregroundStyle(job.state == .failed ? Theme.orange : .secondary).lineLimit(1)
                }
                if job.state == .running || job.state == .waiting {
                    TunerBar(value: job.shownProgress, tint: Theme.color(job.kind), height: 20)
                } else if job.state == .done {
                    TunerBar(value: 1, tint: Theme.green, done: true, height: 20)
                }
            }
            if let fix = Fix.best(for: job) {
                Button { store.apply(fix, to: job) } label: { Label(fix.label, systemImage: fix.symbol) }
                    .buttonStyle(.borderedProminent).tint(Theme.brass)
            }
            let pairs = job.comparePairs
            if !pairs.isEmpty {
                Button { CompareController.shared.show(pairs, title: job.title) } label: {
                    Label("Confronta", systemImage: "square.split.2x1")
                }
            }
            if job.state == .done && !job.outputs.isEmpty {
                Button("Mostra") { store.reveal(job.outputs.map { $0.path }) }.buttonStyle(.borderedProminent).tint(Theme.green)
            } else if job.state == .running {
                Button("Annulla") { store.cancel(job) }
            }
            Button("Coda") { openQueue() }
            if let onClose {
                // Chiude la barra (il lavoro resta nella Coda). Se sta ancora lavorando, continua in sottofondo.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hoverClose ? Theme.ink : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.ink.opacity(hoverClose ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
                .onHover { hoverClose = $0 }
                .help(job.state == .running || job.state == .waiting
                      ? "Nascondi: il lavoro continua e lo trovi nella Coda" : "Chiudi (il risultato resta nella Coda)")
            }
        }
        .padding(14)
        .card()
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Rende trascinabile il file creato (in Mail, WhatsApp, una cartella…).
    @ViewBuilder func fileDrag(_ url: URL?) -> some View {
        if let url {
            self.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Trascina il file creato dove ti serve")
        } else {
            self
        }
    }
}

/// Raccoglie i tasti premuti nella finestra (per scegliere gli spicchi con 1–8).
struct KeyCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.handler = handler
        return v
    }
    func updateNSView(_ v: KeyView, context: Context) { v.handler = handler }

    final class KeyView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, w.isKeyWindow,
                      !(w.firstResponder is NSTextView) else { return e }
                return (self.handler?(e) ?? false) ? nil : e
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
