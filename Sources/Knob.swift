import SwiftUI
import AppKit

/// Una posizione della manopola: il valore, la sigla scritta intorno e la descrizione completa.
struct KnobOption<Value: Hashable>: Identifiable {
    let value: Value
    let short: String
    let label: String
    var id: Value { value }
}

/// Manopola in avorio e ottone, come quelle della radio, con uno scatto per ogni posizione.
/// Si usa trascinando (in cerchio, in su o in giù), con la rotellina, con un clic (posizione successiva)
/// o con le frecce della tastiera. Sotto mostra sempre la scelta corrente.
struct Knob<Value: Hashable>: View {
    let title: String
    let options: [KnobOption<Value>]
    @Binding var selection: Value
    var tint: Color = Theme.accent
    var size: CGFloat = 112

    @FocusState private var focused: Bool
    /// «list» (elenco, predefinito) o «knob» (manopola): si sceglie nelle Opzioni.
    @AppStorage("controlStyle") private var style = "list"
    @State private var dragStart: Int? = nil
    @State private var dragMoved = false

    /// Arco della manopola: da −135° a +135° (0° = in alto), come un selettore d'epoca.
    private let sweep: Double = 270

    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }
    private var labelRadius: CGFloat { size / 2 + 22 }
    private var box: CGFloat { size + 92 }

    private func angle(for i: Int) -> Double {
        guard options.count > 1 else { return 0 }
        return -sweep / 2 + sweep * Double(i) / Double(options.count - 1)
    }

    private func labelPoint(_ i: Int) -> CGPoint {
        let a = CGFloat(angle(for: i) * .pi / 180)
        return CGPoint(x: box / 2 + labelRadius * CGFloat(sin(Double(a))), y: box / 2 - labelRadius * CGFloat(cos(Double(a))))
    }

    var body: some View {
        if style == "knob" { knob } else { list }
    }

    /// Elenco: più rapido per scegliere tra opzioni scritte. Stessi valori della manopola.
    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(options) { o in Text(o.label).tag(o.value) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var knob: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ZStack {
                // Sigle e tacche intorno alla manopola
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    let on = i == index
                    Text(o.short)
                        .font(.system(size: 10, weight: on ? .bold : .medium, design: .rounded))
                        .foregroundStyle(on ? tint : Theme.ink.opacity(0.55))
                        .fixedSize()
                        .position(labelPoint(i))
                        .onTapGesture { set(i) }
                    Capsule()
                        .fill(on ? tint : Theme.ink.opacity(0.28))
                        .frame(width: 2, height: on ? 7 : 5)
                        .offset(y: -(size / 2 + 7))
                        .rotationEffect(.degrees(angle(for: i)))
                        .position(x: box / 2, y: box / 2)
                }

                // Corpo della manopola
                knobBody
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(angle(for: index)))
                    .animation(.spring(response: 0.28, dampingFraction: 0.62), value: index)
                    .position(x: box / 2, y: box / 2)
                    .gesture(drag)
                    .overlay(ScrollCatcher { dy in step(dy > 0 ? 1 : -1) }.frame(width: size, height: size)
                        .position(x: box / 2, y: box / 2))
            }
            .frame(width: box, height: box)
            .coordinateSpace(.named("knob"))

            Text(options.indices.contains(index) ? options[index].label : "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }       // le frecce funzionano subito, senza cliccare prima
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(-1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(options.indices.contains(index) ? options[index].label : "")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var knobBody: some View {
        ZStack {
            // Ombra e anello d'ottone
            Circle()
                .fill(AngularGradient(colors: [Theme.brass, Theme.brass.opacity(0.55), Theme.brass, Theme.brass.opacity(0.55), Theme.brass],
                                      center: .center))
                .shadow(color: Theme.shadow.opacity(0.28), radius: 8, y: 4)
            // Avorio, con la luce dall'alto
            Circle()
                .fill(RadialGradient(colors: [Theme.ivory, Theme.parchment], center: UnitPoint(x: 0.4, y: 0.3),
                                     startRadius: 2, endRadius: size * 0.6))
                .padding(size * 0.06)
            // Zigrinatura del bordo
            ForEach(0..<36, id: \.self) { k in
                Capsule().fill(Theme.ink.opacity(0.10))
                    .frame(width: 1.2, height: size * 0.07)
                    .offset(y: -size * 0.395)
                    .rotationEffect(.degrees(Double(k) * 10))
            }
            // Indice della manopola
            Capsule().fill(tint.gradient)
                .frame(width: size * 0.05, height: size * 0.24)
                .offset(y: -size * 0.24)
            // Tappo centrale
            Circle()
                .fill(RadialGradient(colors: [Theme.ivory, Theme.parchmentDeep], center: UnitPoint(x: 0.4, y: 0.35),
                                     startRadius: 1, endRadius: size * 0.2))
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().strokeBorder(Theme.brass.opacity(focused ? 0.9 : 0.4), lineWidth: focused ? 2 : 1))
        }
        .contentShape(Circle())
    }

    /// Trascinare: conta la direzione del puntatore rispetto al centro (si gira come una manopola vera);
    /// un clic senza trascinare passa alla posizione successiva.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("knob"))
            .onChanged { v in
                focused = true
                if dragStart == nil { dragStart = index; dragMoved = false }
                let d = hypot(v.translation.width, v.translation.height)
                if d > 3 { dragMoved = true }
                guard dragMoved else { return }
                let c = CGPoint(x: box / 2, y: box / 2)
                let dx = v.location.x - c.x, dy = v.location.y - c.y
                if hypot(dx, dy) > size * 0.18 {
                    // Gira intorno al centro
                    var deg = atan2(dx, -dy) * 180 / .pi            // 0 = in alto, senso orario
                    deg = max(-sweep / 2, min(sweep / 2, deg))
                    set(nearest(deg))
                } else if let s = dragStart {
                    // Vicino al centro: su = avanti, giù = indietro
                    set(s + Int((-v.translation.height / 18).rounded()))
                }
            }
            .onEnded { _ in
                if !dragMoved { set((index + 1) % max(options.count, 1)) }
                dragStart = nil
                dragMoved = false
            }
    }

    private func nearest(_ deg: Double) -> Int {
        guard options.count > 1 else { return 0 }
        let t = (deg + sweep / 2) / sweep
        return Int((t * Double(options.count - 1)).rounded())
    }

    private func step(_ d: Int) { set(index + d) }

    private func set(_ i: Int) {
        guard !options.isEmpty else { return }
        let n = max(0, min(options.count - 1, i))
        guard n != index else { return }
        selection = options[n].value
        Sounds.tick()
    }
}

/// Riceve la rotellina del mouse (o due dita sul trackpad) sopra la manopola, senza bloccare i clic.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        // I clic passano alla manopola sotto
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                // Trackpad: somma i piccoli spostamenti, uno scatto ogni 12 punti
                let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
                self.accumulated += dy
                while abs(self.accumulated) >= 12 {
                    self.onScroll?(self.accumulated)
                    self.accumulated -= self.accumulated > 0 ? 12 : -12
                }
                if e.phase == .ended || e.momentumPhase == .ended { self.accumulated = 0 }
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
