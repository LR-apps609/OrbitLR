import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  3.9.2 · Dopo la torta: una nuvoletta dove c'era la torta dice come va il lavoro e, alla fine,
//  DOVE è stato salvato il file, con «Mostra nella cartella» e «Apri».
//  Resta qualche secondo (ferma finché ci sei sopra col puntatore), poi sparisce da sola.
// ════════════════════════════════════════════════════════════════════

@MainActor
final class ResultBubble {
    static let shared = ResultBubble()

    private var panels: [UUID: NSPanel] = [:]
    private var order: [UUID] = []
    /// Lo spazio della finestra (trasparente): la nuvoletta occupa solo l'altezza che le serve.
    static let size = NSSize(width: 340, height: 132)

    /// Segue un lavoro partito dalla torta, vicino al punto dove era la torta.
    func track(_ job: Job, near point: NSPoint?) {
        job.quietNotify = true                       // niente notifica doppia di macOS
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let id = job.id
        p.contentView = NSHostingView(rootView: ResultBubbleView(job: job) { [weak self] in self?.close(id) })
        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        // Le nuvolette di più lavori una sotto l'altra
        let stack = CGFloat(order.count)
        p.setFrameOrigin(Self.origin(near: anchor, in: vis, stack: stack))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = 1
        }
        panels[id] = p
        order.append(id)
        if order.count > 3, let old = order.first { close(old) }
    }

    /// Sotto il punto della torta, sempre dentro lo schermo.
    static func origin(near anchor: NSPoint, in vis: NSRect, stack: CGFloat) -> NSPoint {
        let w = size.width, h = size.height
        var x = anchor.x - w / 2
        var y = anchor.y - 150 - h - stack * (h + 8)
        x = min(max(vis.minX + 8, x), vis.maxX - w - 8)
        if y < vis.minY + 8 { y = min(vis.maxY - h - 8, anchor.y + 150 + stack * (h + 8)) }
        y = min(max(vis.minY + 8, y), vis.maxY - h - 8)
        return NSPoint(x: x, y: y)
    }

    func close(_ id: UUID) {
        guard let p = panels[id] else { return }
        panels[id] = nil
        order.removeAll { $0 == id }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

struct ResultBubbleView: View {
    @ObservedObject var job: Job
    /// La cronologia arriva un attimo dopo la fine del lavoro: la nuvoletta si aggiorna quando c'è
    @ObservedObject private var store = QueueStore.shared
    let close: () -> Void
    @State private var hover = false
    @State private var hideTask: Task<Void, Never>? = nil
    /// 4.0 · «Annulla»: il file creato è andato nel Cestino
    @State private var undone = false
    /// 4.0 · La domanda «Ti piace OrbitLR?», una volta sola dopo qualche lavoro riuscito
    @State private var ask = false

    /// La voce della cronologia di questo lavoro (per annullare e per il peso risparmiato).
    private var entry: HistoryEntry? {
        let paths = job.outputs.map(\.path)
        guard !paths.isEmpty else { return nil }
        return QueueStore.shared.history.first { $0.outputs == paths }
    }

    /// Si può annullare solo se l'originale c'è ancora (se è andato nel Cestino, meglio non toccare niente).
    private var canUndo: Bool {
        !job.outputs.isEmpty && job.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            && job.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var gainText: String? {
        guard let e = entry, let b = e.before, let a = e.after, b > 0, a < b else { return nil }
        let pct = Int((Double(b - a) / Double(b) * 100).rounded())
        guard pct >= 1 else { return nil }
        let saved = Fmt.bytes(b - a)
        return String(localized: "−\(pct)% · risparmiati \(saved)")
    }

    private var folderName: String {
        guard let f = job.outputs.first?.deletingLastPathComponent() else { return "" }
        if f.path == FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path { return String(localized: "Download") }
        if f.path == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path { return String(localized: "Scrivania") }
        return f.lastPathComponent
    }

    private var sizeText: String {
        let total = job.outputs.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
        return total > 0 ? Fmt.bytes(total) : ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                switch job.state {
                case .done where undone:
                    Text("Annullato").font(.system(size: 13, weight: .bold))
                    Text("Il file creato è nel Cestino; l’originale è dov’era.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                case .done where !job.outputs.isEmpty:
                    Text(job.outputs.count == 1 ? String(localized: "Salvato in «\(folderName)»") : String(localized: "\(job.outputs.count) file in «\(folderName)»"))
                        .font(.system(size: 13, weight: .bold))
                    Text([job.outputs.count == 1 ? job.outputs[0].lastPathComponent : nil, sizeText.isEmpty ? nil : sizeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let g = gainText {
                        Text(g).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.green)
                    }
                    HStack(spacing: 8) {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs); close() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        if job.outputs.count == 1 {
                            Button("Apri") { NSWorkspace.shared.open(job.outputs[0]); close() }
                        }
                        if canUndo {
                            Button(String(localized: "Elimina il risultato")) { undo() }
                                .help("Manda nel Cestino il file appena creato")
                        }
                    }
                    .controlSize(.small)
                    if ask {
                        HStack(spacing: 6) {
                            Text("Ti piace OrbitLR?").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            ForEach(Feedback.faces, id: \.id) { f in
                                Button(f.emoji) { Feedback.show(face: f.id); close() }
                                    .buttonStyle(.plain).font(.system(size: 16)).help(String(localized: String.LocalizationValue(f.name)))
                            }
                            Button("No grazie") { Feedback.markAsked(); ask = false }
                                .buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                case .done:
                    Text("Fatto").font(.system(size: 13, weight: .bold))
                    Text(job.notes.first ?? job.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                case .failed:
                    Text("Non riuscito").font(.system(size: 13, weight: .bold))
                    Text(job.failures.first ?? String(localized: "Apri OrbitLR per i dettagli")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    // 5.1 · Il pulsante che risolve, oppure Riprova: mai solo il titolo e la ✕
                    HStack(spacing: 6) {
                        if let fix = Fix.best(for: job) {
                            Button { QueueStore.shared.apply(fix, to: job); close() } label: { Label(fix.label, systemImage: fix.symbol) }
                                .buttonStyle(.borderedProminent).tint(Theme.brass)
                        } else {
                            Button("Riprova") { QueueStore.shared.retry(job); close() }
                        }
                    }
                    .controlSize(.small)
                case .cancelled:
                    Text("Interrotto").font(.system(size: 13, weight: .bold))
                default:
                    Text(job.title).font(.system(size: 13, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    ProgressBar(value: job.shownProgress, tint: Theme.color(job.kind))
                    Text(job.status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.ink.opacity(0.08)))
            }
            .buttonStyle(.plain).help("Chiudi").accessibilityLabel("Chiudi")
        }
        .padding(12)
        .frame(width: ResultBubble.size.width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { h in hover = h; if h { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: job.state) { _, st in
            if st == .done, !job.outputs.isEmpty, Feedback.shouldAskNow { ask = true; Feedback.markAsked() }
            scheduleHide()
        }
        .onAppear { scheduleHide() }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .done where !job.outputs.isEmpty:
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.outputs[0].path)).resizable()
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").font(.system(size: 22)).foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }

    private func undo() {
        if let e = entry { QueueStore.shared.undo(e) } else {
            for u in job.outputs { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        }
        undone = true
        scheduleHide()
    }

    /// A lavoro finito resta 8 secondi (12 se non è riuscito); mai mentre il puntatore è sopra.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !hover, job.state == .done || job.state == .failed || job.state == .cancelled else { return }
        let secs: UInt64 = undone ? 3 : (ask ? 15 : (job.state == .failed ? 12 : 8))
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            if !Task.isCancelled { close() }
        }
    }
}
