import SwiftUI
import AppKit
import PDFKit

// ════════════════════════════════════════════════════════════════════
//  Confronta prima/dopo (punto 34)
//  Originale e risultato sovrapposti, con una linea da trascinare.
//  Per immagini compresse, ridimensionate o convertite, e per i PDF compressi.
// ════════════════════════════════════════════════════════════════════

/// Una coppia originale → risultato.
struct ComparePair: Identifiable {
    let id = UUID()
    let before: URL
    let after: URL
    var isPDF: Bool { before.pathExtension.lowercased() == "pdf" }
}

extension Job {
    /// Le coppie da confrontare, se l'operazione ha senso da guardare (compressione, ridimensionamento, conversione
    /// di immagini, compressione di PDF) e gli originali ci sono ancora.
    var comparePairs: [ComparePair] {
        guard state == .done, !outputs.isEmpty else { return [] }
        let id = action.id
        let tools: Set<String> = ["resize", "pdfcompress", "searchable", "removebg", "straighten", "upscale", "aienhance"]
        guard tools.contains(id) || id.hasPrefix("to:") else { return [] }
        let ins = mainFiles
        guard ins.count == outputs.count else { return [] }
        let fm = FileManager.default
        return zip(ins, outputs).compactMap { a, b in
            guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path) else { return nil }
            let ka = Catalog.kind(of: a), kb = Catalog.kind(of: b)
            let images = ka == .img && kb == .img
            let pdfs = ka == .pdf && kb == .pdf
            return images || pdfs ? ComparePair(before: a, after: b) : nil
        }
    }
}

final class CompareController: @unchecked Sendable {
    static let shared = CompareController()
    private var windows: [NSWindow] = []

    func show(_ pairs: [ComparePair], title: String) {
        guard !pairs.isEmpty else { NSSound.beep(); return }
        let host = NSHostingView(rootView: CompareView(pairs: pairs))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Confronta · " + title
        w.contentView = host
        w.contentMinSize = NSSize(width: 560, height: 460)
        w.isReleasedWhenClosed = false
        w.center()
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windows.removeAll { $0 === w }
            if let t = token { NotificationCenter.default.removeObserver(t) }
        }
        windows.append(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct CompareView: View {
    let pairs: [ComparePair]

    @State private var pairIndex = 0
    @State private var page = 0
    @State private var split: CGFloat = 0.5           // posizione della linea, da 0 a 1
    @State private var zoom: CGFloat = 1               // 1 = adatta alla finestra
    @State private var pan: CGSize = .zero
    @State private var before: NSImage? = nil
    @State private var after: NSImage? = nil
    @State private var pageCount = 1
    @State private var beforeInfo = ""
    @State private var afterInfo = ""

    private var pair: ComparePair { pairs[min(pairIndex, pairs.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20).padding(.vertical, 14)
            stage
                .padding(.horizontal, 20)
            footer
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Theme.cream)
        .foregroundStyle(Theme.ink)
        .onAppear(perform: load)
        .onChange(of: pairIndex) { _, _ in page = 0; load() }
        .onChange(of: page) { _, _ in load() }
        .onChange(of: zoom) { _, z in if z == 1 { pan = .zero } }
    }

    // MARK: Testata: nomi, pesi, risparmio

    private var header: some View {
        let b = Job.size(of: pair.before), a = Job.size(of: pair.after)
        let pct = b > 0 ? Int((Double(a - b) / Double(b) * 100).rounded()) : 0
        return HStack(spacing: 16) {
            side("Prima", pair.before, bytes: b, info: beforeInfo, color: .secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            side("Dopo", pair.after, bytes: a, info: afterInfo, color: Theme.ink)
            Spacer()
            if b > 0 {
                Text(pct <= 0 ? "−\(abs(pct))%" : "+\(pct)%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(pct < 0 ? Theme.green : Theme.brass)
                    .help(pct < 0 ? "Spazio risparmiato" : "Il risultato pesa più dell'originale")
            }
        }
    }

    private func side(_ title: String, _ url: URL, bytes: Int64, info: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + (info.isEmpty ? "" : " · " + info))
                .font(.system(size: 11, design: .rounded)).foregroundStyle(color)
        }
    }

    // MARK: Le due immagini sovrapposte, con la linea

    private var stage: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let fit = fitted(in: g.size)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.parchment.opacity(0.45))
                if let before, let after {
                    layer(before, fit: fit, size: g.size)
                    layer(after, fit: fit, size: g.size)
                        .clipShape(RightPart(from: split))

                    // Linea e maniglia
                    Rectangle().fill(Theme.ivory).frame(width: 2, height: h)
                        .shadow(color: Theme.shadow.opacity(0.5), radius: 2)
                        .position(x: w * split, y: h / 2)
                    Circle().fill(Theme.ivory).frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Theme.brass, lineWidth: 2))
                        .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.ink))
                        .shadow(color: Theme.shadow.opacity(0.3), radius: 4, y: 2)
                        .position(x: w * split, y: h / 2)

                    tag("Prima").position(x: 46, y: 22)
                    tag("Dopo").position(x: w - 42, y: 22)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = max(0, min(1, v.location.x / max(w, 1)))
            })
            .overlay(PanCatcher { dx, dy in
                guard zoom > 1 else { return }
                pan.width += dx
                pan.height += dy
                let maxX = fit.width * (zoom - 1) / 2, maxY = fit.height * (zoom - 1) / 2
                pan.width = max(-maxX, min(maxX, pan.width))
                pan.height = max(-maxY, min(maxY, pan.height))
            })
        }
    }

    /// Un'immagine adattata, ingrandita e spostata: le due «facce» usano esattamente la stessa trasformazione.
    private func layer(_ img: NSImage, fit: CGSize, size: CGSize) -> some View {
        Image(nsImage: img).resizable().interpolation(zoom > 1 ? .none : .high)
            .frame(width: fit.width, height: fit.height)
            .scaleEffect(zoom)
            .offset(pan)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ivory)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Theme.ink.opacity(0.7)))
    }

    /// Dimensione dell'originale adattata allo spazio disponibile.
    private func fitted(in s: CGSize) -> CGSize {
        guard let before, before.size.width > 0, before.size.height > 0 else { return s }
        let r = min(s.width / before.size.width, s.height / before.size.height)
        return CGSize(width: before.size.width * r, height: before.size.height * r)
    }

    // MARK: Piede: pagine, coppie, ingrandimento

    private var footer: some View {
        HStack(spacing: 14) {
            if pairs.count > 1 {
                stepper("File \(pairIndex + 1) di \(pairs.count)", index: $pairIndex, count: pairs.count)
            }
            if pair.isPDF && pageCount > 1 {
                stepper("Pagina \(page + 1) di \(pageCount)", index: $page, count: pageCount)
            }
            Spacer()
            Text(zoom > 1 ? "Due dita sul trackpad (o la rotellina) per spostarti" : "Trascina la linea per confrontare")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Ingrandimento", selection: $zoom) {
                Text("Adatta").tag(CGFloat(1))
                Text("2×").tag(CGFloat(2))
                Text("4×").tag(CGFloat(4))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func stepper(_ label: String, index: Binding<Int>, count: Int) -> some View {
        HStack(spacing: 6) {
            Button { index.wrappedValue = max(0, index.wrappedValue - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(index.wrappedValue == 0)
            Text(label).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Button { index.wrappedValue = min(count - 1, index.wrappedValue + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index.wrappedValue >= count - 1)
        }
    }

    // MARK: Caricamento

    private func load() {
        let p = pair, pg = page
        before = nil
        after = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let b: (NSImage?, String, Int), a: (NSImage?, String, Int)
            if p.isPDF {
                b = Self.renderPDF(p.before, page: pg)
                a = Self.renderPDF(p.after, page: pg)
            } else {
                b = Self.image(p.before)
                a = Self.image(p.after)
            }
            DispatchQueue.main.async {
                guard p.id == pair.id, pg == page else { return }
                before = b.0
                after = a.0
                beforeInfo = b.1
                afterInfo = a.1
                pageCount = max(1, min(b.2, a.2))
            }
        }
    }

    /// Immagine con le sue dimensioni in pixel (quelle vere, non quelle «in punti»).
    private static func image(_ url: URL) -> (NSImage?, String, Int) {
        guard let img = NSImage(contentsOf: url) else { return (nil, "", 1) }
        let rep = img.representations.first
        let px = rep.map { "\($0.pixelsWide) × \($0.pixelsHigh) px" } ?? ""
        if let rep, rep.pixelsWide > 0 {
            // Stessa scala per tutte e due: conta la forma, non la risoluzione
            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return (img, px, 1)
    }

    /// Una pagina del PDF disegnata ad alta risoluzione: così si vedono gli effetti della compressione sulle immagini.
    private static func renderPDF(_ url: URL, page: Int) -> (NSImage?, String, Int) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return (nil, "", 1) }
        let n = doc.pageCount
        guard let pg = doc.page(at: min(page, n - 1)) else { return (nil, "", n) }
        let box = pg.bounds(for: .mediaBox)
        let scale = 2400 / max(box.width, box.height, 1)
        let img = pg.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        return (img, n == 1 ? "1 pagina" : "\(n) pagine", n)
    }
}

/// La parte destra dello spazio («Dopo»), dalla linea in poi.
private struct RightPart: Shape {
    var from: CGFloat
    var animatableData: CGFloat {
        get { from }
        set { from = newValue }
    }
    func path(in r: CGRect) -> Path {
        let x = r.width * from
        return Path(CGRect(x: x, y: 0, width: max(0, r.width - x), height: r.height))
    }
}

/// Trackpad (due dita) e rotellina sopra il confronto: sposta la vista quando è ingrandita. I clic passano sotto.
struct PanCatcher: NSViewRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onPan = onPan
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.onPan = onPan }

    final class CatcherView: NSView {
        var onPan: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
                self.onPan?(e.scrollingDeltaX * k, e.scrollingDeltaY * k)
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
