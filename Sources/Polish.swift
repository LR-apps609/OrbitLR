import SwiftUI
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
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, side: CGFloat, done: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)|\(Int(side))|\(Self.stamp(url))" as NSString
        if let img = cache.object(forKey: key) { done(img); return }
        guard FileManager.default.fileExists(atPath: url.path) else { done(nil); return }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            let img = rep?.nsImage
            if let img { self?.cache.setObject(img, forKey: key) }
            DispatchQueue.main.async { done(img) }
        }
    }

    /// Data di modifica: se il file cambia, la miniatura si rifà.
    private static func stamp(_ url: URL) -> Int {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return Int(d.timeIntervalSince1970)
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
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: url?.path) {
            image = nil
            guard let url else { return }
            ThumbCache.shared.image(for: url, side: size * 2) { img in image = img }
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
        Text(prefix + ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file))
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
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pop = false }
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
        .accessibilityValue(done ? "completato" : "\(Int(v * 100)) per cento")
    }
}

// MARK: - Radiolina per le pagine vuote

/// Una piccola radio d'epoca disegnata: la griglia dell'altoparlante, la scala con la lancetta che oscilla
/// piano, e sopra il simbolo della pagina che galleggia come una nota.
struct RadioIllustration: View {
    let symbol: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            ZStack {
                // Nota che galleggia
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(color.opacity(0.14)))
                    .offset(x: 46, y: -64 + CGFloat(sin(t * 1.4)) * 4)
                    .rotationEffect(.degrees(sin(t * 0.9) * 6))

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
                    RoundedRectangle(cornerRadius: 4).fill(Theme.ivory)
                    HStack(spacing: 5) {
                        ForEach(0..<8, id: \.self) { i in
                            Rectangle().fill(Theme.ink.opacity(i % 2 == 0 ? 0.35 : 0.18)).frame(width: 1, height: i % 2 == 0 ? 9 : 5)
                        }
                    }
                    .padding(.leading, 5)
                    Capsule().fill(Theme.color(.pdf)).frame(width: 2, height: 16)
                        .offset(x: 8 + CGFloat((sin(t * 0.7) + 1) / 2) * 50)
                }
                .frame(width: 68, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.brass.opacity(0.6)))
                .offset(x: 38, y: -18)

                // Manopole
                HStack(spacing: 14) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle().fill(Theme.ivory).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.brass, lineWidth: 1.5))
                            .overlay(Capsule().fill(Theme.ink.opacity(0.6)).frame(width: 2, height: 6).offset(y: -4)
                                .rotationEffect(.degrees(i == 0 ? sin(t * 0.7) * 50 : -30)))
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
        }
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
