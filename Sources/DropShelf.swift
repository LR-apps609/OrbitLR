import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  3.9.1 · Il ripiano di OrbitLR: quando trascini dei file da qualsiasi parte (Finder, Scrivania, Mail…)
//  al bordo destro dello schermo compare un bersaglio con la torta. Rilasci lì → si apre la torta.
//  Non serve andare nella barra dei menu (dove macOS può mostrare la Scrivania e il menu si chiude).
//
//  Come lo sa: al clic del mouse in un'altra app si ricorda il contatore degli appunti del trascinamento;
//  finché il tasto resta premuto controlla 10 volte al secondo se è partito un trascinamento con dei file.
//  Nessun permesso speciale: solo clic del mouse, mai tasti né contenuti.
// ════════════════════════════════════════════════════════════════════

@MainActor
final class DropShelf: NSObject {
    static let shared = DropShelf()
    static let key = "dropShelf"

    /// Attivo di base; si spegne in Opzioni.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private var monitor: Any?
    private var poll: Timer?
    private var startCount = 0
    private var panel: NSPanel?
    private var shownForCount = -1
    private var hideWork: DispatchWorkItem?
    let model = ShelfModel()

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        poll?.invalidate()
        poll = nil
        hide(animated: false)
    }

    private func mouseDown() {
        guard Self.enabled else { return }
        startCount = NSPasteboard(name: .drag).changeCount
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let pb = NSPasteboard(name: .drag)
        if down {
            // Un trascinamento nuovo, con dei file dentro: compare il ripiano (una volta per trascinamento)
            if pb.changeCount != startCount, pb.changeCount != shownForCount, Self.hasFiles(pb) {
                shownForCount = pb.changeCount
                show()
            }
            return
        }
        // Tasto lasciato: niente più da controllare. Il ripiano sparisce poco dopo (se il file è caduto
        // sul ripiano, la torta si è già aperta).
        poll?.invalidate()
        poll = nil
        if panel?.isVisible == true { scheduleHide(after: 0.35) }
    }

    /// Ci sono file (non testo o immagini incollate) negli appunti del trascinamento?
    static func hasFiles(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        return types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }

    /// Dove sta il ripiano: bordo destro dello schermo col puntatore, a metà altezza.
    static func frame(for screen: NSRect, size: NSSize) -> NSRect {
        NSRect(x: screen.maxX - size.width - 18, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func show() {
        hideWork?.cancel()
        let size = NSSize(width: 150, height: 172)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        let target = Self.frame(for: vis, size: size)
        let p = panel ?? makePanel(size: size)
        panel = p
        model.targeted = false
        p.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
    }

    private func scheduleHide(after s: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    func hide(animated: Bool) {
        guard let p = panel, p.isVisible else { return }
        if !animated { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    /// File rilasciati sul ripiano: la torta accanto al ripiano.
    func dropped(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        Sounds.drop()
        let at = panel.map { NSPoint(x: $0.frame.minX - 40, y: $0.frame.midY) }
        hide(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { PieController.shared.present(files: files, at: at) }
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu                       // sopra le finestre dell'app da cui trascini
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ShelfView(model: model) { [weak self] urls in self?.dropped(urls) })
        return p
    }
}

final class ShelfModel: ObservableObject {
    @Published var targeted = false
}

/// Il bersaglio: la torta di Orbit in un cerchio, che si allarga quando ci passi sopra con il file.
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let onDrop: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(Theme.accent.opacity(model.targeted ? 0.95 : 0.45),
                                      style: StrokeStyle(lineWidth: 2, dash: model.targeted ? [] : [6, 4]))
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 62, height: 62)
                    .scaleEffect(model.targeted ? 1.12 : 1)
            }
            .frame(width: 118, height: 118)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
            Text(model.targeted ? "Rilascia qui" : "OrbitLR")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.regularMaterial))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { model.targeted = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.targeted)
        .accessibilityLabel("Ripiano di OrbitLR: rilascia qui i file per aprire la torta")
    }
}
