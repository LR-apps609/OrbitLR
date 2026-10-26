import SwiftUI
import AppKit
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class AppState: ObservableObject, @unchecked Sendable {
    static let shared = AppState()
    /// 3.5 · Si riapre sulla scheda dove eri (solo le schede di lavoro)
    @Published var selection: SidebarItem? = {
        // 3.9 · «Scorciatoie» ora si chiama «Le mie azioni»: chi l'aveva lasciata aperta la ritrova
        let saved = UserDefaults.standard.string(forKey: "lastTab") ?? ""
        return SidebarItem(rawValue: saved == "Scorciatoie" ? "Le mie azioni" : saved)
    }()
        .flatMap { SidebarItem.kept.contains($0) ? $0 : nil } ?? .workspace {
        willSet { if newValue != selection { Perf.begin(.tabSwitch) } }      // 3.4.1 · misura del cambio scheda
        didSet { if let s = selection, SidebarItem.kept.contains(s) { UserDefaults.standard.set(s.rawValue, forKey: "lastTab") } }
    }
    let workspace = Workspace()
    /// La scheda Audio tiene il suo file anche quando si cambia scheda (la scheda Video è un progetto a sé).
    let audioTab = MediaTabModel(videoTab: false)
    /// 2.8 · Le foto della scheda Immagini restano anche cambiando scheda.
    let imagesTab = KindTabModel(accepts: [.img])
    /// 2.8.2 · La scheda File: PDF, documenti, fogli, presentazioni, testi.
    let filesTab = KindTabModel(accepts: [.pdf, .doc, .sheet, .slide, .text])
    /// 3.0 · Gli strumenti veloci della scheda Video (comprimi, taglia, GIF…), tolti dal menu a torta.
    let videoTools = KindTabModel(accepts: [.video])
    /// 3.7 · La scheda Video si apre sulle cose di base (taglia, comprimi, Discord, WhatsApp…);
    /// «Editor» apre il montaggio completo.
    @Published var videoMode: VideoMode = .tools
    /// La finestra principale, per riportarla in primo piano senza aprirne una seconda.
    weak var mainWindow: NSWindow?
    /// 3.5 · La finestra di cui si sorveglia la chiusura (una volta sola)
    static weak var closeWatched: NSWindow?
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

enum VideoMode: String { case montage, tools }

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
    /// 2.7: dove sono stati lasciati i file (la torta nasce da lì e vola al centro).
    var dropPoint: CGPoint? = nil
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
        if skippedKinds > 0 { msg.append(String(localized: "al massimo \(Self.maxKinds) tipi di file diversi alla volta")) }
        if skippedFiles > 0 { msg.append(String(localized: "al massimo \(Self.maxPerKind) file dello stesso tipo")) }
        let kept = msg.joined(separator: String(localized: " e "))
        notice = msg.isEmpty ? nil : String(localized: "Ho tenuto \(kept): gli altri non sono stati aggiunti.")

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
        let base = Catalog.pieActions(for: gr.kind, exts: exts, mergeable: mergeable, count: gr.files.count)
        pie.setup(actions: RecipeStore.shared.merged(PresetStore.shared.merged(base, kind: gr.kind), kind: gr.kind))
        pie.loadEstimates(files: gr.files, kind: gr.kind)
        pie.tint = Theme.color(gr.kind)
        pie.suggestedId = Catalog.suggested(for: gr.kind, exts: exts)
        pie.lastId = UserDefaults.standard.string(forKey: "last_" + gr.kind.rawValue)
        pie.fileName = gr.files[0].lastPathComponent
        let bytes = gr.files.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        let size = Fmt.bytes(bytes)
        pie.subtitle = gr.files.count > 1 ? String(localized: "e altri \(gr.files.count - 1) · \(size)") : size
        pie.icon = NSWorkspace.shared.icon(forFile: gr.files[0].path)
        pie.onClose = {}
        pie.onPick = { [weak self, weak gr] a in
            guard let self, let gr else { return }
            self.picked(a, in: gr)
        }
        loadThumbnail(gr.files[0], into: pie)
    }

    private func picked(_ chosen: Action, in gr: FileGroup) {
        gr.pie.estimateTask?.cancel()          // 2.7.1 · si sceglie: la stima si ferma e lascia la macchina alla conversione
        var a = chosen
        var presetParam: String? = nil
        // 3.2 · Una ricetta: tutti i suoi passi, uno dopo l'altro
        if let recipe = RecipeStore.shared.recipe(for: chosen) {
            lastJob = RecipeStore.shared.run(recipe, files: gr.files)
            return
        }
        if let r = PresetStore.shared.resolve(chosen) { a = r.0; presetParam = r.1 }
        UserDefaults.standard.set(chosen.id, forKey: "last_" + gr.kind.rawValue)
        gr.pie.lastId = chosen.id
        var targets = gr.files + subs
        // 3.0 · «Modifica in…»: il file va nella sua scheda, con tutte le modifiche
        if let t = Catalog.openTarget(a.id) {
            let files = gr.files
            Task { @MainActor in Drawer.send(files, to: t) }
            return
        }
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
    @ObservedObject private var store = QueueStore.shared

    var body: some View {
        ZStack {
            GlowBackground(tint: ws.groups.isEmpty ? Theme.accent : ws.tint)
            if ws.groups.isEmpty { empty } else { loaded }
        }
        .coordinateSpace(name: "workspace")
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers, location in
            let wasEmpty = ws.groups.isEmpty
            loadURLs(providers) { urls in
                Sounds.drop()
                if wasEmpty { ws.dropPoint = location }
                ws.load(urls, append: !ws.groups.isEmpty)
            }
            return true
        }
        .sheet(item: $ws.pending) { p in
            if (p.kind == .cut || p.kind == .gifcut || p.kind == .ringtone), let url = p.mainFile {
                TrimEditorView(url: url, mode: p.kind) { v in ws.confirm(p, value: v) }
            } else {
                ParamView(kind: p.kind, action: p.action, files: p.files) { v in ws.confirm(p, value: v) }
            }
        }
        .quickLookPreview($ws.preview, in: ws.allFiles)
    }

    // Nessun file: grande area cliccabile, e sotto (2.7.5) quanto hai fatto questo mese
    private var empty: some View {
        VStack(spacing: 0) {
            dropArea
            let stats = MonthStats.of(store.history)
            if stats.files > 0 {
                MonthStatsRow(stats: stats)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 40).padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
    }

    private var dropArea: some View {
        Button(action: { choose(append: false) }) {
            VStack(spacing: 18) {
                EmptyOrbit(open: hoverDrop || targeted)
                VStack(spacing: 6) {
                    // 3.0 · La frase guida: due passi, niente di più
                    Text(targeted ? String(localized: "Rilascia qui") : String(localized: "Trascina un file. Scegli cosa farne.")).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("oppure clicca per sceglierlo · dal Finder: clic destro → OrbitLR, oppure ⌥⌘C")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .help("Fino a \(Workspace.maxPerKind) file dello stesso tipo, o \(Workspace.maxKinds) tipi diversi insieme")
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
            .frame(maxWidth: 640, minHeight: 220, maxHeight: 360)   // 2.8.9 · si stringe nelle finestre basse
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
        .animation(Motion.quick, value: hoverDrop)
        .animation(Motion.quick, value: targeted)
        .padding(40)
    }

    private var loaded: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if ws.groups.count > 1 {
                    Label("\(ws.groups.count) tipi di file · \(ws.allFiles.count) file", systemImage: "square.grid.2x2")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ws.togglePreview() } label: { Label("Anteprima", systemImage: "eye") }
                    .help("Anteprima del file (Spazio)")
                Button { choose(append: true) } label: { Label("Aggiungi file…", systemImage: "plus") }
                Button { ws.clear() } label: { Label("Togli tutto", systemImage: "xmark") }
                    .help("Togli i file dalla scheda (restano dove sono)")
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
        // Il risultato arriva dal basso con un piccolo rimbalzo
        .animation(Motion.spring(0.42, 0.72), value: ws.lastJob?.id)
        .background(KeyCatcher { e in
            // 3.4.2 · La scheda resta viva anche quando non si vede: i tasti valgono solo se è davanti
            guard AppState.shared.selection == nil || AppState.shared.selection == .workspace else { return false }
            // Spazio = anteprima (ma non mentre si sta cercando un'azione)
            if e.keyCode == 49 && (ws.single?.pie.query.isEmpty ?? true) { ws.togglePreview(); return true }
            guard let g = ws.single else { return false }
            return PieKeys.handle(e, model: g.pie, close: { ws.clear() })
        })
    }

    @ViewBuilder private var statusBar: some View {
        if let job = ws.lastJob {
            JobStatusBar(job: job, openQueue: { app.selection = .activity },
                         onClose: { withAnimation(Motion.quick) { ws.lastJob = nil } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            HStack(spacing: 18) {
                hint("hand.tap", String(localized: "Clic su un’azione"))
                if ws.single != nil { hint("keyboard", String(localized: "1–8 · Invio = ultima scelta")) }
                hint("magnifyingglass", String(localized: "Scrivi per cercare"))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12.5)).foregroundStyle(.secondary)
    }

    private func choose(append: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Apri")
        Sheet.choose(panel) { urls in if !urls.isEmpty { ws.load(urls, append: append) } }
    }
}

/// Un solo tipo di file: menu grande al centro, X per togliere il file, elenco se sono più di uno.
struct SinglePie: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var group: FileGroup
    /// 2.7: la torta parte dal punto in cui hai lasciato il file e arriva al centro (0 = là, 1 = al centro).
    @State private var arrive: CGFloat = 1
    @State private var from: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(ws: Workspace, group: FileGroup) {
        _ws = ObservedObject(wrappedValue: ws)
        _group = ObservedObject(wrappedValue: group)
        // Se arriva da un trascinamento parte piccola (niente lampo al centro prima del volo)
        _arrive = State(initialValue: ws.dropPoint != nil ? 0 : 1)
    }

    var body: some View {
        GeometryReader { g in
            let stripH: CGFloat = group.files.count > 1 ? 54 : 0
            let side = max(340, min(600, min(g.size.width - 80, g.size.height - 40 - stripH)))
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                PieView(model: group.pie, side: side,
                        removeHelp: group.files.count > 1 ? String(localized: "Togli questo file") : String(localized: "Togli il file"),
                        onRemove: { ws.remove(group.files[0], from: group) })
                    .frame(width: side, height: side)
                    .scaleEffect(0.3 + 0.7 * arrive)
                    .offset(x: from.width * (1 - arrive), y: from.height * (1 - arrive))
                    .onAppear {
                        guard let p = ws.dropPoint, !reduceMotion else { arrive = 1; ws.dropPoint = nil; return }
                        ws.dropPoint = nil
                        let f = g.frame(in: .named("workspace"))
                        let center = CGPoint(x: f.midX, y: f.midY - stripH / 2)
                        from = CGSize(width: p.x - center.x, height: p.y - center.y)
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { arrive = 0 }
                        DispatchQueue.main.async {
                            withAnimation(Motion.spring(0.55, 0.78)) { arrive = 1 }
                        }
                    }
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
                    removeHelp: group.files.count > 1 ? String(localized: "Togli questi \(group.files.count) file") : String(localized: "Togli il file"),
                    onRemove: { ws.removeGroup(group) }, delay: delay)
                .frame(width: side, height: side)
            HStack(spacing: 6) {
                Image(systemName: Theme.symbol(group.kind))
                Text(group.files.count > 1 ? String(localized: "\(group.kind.label) · \(group.files.count) file") : group.kind.label)
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
                    Text(job.state == .done && !job.gainText.isEmpty ? String(localized: "Fatto · \(job.gainText)") : job.status)
                        .font(.system(size: 12.5, weight: job.state == .done ? .semibold : .regular))
                        .foregroundStyle(job.state == .failed ? Theme.orange : (job.state == .done ? Theme.green : .secondary)).lineLimit(1)
                        .contentTransition(.numericText())
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
                UseInMenu(url: job.outputs[0])          // 3.0 · il passo successivo, in un clic
                Button("Mostra nel Finder") { store.reveal(job.outputs.map { $0.path }) }.buttonStyle(.borderedProminent).tint(Theme.green)
            } else if job.state == .running {
                Button("Interrompi") { store.cancel(job) }
            }
            Button("Attività") { openQueue() }
                .help("Tutti i lavori, in corso e fatti")
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
                      ? String(localized: "Nascondi: il lavoro continua e lo trovi in Attività") : String(localized: "Chiudi (il risultato resta in Attività)"))
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

/// Il «quadrante» della pagina vuota: gli spicchi colorati dei tipi di file girano piano come una manopola;
/// quando ci passi sopra (o trascini dei file) si aprono, come fa il menu a torta.
struct EmptyOrbit: View {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let kinds: [Kind] = [.img, .pdf, .video, .audio, .doc, .sheet, .slide, .text]
    /// 3.4.1 · Giro e respiro sono animazioni native (a 60/120 immagini al secondo), non più ridisegni a 24
    @State private var spin = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(open ? 0.10 : 0.06)).frame(width: 168, height: 168)
                .scaleEffect(breathe ? 1.025 : 0.975)
            ZStack {
                ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in
                    let a = Double(i) / Double(kinds.count)
                    Circle()
                        .trim(from: a + 0.012, to: a + 1.0 / Double(kinds.count) - 0.012)
                        .stroke(Theme.color(k).gradient, style: StrokeStyle(lineWidth: open ? 24 : 18, lineCap: .butt))
                        .frame(width: open ? 148 : 128, height: open ? 148 : 128)
                }
            }
            .rotationEffect(.degrees(spin ? 360 : 0))
            Circle().fill(Theme.ivory).frame(width: 74, height: 74)
                .shadow(color: Theme.shadow.opacity(0.18), radius: 6, y: 2)
            Circle().strokeBorder(Theme.brass, lineWidth: 2).frame(width: 74, height: 74)
            Image(systemName: open ? "arrow.down" : "plus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 176, height: 176)
        .animation(Motion.spring(0.35, 0.7), value: open)
        .modifier(LoopDriver(on: $spin, animation: .linear(duration: 40).repeatForever(autoreverses: false)))
        .modifier(LoopDriver(on: $breathe, animation: .easeInOut(duration: 2).repeatForever(autoreverses: true)))
        .accessibilityHidden(true)
    }
}

