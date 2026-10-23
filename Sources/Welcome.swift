import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Avvio di OrbitLR
//  • Primo avvio: schedina di caricamento, poi tre schermate di benvenuto (punto 36).
//  • Avvii successivi: 2–3 secondi di animazione, poi un suggerimento diverso ogni volta,
//    con «Non mostrare più». Niente schedina se l'app si apre per un file o all'accesso al Mac.
//  • «Guida rapida» (barra dei menu): le tre schermate, quando vuoi.
// ════════════════════════════════════════════════════════════════════

final class WelcomeController: ObservableObject, @unchecked Sendable {
    static let shared = WelcomeController()

    enum Phase: Equatable { case loading, permissions, page(Int), tip, news }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let symbol: String
    }

    let steps = [
        Step(id: 0, title: "Preparo il motore di conversione", symbol: "gearshape.2.fill"),
        Step(id: 1, title: "Carico i suoni", symbol: "speaker.wave.2.fill"),
        Step(id: 2, title: "Controllo i componenti", symbol: "shippingbox.fill"),
        Step(id: 3, title: "Imposto le scorciatoie", symbol: "command"),
    ]

    @Published var phase: Phase = .loading
    @Published var doneSteps = 0
    @Published var componentsFound = 0
    @Published var firstLaunch = false
    /// Avvio normale: schedina compatta che sparisce da sola appena l'app è pronta.
    @Published var quick = false
    @Published var stepText = ""
    @Published var tip: Tip = Tip.all[0]
    /// Dopo un aggiornamento: al posto del suggerimento compare «Cosa c'è di nuovo».
    @Published var justUpdated = false
    @Published var fromVersion = ""
    /// 2.9.2 · I permessi di macOS, chiesti qui all'inizio e non a metà lavoro.
    let permissions = Permissions()
    /// Dopo la schermata dei permessi: le tre schermate (primo avvio) o le novità (aggiornamento).
    private var afterPermissions: Phase? = nil
    private var window: NSWindow?
    private var hidden: [NSWindow] = []

    /// Vero se l'app è stata aperta per dei file (Finder, ⌥⌘C, Dock) o all'accesso al Mac: niente schedina.
    var skipNextSplash = false
    /// Vero mentre la schedina di avvio (o la guida) è aperta.
    var isShowing: Bool { window != nil }

    static var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: "welcomeDone") }
    /// Schermata a ogni apertura: spenta di base (per un'app di utilità l'attesa a ogni avvio stanca).
    /// Compare comunque al primo avvio e dopo ogni aggiornamento.
    /// Dalla 2.6.3 accesa di base: dura solo il tempo vero dell'avvio (niente attese finte, niente suggerimenti).
    static var splashEnabled: Bool { UserDefaults.standard.object(forKey: "launchScreen") as? Bool ?? true }
    static var tipsEnabled: Bool { UserDefaults.standard.object(forKey: "tips") as? Bool ?? true }

    /// Chiamata all'avvio: decide se mostrare benvenuto, schedina con suggerimento, o niente.
    func showAtLaunch() {
        // Aperta con doppio clic su un aggiornamento: niente schedina e niente finestra, solo l'aggiornamento
        if Updater.shared.busy { skipNextSplash = false; return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let last = UserDefaults.standard.string(forKey: "lastLaunchVersion")
        UserDefaults.standard.set(current, forKey: "lastLaunchVersion")
        justUpdated = last != nil && last != current
        fromVersion = last ?? ""
        UserDefaults.standard.set(fromVersion, forKey: "newsFrom")
        if justUpdated { DockIcon.refreshIfNeeded() }
        if Self.isFirstLaunch {
            show(mode: .first)
        } else if (Self.splashEnabled || justUpdated) && !skipNextSplash {
            show(mode: .splash)
        } else {
            LaunchGate.release()          // niente schedina: la finestra compare subito
        }
        skipNextSplash = false
    }

    enum Mode { case first, splash, guide }

    /// «Guida rapida»: solo le tre schermate.
    func showGuide() { show(mode: .guide) }

    private func show(mode: Mode) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        firstLaunch = mode == .first
        quick = mode == .splash
        phase = mode == .guide ? .page(0) : .loading
        doneSteps = 0
        // Resta solo la schedina, come durante l'aggiornamento
        hidden = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        hidden.forEach { $0.orderOut(nil) }

        let size = NSSize(width: 500, height: 470)
        let host = NSHostingView(rootView: WelcomeView(ctl: self))
        host.frame.size = size
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.level = .floating                 // sempre sopra la finestra principale, anche se macOS la crea dopo
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        WindowClose.once(w) { [weak self] in
            self?.finished()
        }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        if mode != .guide { runLoading(quick: mode == .splash) }
    }

    /// Lavori veri dell'avvio. Al primo avvio ogni passo resta visibile ~0,6 s; agli altri avvii è tutto più rapido
    /// (in totale 2–3 secondi), giusto il tempo dell'animazione.
    private func runLoading(quick: Bool) {
        let work: [() -> Void] = [
            { Paths.installScript() },
            { DispatchQueue.main.sync { Sounds.shared.prepare() } },
            { let n = Installer.shared.components.filter { $0.installed }.count
              DispatchQueue.main.async { self.componentsFound = n } },
            { DispatchQueue.main.sync { PresetStore.shared.registerHotkeys() } },
        ]
        // Avvio normale: nessuna attesa finta, solo il minimo perché la barra si veda riempire (circa un secondo)
        let minStep = quick ? 0.08 : 0.6
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, job) in work.enumerated() {
                let t0 = Date()
                DispatchQueue.main.async { self.stepText = self.steps[i].title + "…" }
                job()
                let spent = Date().timeIntervalSince(t0)
                if spent < minStep { Thread.sleep(forTimeInterval: minStep - spent) }
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { self.doneSteps = i + 1 } }
            }
            let total = Date().timeIntervalSince(started)
            let tail = quick ? max(0.1, 0.6 - total) : 0.7
            Thread.sleep(forTimeInterval: tail)
            DispatchQueue.main.async { self.afterLoading(quick: quick) }
        }
    }

    private func afterLoading(quick: Bool) {
        guard window != nil else { return }
        if !quick {
            afterPermissions = .page(0)
            withAnimation(.easeInOut(duration: 0.35)) { phase = .permissions }
        } else if justUpdated {
            justUpdated = false
            afterPermissions = News.items.isEmpty ? nil : .news
            withAnimation(.easeInOut(duration: 0.35)) { phase = .permissions }
        } else {
            finish()                 // pronta: la schedina sfuma e compare la finestra
        }
    }

    /// Fine della schermata dei permessi (chiesti o rimandati).
    func permissionsDone() {
        if let p = afterPermissions {
            afterPermissions = nil
            withAnimation(.easeInOut(duration: 0.35)) { phase = p }
        } else {
            finish()
        }
    }

    func next() {
        if case .page(let n) = phase {
            if n >= 2 { finish() } else { withAnimation(.easeInOut(duration: 0.25)) { phase = .page(n + 1) } }
        }
    }

    func back() {
        if case .page(let n) = phase, n > 0 { withAnimation(.easeInOut(duration: 0.25)) { phase = .page(n - 1) } }
    }

    func anotherTip() {
        withAnimation(.easeInOut(duration: 0.25)) { tip = Tip.next() }
    }

    /// «Non mostrare più»: dalla prossima volta, solo l'animazione (si riattiva dalle Opzioni).
    func stopTips() {
        UserDefaults.standard.set(false, forKey: "tips")
        finish()
    }

    func finish() {
        guard let w = window else { return }
        finished()
        // Dissolvenza morbida verso la finestra principale
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            w.alphaValue = 1
        })
    }

    private func finished() {
        guard window != nil else { return }
        UserDefaults.standard.set(true, forKey: "welcomeDone")
        window = nil
        LaunchGate.release()
        hidden.forEach { $0.alphaValue = 1; $0.makeKeyAndOrderFront(nil) }
        hidden = []
        // La finestra principale potrebbe essere nata dopo la schedina: va mostrata comunque
        AppDelegate.revealMainWindow()
        NSApp.activate()
    }
}

// MARK: - Novità della versione (NOVITA.txt, incluso nell'app)

enum News {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "NOVITA", withExtension: "txt"),
              let t = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return t
    }()

    /// 2.7.5 · Solo le novità arrivate dopo la versione che avevi (al massimo le ultime 3 versioni),
    /// non tutta la storia dell'app.
    static func items(since from: String, in text: String = text, maxVersions: Int = 3) -> [String] {
        var out: [String] = []
        var versions = 0
        var take = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = version(inHeader: line) {
                take = versions < maxVersions && (from.isEmpty ? versions == 0 : newer(v, than: from))
                if take { versions += 1 }
                if !take && versions > 0 { break }       // le sezioni sono in ordine, dalla più nuova
                continue
            }
            if take, line.hasPrefix("•") { out.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    static var items: [String] { items(since: UserDefaults.standard.string(forKey: "newsFrom") ?? "") }

    /// «Novità della 2.7.4 «Passo dopo passo»:» → «2.7.4»
    static func version(inHeader line: String) -> String? {
        guard line.hasPrefix("Novità della ") else { return nil }
        let rest = line.dropFirst("Novità della ".count)
        let v = rest.prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 2.7.5 · Dove si trova la novità: la scheda da aprire con «Mostra».
    static func place(of item: String) -> SidebarItem? {
        let s = item.lowercased()
        if s.hasPrefix("video") || s.contains("progetti") || s.contains("montaggio") { return .video }
        if s.hasPrefix("cronologia") { return .history }
        if s.hasPrefix("audio") || s.contains("testo in voce") { return .audio }
        if s.hasPrefix("coda") { return .queue }
        if s.contains("torta") || s.contains("spicchi") || s.hasPrefix("conversione") { return .workspace }
        return nil
    }
}

// MARK: - Suggerimenti

struct Tip: Equatable {
    let symbol: String
    let title: String
    let text: String

    static let all: [Tip] = [
        Tip(symbol: "film.fill", title: "Scheda Video",
            text: "Nella barra a sinistra apri Video: tagli, formato per Reels e TikTok che segue il soggetto, musica, unione di più video."),
        Tip(symbol: "bell.and.waves.left.and.right", title: "Suonerie per iPhone",
            text: "Nella scheda Audio scegli «Suoneria iPhone», sposta il riquadro sul pezzo che ti piace e crea il file .m4r."),
        Tip(symbol: "text.bubble", title: "Testo in voce",
            text: "Nella scheda Audio scrivi un testo e OrbitLR lo legge in un file audio. Le voci «Premium» di macOS sono le più naturali."),
        Tip(symbol: "space", title: "Anteprima con Spazio",
            text: "Con un file aperto nel menu, premi Spazio per vederlo grande, come nel Finder."),
        Tip(symbol: "star.circle.fill", title: "Preset con scorciatoia",
            text: "Spunta «Salva come preset» quando scegli le opzioni, poi assegnagli ⌃⌥1…9 nella pagina Preset: selezioni i file nel Finder e parte da solo."),
        Tip(symbol: "square.split.2x1", title: "Confronta prima e dopo",
            text: "Dopo una compressione, nella Coda premi Confronta e trascina la linea per vedere la differenza, anche ingrandita."),
        Tip(symbol: "keyboard", title: "Tasti 1–8",
            text: "Nel menu a torta ogni spicchio ha il suo numero. Invio ripete l’ultima scelta per quel tipo di file."),
        Tip(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Trascina il risultato",
            text: "L’icona colorata del file creato si trascina dove vuoi: in Mail, in WhatsApp, in una cartella."),
        Tip(symbol: "square.grid.2x2", title: "Tipi di file diversi",
            text: "Apri insieme foto, PDF e audio: compare un piccolo menu per ogni tipo, fino a 6."),
        Tip(symbol: "dial.medium", title: "Manopole",
            text: "Le manopole si girano trascinando, con la rotellina o con le frecce. Un clic passa alla posizione successiva."),
        Tip(symbol: "moon.stars.fill", title: "Radio di notte",
            text: "In Opzioni → Aspetto e suoni scegli la modalità scura e il tema: salvia, celeste o terracotta."),
        Tip(symbol: "command", title: "Tutte le scorciatoie",
            text: "Il pulsante ⌘ in alto nella finestra mostra sempre l’elenco completo delle scorciatoie."),
        Tip(symbol: "arrow.uturn.backward.circle.fill", title: "Si può sempre annullare",
            text: "Nella Cronologia, «Annulla» sposta nel Cestino i file creati e rimette a posto le rinomine."),
        Tip(symbol: "folder.fill", title: "Anche le cartelle",
            text: "Trascina una cartella intera: OrbitLR prende tutti i file che contiene, divisi per tipo."),
        Tip(symbol: "eye.slash", title: "Privacy delle foto",
            text: "«Rimuovi i metadati» toglie posizione GPS, dispositivo e data prima di condividere una foto."),
    ]

    /// Un suggerimento diverso a ogni avvio, a giro.
    static func next() -> Tip {
        let i = UserDefaults.standard.integer(forKey: "tipIndex")
        UserDefaults.standard.set(i + 1, forKey: "tipIndex")
        return all[i % all.count]
    }
}

// MARK: - Vista

struct WelcomeView: View {
    @ObservedObject var ctl: WelcomeController

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var body: some View {
        ZStack {
            GlowBackground(tint: Theme.accent)
            switch ctl.phase {
            case .loading:
                loading.transition(.opacity)
            case .tip:
                tipView.transition(.opacity)
            case .news:
                newsView.transition(.opacity)
            case .permissions:
                PermissionsView(p: ctl.permissions, firstLaunch: ctl.firstLaunch) { ctl.permissionsDone() }
                    .transition(.opacity)
            case .page(let n):
                page(n).transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                               removal: .move(edge: .leading).combined(with: .opacity)))
                    .id(n)
            }
        }
        .frame(width: 500, height: 470)
        .foregroundStyle(Theme.ink)
    }

    // MARK: Caricamento

    @ViewBuilder private var loading: some View {
        if ctl.quick { quickLoading } else { fullLoading }
    }

    /// Avvio normale: solo il marchio che si anima, il nome e la barra. Pochi elementi, niente da leggere.
    private var quickLoading: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            BrandAnimation(size: CGSize(width: 320, height: 180))
            VStack(spacing: 4) {
                Text("OrbitLR").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Versione \(version)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brass)
            }
            VStack(spacing: 7) {
                ProgressBar(value: Double(ctl.doneSteps) / Double(ctl.steps.count), tint: Theme.accent, height: 8)
                Text(ctl.stepText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 90)
            Spacer(minLength: 0)
        }
    }

    private var fullLoading: some View {
        VStack(spacing: 14) {
            BrandAnimation(size: CGSize(width: 300, height: 170))
                .padding(.top, 22)
            VStack(spacing: 3) {
                Text(ctl.firstLaunch ? "Benvenuto in OrbitLR" : "OrbitLR").font(.system(size: 19, weight: .bold, design: .rounded))
                if !ctl.firstLaunch {
                    Text("Versione \(version)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brass)
                }
            }
            ProgressBar(value: Double(ctl.doneSteps) / Double(ctl.steps.count), tint: Theme.accent, height: 10)
                .padding(.horizontal, 40)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(ctl.steps) { s in
                    let done = s.id < ctl.doneSteps
                    let current = s.id == ctl.doneSteps
                    HStack(spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : s.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(done ? Theme.green : (current ? Theme.accent : Color.secondary))
                            .frame(width: 18)
                        Text(s.id == 2 && done ? "\(s.title) · \(ctl.componentsFound) di \(Installer.shared.components.count) pronti" : s.title)
                            .font(.system(size: 12, weight: current ? .semibold : .regular))
                            .foregroundStyle(done || current ? Theme.ink : Color.secondary)
                        if current { ProgressView().controlSize(.mini) }
                    }
                }
            }
            .frame(width: 330, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: Suggerimento

    private var tipView: some View {
        VStack(spacing: 14) {
            BrandAnimation(size: CGSize(width: 240, height: 130))
                .padding(.top, 20)
            Text("LO SAPEVI?").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.brass)
            VStack(spacing: 10) {
                Image(systemName: ctl.tip.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.accent.opacity(0.14)))
                Text(ctl.tip.title).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(ctl.tip.text).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .id(ctl.tip.title)
            .transition(.opacity)
            Spacer(minLength: 0)
            HStack {
                Button("Non mostrare più") { ctl.stopTips() }
                    .help("Dalla prossima volta solo l’animazione. Si riattiva in Opzioni → Aspetto e suoni")
                Button { ctl.anotherTip() } label: { Label("Un altro", systemImage: "arrow.right") }
                Spacer()
                Button("Inizia") { ctl.finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
    }

    // MARK: Cosa c'è di nuovo

    private var newsView: some View {
        VStack(spacing: 12) {
            BrandAnimation(size: CGSize(width: 220, height: 110))
                .padding(.top, 18)
            VStack(spacing: 3) {
                Text("COSA C’È DI NUOVO").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.brass)
                Text("OrbitLR \(version)").font(.system(size: 19, weight: .bold, design: .rounded))
                if !ctl.fromVersion.isEmpty {
                    Text("aggiornata dalla \(ctl.fromVersion)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(News.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                            Text(item).font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            // 2.7.5 · «Mostra»: apre la scheda dove si trova la novità
                            if let place = News.place(of: item) {
                                Button {
                                    AppState.shared.selection = place
                                    ctl.finish()
                                } label: { Text("Mostra ›").font(.system(size: 11.5, weight: .semibold)) }
                                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                                .help("Apri «\(place.rawValue)»")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .scrollIndicators(.visible)          // 2.8.7 · la barra per scorrere si vede sempre
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(0.05)))
            .padding(.horizontal, 28)
            HStack {
                Spacer()
                Button("Inizia") { ctl.finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
    }

    // MARK: Le tre schermate

    private struct PageInfo {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        let tips: [String]
    }

    private var pages: [PageInfo] {
        [
            PageInfo(symbol: "cursorarrow.click.2", color: Theme.color(.img), title: "Tasto destro nel Finder",
                     text: "Clic destro su uno o più file, poi «OrbitLR»: lo trovi in fondo al menu o in «Servizi».",
                     tips: ["Funziona anche con le cartelle", "Fino a 100 file dello stesso tipo"]),
            PageInfo(symbol: "command", color: Theme.color(.pdf), title: "Seleziona e premi ⌥⌘C",
                     text: "Seleziona i file nel Finder e premi ⌥⌘C: il menu a torta si apre accanto al puntatore.",
                     tips: ["Muovi il mouse verso un’azione e fai clic", "Tasti 1–8 per scegliere, Invio = ultima scelta",
                            "I tuoi preset partono con ⌃⌥1…9"]),
            PageInfo(symbol: "hand.draw.fill", color: Theme.color(.video), title: "Trascina, oppure usa la finestra",
                     text: "Trascina i file nella finestra di OrbitLR o sulla sua icona nel Dock. L’icona in alto a destra, nella barra dei menu, mostra i lavori in corso.",
                     tips: ["Spazio = anteprima del file", "Il pulsante ⌘ in alto elenca tutte le scorciatoie",
                            "Nella Coda: Confronta, per vedere prima e dopo"]),
        ]
    }

    private func page(_ n: Int) -> some View {
        let p = pages[min(n, pages.count - 1)]
        return VStack(spacing: 16) {
            ZStack {
                Circle().fill(p.color.opacity(0.16)).frame(width: 120, height: 120)
                Circle().strokeBorder(p.color.opacity(0.45), lineWidth: 1).frame(width: 120, height: 120)
                Image(systemName: p.symbol).font(.system(size: 46, weight: .semibold)).foregroundStyle(p.color)
            }
            .padding(.top, 40)
            Text(p.title).font(.system(size: 21, weight: .bold, design: .rounded))
            Text(p.text).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(p.tips, id: \.self) { t in
                    Label(t, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ink)
                }
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
            .card(radius: 12)
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule().fill(i == n ? Theme.accent : Theme.ink.opacity(0.18))
                            .frame(width: i == n ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if n > 0 { Button("Indietro") { ctl.back() } }
                else { Button("Salta") { ctl.finish() } }
                Button(n == pages.count - 1 ? "Inizia" : "Avanti") { ctl.next() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
    }
}

// MARK: - 2.9.2 · Permessi

struct PermissionsView: View {
    @ObservedObject var p: Permissions
    let firstLaunch: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.14)).frame(width: 52, height: 52)
                Image(systemName: "lock.open.fill").font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.top, 16)
            Text("Prima di iniziare").font(.system(size: 20, weight: .bold, design: .rounded))
            Text(firstLaunch
                 ? "macOS ti chiederà alcuni permessi. Meglio adesso, tutti insieme, che a metà lavoro."
                 : "Dopo un aggiornamento macOS chiede di nuovo i permessi. Meglio adesso, tutti insieme, che a metà lavoro.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            VStack(spacing: 0) {
                ForEach(p.items) { it in
                    HStack(spacing: 10) {
                        Image(systemName: it.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.title).font(.system(size: 12.5, weight: .semibold))
                            Text(it.why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        status(it.state)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(0.05)))
            .padding(.horizontal, 28)
            if p.items.contains(where: { $0.state == .denied }) {
                Text("Quelli con ✕ si possono dare dopo in Impostazioni di Sistema → Privacy e sicurezza.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                if !p.done && !p.running { Button("Più tardi") { onDone() } }
                Spacer()
                Button(p.done ? "Continua" : "Concedi i permessi") {
                    if p.done { onDone() } else { p.askAll { } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(p.running)
            }
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
    }

    @ViewBuilder private func status(_ s: Permissions.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(Theme.ink.opacity(0.25))
        case .asking: ProgressView().controlSize(.small)
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.75))
        }
    }
}
