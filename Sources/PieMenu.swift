import AppKit
import SwiftUI

// MARK: - Modello

final class PieModel: ObservableObject, @unchecked Sendable {
    @Published var items: [Action] = []
    @Published var hover: Int? = nil
    @Published var inMore = false
    @Published var fileName = ""
    @Published var subtitle = ""
    @Published var icon: NSImage = NSImage()
    @Published var tint: Color = Theme.accent
    @Published var lastId: String? = nil
    @Published var suggestedId: String? = nil
    /// Menu aperto (true) o in chiusura (false): guida l'animazione della manopola.
    @Published var shown = false
    /// Aumenta a ogni cambio d'anello («Altro» o ritorno): fa ripartire l'animazione.
    @Published var spin = 0
    var all: [Action] = []
    var pages: [[Action]] = []      // anello principale + anelli «Altro», 8 spicchi al massimo ciascuno
    var page = 0
    var onPick: (Action) -> Void = { _ in }
    var onClose: () -> Void = {}

    func setup(actions: [Action]) {
        all = actions
        pages = []
        var rest = actions
        while !rest.isEmpty {
            if rest.count <= 8 { pages.append(rest); rest = [] }
            else { pages.append(Array(rest.prefix(7)) + [Action.more]); rest = Array(rest.dropFirst(7)) }
        }
        page = 0
        items = pages.first ?? []
        inMore = false
        hover = nil
    }

    func pick(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let a = items[i]
        Sounds.select()
        if a.id == Action.more.id, page + 1 < pages.count {
            page += 1
            items = pages[page]
            inMore = true
            hover = nil
            spin += 1
            return
        }
        onPick(a)
    }

    func back() {
        if page > 0 { page -= 1 }
        items = pages.indices.contains(page) ? pages[page] : []
        inMore = page > 0
        hover = nil
        spin += 1
    }

    /// Spicchio sotto il puntatore: conta la direzione, non serve centrare il pulsante.
    func index(at p: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > inner * 0.92, d < outer + 26, !items.isEmpty else { return nil }
        var deg = Double(atan2(dy, dx)) * 180 / .pi + 90          // 0 = in alto, senso orario
        if deg < 0 { deg += 360 }
        let step = 360 / Double(items.count)
        return Int((deg + step / 2).truncatingRemainder(dividingBy: 360) / step) % items.count
    }

    var lastAction: Action? { all.first { $0.id == lastId } }
    var suggestedAction: Action? { all.first { $0.id == suggestedId } }
}

// MARK: - Forme

/// Trama della griglia dell'altoparlante (punto 32): forellini sfalsati, come la tela delle radio d'epoca.
/// Un solo disegno per tutto l'anello, così resta leggera anche durante le animazioni.
struct GrilleTexture: View {
    var spacing: CGFloat = 7

    var body: some View {
        Canvas { ctx, size in
            var holes = Path()
            var light = Path()
            let r = spacing * 0.2
            var row = 0
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? spacing / 2 : spacing
                while x < size.width {
                    holes.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    light.addEllipse(in: CGRect(x: x - r, y: y - r + r * 0.9, width: r * 2, height: r * 1.2))
                    x += spacing
                }
                y += spacing * 0.87
                row += 1
            }
            ctx.fill(light, with: .color(Theme.ivory.opacity(0.35)))   // bordo illuminato sotto il foro
            ctx.fill(holes, with: .color(Theme.ink.opacity(0.13)))
        }
        .drawingGroup()
    }
}

struct RingShape: Shape {
    let innerRatio: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: r)
        let k = r.width / 2 * (1 - innerRatio)
        p.addEllipse(in: r.insetBy(dx: k, dy: k))
        return p
    }
}

struct WedgeShape: Shape {
    let index: Int, count: Int, innerRatio: CGFloat
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), outer = r.width / 2, inner = outer * innerRatio
        let step = 360.0 / Double(max(count, 1))
        let a0 = -90 + Double(index) * step - step / 2, a1 = a0 + step
        var p = Path()
        for k in 0...24 {
            let a = (a0 + (a1 - a0) * Double(k) / 24) * .pi / 180
            let pt = CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        for k in 0...24 {
            let a = (a1 - (a1 - a0) * Double(k) / 24) * .pi / 180
            p.addLine(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Vista (usata sia nella finestra sia vicino al puntatore)

struct PieView: View {
    @ObservedObject var model: PieModel
    var side: CGFloat = 520
    var removeHelp: String = ""
    var onRemove: (() -> Void)? = nil
    /// Ritardo dell'animazione d'apertura (le mini-torte si aprono una dopo l'altra).
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = chiuso al centro, 1 = aperto. Animato all'apertura, alla chiusura e a ogni cambio d'anello.
    @State private var bloom: CGFloat = 0

    private var outer: CGFloat { side * 0.442 }
    private var inner: CGFloat { side * 0.185 }
    private var petal: CGFloat { side * 0.148 }
    private var centerSize: CGFloat { side * 0.35 }
    private var mid: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        ZStack {
            // Anello
            // Anello color crema, come la griglia della radio, con bordo salvia e ottone
            RingShape(innerRatio: inner / outer)
                .fill(LinearGradient(colors: [Theme.parchment, Theme.parchmentDeep], startPoint: .top, endPoint: .bottom),
                      style: FillStyle(eoFill: true))
                .frame(width: outer * 2, height: outer * 2)
                // Griglia dell'altoparlante: una trama leggera di forellini, solo sull'anello
                .overlay(
                    GrilleTexture(spacing: max(4.5, side * 0.0145))
                        .frame(width: outer * 2, height: outer * 2)
                        .mask(RingShape(innerRatio: inner / outer).fill(style: FillStyle(eoFill: true)))
                        .allowsHitTesting(false)
                )
                .overlay(
                    Circle().strokeBorder(
                        AngularGradient(colors: [Theme.sageDeep.opacity(0.7), Theme.brass.opacity(0.6), Theme.sageDeep.opacity(0.7),
                                                 Theme.brass.opacity(0.6), Theme.sageDeep.opacity(0.7)], center: .center), lineWidth: 3)
                        .frame(width: outer * 2, height: outer * 2)
                )
                .shadow(color: Theme.shadow.opacity(0.25), radius: 24, y: 12)
                .scaleEffect(0.55 + 0.45 * bloom)
                .opacity(Double(min(1, bloom * 1.6)))

            // Spicchio evidenziato
            if let h = model.hover {
                WedgeShape(index: h, count: model.items.count, innerRatio: inner / outer)
                    .fill(RadialGradient(colors: [model.tint.opacity(0.12), model.tint.opacity(0.45)],
                                         center: .center, startRadius: inner, endRadius: outer))
                    .frame(width: outer * 2, height: outer * 2)
                    .animation(.easeOut(duration: 0.12), value: model.hover)
            }

            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, a in
                petalView(a, index: i)
                    .modifier(PetalPlacement(bloom: bloom, index: i, count: model.items.count, mid: mid,
                                             inner: inner, outer: outer))
            }

            centerView
                .frame(width: centerSize, height: centerSize)
                .background(Circle().fill(Theme.ivory))
                .overlay(Circle().strokeBorder(Theme.brass.opacity(0.7), lineWidth: 2))
                .shadow(color: Theme.shadow.opacity(0.18), radius: 12, y: 4)
                .scaleEffect(0.82 + 0.18 * bloom)
                .opacity(Double(min(1, 0.2 + bloom)))
                .position(mid)

            if let remove = onRemove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: max(9, side * 0.022), weight: .bold))
                        .foregroundStyle(Theme.ivory)
                        .frame(width: max(20, side * 0.05), height: max(20, side * 0.05))
                        .background(Circle().fill(Theme.ink.opacity(0.75)))
                }
                .buttonStyle(.plain)
                .help(removeHelp)
                .position(x: mid.x + centerSize * 0.36, y: mid.y - centerSize * 0.36)
                .opacity(Double(bloom))
            }
        }
        .frame(width: side, height: side)
        .onAppear { model.shown = true; animateOpen(from: 0) }
        .onChange(of: model.shown) { _, now in if !now { animateClose() } }
        .onChange(of: model.spin) { _, _ in animateOpen(from: 0.35) }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let i = model.index(at: p, center: mid, inner: inner, outer: outer)
                if i != model.hover {
                    if i != nil { Sounds.tick() }
                    model.hover = i
                }
            case .ended:
                model.hover = nil
            }
        }
        .onTapGesture {
            if let h = model.hover { model.pick(h) }
            else if model.inMore { model.back() }
            else { model.onClose() }
        }
    }


    private func animateOpen(from start: CGFloat) {
        if reduceMotion { bloom = 1; return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { bloom = start }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.74).delay(delay)) { bloom = 1 }
    }

    private func animateClose() {
        if reduceMotion { bloom = 0; return }
        withAnimation(.easeIn(duration: 0.14)) { bloom = 0 }
    }

    private func petalView(_ a: Action, index i: Int) -> some View {
        let on = model.hover == i
        let suggested = a.id == model.suggestedId
        return VStack(spacing: 4) {
            Image(systemName: a.symbol).font(.system(size: petal * 0.27, weight: .semibold))
            Text(a.short).font(.system(size: max(10, petal * 0.145), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(on ? Color.white : Theme.ink)
        .frame(width: petal, height: petal)
        .background(
            Circle().fill(on ? AnyShapeStyle(model.tint.gradient) : AnyShapeStyle(Theme.ivory))
                .shadow(color: Theme.shadow.opacity(on ? 0 : 0.12), radius: 3, y: 2)
        )
        .overlay(Circle().strokeBorder(suggested ? model.tint : Theme.ink.opacity(0.14), lineWidth: suggested ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if suggested && !on {
                Image(systemName: "star.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ivory)
                    .padding(4).background(Circle().fill(Theme.brass)).offset(x: -4, y: 2)
            } else if a.id == model.lastId && !on {
                Circle().fill(Theme.brass).frame(width: 9, height: 9).offset(x: -10, y: 8)
            }
        }
        .scaleEffect(on ? 1.15 : 1)
        .shadow(color: on ? model.tint.opacity(0.6) : .clear, radius: 16, y: 6)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a.title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var centerView: some View {
        if let h = model.hover, model.items.indices.contains(h) {
            let a = model.items[h]
            VStack(spacing: 6) {
                Image(systemName: a.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(model.tint)
                Text(a.title).font(.system(size: 14, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                Text(a.hint).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                Text("Tasto \(h + 1)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(16)
        } else if model.inMore {
            VStack(spacing: 6) {
                Image(systemName: "chevron.backward.circle.fill").font(.system(size: 26)).foregroundStyle(model.tint)
                Text("Altre azioni").font(.system(size: 14, weight: .semibold))
                Text("Clic qui per tornare").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Image(nsImage: model.icon).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: centerSize * 0.40, height: centerSize * 0.40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(model.fileName).font(.system(size: 12, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(model.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(14)
        }
    }
}

/// Apertura «a manopola»: ogni spicchio parte vicino al centro, ruotato indietro di 70°,
/// e girando in senso orario arriva al suo posto, poco dopo il precedente.
/// È «Animatable»: SwiftUI ricalcola la posizione a ogni fotogramma, così il percorso è un arco e non una linea retta.
struct PetalPlacement: ViewModifier, Animatable {
    var bloom: CGFloat
    let index: Int, count: Int
    let mid: CGPoint
    let inner: CGFloat, outer: CGFloat

    var animatableData: CGFloat {
        get { bloom }
        set { bloom = newValue }
    }

    func body(content: Content) -> some View {
        let n = CGFloat(max(count, 1))
        let lag = 0.35 * CGFloat(index) / n               // l'ultimo parte quando il primo è a un terzo
        let o = max(0, min(1.12, (bloom - lag) / (1 - lag)))   // sopra 1: il piccolo rimbalzo della molla
        let step = 360.0 / Double(n)
        let a = CGFloat((-90 + Double(index) * step - 70 * Double(1 - min(o, 1))) * .pi / 180)
        let r0: CGFloat = inner * 0.55, r1: CGFloat = (inner + outer) / 2
        let r: CGFloat = r0 + (r1 - r0) * o
        let p = CGPoint(x: mid.x + r * cos(a), y: mid.y + r * sin(a))
        return content
            .scaleEffect(0.3 + 0.7 * o)
            .opacity(Double(min(1, o * 1.4)))
            .position(p)
    }
}

// MARK: - Menu vicino al puntatore (Finder, scorciatoia, Dock)

final class PiePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PieController: @unchecked Sendable {
    static let shared = PieController()
    private var panel: PiePanel?
    private var model: PieModel?
    private var monitors: [Any] = []
    private var pending: [(Kind, [URL])] = []
    private var subs: [URL] = []
    private var mergeDone = false

    func present(files: [URL], at point: NSPoint? = nil) {
        close()
        var groups: [Kind: [URL]] = [:]
        var order: [Kind] = []
        subs = []
        for f in PieController.expand(files) {
            guard let k = Catalog.kind(of: f) else { continue }
            if k == .sub { subs.append(f); continue }
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(f)
        }
        pending = order.map { ($0, groups[$0] ?? []) }
        mergeDone = false
        if pending.isEmpty {
            let a = NSAlert()
            a.messageText = subs.isEmpty ? "Nessun file supportato" : "Seleziona il video insieme al file .srt"
            a.runModal()
            return
        }
        showNext(at: point ?? NSEvent.mouseLocation)
    }

    /// Le cartelle diventano l'elenco dei file che contengono (i pacchetti Pages/Numbers/Keynote restano interi).
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        let packages: Set<String> = ["pages", "numbers", "key", "rtfd"]
        for u in urls {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue && !packages.contains(u.pathExtension.lowercased()) {
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in en {
                        if f.path.contains("/Convertiti/") { continue }
                        if packages.contains(f.pathExtension.lowercased()) { out.append(f); en.skipDescendants(); continue }
                        if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(f) }
                    }
                }
            } else {
                out.append(u)
            }
        }
        return out
    }

    private func showNext(at point: NSPoint) {
        guard !pending.isEmpty else { return }
        let (kind, files) = pending.removeFirst()
        if mergeDone && (kind == .pdf || kind == .img) { showNext(at: point); return }

        let mergeable = (files + pending.filter { $0.0 == .pdf || $0.0 == .img }.flatMap { $0.1 })
            .filter { let k = Catalog.kind(of: $0); return k == .pdf || k == .img }.count
        let exts = Set(files.map { Catalog.norm($0.pathExtension) })
        let model = PieModel()
        model.setup(actions: PresetStore.shared.merged(Catalog.actions(for: kind, exts: exts, mergeable: mergeable), kind: kind))
        model.tint = Theme.color(kind)
        model.suggestedId = Catalog.suggested(for: kind, exts: exts)
        model.fileName = files.count == 1 ? files[0].lastPathComponent : "\(files.count) \(kind.name)"
        model.icon = NSWorkspace.shared.icon(forFile: files[0].path)
        model.lastId = UserDefaults.standard.string(forKey: "last_" + kind.rawValue)
        if let a = model.lastAction { model.subtitle = "Invio: " + a.short }
        else if let s = model.suggestedAction { model.subtitle = "Consigliato: " + s.short }
        else { model.subtitle = "Scegli un’azione" }
        model.onClose = { [weak self] in self?.close(); self?.pending = [] }
        model.onPick = { [weak self] chosen in
            guard let self else { return }
            UserDefaults.standard.set(chosen.id, forKey: "last_" + kind.rawValue)
            var action = chosen
            var presetParam: String? = nil
            if let r = PresetStore.shared.resolve(chosen) { action = r.0; presetParam = r.1 }
            self.close()
            if Interactive.handles(action.id) {
                Interactive.open(action, files: files)
                self.pending = []
                return
            }
            var targets = files + self.subs
            if action.id == "merge" {
                self.mergeDone = true
                targets = files + self.pending.filter { $0.0 == .pdf || $0.0 == .img }.flatMap { $0.1 }
            }
            let go: (String) -> Void = { param in
                QueueStore.shared.enqueue(files: targets, action: action, param: param)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showNext(at: point) }
            }
            if let p = presetParam {
                go(p)
            } else if let pk = action.param {
                ParamController.shared.ask(pk, action: action, files: files, at: point) { value in
                    if let value { go(value) } else { self.pending = [] }
                }
            } else {
                go("")
            }
        }
        open(model, at: point)
    }

    private func open(_ model: PieModel, at point: NSPoint) {
        let side: CGFloat = 520
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - side)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - side)
        }
        let p = PiePanel(contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PieView(model: model, side: side))
        panel = p
        self.model = model
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.panel != nil else { return e }
            return PieKeys.handle(e, model: model, close: { self.close(); self.pending = [] }) ? nil : e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close(); self?.pending = []
        }) { monitors.append(m) }
    }

    /// Chiude il menu: gli spicchi rientrano al centro (0,14 s), poi la finestrella sparisce.
    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard let p = panel else { return }
        panel = nil
        model?.shown = false
        model = nil
        p.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { p.orderOut(nil) }
    }
}

/// Tastiera del menu: 1–8 sceglie, Invio = ultima scelta (o consigliata), Esc chiude o torna indietro.
enum PieKeys {
    static func handle(_ e: NSEvent, model: PieModel, close: () -> Void) -> Bool {
        if e.keyCode == 53 {
            if model.inMore { model.back() } else { close() }
            return true
        }
        if e.keyCode == 36 || e.keyCode == 76 {
            let target = model.lastId ?? model.suggestedId
            if let t = target, let i = model.items.firstIndex(where: { $0.id == t }) { model.pick(i); return true }
            return false
        }
        if let ch = e.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= model.items.count {
            model.pick(n - 1)
            return true
        }
        return false
    }
}
