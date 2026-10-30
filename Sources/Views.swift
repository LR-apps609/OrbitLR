import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLook

// MARK: - Struttura della finestra

enum SidebarItem: String, CaseIterable, Identifiable {
    case workspace = "Conversione", files = "File", images = "Immagini", video = "Video", audio = "Audio",
         activity = "Attività", automation = "Automazioni", presets = "Le mie azioni", components = "Componenti",
         help = "Aiuto"
    var id: String { rawValue }
    /// Le schede di lavoro (in alto) e le attività (sotto).
    static let tabs: [SidebarItem] = [.workspace, .files, .images, .video, .audio]
    /// 3.0 · Coda e Cronologia sono una pagina sola: «Attività».
    static let activities: [SidebarItem] = [.activity]
    /// 3.4.2 · Le schede che restano vive (le più usate); le altre si ricostruiscono quando servono.
    static let kept: [SidebarItem] = tabs
    /// Per chi vuole di più: chiuso di base, si apre con un clic.
    static let advanced: [SidebarItem] = [.automation, .presets, .components]
    /// 5.0 · Il nome che si vede (il valore resta quello di sempre: è salvato nelle preferenze)
    var title: String {
        switch self {
        case .workspace: return String(localized: "Converti")
        case .files: return String(localized: "PDF e documenti")
        case .automation: return String(localized: "Cartelle automatiche")   // come il titolo della pagina e come su Windows
        default: return String(localized: String.LocalizationValue(rawValue))
        }
    }
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
    /// 3.4.2 · Le schede già aperte almeno una volta (restano vive)
    @State private var visited: Set<SidebarItem> = []
    /// 5.0.2 · macOS 14 (Sonoma) a volte disegna la barra laterale prima di sapere quanto è larga (voci «I…»,
    /// sotto i pallini della finestra) e poi non la ridisegna. Lì la si ricostruisce quando cambia larghezza o si riapre.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarBucket = 0
    @State private var sidebarKick = 0
    private static let sonoma = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15
    private var sidebarID: String { Self.sonoma ? "\(sidebarBucket)-\(sidebarKick)-\(sidebarVisibility == .detailOnly ? 0 : 1)" : "s" }

    private var current: SidebarItem { app.selection ?? .workspace }

    @ViewBuilder private func page(_ item: SidebarItem) -> some View {
        switch item {
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

    /// Lasciando una scheda viva: si ferma quello che suona o si muove (prima lo faceva la scomparsa della scheda).
    static func left(_ item: SidebarItem?) {
        switch item {
        case .video?:
            VideoProjectStore.shared.pause()
            // 3.5.1 · Un campo di testo del montaggio non resta acceso di nascosto: tornando, i tasti J/K/L/S funzionano
            if VideoProjectStore.shared.typing {
                AppState.shared.mainWindow?.makeFirstResponder(nil)
                VideoProjectStore.shared.typing = false
            }
        case .audio?:
            AppState.shared.audioTab.trim?.pause()
        default: break
        }
    }
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
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
                            withAnimation(Motion.quick) { advancedOpen.toggle() }
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
                        .help(advancedOpen ? String(localized: "Nascondi Automazioni, Le mie azioni e Componenti") : String(localized: "Mostra Automazioni, Le mie azioni e Componenti"))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: 10) {
                    // 3.0 · Il Cassetto al posto di «Risparmiati questo mese» (la cifra resta in Cronologia)
                    DrawerSidebar()

                    // 3.0 · Opzioni, Aiuto e Segnala un problema: una riga sola
                    HStack(spacing: 6) {
                        FooterButton(title: String(localized: "Opzioni"), symbol: "gearshape.fill", help: String(localized: "Dove salvare i file, aspetto, avvio (⌘,)")) { openSettings() }
                        FooterButton(title: String(localized: "Aiuto"), symbol: "questionmark.circle.fill", help: String(localized: "Guida, domande frequenti e scorciatoie"),
                                     selected: app.selection == .help) { app.selection = .help }
                        FooterButton(title: String(localized: "Segnala"), symbol: "ladybug.fill", help: String(localized: "Segnala un problema: mi arriva con uno screenshot")) { app.showBugReport = true }
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
            .id(sidebarID)
            .background(GeometryReader { g in Color.clear.preference(key: SidebarWidthKey.self, value: g.size.width) })
            .onPreferenceChange(SidebarWidthKey.self) { w in
                guard Self.sonoma else { return }
                let b = Int((w / 6).rounded())
                if b != sidebarBucket { sidebarBucket = b }
            }
            .onAppear {
                // Sonoma: un secondo disegno a finestra già al suo posto
                guard Self.sonoma, sidebarKick == 0 else { return }        // una volta sola (il ridisegno la fa riapparire)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sidebarKick = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sidebarKick = 2 }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            // 3.4.2 · Schede istantanee: le schede di lavoro restano vive dopo la prima apertura.
            // Tornarci non le ricostruisce: compare subito com'era (file, selezione, scorrimento).
            // Le altre pagine (Aiuto, Scorciatoie…) si costruiscono quando servono, come prima.
            ZStack {
                ForEach(SidebarItem.kept.filter { visited.contains($0) || $0 == current }) { item in
                    let on = current == item
                    page(item)
                        .environment(\.isFrontTab, on)
                        .opacity(on ? 1 : 0)
                        .offset(y: on || Motion.reduced ? 0 : 4)
                        .allowsHitTesting(on)
                        .disabled(!on)                 // niente scorciatoie da tastiera dalle schede nascoste
                        .accessibilityHidden(!on)
                        .zIndex(on ? 1 : 0)
                }
                if !SidebarItem.kept.contains(current) {
                    page(current)
                        .id(current)
                        .transition(.asymmetric(insertion: Motion.reduced ? .opacity : .opacity.combined(with: .offset(y: 4)), removal: .identity))
                        .zIndex(2)
                }
            }
            .animation(Motion.quick, value: app.selection)
            .navigationTitle(current.title)
            .onAppear {
                visited.insert(current)
                // 3.4.2 · Dopo l'avvio, a macchina libera, le altre schede si preparano una alla volta:
                // anche la prima apertura di ciascuna diventa istantanea
                for (i, item) in SidebarItem.kept.enumerated() where item != current {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 0.35) { visited.insert(item) }
                }
            }
            .onChange(of: app.selection) { old, new in
                if let n = new { visited.insert(n) }
                Self.left(old)
                DispatchQueue.main.async { Perf.end(.tabSwitch) }       // 3.4.1 · misura del cambio scheda
            }
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
            // 3.5 · Alla prima chiusura della finestra, OrbitLR spiega che resta pronta in alto
            if AppState.closeWatched !== w {
                AppState.closeWatched = w
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                    AppDelegate.windowClosed()
                }
            }
        })     // niente «lampo» prima della schedina di avvio
        .sheet(isPresented: $app.showBugReport) { BugReportView { app.showBugReport = false } }
        .toolbar {
            // Sempre visibile, in ogni pagina: l'elenco delle scorciatoie
            ToolbarItem(placement: .primaryAction) { UpdateBadgeButton() }      // 4.1.2 · solo se c'è una versione nuova
            ToolbarItem(placement: .primaryAction) { ShortcutsButton() }
        }
        .tint(Theme.accent)
        .foregroundStyle(Theme.ink)
        .id(palette)                       // cambio di tema: tutta la finestra si ridisegna con i nuovi colori
    }

    @ViewBuilder private func sidebarRow(_ item: SidebarItem) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(item.title)
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
        .buttonStyle(Pressable())
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
                PageHeader(title: String(localized: "Attività"), subtitle: subtitle, color: SidebarItem.activity.color) {
                    if store.jobs.contains(where: { $0.state != .running && $0.state != .waiting }) {
                        Button("Togli i completati") { store.clearFinished() }
                            .help("Toglie dall’elenco i lavori finiti, non riusciti o interrotti (i file restano)")
                    }
                    if !store.history.isEmpty {
                        Button(role: .destructive) {
                            let a = NSAlert()
                            a.messageText = String(localized: "Svuotare la cronologia?")
                            a.informativeText = String(localized: "Spariscono tutte le voci dall’elenco. I file creati restano dove sono.")
                            a.addButton(withTitle: String(localized: "Svuota"))
                            a.addButton(withTitle: String(localized: "Annulla"))
                            Sheet.confirmDestructive(a) { ok in if ok { withAnimation(Motion.quick) { store.forgetAll() } } }   // 5.1 · «Annulla» predefinito
                        } label: { Label("Svuota la cronologia…", systemImage: "trash") }
                        .help("Svuota la cronologia (i file non vengono toccati)")
                    }
                }
                UndoToastBar(place: .history)          // 5.1
                if open.isEmpty && store.history.isEmpty {
                    EmptyState(symbol: "clock", color: SidebarItem.activity.color, title: String(localized: "Ancora nessun lavoro"),
                               text: String(localized: "Qui vedi quello che OrbitLR sta facendo e tutto quello che hai creato, giorno per giorno."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            if !open.isEmpty {
                                Section {
                                    ForEach(open) { job in JobCard(job: job) { preview = $0 } }
                                } header: {
                                    ActivityHeader(title: String(localized: "Adesso"), detail: openDetail)
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
    }

    private var subtitle: String {
        let r = store.runningJobs.count
        let w = store.jobs.filter { $0.state == .waiting }.count
        let saved = Fmt.bytes(store.savedThisMonth)
        let now = r == 0 && w == 0 ? String(localized: "Niente in corso") : String(localized: "\(r) in corso") + (w > 0 ? " · " + String(localized: "\(w) in attesa") : "")
        return now + (store.savedThisMonth > 0 ? " · " + String(localized: "\(saved) risparmiati questo mese") : "")
    }

    private var openDetail: String {
        let n = open.count
        return n == 1 ? String(localized: "1 lavoro") : String(localized: "\(n) lavori")
    }
}

/// L'intestazione «Adesso» sopra i lavori in corso.
private struct ActivityHeader: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text(job.action.title).font(.system(size: 12.5)).foregroundStyle(.secondary)
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
                    Text(job.state == .running ? job.statusWithTime : job.status).font(.system(size: 12, weight: job.state == .running ? .regular : .semibold))
                        .foregroundStyle(statusColor).lineLimit(2)
                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.sizeText).font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
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
                .disabled(job.outputs.isEmpty)
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
            tile(symbol: "doc.on.doc.fill", color: Theme.accent, title: String(localized: "File creati questo mese")) {
                Text("\(stats.files)").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            tile(symbol: "arrow.down.circle.fill", color: Theme.green, title: String(localized: "Spazio risparmiato")) {
                CountingBytes(value: Double(stats.saved), font: .system(size: 24, weight: .bold, design: .rounded), color: Theme.green)
            }
            tile(symbol: "star.fill", color: Theme.brass, title: String(localized: "L’azione che usi di più")) {
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
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                if !entry.undone { SaveRecipeChip(entry: entry, history: store.history) }
            }
            Spacer()
            if let b = entry.before, let a = entry.after, b > 0 {
                Text(Fmt.bytes(b) + " → " + Fmt.bytes(a))
                    .font(.system(size: 12.5, design: .rounded)).foregroundStyle(a < b ? Theme.green : .secondary)
            }
            if entry.undone {
                Text("Nel Cestino").font(.system(size: 12.5)).foregroundStyle(.secondary)
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
                        a.messageText = entry.outputs.count == 1 ? String(localized: "Spostare il file nel Cestino?") : String(localized: "Spostare \(entry.outputs.count) file nel Cestino?")
                        a.informativeText = String(localized: "Si possono ancora recuperare dal Cestino.")
                        a.addButton(withTitle: String(localized: "Sposta nel Cestino"))
                        a.addButton(withTitle: String(localized: "Annulla"))
                        Sheet.confirmDestructive(a) { ok in if ok { store.undo(entry) } }   // 5.1 · «Annulla» predefinito
                    }
                }
                Button("Togli dalla cronologia") { withAnimation(Motion.quick) { store.forgetUndoably(entry) } }   // 5.1 · con «Annulla»
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
        month.locale = Locale(identifier: AppLanguage.active == "en" ? "en_US" : "it_IT")
        month.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [HistoryEntry]] = [:]
        for e in list {
            let key: String, title: String
            if cal.isDateInToday(e.date) { key = "0"; title = String(localized: "Oggi") }
            else if cal.isDateInYesterday(e.date) { key = "1"; title = String(localized: "Ieri") }
            else if cal.isDate(e.date, equalTo: now, toGranularity: .weekOfYear) { key = "2"; title = String(localized: "Questa settimana") }
            else if cal.isDate(e.date, equalTo: now, toGranularity: .month) { key = "3"; title = String(localized: "Questo mese") }
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
            Text(day.entries.count == 1 ? String(localized: "1 lavoro") : String(localized: "\(day.entries.count) lavori"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if day.saved > 0 {
                Label(String(localized: "\(Fmt.bytes(day.saved)) risparmiati"),
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
                    PageHeader(title: String(localized: "Componenti"),
                               subtitle: String(localized: "I programmi che fanno il lavoro. Quelli mancanti servono solo ad alcune funzioni."),
                               color: Theme.green) {
                        Button(testing ? String(localized: "Controllo in corso…") : String(localized: "Controllo automatico")) { runTest() }
                            .disabled(testing)
                        if !installer.missing.isEmpty && installer.brewPath != nil {
                            Button("Installa tutti i mancanti") { installer.install(installer.missing, id: "all") }
                                .buttonStyle(.borderedProminent).tint(Theme.green).disabled(installer.running != nil)
                                .help(installer.running != nil ? String(localized: "Aspetta: sto già installando un programma.") : "")
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Già incluso in macOS").font(.system(size: 13, weight: .semibold))
                            Text("JPG, PNG, HEIC, TIFF, ridimensionamento foto, MP4, MOV, M4A, HEVC, PDF e testo dalle immagini: funzionano senza installare nulla.")
                                .font(.system(size: 12.5)).foregroundStyle(.secondary)
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
                                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
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
                    Text(c.purpose).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(c.unlocks).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok && installer.brewPath != nil {
                if installer.running == c.id { ProgressView().controlSize(.small) }
                else {
                    Button("Installa") { installer.install([c], id: c.id) }.disabled(installer.running != nil)
                        .help(installer.running != nil ? String(localized: "Aspetta: sto già installando un programma.") : "")
                }
            }
        }
        .padding(14)
        .card(radius: 12)
    }

    private func runTest() {
        testing = true
        testOutput = String(localized: "Provo tutte le funzioni con file di prova (circa un minuto)…")
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [Paths.script.path, "--test"]
            p.environment = Paths.engineEnvironment()
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

extension View {
    /// 3.0 · Il pulsante principale della schermata (uno solo): pieno se `on`, normale altrimenti.
    @ViewBuilder func primaryButton(_ on: Bool = true) -> some View {
        if on { self.buttonStyle(.borderedProminent).tint(Theme.accent) } else { self.buttonStyle(.bordered) }
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TitleAccent(color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 8) { actions() }
        }
    }
}

/// 3.9 · Il segno d'ottone accanto al titolo di ogni scheda: stessa intestazione ovunque, una sola app.
struct TitleAccent: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(color.gradient).frame(width: 5, height: 36)
            .accessibilityHidden(true)
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
            // 4.1.2 · Versione nuova: si vede anche dal menu in alto
            MenuUpdateRow()
            MenuDropZone()
            // 4.0 · Quanto hai risparmiato questo mese
            if store.savedThisMonth > 0 {
                Label("Questo mese hai risparmiato \(Fmt.bytes(store.savedThisMonth))", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
            }
            if store.runningJobs.isEmpty {
                Text("Niente in corso").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                ForEach(store.runningJobs) { job in RunningRow(job: job) }
            }
            if !store.history.isEmpty {
                Divider()
                Text("Recenti").font(.system(size: 11.5)).foregroundStyle(.secondary)
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
            Button("Suggerisci un’idea…") { Feedback.show() }
                .buttonStyle(.plain)
            SettingsLink { Text("Opzioni…") }.buttonStyle(.plain)
            Button("Esci") { NSApp.terminate(nil) }.buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 290)
    }
}

/// 3.2 · Trascina un file sul menu di OrbitLR (dalla barra in alto): si apre la torta, senza aprire la finestra.
struct MenuDropZone: View {
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.pie.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(targeted ? String(localized: "Rilascia qui") : String(localized: "Trascina qui un file")).font(.system(size: 12.5, weight: .semibold))
            Text("si apre la torta, senza aprire la finestra").font(.system(size: 11)).foregroundStyle(.secondary)
            if UserDefaults.standard.object(forKey: "dropShelf") as? Bool ?? true {
                // 3.9.1 · Più comodo: il ripiano compare da solo al bordo destro
                Text("Più comodo: trascina un file da dove vuoi, OrbitLR compare sul lato dello schermo")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(targeted ? 0.16 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(targeted ? 0.9 : 0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            Sounds.drop()
            NSApp.keyWindow?.orderOut(nil)            // si chiude il menu, poi la torta accanto al puntatore
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { PieController.shared.present(files: files) }
            return true
        } isTargeted: { targeted = $0 }
        .animation(Motion.quick, value: targeted)
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
                Text(job.statusWithTime).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
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
    /// 3.9.1 · Il ripiano al bordo dello schermo
    @AppStorage("dropShelf") private var dropShelf = true
    @AppStorage("dropShelfSide") private var dropShelfSide = "right"
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
                            Text(draft.destPath.isEmpty ? String(localized: "Nessuna cartella scelta") : draft.destPath)
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
                    LanguagePicker()
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
                    Picker("Come scegli le opzioni", selection: $draft.controlStyle) {
                        Text("Da un elenco").tag("list")
                        Text("Con le manopole d’ottone").tag("knob")
                    }
                }
                Section("Avvio") {
                    Toggle("Apri OrbitLR all’accesso al Mac (il menu si apre all’istante)", isOn: $draft.launchAtLogin)
                    Toggle("Scorciatoia ⌥⌘C sui file selezionati nel Finder", isOn: $draft.hotkey)
                    if draft.hotkey && Hotkey.shared.conflict {
                        Label("⌥⌘C è già usata da un’altra app: nel Finder potrebbe non funzionare.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Toggle("Ripiano: quando trascini dei file, OrbitLR compare sul lato dello schermo", isOn: $dropShelf)
                    if dropShelf {
                        Picker("Lato del ripiano", selection: $dropShelfSide) {
                            Text("Destra").tag("right")
                            Text("Sinistra").tag("left")
                        }
                    }
                    Toggle("Controlla da sola se c’è una versione nuova (ogni 3 ore)", isOn: $autoUpdate)
                    Button("Controlla adesso…") { Task { @MainActor in await UpdateCheck.check(userInitiated: true) } }
                }
                // 5.0 · La promessa sulla privacy, scritta con precisione
                Section("Privacy") {
                    Text("I tuoi file non lasciano mai il Mac: OrbitLR li lavora qui. Su internet va solo quando lo chiedi tu (Video e Audio Downloader) e, una volta sola, per scaricare il motore di alcune funzioni (IA, trascrizione) e per controllare gli aggiornamenti.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Link("Informativa sulla privacy", destination: URL(string: "https://lr-apps609.github.io/OrbitLR/privacy.html")!)
                }
                // 3.0 · Quello che serve di rado, chiuso di base
                Section {
                    DisclosureGroup("Avanzate", isExpanded: $advanced) {
                        Toggle("Animazione di avvio", isOn: $draft.splash)
                        Toggle("Lascia fare a macOS quando può (consigliato)", isOn: $draft.useNative)
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
                // 3.9 · Come in tutto il Mac: ogni scelta vale subito, senza «Applica»
                if saved {
                    Label("Salvato", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.green)
                        .transition(.opacity)
                }
                Spacer()
                Button("Chiudi") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.parchment.opacity(0.45))
        }
        .frame(width: 580)
        .background(Theme.cream)
        .foregroundStyle(Theme.ink)
        .onAppear { settings.refresh(); draft = settings.draft; saved = false }
        .onChange(of: draft) { _, _ in
            guard changed else { return }
            settings.apply(draft)
            withAnimation(Motion.quick) { saved = true }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { draft.destPath = u.path }
    }
}

/// 4.1.2 · Nel menu in alto: «Nuova versione 4.2 · Installa».
struct MenuUpdateRow: View {
    @ObservedObject var badge = UpdateBadge.shared
    var body: some View {
        if let rel = badge.available {
            Button { Task { @MainActor in await UpdateCheck.install(rel) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.brass)
                    Text(badge.installing ? badge.downloadingText : String(localized: "Nuova versione \(rel.version) · Installa"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brass.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(badge.installing)
        }
    }
}

/// 5.0.2 · La larghezza della barra laterale (per ridisegnarla su Sonoma).
private struct SidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
