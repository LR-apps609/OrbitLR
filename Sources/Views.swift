import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLook

// MARK: - Struttura della finestra

enum SidebarItem: String, CaseIterable, Identifiable {
    case workspace = "Conversione", files = "File", images = "Immagini", video = "Video", audio = "Audio",
         activity = "Attività", automation = "Automazioni", presets = "Scorciatoie", components = "Componenti",
         help = "Aiuto"
    var id: String { rawValue }
    /// Le schede di lavoro (in alto) e le attività (sotto).
    static let tabs: [SidebarItem] = [.workspace, .files, .images, .video, .audio]
    /// 3.0 · Coda e Cronologia sono una pagina sola: «Attività».
    static let activities: [SidebarItem] = [.activity]
    /// Per chi vuole di più: chiuso di base, si apre con un clic.
    static let advanced: [SidebarItem] = [.automation, .presets, .components]
    var symbol: String {
        switch self {
        case .workspace: return "chart.pie.fill"
        case .files: return "doc.richtext.fill"
        case .images: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .activity: return "clock.arrow.circlepath"
        case .presets: return "star.circle.fill"
        case .automation: return "folder.badge.gearshape"
        case .components: return "shippingbox.fill"
        case .help: return "questionmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .workspace: return Theme.accent
        case .files: return Theme.color(.pdf)
        case .images: return Theme.color(.img)
        case .video: return Theme.color(.video)
        case .audio: return Theme.color(.audio)
        case .activity: return Theme.brass
        case .presets: return Theme.brass
        case .automation: return Theme.color(.doc)
        case .components: return Theme.green
        case .help: return Theme.accent
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var store: QueueStore
    @EnvironmentObject var app: AppState
    @AppStorage("palette") private var palette = "sage"
    @AppStorage("sidebarAdvanced") private var advancedOpen = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                    Text("OrbitLR").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)

                List(selection: $app.selection) {
                    Section("Schede") {
                        ForEach(SidebarItem.tabs) { item in sidebarRow(item) }
                    }
                    Section {
                        ForEach(SidebarItem.activities) { item in sidebarRow(item) }
                    }
                    // 2.7.2 · «Avanzate» si vede che è un pulsante: icona, freccia che gira, sfondo leggero
                    Section {
                        if advancedOpen { ForEach(SidebarItem.advanced) { item in sidebarRow(item) } }
                    } header: {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { advancedOpen.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                                Text("Avanzate").font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                    .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                            }
                            .foregroundStyle(Theme.ink.opacity(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cream.opacity(0.35)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(advancedOpen ? "Nascondi Automazioni, Scorciatoie e Componenti" : "Mostra Automazioni, Scorciatoie e Componenti")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: 10) {
                    // 3.0 · Il Cassetto al posto di «Risparmiati questo mese» (la cifra resta in Cronologia)
                    DrawerSidebar()

                    // 3.0 · Opzioni, Aiuto e Segnala un problema: una riga sola
                    HStack(spacing: 6) {
                        FooterButton(title: "Opzioni", symbol: "gearshape.fill", help: "Dove salvare i file, aspetto, avvio (⌘,)") { openSettings() }
                        FooterButton(title: "Aiuto", symbol: "questionmark.circle.fill", help: "Guida, domande frequenti e scorciatoie",
                                     selected: app.selection == .help) { app.selection = .help }
                        FooterButton(title: "Segnala", symbol: "ladybug.fill", help: "Segnala un problema: mi arriva con uno screenshot") { app.showBugReport = true }
                            .accessibilityLabel("Segnala un problema")
                    }

                    // 2.8.8 · La versione, sempre visibile; un clic controlla se ce n'è una nuova
                    Button {
                        Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                            Text("OrbitLR \(UpdateCheck.current)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("La versione che hai. Clicca per controllare se ce n’è una nuova")
                    .accessibilityLabel("OrbitLR versione \(UpdateCheck.current), controlla aggiornamenti")
                }
                .padding(12)
            }
            .background(LinearGradient(colors: [Theme.sageLight, Theme.sage.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            // Passaggio morbido tra le pagine (dissolvenza breve)
            ZStack {
                Group {
                    switch app.selection ?? .workspace {
                    case .workspace: WorkspaceView(ws: app.workspace)
                    case .files: KindTabView(m: app.filesTab, style: .files)
                    case .images: KindTabView(m: app.imagesTab, style: .images)
                    case .video: VideoTabView(s: VideoProjectStore.shared)
                    case .audio: AudioTabView(m: app.audioTab)
                    case .activity: ActivityView()
                    case .presets: PresetsView()
                    case .automation: AutomationView()
                    case .components: ComponentsView()
                    case .help: HelpView()
                    }
                }
                .id(app.selection ?? .workspace)
                // 2.7: la pagina nuova entra con una molla leggera (sale un poco e si posa), come una manopola che scatta
                // 2.7.2 · più rapida: la pagina vecchia sparisce subito, la nuova entra in 0,2 s (niente zoom, che rallentava)
                .transition(.asymmetric(insertion: Motion.reduced ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .identity))
            }
            .animation(Motion.spring(0.2, 0.9), value: app.selection)
            // 2.8.6 · Nessuna pagina può far crescere la finestra oltre lo schermo: quello che non ci sta resta sotto
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .background(WindowReader { w in
            // Una sola finestra principale: se ne nasce un'altra mentre la prima è aperta, si chiude subito
            if let existing = AppState.shared.mainWindow, existing !== w, existing.isVisible || existing.isMiniaturized {
                DispatchQueue.main.async {
                    w.close()
                    existing.makeKeyAndOrderFront(nil)
                }
                return
            }
            AppState.shared.mainWindow = w
            LaunchGate.attach(w)
        })     // niente «lampo» prima della schedina di avvio
        .sheet(isPresented: $app.showBugReport) { BugReportView { app.showBugReport = false } }
        .toolbar {
            // Sempre visibile, in ogni pagina: l'elenco delle scorciatoie
            ToolbarItem(placement: .primaryAction) { ShortcutsButton() }
        }
        .tint(Theme.accent)
        .foregroundStyle(Theme.ink)
        .id(palette)                       // cambio di tema: tutta la finestra si ridisegna con i nuovi colori
    }

    @ViewBuilder private func sidebarRow(_ item: SidebarItem) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(item.rawValue)
            } icon: {
                Image(systemName: item.symbol).foregroundStyle(item.color)
            }
        }
        .badge(item == .activity ? store.runningJobs.count : 0)
        .tag(item)
        // 3.0 · Un file del Cassetto (o del Finder) trascinato sulla riga di una scheda: si apre lì
        .dropDestination(for: URL.self) { urls, _ in
            guard let t = DrawerTarget.forSidebar(item), !urls.isEmpty else { return false }
            Drawer.send(urls, to: t)
            return true
        }
    }
}

/// 3.0 · Un pulsante della riga in fondo alla barra laterale.
private struct FooterButton: View {
    let title: String
    let symbol: String
    let help: String
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.18) : (hover ? Theme.ivory : Theme.ivory.opacity(0.7))))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Attività (Coda e Cronologia insieme)

struct ActivityView: View {
    @EnvironmentObject var store: QueueStore
    @EnvironmentObject var app: AppState
    @State var preview: URL? = nil

    /// I lavori ancora aperti: in corso, in attesa, non riusciti o interrotti. Quelli finiti sono già nella cronologia.
    private var open: [Job] { store.jobs.filter { $0.state != .done } }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Attività", subtitle: subtitle, color: SidebarItem.activity.color) {
                    if store.jobs.contains(where: { $0.state != .running && $0.state != .waiting }) {
                        Button("Togli i completati") { store.clearFinished() }
                            .help("Toglie dall’elenco i lavori finiti, non riusciti o interrotti (i file restano)")
                    }
                    if !store.history.isEmpty {
                        Button(role: .destructive) {
                            let a = NSAlert()
                            a.messageText = "Svuotare la cronologia?"
                            a.informativeText = "Spariscono tutte le voci dall’elenco. I file creati restano dove sono."
                            a.addButton(withTitle: "Svuota")
                            a.addButton(withTitle: "Annulla")
                            if a.runModal() == .alertFirstButtonReturn { withAnimation(.easeOut(duration: 0.2)) { store.forgetAll() } }
                        } label: { Label("Svuota la cronologia…", systemImage: "trash") }
                        .help("Svuota la cronologia (i file non vengono toccati)")
                    }
                }
                if open.isEmpty && store.history.isEmpty {
                    EmptyState(symbol: "clock", color: SidebarItem.activity.color, title: "Ancora nessun lavoro",
                               text: "Qui vedi quello che OrbitLR sta facendo e tutto quello che hai creato, giorno per giorno.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            if !open.isEmpty {
                                Section {
                                    ForEach(open) { job in JobCard(job: job) { preview = $0 } }
                                } header: {
                                    ActivityHeader(title: "Adesso", detail: openDetail)
                                }
                            }
                            if !store.history.isEmpty {
                                MonthStatsRow(stats: MonthStats.of(store.history)).padding(.vertical, 6)
                            }
                            ForEach(HistoryDay.group(store.history)) { day in
                                Section {
                                    ForEach(day.entries) { e in HistoryRow(entry: e) }
                                } header: {
                                    DayHeader(day: day)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .padding(28)
        }
        .quickLookPreview($preview, in: store.jobs.flatMap { $0.outputs })
        .navigationTitle("Attività")
    }

    private var subtitle: String {
        let r = store.runningJobs.count
        let w = store.jobs.filter { $0.state == .waiting }.count
        let saved = ByteCountFormatter.string(fromByteCount: store.savedThisMonth, countStyle: .file)
        let now = r == 0 && w == 0 ? "Niente in corso" : "\(r) in corso" + (w > 0 ? " · \(w) in attesa" : "")
        return now + (store.savedThisMonth > 0 ? " · \(saved) risparmiati questo mese" : "")
    }

    private var openDetail: String {
        let n = open.count
        return n == 1 ? "1 lavoro" : "\(n) lavori"
    }
}

/// L'intestazione «Adesso» sopra i lavori in corso.
private struct ActivityHeader: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .padding(.vertical, 6)
        .background(Theme.background)
    }
}

struct JobCard: View {
    @ObservedObject var job: Job
    var onPreview: (URL) -> Void = { _ in }
    @EnvironmentObject var store: QueueStore
    @State var hover = false

    var body: some View {
        HStack(spacing: 14) {
            FileThumb(url: job.outputs.first ?? job.mainFiles.first, kind: job.kind, size: 44)
                .fileDrag(job.outputs.first)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(job.action.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if job.state == .running || job.state == .waiting {
                    TunerBar(value: job.shownProgress, tint: Theme.color(job.kind), height: 22)
                } else if job.state == .done {
                    TunerBar(value: 1, tint: Theme.green, done: true, height: 22)
                }
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol).font(.system(size: 11, weight: .bold)).foregroundStyle(statusColor)
                    Text(job.status).font(.system(size: 12, weight: job.state == .running ? .regular : .semibold))
                        .foregroundStyle(statusColor).lineLimit(2)
                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.sizeText).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                SavedBadge(job: job)
            }
            .frame(width: 140, alignment: .leading)
            HStack(spacing: 6) {
                if let fix = Fix.best(for: job) {
                    Button { store.apply(fix, to: job) } label: { Label(fix.label, systemImage: fix.symbol) }
                        .buttonStyle(.borderedProminent).tint(Theme.brass)
                }
                if let first = job.outputs.first, job.state == .done {
                    Button { onPreview(first) } label: { Image(systemName: "eye") }.help("Anteprima del risultato")
                }
                let pairs = job.comparePairs
                if !pairs.isEmpty {
                    Button { CompareController.shared.show(pairs, title: job.title) } label: {
                        Image(systemName: "square.split.2x1")
                    }
                    .help("Confronta: originale e risultato, con la linea da trascinare")
                }
                actionButton
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        .onHover { hover = $0 }
        .help(job.failures.joined(separator: "\n"))
    }

    private var statusSymbol: String {
        switch job.state {
        case .done: return job.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .waiting: return "clock.fill"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .done: return job.failures.isEmpty ? Theme.green : Theme.orange
        case .failed: return Theme.orange
        case .cancelled, .waiting: return .secondary
        case .running: return .primary
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch job.state {
        case .running, .waiting: Button("Interrompi") { store.cancel(job) }
        case .done:
            Button("Mostra nel Finder") { store.reveal(job.outputs.map { $0.path }) }
                .buttonStyle(.borderedProminent).tint(Theme.green).disabled(job.outputs.isEmpty)
        case .failed, .cancelled: Button("Riprova") { store.retry(job) }
        }
    }
}

// MARK: - Cronologia

/// 2.7 · Tre numeri del mese, grandi e semplici.
struct MonthStatsRow: View {
    let stats: MonthStats
    var body: some View {
        HStack(spacing: 12) {
            tile(symbol: "doc.on.doc.fill", color: Theme.accent, title: "File creati questo mese") {
                Text("\(stats.files)").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            tile(symbol: "arrow.down.circle.fill", color: Theme.green, title: "Spazio risparmiato") {
                CountingBytes(value: Double(stats.saved), font: .system(size: 24, weight: .bold, design: .rounded), color: Theme.green)
            }
            tile(symbol: "star.fill", color: Theme.brass, title: "L’azione che usi di più") {
                Text(stats.topAction ?? "—").font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func tile<V: View>(symbol: String, color: Color, title: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
                .frame(width: 40, height: 40).background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                value()
                Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .card(radius: 14)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @EnvironmentObject var store: QueueStore

    var body: some View {
        HStack(spacing: 12) {
            FileThumb(url: entry.undone ? nil : entry.outputs.first.map { URL(fileURLWithPath: $0) },
                      kind: entry.kind.flatMap { Kind(rawValue: $0) }, size: 38)
                .opacity(entry.undone ? 0.4 : 1)
                .fileDrag(entry.undone ? nil : entry.outputs.first.map { URL(fileURLWithPath: $0) })
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(entry.action) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = entry.before, let a = entry.after, b > 0 {
                Text(ByteCountFormatter.string(fromByteCount: b, countStyle: .file) + " → " + ByteCountFormatter.string(fromByteCount: a, countStyle: .file))
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(a < b ? Theme.green : .secondary)
            }
            if entry.undone {
                Text("Nel Cestino").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                if let first = entry.outputs.first, FileManager.default.fileExists(atPath: first) {
                    UseInMenu(url: URL(fileURLWithPath: first), compact: true)
                }
                Button("Mostra nel Finder") { store.reveal(entry.outputs) }
            }
            // 3.0 · Un menu solo per le azioni meno frequenti
            Menu {
                if !entry.undone {
                    Button("Elimina i file creati…") {
                        let a = NSAlert()
                        a.messageText = entry.outputs.count == 1 ? "Spostare il file nel Cestino?" : "Spostare \(entry.outputs.count) file nel Cestino?"
                        a.informativeText = "Si possono ancora recuperare dal Cestino."
                        a.addButton(withTitle: "Sposta nel Cestino")
                        a.addButton(withTitle: "Annulla")
                        if a.runModal() == .alertFirstButtonReturn { store.undo(entry) }
                    }
                }
                Button("Togli dalla cronologia") { withAnimation(.easeOut(duration: 0.2)) { store.forget(entry) } }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            .help("Altro: elimina i file creati o togli la voce (il file resta dov’è)")
            .accessibilityLabel("Altre azioni")
        }
        .padding(12)
        .card(radius: 12)
    }
}

/// Un giorno (o un periodo) della Cronologia: «Oggi», «Ieri», «Questa settimana», poi i mesi.
struct HistoryDay: Identifiable {
    let id: String
    let title: String
    let entries: [HistoryEntry]

    var saved: Int64 {
        entries.reduce(Int64(0)) { sum, e in
            guard !e.undone, let b = e.before, let a = e.after, b > a else { return sum }
            return sum + (b - a)
        }
    }

    static func group(_ list: [HistoryEntry]) -> [HistoryDay] {
        let cal = Calendar.current
        let now = Date()
        let month = DateFormatter()
        month.locale = Locale(identifier: "it_IT")
        month.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [HistoryEntry]] = [:]
        for e in list {
            let key: String, title: String
            if cal.isDateInToday(e.date) { key = "0"; title = "Oggi" }
            else if cal.isDateInYesterday(e.date) { key = "1"; title = "Ieri" }
            else if cal.isDate(e.date, equalTo: now, toGranularity: .weekOfYear) { key = "2"; title = "Questa settimana" }
            else if cal.isDate(e.date, equalTo: now, toGranularity: .month) { key = "3"; title = "Questo mese" }
            else {
                let c = cal.dateComponents([.year, .month], from: e.date)
                key = "m\(c.year ?? 0)-\(c.month ?? 0)"
                title = month.string(from: e.date).capitalized
            }
            if buckets[key] == nil { order.append(key); titles[key] = title }
            buckets[key, default: []].append(e)
        }
        return order.map { HistoryDay(id: $0, title: titles[$0] ?? "", entries: buckets[$0] ?? []) }
    }
}

struct DayHeader: View {
    let day: HistoryDay
    var body: some View {
        HStack(spacing: 10) {
            Text(day.title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text(day.entries.count == 1 ? "1 lavoro" : "\(day.entries.count) lavori")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if day.saved > 0 {
                Label(ByteCountFormatter.string(fromByteCount: day.saved, countStyle: .file) + " risparmiati",
                      systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.green)
            }
        }
        .padding(.vertical, 6)
        .padding(.top, 6)
        .background(Theme.background)
    }
}

// MARK: - Componenti

struct ComponentsView: View {
    @ObservedObject var installer = Installer.shared
    @State var testOutput = ""
    @State var testing = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Componenti",
                               subtitle: "I programmi che fanno il lavoro. Quelli mancanti servono solo ad alcune funzioni.",
                               color: Theme.green) {
                        Button(testing ? "Controllo in corso…" : "Controllo automatico") { runTest() }
                            .disabled(testing)
                        if !installer.missing.isEmpty && installer.brewPath != nil {
                            Button("Installa tutti i mancanti") { installer.install(installer.missing, id: "all") }
                                .buttonStyle(.borderedProminent).tint(Theme.green).disabled(installer.running != nil)
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Già incluso in macOS").font(.system(size: 13, weight: .semibold))
                            Text("JPG, PNG, HEIC, TIFF, ridimensionamento foto, MP4, MOV, M4A, HEVC, PDF e testo dalle immagini: funzionano senza installare nulla.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .card(radius: 12)

                    if installer.brewPath == nil {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.brass)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manca Homebrew").font(.system(size: 13, weight: .semibold))
                                Text("Serve per installare gli altri componenti. Si installa una volta sola nel Terminale, con la password del Mac.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Installa Homebrew") { installer.installHomebrewInTerminal() }
                        }
                        .padding(14)
                        .card(radius: 12)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(installer.components) { c in componentCard(c) }
                    }
                    .id(installer.refresh)

                    if installer.running != nil || !installer.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if installer.running != nil {
                                    ProgressView().controlSize(.small)
                                    Text("Installazione in corso… può richiedere qualche minuto").font(.system(size: 12, weight: .semibold))
                                } else if let r = installer.lastResult {
                                    Text(r).font(.system(size: 12, weight: .semibold))
                                }
                                Spacer()
                                if installer.running != nil { Button("Interrompi") { installer.cancel() } }
                            }
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(installer.lines.enumerated()), id: \.offset) { i, l in
                                            Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).id(i)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 140)
                                .onChange(of: installer.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                            }
                        }
                        .padding(14)
                        .card(radius: 12)
                    }

                    if !testOutput.isEmpty {
                        Text(testOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .card()
                    }
                }
                .padding(28)
            }
        }
        .navigationTitle("Componenti")
    }

    private func componentCard(_ c: ComponentInfo) -> some View {
        let ok = c.installed
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22)).foregroundStyle(ok ? Theme.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.name).font(.system(size: 13, weight: .semibold))
                    Text(c.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(c.unlocks).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok && installer.brewPath != nil {
                if installer.running == c.id { ProgressView().controlSize(.small) }
                else { Button("Installa") { installer.install([c], id: c.id) }.disabled(installer.running != nil) }
            }
        }
        .padding(14)
        .card(radius: 12)
    }

    private func runTest() {
        testing = true
        testOutput = "Provo tutte le funzioni con file di prova (circa un minuto)…"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [Paths.script.path, "--test"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { testOutput = text; testing = false; Installer.shared.refresh += 1 }
        }
    }
}

// MARK: - Elementi comuni

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(color.gradient).frame(width: 5, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 8) { actions() }
        }
    }
}

struct EmptyState: View {
    let symbol: String, color: Color, title: String, text: String
    var body: some View {
        VStack(spacing: 12) {
            RadioIllustration(symbol: symbol, color: color)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func loadURLs(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
}

// MARK: - Barra dei menu

struct MenuBarView: View {
    @EnvironmentObject var store: QueueStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("OrbitLR").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
            }
            if store.runningJobs.isEmpty {
                Text("Nessuna operazione in corso").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(store.runningJobs) { job in RunningRow(job: job) }
            }
            if !store.history.isEmpty {
                Divider()
                Text("Recenti").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(store.history.prefix(4)) { e in
                    Button { store.reveal(e.outputs) } label: {
                        HStack(spacing: 8) {
                            KindBadge(kind: e.kind.flatMap { Kind(rawValue: $0) }, size: 20)
                            Text(e.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button("Apri OrbitLR") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.plain)
            Button("Guida rapida") { WelcomeController.shared.showGuide() }
                .buttonStyle(.plain)
            SettingsLink { Text("Opzioni…") }.buttonStyle(.plain)
            Button("Esci") { NSApp.terminate(nil) }.buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 290)
    }
}

struct RunningRow: View {
    @ObservedObject var job: Job
    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: job.kind, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                ProgressBar(value: job.shownProgress, tint: Theme.color(job.kind))
                Text(job.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Opzioni

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsModel
    @State var draft = SettingsDraft()
    /// 2.8.9 · Controllo automatico degli aggiornamenti (una volta al giorno)
    @AppStorage(UpdateCheck.autoKey) private var autoUpdate = true
    /// 2.9 · Motore video classico (senza filtri)
    @AppStorage(VideoProjectBuilder.classicKey) private var classicVideo = false
    @State var saved = false
    @State private var advanced = false

    private var changed: Bool { draft != settings.draft }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("File creati") {
                    Picker("Dove salvarli", selection: $draft.dest) {
                        Text("Nella stessa cartella dell’originale").tag("same")
                        Text("In una sottocartella «Convertiti»").tag("sub")
                        Text("In una cartella a scelta").tag("fixed")
                    }
                    if draft.dest == "fixed" {
                        HStack {
                            Text(draft.destPath.isEmpty ? "Nessuna cartella scelta" : draft.destPath)
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer()
                            Button("Scegli…") { chooseFolder() }
                        }
                    }
                    Picker("Dopo la conversione, l’originale", selection: $draft.original) {
                        Text("Resta dov’è").tag("keep")
                        Text("Va nel Cestino").tag("trash")
                    }
                    Text("Il Cestino vale solo per conversioni, compressioni e ridimensionamenti riusciti. Si può sempre recuperare dal Cestino.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Conserva le date originali dei file", isOn: $draft.keepDates)
                }
                Section("Aspetto") {
                    Picker("Chiaro o scuro", selection: $draft.appearance) {
                        Text("Come il Mac").tag("auto")
                        Text("Chiaro").tag("light")
                        Text("Scuro · radio di notte").tag("dark")
                    }
                    Picker("Colori", selection: $draft.palette) {
                        ForEach(Palette.allCases) { p in
                            Text(p.name).tag(p.rawValue)
                        }
                    }
                    Toggle("Suoni discreti (clic, scatto, fine lavoro)", isOn: $draft.sounds)
                    Picker("Opzioni nei pannelli", selection: $draft.controlStyle) {
                        Text("Elenco (più rapido)").tag("list")
                        Text("Manopole (stile radio)").tag("knob")
                    }
                }
                Section("Avvio") {
                    Toggle("Apri OrbitLR all’accesso al Mac (il menu si apre all’istante)", isOn: $draft.launchAtLogin)
                    Toggle("Scorciatoia ⌥⌘C sui file selezionati nel Finder", isOn: $draft.hotkey)
                    Toggle("Controlla da sola se c’è una versione nuova (una volta al giorno)", isOn: $autoUpdate)
                    Button("Controlla adesso…") { Task { @MainActor in await UpdateCheck.check(userInitiated: true) } }
                }
                // 3.0 · Quello che serve di rado, chiuso di base
                Section {
                    DisclosureGroup("Avanzate", isExpanded: $advanced) {
                        Toggle("Animazione di avvio", isOn: $draft.splash)
                        Toggle("Usa i motori di macOS quando possibile", isOn: $draft.useNative)
                        Text("Immagini, MP4, MOV e M4A li fa direttamente macOS: più veloce e senza programmi da installare. Disattivalo solo se un risultato non ti convince.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Motore video classico (senza filtri)", isOn: $classicVideo)
                        Text("Solo se un video si vede o si esporta male: torna al modo di prima, ma filtri ed effetti non si applicano.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Trascrizione e testo dalle foto", selection: $draft.quality) {
                            Text("Veloce (scarica 470 MB)").tag("small")
                            Text("Precisa (scarica 1,6 GB, meglio per l’italiano)").tag("turbo")
                        }
                        Picker("Lingua della trascrizione", selection: $draft.language) {
                            Text("Automatica").tag("auto")
                            Text("Italiano").tag("it")
                            Text("Inglese").tag("en")
                            Text("Spagnolo").tag("es")
                            Text("Francese").tag("fr")
                            Text("Tedesco").tag("de")
                        }
                        Picker("Menu del clic destro nel Finder", selection: $draft.quickActionMenu) {
                            Text("Menu a torta").tag("native")
                            Text("Elenco classico").tag("classic")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .id(settings.palette)          // ridisegna con i colori del nuovo tema

            HStack(spacing: 10) {
                if changed {
                    Label("Modifiche non ancora applicate", systemImage: "circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.brass)
                } else if saved {
                    Label("Modifiche salvate", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.green)
                }
                Spacer()
                Button(changed ? "Scarta" : "Chiudi") {
                    if changed { draft = settings.draft } else { NSApp.keyWindow?.close() }
                }
                .keyboardShortcut(.cancelAction)
                .help(changed ? "Butta le modifiche non applicate" : "Chiudi le Opzioni")
                Button("Applica") {
                    settings.apply(draft)
                    withAnimation { saved = true }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!changed)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.parchment.opacity(0.45))
        }
        .frame(width: 580)
        .background(Theme.cream)
        .foregroundStyle(Theme.ink)
        .onAppear { settings.refresh(); draft = settings.draft; saved = false }
        .onChange(of: draft) { _, _ in if changed { saved = false } }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { draft.destPath = u.path }
    }
}
