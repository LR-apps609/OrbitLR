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
    static let size = NSSize(width: 340, height: 96)

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
    let close: () -> Void
    @State private var hover = false
    @State private var hideTask: Task<Void, Never>? = nil

    private var folderName: String {
        guard let f = job.outputs.first?.deletingLastPathComponent() else { return "" }
        if f.path == FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path { return "Download" }
        if f.path == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path { return "Scrivania" }
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
                case .done where !job.outputs.isEmpty:
                    Text(job.outputs.count == 1 ? "Salvato in «\(folderName)»" : "\(job.outputs.count) file in «\(folderName)»")
                        .font(.system(size: 13, weight: .bold))
                    Text([job.outputs.count == 1 ? job.outputs[0].lastPathComponent : nil, sizeText.isEmpty ? nil : sizeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Mostra nella cartella") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs); close() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        if job.outputs.count == 1 {
                            Button("Apri") { NSWorkspace.shared.open(job.outputs[0]); close() }
                        }
                    }
                    .controlSize(.small)
                case .done:
                    Text("Fatto").font(.system(size: 13, weight: .bold))
                    Text(job.notes.first ?? job.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                case .failed:
                    Text("Non riuscito").font(.system(size: 13, weight: .bold))
                    Text(job.failures.first ?? "Apri OrbitLR per i dettagli").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
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
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.ink.opacity(0.08)))
            }
            .buttonStyle(.plain).accessibilityLabel("Chiudi")
        }
        .padding(12)
        .frame(width: ResultBubble.size.width, height: ResultBubble.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
        .onHover { h in hover = h; if h { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: job.state) { _, _ in scheduleHide() }
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

    /// A lavoro finito resta 8 secondi (12 se non è riuscito); mai mentre il puntatore è sopra.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !hover, job.state == .done || job.state == .failed || job.state == .cancelled else { return }
        let secs: UInt64 = job.state == .failed ? 12 : 8
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            if !Task.isCancelled { close() }
        }
    }
}
