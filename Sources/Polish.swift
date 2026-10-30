import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import QuartzCore
import AppKit
import QuickLookThumbnailing

// ════════════════════════════════════════════════════════════════════
//  Rifiniture grafiche della 2.3.3
//  • Miniature vere dei file (Coda, Cronologia, barra del risultato)
//  • Numeri che «contano» (peso risparmiato)
//  • Barra a sintonizzatore, come la scala di una radio d'epoca
//  • Radiolina illustrata per le pagine vuote
//  • Avanzamento sull'icona nel Dock
// ════════════════════════════════════════════════════════════════════

// MARK: - Miniature

/// Le miniature già create, così scorrendo la Cronologia non vengono rifatte.
/// 3.4.4 · Anche sul disco (Cache di OrbitLR): al riavvio, Cassetto, Attività e schede le hanno subito.
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private let disk = DispatchQueue(label: "orbitlr.miniature", qos: .utility, attributes: .concurrent)
    static var folder: URL { Paths.home.appendingPathComponent("Library/Caches/OrbitLR/Miniature", isDirectory: true) }

    /// L'ultima miniatura per file e misura, senza guardare la data del file: si legge dal thread principale
    /// senza toccare il disco (la versione giusta arriva comunque da `image`, controllata in sottofondo)
    private let latest = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600; latest.countLimit = 600 }

    private static func key(_ url: URL, _ side: CGFloat) -> String { "\(url.path)|\(Int(side))|\(stamp(url))" }

    /// Il file sul disco per una miniatura (nome = impronta della chiave).
    static func diskURL(_ key: String) -> URL {
        var h: UInt64 = 1469598103934665603                    // FNV-1a: stabile tra un avvio e l'altro
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return folder.appendingPathComponent(String(h, radix: 36) + ".png")
    }

    /// Solo dalla memoria, subito (per mostrare la miniatura già al primo disegno, senza dissolvenze).
    func cached(for url: URL?, side: CGFloat) -> NSImage? {
        guard let url else { return nil }
        return latest.object(forKey: "\(url.path)|\(Int(side))" as NSString)
    }

    func image(for url: URL, side: CGFloat, done: @escaping (NSImage?) -> Void) {
        let quick = "\(url.path)|\(Int(side))" as NSString
        let t0 = CACurrentMediaTime()
        // 3.5 · Tutto quello che tocca il disco (data del file, file sul disco) avviene in sottofondo
        disk.async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.latest.removeObject(forKey: quick)          // file sparito: niente miniatura vecchia al prossimo disegno
                DispatchQueue.main.async { done(nil) }; return
            }
            let k = Self.key(url, side)
            if let img = self.cache.object(forKey: k as NSString) { DispatchQueue.main.async { done(img) }; return }
            let file = Self.diskURL(k)
            if let img = NSImage(contentsOf: file) {
                self.cache.setObject(img, forKey: k as NSString)
                self.latest.setObject(img, forKey: quick)
                Perf.record(.thumbnail, CACurrentMediaTime() - t0)
                DispatchQueue.main.async { done(img) }
                return
            }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                // 5.0.2 · Se Quick Look non dà la miniatura (su alcuni Mac con macOS 14, per i video), la si fa da sé
                let img = rep?.nsImage ?? Self.fallback(url, side: side)
                if img == nil { self?.latest.removeObject(forKey: quick) }
                if let img, let self {
                    self.cache.setObject(img, forKey: k as NSString)
                    self.latest.setObject(img, forKey: quick)
                    Perf.record(.thumbnail, CACurrentMediaTime() - t0)
                    if let cg = rep?.cgImage {
                        self.disk.async {
                            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                            let bitmap = NSBitmapImageRep(cgImage: cg)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: file, options: .atomic)
                        }
                    }
                }
                DispatchQueue.main.async { done(img) }
            }
        }
    }

    /// 5.0.2 · Miniatura senza Quick Look: un fotogramma per i video, ImageIO per le foto.
    static func fallback(_ url: URL, side: CGFloat) -> NSImage? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: side * 2, height: side * 2)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            for t in [0.5, 0.0] {
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    return NSImage(cgImage: cg, size: .zero)
                }
            }
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side * 2,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// La stessa, da attendere dentro una `.task` (così una risposta per un file vecchio si può scartare).
    func image(for url: URL, side: CGFloat) async -> NSImage? {
        await withCheckedContinuation { c in image(for: url, side: side) { c.resume(returning: $0) } }
    }

    /// Data di modifica: se il file cambia, la miniatura si rifà.
    private static func stamp(_ url: URL) -> Int {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return Int(d.timeIntervalSince1970)
    }

    /// 3.5.2 · Via tutte le miniature, in memoria e sul disco.
    func forgetAll() {
        cache.removeAllObjects()
        latest.removeAllObjects()
        disk.async(flags: .barrier) { try? FileManager.default.removeItem(at: Self.folder) }
    }

    /// Le miniature sul disco più vecchie di 30 giorni se ne vanno (all'avvio, in sottofondo).
    static func trimDisk(olderThan days: Double = 30) {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let limit = Date().addingTimeInterval(-days * 86_400)
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentAccessDateKey]) else { return }
            for u in items {
                let d = (try? u.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
                if d < limit { try? fm.removeItem(at: u) }
            }
        }
    }
}

/// L'anteprima reale del file (la foto, la prima pagina del PDF, un fotogramma del video),
/// con un piccolo bollino del tipo di file nell'angolo. Finché non è pronta, o se il file non c'è più,
/// mostra il riquadro colorato di sempre.
struct FileThumb: View {
    let url: URL?
    let kind: Kind?
    var size: CGFloat = 44
    @State private var image: NSImage? = nil

    init(url: URL?, kind: Kind?, size: CGFloat = 44) {
        self.url = url
        self.kind = kind
        self.size = size
        // 3.4.4 · Se la miniatura è già pronta, c'è dal primo disegno: niente riquadro vuoto né dissolvenza
        _image = State(initialValue: ThumbCache.shared.cached(for: url, side: size * 2))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Theme.stroke))
                    .shadow(color: Theme.shadow.opacity(0.18), radius: 4, y: 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                KindBadge(kind: kind, size: max(14, size * 0.4))
                    .offset(x: size * 0.12, y: size * 0.12)
            } else {
                KindBadge(kind: kind, size: size)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.quick, value: image != nil)
        .task(id: url?.path) {
            guard let url else { image = nil; return }
            // 3.5.1 · Sempre la miniatura di QUESTO file (mai quella del precedente), e una risposta
            // arrivata tardi per un file vecchio viene scartata
            image = ThumbCache.shared.cached(for: url, side: size * 2)
            let img = await ThumbCache.shared.image(for: url, side: size * 2)
            guard !Task.isCancelled else { return }
            if img !== image { image = img }
        }
    }
}

// MARK: - Numeri che contano

/// Un peso (byte) che, quando cambia, «conta» fino al nuovo valore invece di saltare.
struct CountingBytes: View, Animatable {
    var value: Double
    var prefix: String = ""
    var font: Font = .system(size: 12, design: .rounded)
    var color: Color = .secondary

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(prefix + Fmt.bytes(Int64(max(0, value))))
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

/// «−4,2 MB» che conta da zero quando il lavoro finisce, con un piccolo scatto.
struct SavedBadge: View {
    @ObservedObject var job: Job
    @State private var shown: Double = 0
    @State private var pop = false

    private var saved: Double {
        guard job.state == .done, job.renames == nil, job.beforeBytes > 0 else { return 0 }
        return Double(job.beforeBytes - job.afterBytes)
    }

    var body: some View {
        Group {
            if saved > 0 {
                CountingBytes(value: shown, prefix: "−", font: .system(size: 13, weight: .bold, design: .rounded), color: Theme.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.green.opacity(0.14)))
                    .scaleEffect(pop ? 1.12 : 1)
                    .help("Spazio risparmiato")
            }
        }
        .onAppear { shown = saved }
        .onChange(of: job.state) { _, s in
            guard s == .done, saved > 0 else { return }
            shown = 0
            withAnimation(.easeOut(duration: 0.9)) { shown = saved }
            withAnimation(Motion.spring(0.25, 0.5)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(Motion.spring(0.3, 0.7)) { pop = false }
            }
        }
    }
}

// MARK: - Barra di avanzamento

/// Barra che si riempie: sfondo verde leggero, riempimento verde più forte, percentuale accanto.
/// Va sempre avanti da sinistra a destra; a lavoro finito è piena e mostra la spunta.
/// (Il nome «TunerBar» è rimasto da quando era a forma di scala da radio.)
struct TunerBar: View {
    let value: Double          // 0…1
    let tint: Color            // non più usato per il colore: la barra è sempre verde, come richiesto
    var done = false
    var height: CGFloat = 26   // altezza della riga; la barra vera è più sottile

    private var v: Double { done ? 1 : max(0, min(1, value)) }
    private var barHeight: CGFloat { max(6, min(10, height * 0.42)) }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { g in
                let w: CGFloat = g.size.width
                let fillWidth: CGFloat = max(barHeight, w * CGFloat(v))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.green.opacity(0.18))
                    // 2.7: la scala della radio, tacche ogni 10%
                    HStack(spacing: 0) {
                        ForEach(1..<10, id: \.self) { _ in
                            Spacer(minLength: 0)
                            Rectangle().fill(Theme.ink.opacity(0.16)).frame(width: 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.green.opacity(0.85), Theme.green],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            // Riflesso leggero in alto, per un aspetto più rifinito
                            Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                          startPoint: .top, endPoint: .center))
                                .frame(width: fillWidth)
                        }
                        .opacity(v > 0.001 ? 1 : 0)
                }
            }
            .frame(height: barHeight)
            .clipShape(Capsule())
            // La lancetta d'ottone che corre con il riempimento (fuori dal ritaglio, così sporge un poco)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    let x = max(barHeight / 2, g.size.width * CGFloat(v) - 1)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.brass)
                        .frame(width: 2.5, height: barHeight + 8)
                        .shadow(color: Theme.shadow.opacity(0.3), radius: 1, y: 1)
                        .offset(x: x - 1.25, y: -4)
                        .opacity(v > 0.001 && !done ? 1 : 0)
                }
            }

            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                } else {
                    Text("\(Int((v * 100).rounded(.down)))%").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
        .frame(height: max(barHeight, 14))
        .animation(.easeOut(duration: 0.35), value: v)
        .accessibilityElement()
        .accessibilityLabel("Avanzamento")
        .accessibilityValue(done ? String(localized: "completato") : String(localized: "\(Int(v * 100)) per cento"))
    }
}

// MARK: - Radiolina per le pagine vuote

/// Una piccola radio d'epoca disegnata: la griglia dell'altoparlante, la scala con la lancetta che oscilla
/// piano, e sopra il simbolo della pagina che galleggia come una nota.
struct RadioIllustration: View {
    let symbol: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active

    /// 3.4.1 · Movimenti nativi e continui (prima: 20 ridisegni al secondo, a scatti)
    @State private var bob = false
    @State private var sweep = false

    var body: some View {
        ZStack {
                // Nota che galleggia
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(color.opacity(0.14)))
                    .offset(x: 46, y: bob ? -68 : -60)
                    .rotationEffect(.degrees(bob ? 6 : -6))

                // Corpo
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.sageLight, Theme.sage], startPoint: .top, endPoint: .bottom))
                    .frame(width: 170, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.brass.opacity(0.6), lineWidth: 2))
                    .shadow(color: Theme.shadow.opacity(0.18), radius: 10, y: 6)

                // Altoparlante
                Circle().fill(Theme.parchment)
                    .frame(width: 66, height: 66)
                    .overlay(GrilleTexture(spacing: 5).clipShape(Circle()))
                    .overlay(Circle().strokeBorder(Theme.brass.opacity(0.7), lineWidth: 2))
                    .offset(x: -40, y: 2)

                // Scala con lancetta
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Radius.xs).fill(Theme.ivory)
                    HStack(spacing: 5) {
                        ForEach(0..<8, id: \.self) { i in
                            Rectangle().fill(Theme.ink.opacity(i % 2 == 0 ? 0.35 : 0.18)).frame(width: 1, height: i % 2 == 0 ? 9 : 5)
                        }
                    }
                    .padding(.leading, 5)
                    Capsule().fill(Theme.color(.pdf)).frame(width: 2, height: 16)
                        .offset(x: sweep ? 58 : 8)
                }
                .frame(width: 68, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Theme.brass.opacity(0.6)))
                .offset(x: 38, y: -18)

                // Manopole
                HStack(spacing: 14) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle().fill(Theme.ivory).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.brass, lineWidth: 1.5))
                            .overlay(Capsule().fill(Theme.ink.opacity(0.6)).frame(width: 2, height: 6).offset(y: -4)
                                .rotationEffect(.degrees(i == 0 ? (sweep ? 50 : -50) : -30)))
                    }
                }
                .offset(x: 38, y: 18)

                // Piedini
                HStack(spacing: 110) {
                    Capsule().fill(Theme.brass).frame(width: 14, height: 5)
                    Capsule().fill(Theme.brass).frame(width: 14, height: 5)
                }
                .offset(y: 52)
        }
        .frame(width: 200, height: 170)
        .modifier(LoopDriver(on: $bob, animation: .easeInOut(duration: 2.2).repeatForever(autoreverses: true)))
        .modifier(LoopDriver(on: $sweep, animation: .easeInOut(duration: 4.5).repeatForever(autoreverses: true)))
        .accessibilityHidden(true)
    }
}

// MARK: - Icona nel Dock

/// Mentre OrbitLR lavora, sotto l'icona nel Dock compare una barra che si riempie, e il numero dei lavori.
final class DockProgress: @unchecked Sendable {
    static let shared = DockProgress()
    private let view = DockView()
    private var showing = false

    /// Chiamata spesso (dal timer dell'icona nella barra dei menu): aggiorna solo se serve.
    func update() {
        let running = QueueStore.shared.jobs.filter { $0.state == .running }
        let waiting = QueueStore.shared.jobs.filter { $0.state == .waiting }.count
        let tile = NSApp.dockTile
        guard !running.isEmpty || waiting > 0 else {
            if showing {
                showing = false
                tile.contentView = nil
                tile.badgeLabel = nil
                tile.display()
            }
            return
        }
        if !showing {
            showing = true
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        }
        let known = running.map { $0.shownProgress }
        view.progress = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
        view.phase += 0.06
        let total = running.count + waiting
        tile.badgeLabel = total > 1 ? "\(total)" : nil
        tile.display()
    }

    final class DockView: NSView {
        var progress: Double? = nil     // nil = in corso senza percentuale
        var phase: Double = 0

        override func draw(_ dirtyRect: NSRect) {
            let b = bounds
            NSApp.applicationIconImage?.draw(in: b)
            let bar = NSRect(x: b.width * 0.12, y: b.height * 0.08, width: b.width * 0.76, height: b.height * 0.1)
            let r = bar.height / 2
            NSColor(white: 0, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: bar.insetBy(dx: -2, dy: -2), xRadius: r + 2, yRadius: r + 2).fill()
            NSColor(white: 1, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
            NSColor(srgbRed: 0.37, green: 0.60, blue: 0.33, alpha: 1).setFill()   // verde di OrbitLR
            if let p = progress {
                let fill = NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(p)), height: bar.height)
                NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
            } else {
                // Senza percentuale: un tratto che va e viene
                let seg = bar.width * 0.3
                let x = bar.minX + (bar.width - seg) * CGFloat((sin(phase) + 1) / 2)
                NSBezierPath(roundedRect: NSRect(x: x, y: bar.minY, width: seg, height: bar.height), xRadius: r, yRadius: r).fill()
            }
        }
    }
}

// MARK: - Accesso alla finestra

/// Dà accesso alla finestra AppKit che contiene una vista SwiftUI, appena la vista ci entra
/// (prima che la finestra compaia sullo schermo).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ v: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
}

/// All'avvio la finestra principale nasce invisibile: compare quando la schedina di avvio si chiude
/// (o subito, se la schedina non serve). Così non c'è il «lampo» della finestra prima dell'animazione.
enum LaunchGate {
    static var holding = false
    private static var held: [NSWindow] = []

    static func attach(_ w: NSWindow) {
        guard holding, !held.contains(where: { $0 === w }) else { return }
        w.alphaValue = 0
        // Invisibile ma presente: senza questo i clic la «attraversano» e finiscono sui suoi pulsanti
        // (es. clic su «Inizia» nella schedina → si apriva la scelta dei file e l'app restava nascosta)
        w.ignoresMouseEvents = true
        held.append(w)
        // Durante un aggiornamento nessuna finestra deve comparire: resta solo la schedina
        if Updater.shared.busy { DispatchQueue.main.async { w.orderOut(nil) } }
    }

    static func release() {
        guard !Updater.shared.busy else { return }
        if holding { Perf.end(.launch) }
        holding = false
        for w in held {
            w.alphaValue = 1
            w.ignoresMouseEvents = false
            // Nascosta per un aggiornamento poi annullato: torna visibile
            if !w.isVisible { w.orderFront(nil) }
        }
        held = []
    }
}

/// Osserva la chiusura di una finestra una sola volta, poi smette (niente osservatori dimenticati).
enum WindowClose {
    static func once(_ w: NSWindow, _ action: @escaping () -> Void) {
        final class Box: @unchecked Sendable { var token: NSObjectProtocol? }
        let box = Box()
        box.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            if let t = box.token { NotificationCenter.default.removeObserver(t) }
            box.token = nil
            action()
        }
    }
}

// MARK: - 2.7.6 · Icona del Dock aggiornata dopo un aggiornamento

/// macOS tiene in memoria le icone delle app: dopo l'aggiornamento il Dock può mostrare ancora quella vecchia.
/// Quando l'icona è cambiata rispetto all'ultima vista su questo Mac, si avvisa macOS e il Dock si ridisegna (una volta sola).
enum DockIcon {
    /// Da aumentare ogni volta che cambia l'icona dell'app (2 = quadrante della 2.7).
    static let revision = 3          // 3 = la torta di Orbit (3.9)
    static let key = "dockIconRevision"

    static func needsRefresh(stored: Int) -> Bool { stored < revision }

    static func refreshIfNeeded() {
        let d = UserDefaults.standard
        guard needsRefresh(stored: d.integer(forKey: key)) else { return }
        d.set(revision, forKey: key)
        let app = Bundle.main.bundlePath
        guard app.hasPrefix("/Applications/") else { return }        // solo l'app installata, mai una copia di prova
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: app)
            run(Updater.lsregister, ["-f", app])
            NSWorkspace.shared.noteFileSystemChanged(app)
            Thread.sleep(forTimeInterval: 1.5)                          // si lascia aprire la finestra, poi il Dock
            run("/usr/bin/killall", ["Dock"])                            // il Dock si riapre da solo in un attimo
        }
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
