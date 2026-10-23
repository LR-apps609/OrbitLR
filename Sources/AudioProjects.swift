import SwiftUI
import AppKit
import Combine

// ════════════════════════════════════════════════════════════════════
//  2.8.5 · Progetti audio: ogni file aperto nella scheda Audio diventa un
//  progetto che si salva da solo (file, strumento, selezione, file da
//  unire) e si riprende con un clic, come i Progetti del Video.
// ════════════════════════════════════════════════════════════════════

struct AudioProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var paths: [String]
    /// Segnalibri di macOS: ritrovano i file anche se li sposti o li rinomini.
    var bookmarks: [Data?] = []
    var tool: String
    var start: Double
    var end: Double
    var modified = Date()

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var length: Double { max(0, end - start) }
}

enum AudioProjectLibrary {
    static var folder: URL { Paths.support.appendingPathComponent("Progetti audio", isDirectory: true) }
    static let queue = DispatchQueue(label: "orbitlr.progetti-audio", qos: .utility)
    static let maxKept = 40

    static func url(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    static func save(_ p: AudioProject, in folder: URL) {
        var p = p
        p.bookmarks = p.urls.map { try? $0.bookmarkData() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(p) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? d.write(to: url(for: p.id, in: folder), options: .atomic)
    }

    static func read(_ u: URL) -> AudioProject? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AudioProject.self, from: d)
    }

    /// Dal più recente; i più vecchi oltre `maxKept` vanno nel Cestino da soli.
    static func list(in folder: URL) -> [AudioProject] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let all = files.filter { $0.pathExtension == "json" }.compactMap(read).sorted { $0.modified > $1.modified }
        for old in all.dropFirst(maxKept) { trash(old.id, in: folder) }
        return Array(all.prefix(maxKept))
    }

    static func trash(_ id: UUID, in folder: URL) {
        let u = url(for: id, in: folder)
        if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: u) }
    }

    static func rename(_ id: UUID, to name: String, in folder: URL) {
        guard var p = read(url(for: id, in: folder)) else { return }
        p.name = name
        save(p, in: folder)
    }

    static func duplicate(_ id: UUID, in folder: URL) -> UUID? {
        guard var p = read(url(for: id, in: folder)) else { return nil }
        p.id = UUID()
        p.name += " copia"
        p.modified = Date()
        save(p, in: folder)
        return p.id
    }

    /// Ritrova i file spostati; restituisce false se il primo file non c'è più.
    static func relink(_ p: inout AudioProject) -> Bool {
        let fm = FileManager.default
        var paths: [String] = []
        for (i, path) in p.paths.enumerated() {
            if fm.fileExists(atPath: path) { paths.append(path); continue }
            let bm = i < p.bookmarks.count ? p.bookmarks[i] : nil
            if let found = VideoProjectStore.resolve(bm) { paths.append(found) }
        }
        let firstOK = p.paths.first.map { fm.fileExists(atPath: $0) } == true
            || (p.bookmarks.first.flatMap { VideoProjectStore.resolve($0) } != nil)
        p.paths = paths
        return firstOK && !paths.isEmpty
    }

    static func displayName(for url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - Il modello della scheda: progetti

extension MediaTabModel {
    func refreshProjects() {
        guard !videoTab else { return }
        audioProjects = AudioProjectLibrary.list(in: projectsFolder)
    }

    /// Un file aperto da zero diventa un progetto nuovo.
    func startProject(for url: URL) {
        guard !videoTab, !restoringProject else { return }
        let p = AudioProject(name: AudioProjectLibrary.displayName(for: url), paths: [url.path],
                             tool: currentTool, start: 0, end: 0)
        currentProject = p.id
        AudioProjectLibrary.save(p, in: projectsFolder)
        refreshProjects()
    }

    /// Salva lo stato attuale nel progetto aperto (dopo una breve pausa, per non scrivere a ogni movimento).
    func scheduleProjectSave() {
        guard !videoTab, let id = currentProject, let f = file else { return }
        projectSave?.cancel()
        let folder = projectsFolder
        let snapshot = AudioProject(id: id, name: audioProjects.first { $0.id == id }?.name ?? AudioProjectLibrary.displayName(for: f),
                                    paths: allFiles.map { $0.path }, tool: currentTool,
                                    start: trim?.start ?? 0, end: trim?.end ?? 0)
        let w = DispatchWorkItem { AudioProjectLibrary.save(snapshot, in: folder) }
        projectSave = w
        AudioProjectLibrary.queue.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Riprende un progetto: file, file da unire, strumento e selezione.
    func openProject(_ p: AudioProject) {
        var p = p
        guard AudioProjectLibrary.relink(&p) else {
            notice = "Non trovo più il file di «\(p.name)»: è stato cancellato o è su un disco scollegato."
            NSSound.beep()
            return
        }
        restoringProject = true
        restoredTool = p.tool
        currentTool = p.tool
        let urls = p.urls
        extra = Array(urls.dropFirst())
        open(urls[0])
        restoringProject = false
        currentProject = p.id
        notice = nil
        // La selezione si rimette appena il file è letto
        let start = p.start, end = p.end
        guard end > start, let t = trim else { return }
        restoreCancellable = t.$loading.filter { !$0 }.first().receive(on: DispatchQueue.main).sink { [weak t] _ in
            guard let t, end <= t.duration + 0.05 else { return }
            t.start = start
            t.end = min(end, t.duration)
            t.seek(start)
        }
    }

    func renameProject(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        AudioProjectLibrary.rename(id, to: n, in: projectsFolder)
        refreshProjects()
    }

    func duplicateProject(_ id: UUID) {
        _ = AudioProjectLibrary.duplicate(id, in: projectsFolder)
        refreshProjects()
    }

    func deleteProject(_ id: UUID) {
        if id == currentProject { currentProject = nil }
        AudioProjectLibrary.trash(id, in: projectsFolder)
        refreshProjects()
    }
}

// MARK: - La riga dei progetti (sotto l'area del file, quando non c'è un file aperto)

struct AudioProjectsRow: View {
    @ObservedObject var m: MediaTabModel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Progetti")
                Text("si salvano da soli · clic per riprendere").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(m.audioProjects) { p in card(p) }
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func card(_ p: AudioProject) -> some View {
        Button { m.openProject(p) } label: {
            HStack(spacing: 10) {
                Image(systemName: AudioTool(rawValue: p.tool)?.symbol ?? "waveform")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 32, height: 32).background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(p)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(detail(p)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 220)
            .card(radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apri") { m.openProject(p) }
            Button("Rinomina…") { rename(p) }
            Button("Duplica") { m.duplicateProject(p.id) }
            Divider()
            Button("Elimina…", role: .destructive) { delete(p) }
        }
        .help("Riprendi «\(title(p))» · clic destro per rinominare, duplicare o eliminare")
        .accessibilityLabel("Progetto \(title(p)), \(detail(p))")
    }

    /// 3.0 · Due progetti con lo stesso nome si distinguono dal punto di partenza: «On The Rope · 0:40».
    private func title(_ p: AudioProject) -> String {
        AudioProjectsRow.title(p, among: m.audioProjects)
    }

    static func title(_ p: AudioProject, among all: [AudioProject]) -> String {
        let same = all.filter { $0.name == p.name }
        guard same.count > 1 else { return p.name }
        if Set(same.map { Int($0.start.rounded()) }).count == same.count, p.length > 0.1 {
            return p.name + " · " + formatShort(p.start)
        }
        let n = (same.sorted { $0.modified < $1.modified }.firstIndex { $0.id == p.id } ?? 0) + 1
        return p.name + " · \(n)"
    }

    private func detail(_ p: AudioProject) -> String {
        let tool = AudioTool(rawValue: p.tool)?.title ?? "Audio"
        let sel = p.length > 0.1 ? " · " + formatShort(p.length) : ""
        let files = p.paths.count > 1 ? " · \(p.paths.count) file" : ""
        return tool + sel + files + " · " + p.modified.formatted(.relative(presentation: .named))
    }

    private func rename(_ p: AudioProject) {
        let a = NSAlert()
        a.messageText = "Rinomina il progetto"
        let field = NSTextField(string: p.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rinomina")
        a.addButton(withTitle: "Annulla")
        a.window.initialFirstResponder = field
        Sheet.confirm(a) { ok in if ok { m.renameProject(p.id, to: field.stringValue) } }
    }

    private func delete(_ p: AudioProject) {
        let a = NSAlert()
        a.messageText = "Eliminare «\(p.name)»?"
        a.informativeText = "Il progetto va nel Cestino. Il file audio non viene toccato."
        a.addButton(withTitle: "Elimina")
        a.addButton(withTitle: "Annulla")
        Sheet.confirm(a) { ok in if ok { m.deleteProject(p.id) } }
    }
}
