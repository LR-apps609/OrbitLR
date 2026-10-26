import SwiftUI
import AppKit

/// Icona nella barra dei menu (punto 38): un piccolo quadrante con il menu a torta.
/// Ferma quando OrbitLR è libera; mentre lavora, lo spicchio gira come la lancetta di una radio che cerca la stazione.
final class MenuBarIcon: ObservableObject, @unchecked Sendable {
    static let shared = MenuBarIcon()

    @Published private(set) var image: NSImage
    private let frames: [NSImage]
    private let idle: NSImage
    private var index = 0
    private var timer: Timer?
    private var interval: TimeInterval = 0

    /// Veloce (11 volte al secondo) solo mentre si lavora; da ferma controlla una volta al secondo,
    /// così OrbitLR non consuma batteria quando non fa niente.
    private static let fast: TimeInterval = 0.09
    private static let slow: TimeInterval = 1.0

    init() {
        frames = (0..<12).map { MenuBarIcon.draw(angle: Double($0) * 30, busy: true) }
        idle = MenuBarIcon.draw(angle: 0, busy: false)
        image = idle
        schedule(Self.slow)
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)      // gira anche mentre un menu è aperto
        timer = t
        interval = seconds
    }

    /// Chiamata quando parte un lavoro: l'animazione comincia subito, senza aspettare il controllo lento.
    func wake() {
        schedule(Self.fast)
        tick()
    }

    private func tick() {
        let busy = QueueStore.shared.isBusy || Updater.shared.busy
        QueueStore.shared.tickEstimates()
        DockProgress.shared.update()
        if busy {
            index = (index + 1) % frames.count
            image = frames[index]
            schedule(Self.fast)
        } else {
            if image !== idle {
                image = idle
                index = 0
            }
            schedule(Self.slow)
        }
    }

    /// Disegna un fotogramma da 18×18 punti, «template»: macOS lo colora da solo per barra chiara o scura.
    private static func draw(angle: Double, busy: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Quadrante
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()

            // Tacche, come i numeri di una radio
            for k in 0..<6 {
                let a = CGFloat((Double(k) * 60 + 30) * .pi / 180)
                let sa: CGFloat = CGFloat(sin(Double(a))), ca: CGFloat = CGFloat(cos(Double(a)))
                let p1 = NSPoint(x: c.x + 5.6 * sa, y: c.y + 5.6 * ca)
                let p2 = NSPoint(x: c.x + 6.6 * sa, y: c.y + 6.6 * ca)
                let mark = NSBezierPath()
                mark.move(to: p1)
                mark.line(to: p2)
                mark.lineWidth = 1
                mark.stroke()
            }

            // Spicchio: fermo in alto quando l'app è libera, gira quando lavora
            let start = 90 - angle - 30, end = 90 - angle + 30
            let wedge = NSBezierPath()
            wedge.appendArc(withCenter: c, radius: 5.4, startAngle: CGFloat(start), endAngle: CGFloat(end))
            wedge.appendArc(withCenter: c, radius: 2.4, startAngle: CGFloat(end), endAngle: CGFloat(start), clockwise: true)
            wedge.close()
            wedge.fill()

            // Perno centrale
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)).fill()
            if !busy {
                // Da ferma, un piccolo punto in basso: il «led» spento
                NSBezierPath(ovalIn: NSRect(x: c.x - 0.8, y: c.y - 5.2, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = busy ? String(localized: "OrbitLR al lavoro") : "OrbitLR"
        return img
    }
}

/// L'icona come vista SwiftUI, per la barra dei menu.
struct MenuBarLabel: View {
    @ObservedObject var icon = MenuBarIcon.shared
    var body: some View {
        Image(nsImage: icon.image)
    }
}
