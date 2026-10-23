import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.7.3 · Progetti video, come in CapCut: prima di montare si sceglie
//  il progetto (o se ne crea uno nuovo). Ogni progetto è un file JSON
//  nella cartella «Progetti video» di OrbitLR; i video non si toccano mai.
// ════════════════════════════════════════════════════════════════════

/// Una riga della schermata Progetti.
struct VPEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let modified: Date
    let clipCount: Int
    let duration: Double
    let hasMusic: Bool
    /// Fotogramma per la copertina: la prima clip che si trova ancora.
    let coverPath: String?
    let coverTime: Double
}

enum VideoProjectLibrary {
    static var folder: URL { Paths.support.appendingPathComponent("Progetti video", isDirectory: true) }
    static var legacy: URL { Paths.support.appendingPathComponent("Progetto video.json") }
    /// Tutti i salvataggi passano da qui, uno alla volta: un salvataggio vecchio non scavalca mai uno nuovo.
    static let queue = DispatchQueue(label: "orbitlr.progetti-video", qos: .utility)

    static func url(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    static func read(_ url: URL) -> VideoProject? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VideoProject.self, from: d)
    }

    /// Un progetto vuoto non si tiene: non c'è niente da riprendere.
    static func save(_ p: VideoProject, to url: URL) {
        let fm = FileManager.default
        guard !p.clips.isEmpty || p.music != nil else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(VideoProjectStore.withBookmarks(p)) { try? d.write(to: url, options: .atomic) }
    }

    /// I progetti salvati, dal più recente.
    static func list(in folder: URL) -> [VPEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [VPEntry] = []
        for f in files where f.pathExtension == "json" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), let p = read(f) else { continue }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var cover: (String, Double)? = nil
            for c in p.clips {
                if fm.fileExists(atPath: c.path) { cover = (c.path, c.inPoint); break }
                if let moved = VideoProjectStore.resolve(c.bookmark) { cover = (moved, c.inPoint); break }
            }
            out.append(VPEntry(id: id, name: displayName(p), modified: date, clipCount: p.clips.count,
                               duration: p.duration, hasMusic: p.music != nil, coverPath: cover?.0, coverTime: cover?.1 ?? 0))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    static func displayName(_ p: VideoProject) -> String {
        let n = p.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Progetto senza nome" : n
    }

    /// «Progetto 1», «Progetto 2»… il primo numero libero.
    static func uniqueName(existing: [String], base: String = "Progetto") -> String {
        let taken = Set(existing)
        var n = 1
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func rename(_ id: UUID, to name: String, in folder: URL) {
        let u = url(for: id, in: folder)
        guard var p = read(u) else { return }
        p.name = name
        queue.sync { save(p, to: u) }
    }

    /// Copia del progetto con un nome nuovo («… copia»). Restituisce l'id della copia.
    static func duplicate(_ id: UUID, in folder: URL, existing: [String]) -> UUID? {
        guard var p = read(url(for: id, in: folder)) else { return nil }
        let base = displayName(p) + " copia"
        p.name = existing.contains(base) ? uniqueName(existing: existing, base: base) : base
        let new = UUID()
        queue.sync { save(p, to: url(for: new, in: folder)) }
        return new
    }

    /// Nel Cestino, non cancellato: si può sempre recuperare. I video non si toccano.
    static func trash(_ id: UUID, in folder: URL) {
        let u = url(for: id, in: folder)
        queue.sync {
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Fino alla 2.7.2 c'era un solo progetto («Progetto video.json»): diventa il primo dei Progetti.
    @discardableResult
    static func migrateLegacy(from old: URL = legacy, to folder: URL) -> UUID? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return nil }
        defer {
            // Non si cancella: si rinomina, per sicurezza
            let kept = old.deletingLastPathComponent().appendingPathComponent("Progetto video (prima della 2.7.3).json")
            try? fm.removeItem(at: kept)
            try? fm.moveItem(at: old, to: kept)
        }
        guard var p = read(old), !p.clips.isEmpty || p.music != nil else { return nil }
        if p.name == nil { p.name = uniqueName(existing: list(in: folder).map { $0.name }) }
        let id = UUID()
        queue.sync { save(p, to: url(for: id, in: folder)) }
        return id
    }

    static func cover(path: String, at t: Double) async -> NSImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 480, height: 480)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let r = try? await g.image(at: CMTime(seconds: t + 0.1, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
    }
}

// MARK: - La schermata Progetti

/// 3.0 · La scheda Video: il montaggio (progetti) oppure gli strumenti veloci su uno o più video.
struct VideoTabView: View {
    @ObservedObject var s: VideoProjectStore
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if app.videoMode == .tools {
            KindTabView(m: app.videoTools, style: .video)
        } else {
            VideoEditorView(s: s)
        }
    }
}

/// Montaggio · Strumenti veloci, in cima alla scheda Video.
struct VideoModeSwitch: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        Picker("", selection: $app.videoMode) {
            Text("Montaggio").tag(VideoMode.montage)
            Text("Strumenti veloci").tag(VideoMode.tools)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Montaggio: più video, testi e musica in un progetto. Strumenti veloci: comprimi, taglia, GIF e altro, su uno o tanti video")
    }
}

struct VideoProjectsView: View {
    @ObservedObject var s: VideoProjectStore
    @Environment(\.undoManager) private var undo
    @State private var targeted = false

    private let tint = Theme.color(.video)
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(s.library.isEmpty ? "Trascina qui dei video per iniziare un montaggio."
                                           : "Clicca un progetto per riprenderlo da dove eri rimasto.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                VideoModeSwitch().padding(.leading, 8)
                Spacer()
                Button { s.newProject(undo) } label: { Label("Nuovo progetto", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Inizia un nuovo montaggio (⇧⌘N)")
            }
            if let n = s.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if s.library.isEmpty {
                MediaDropZone(kind: .video, title: "Trascina qui i video",
                              subtitle: "si apre un progetto nuovo · MP4, MOV, M4V · più video vanno in fila",
                              targeted: targeted) { s.newProject(undo) }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        NewProjectCard(tint: tint, targeted: targeted) { s.newProject(undo) }
                        ForEach(s.library) { e in
                            ProjectCard(entry: e, cover: s.covers[e.id], tint: tint,
                                        open: { s.openProject(e.id, undo: undo) },
                                        rename: { rename(e) },
                                        duplicate: { s.duplicateProject(e.id) },
                                        delete: { delete(e) })
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                s.newProject(undo)
                s.add(urls, undo: undo)
            }
            return true
        }
        .onAppear { s.refreshLibrary() }
        .navigationTitle("Video")
    }

    private func rename(_ e: VPEntry) {
        let a = NSAlert()
        a.messageText = "Rinomina il progetto"
        let field = NSTextField(string: e.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rinomina")
        a.addButton(withTitle: "Annulla")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn { s.renameProject(e.id, to: field.stringValue) }
    }

    private func delete(_ e: VPEntry) {
        let a = NSAlert()
        a.messageText = "Eliminare «\(e.name)»?"
        a.informativeText = "Il progetto va nel Cestino, da dove puoi ancora recuperarlo. I tuoi video non vengono toccati."
        a.addButton(withTitle: "Elimina")
        a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn { withAnimation(Motion.quick) { s.deleteProject(e.id, undo: undo) } }
    }
}

private struct NewProjectCard: View {
    let tint: Color
    let targeted: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 54, height: 54)
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(tint)
                }
                Text("Nuovo progetto").font(.system(size: 13, weight: .semibold))
                Text("o trascina qui dei video").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 178)
            .background(RoundedRectangle(cornerRadius: 14).fill(hover || targeted ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(hover || targeted ? 0.7 : 0.35),
                                                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ProjectCard: View {
    let entry: VPEntry
    let cover: NSImage?
    let tint: Color
    let open: () -> Void
    let rename: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(tint.opacity(0.18))
                if let cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: entry.coverPath == nil ? "film.stack" : "film").font(.system(size: 28)).foregroundStyle(tint)
                }
                if hover {
                    Color.black.opacity(0.22)
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white)
                }
            }
            .frame(height: 112).frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Text(formatShort(entry.duration))
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55))).foregroundStyle(.white)
                    .padding(6)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Menu {
                    Button("Apri") { open() }
                    Button("Rinomina…") { rename() }
                    Button("Duplica") { duplicate() }
                    Divider()
                    Button("Elimina…", role: .destructive) { delete() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Rinomina, duplica o elimina")
            }
            .padding(10)
        }
        .frame(height: 178)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Theme.cardHover : Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? tint.opacity(0.6) : Theme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Apri") { open() }
            Button("Rinomina…") { rename() }
            Button("Duplica") { duplicate() }
            Divider()
            Button("Elimina…", role: .destructive) { delete() }
        }
        .help("Clicca per riprendere il progetto")
    }

    private var detail: String {
        let when = entry.modified.formatted(.relative(presentation: .named))
        return "\(entry.clipCount) clip" + (entry.hasMusic ? " · musica" : "") + " · " + when
    }
}
