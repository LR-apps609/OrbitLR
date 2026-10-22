import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.6.2 · Scheda Video come piccolo programma di montaggio (layout B: striscia in basso)
// ════════════════════════════════════════════════════════════════════

/// Il tempo dell'anteprima, a parte: cambia 20 volte al secondo e non deve ridisegnare tutta la scheda.
final class PlayClock: ObservableObject, @unchecked Sendable {
    @Published var time: Double = 0
    @Published var playing = false
}

final class VideoProjectStore: ObservableObject, @unchecked Sendable {
    static let shared = VideoProjectStore()

    @Published private(set) var project = VideoProject()
    @Published private(set) var infos: [String: VPMediaInfo] = [:]
    @Published private(set) var speech: [String: [ClosedRange<Double>]] = [:]
    @Published private(set) var analyzing: Set<String> = []
    @Published private(set) var thumbs: [String: [NSImage]] = [:]
    @Published private(set) var building = false
    @Published var selected: UUID? = nil
    @Published var notice: String? = nil
    @Published var lastJob: Job? = nil

    let clock = PlayClock()
    let player = AVPlayer()
    private var observer: Any?
    private var rebuildTask: Task<Void, Never>?
    private var saveWork: DispatchWorkItem?
    private var loading: Set<String> = []
    private(set) var previewDuration: Double = 0

    private var saveURL: URL { Paths.support.appendingPathComponent("Progetto video.json") }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            if abs(self.clock.time - s) > 0.001 { self.clock.time = s }
            if self.clock.playing, self.previewDuration > 0, s >= self.previewDuration - 0.04 { self.pause() }
        }
        restore()
    }

    // MARK: Stato derivato

    var canvasSize: CGSize {
        guard let i = project.clips.lazy.compactMap({ self.infos[$0.path] }).first(where: { $0.hasVideo }) else { return .zero }
        return i.displaySize
    }
    var songDuration: Double? { project.music.flatMap { infos[$0.path]?.duration } }
    var musicEnd: Double? { VideoProjectBuilder.musicEnd(project, songDuration: songDuration) }
    var speechOnTimeline: [ClosedRange<Double>] { VideoProjectBuilder.speechOnTimeline(project, speech: speech) }

    /// La clip su cui agiscono i comandi: quella scelta, altrimenti quella sotto l'indicatore.
    var targetIndex: Int? {
        if let s = selected, let i = project.clips.firstIndex(where: { $0.id == s }) { return i }
        return project.clip(at: clock.time)?.index
    }

    // MARK: Modifiche (ognuna si può annullare con ⌘Z)

    func change(_ undo: UndoManager?, _ name: String, _ body: (inout VideoProject) -> Void) {
        let before = project
        var p = project
        body(&p)
        guard p != before else { return }
        apply(p)
        registerUndo(undo, name, before: before)
    }

    /// Durante un trascinamento: si vede subito, l'annullamento si registra alla fine (uno solo).
    func live(_ body: (inout VideoProject) -> Void) {
        var p = project
        body(&p)
        if p != project { apply(p) }
    }

    func commit(from before: VideoProject, _ undo: UndoManager?, _ name: String) {
        guard before != project else { return }
        registerUndo(undo, name, before: before)
    }

    private func registerUndo(_ undo: UndoManager?, _ name: String, before: VideoProject) {
        guard let undo else { return }
        let after = project
        undo.registerUndo(withTarget: self) { s in s.restoreState(before, redo: after, undo: undo, name: name) }
        undo.setActionName(name)
    }

    private func restoreState(_ state: VideoProject, redo: VideoProject, undo: UndoManager, name: String) {
        apply(state)
        undo.registerUndo(withTarget: self) { s in s.restoreState(redo, redo: state, undo: undo, name: name) }
        undo.setActionName(name)
    }

    private func apply(_ p: VideoProject) {
        project = p
        if let s = selected, !p.clips.contains(where: { $0.id == s }) { selected = nil }
        let d = p.duration
        if clock.time > d { seek(d) }
        ensureLoaded()
        ensureSpeech()
        scheduleRebuild()
        scheduleSave()
    }

    // MARK: File

    static let readableVideo: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let readableAudio: Set<String> = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "caf", "mp4", "mov", "m4v"]

    /// Video trascinati o scelti: si aggiungono in fondo. Un brano audio diventa la musica.
    func add(_ urls: [URL], undo: UndoManager?) {
        let all = PieController.expand(urls)
        let videos = all.filter { Catalog.kind(of: $0) == .video }
        let audios = all.filter { Catalog.kind(of: $0) == .audio }
        guard !videos.isEmpty || !audios.isEmpty else {
            notice = "Qui si aprono video (e un brano audio, per la musica)."
            NSSound.beep()
            return
        }
        let okVideos = videos.filter { Self.readableVideo.contains(Catalog.norm($0.pathExtension)) }
        let okAudio = audios.first { Self.readableAudio.contains(Catalog.norm($0.pathExtension)) }
        // Formati che macOS non apre da solo: si preparano in automatico e poi entrano nel progetto
        let otherVideos = videos.filter { !Self.readableVideo.contains(Catalog.norm($0.pathExtension)) }
        let otherAudio = okAudio == nil ? audios.first : nil
        notice = nil
        if !otherVideos.isEmpty {
            notice = "Preparo \(otherVideos.count == 1 ? "«" + otherVideos[0].lastPathComponent + "»" : "\(otherVideos.count) video"): entrano nel progetto tra poco."
            AutoConvert.prepare(otherVideos, to: "mp4", kind: .video) { [weak self] ready in
                self?.notice = nil
                self?.add(ready, undo: undo)
            }
        }
        if let a = otherAudio {
            notice = "Preparo «\(a.lastPathComponent)» per la musica…"
            AutoConvert.prepare([a], to: "m4a", kind: .audio) { [weak self] ready in
                guard let self, let r = ready.first else { return }
                self.notice = nil
                Task { @MainActor in await self.setMusic(r, undo: undo) }
            }
        }
        guard !okVideos.isEmpty || okAudio != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var loaded: [VPClip] = []
            for u in okVideos {
                do {
                    let info = try await VPMediaInfo.load(u)
                    guard info.hasVideo else { self.notice = "«\(u.lastPathComponent)» non contiene video."; continue }
                    self.infos[u.path] = info
                    loaded.append(VPClip(path: u.path, inPoint: 0, outPoint: info.videoDuration))
                    self.loadThumbs(u.path, duration: info.videoDuration)
                } catch {
                    self.notice = "«\(u.lastPathComponent)» non si apre: \(error.localizedDescription)"
                }
            }
            if !loaded.isEmpty {
                self.change(undo, loaded.count == 1 ? "Aggiungi video" : "Aggiungi \(loaded.count) video") { $0.clips += loaded }
            }
            if let a = okAudio { await self.setMusic(a, undo: undo) }
        }
    }

    @MainActor
    func setMusic(_ url: URL, undo: UndoManager?) async {
        do {
            let info = try await VPMediaInfo.load(url)
            guard info.hasAudio else { notice = "«\(url.lastPathComponent)» non contiene audio."; NSSound.beep(); return }
            infos[url.path] = info
            change(undo, "Aggiungi musica") { p in
                var m = p.music ?? VPMusic(path: url.path)
                m.path = url.path
                m.inPoint = 0
                // Brano più corto del video: di base si ripete, così il video non resta muto a metà
                m.loop = info.duration < max(0, p.duration - m.offset) - 0.5
                p.music = m
            }
        } catch {
            notice = "La musica non si apre: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    private func ensureLoaded() {
        var paths = project.clips.map { $0.path }
        if let m = project.music { paths.append(m.path) }
        for path in Set(paths) where infos[path] == nil && !loading.contains(path) {
            loading.insert(path)
            Task { @MainActor [weak self] in
                let info = try? await VPMediaInfo.load(URL(fileURLWithPath: path))
                guard let self else { return }
                self.loading.remove(path)
                if let info {
                    self.infos[path] = info
                    if info.hasVideo, self.thumbs[path] == nil { self.loadThumbs(path, duration: info.videoDuration) }
                    self.ensureSpeech()
                    self.scheduleRebuild()
                } else {
                    self.notice = "«\(URL(fileURLWithPath: path).lastPathComponent)» non si apre più."
                }
            }
        }
    }

    private func loadThumbs(_ path: String, duration: Double) {
        guard thumbs[path] == nil else { return }
        thumbs[path] = []
        Task { @MainActor [weak self] in
            let imgs = await TrimModel.thumbnails(url: URL(fileURLWithPath: path), count: 16, duration: duration)
            self?.thumbs[path] = imgs
        }
    }

    /// Le voci nei video servono solo se la musica deve abbassarsi quando si parla.
    private func ensureSpeech() {
        guard let m = project.music, m.duck, project.originalAudible else { return }
        for c in project.clips where speech[c.path] == nil && !analyzing.contains(c.path) {
            guard let info = infos[c.path] else { continue }          // si riprova quando il file è letto
            guard info.hasAudio else { speech[c.path] = []; continue }
            let path = c.path
            analyzing.insert(path)
            Task { @MainActor [weak self] in
                let r = await SpeechDetector.ranges(in: URL(fileURLWithPath: path))
                guard let self else { return }
                self.analyzing.remove(path)
                self.speech[path] = r
                self.scheduleRebuild()
            }
        }
    }

    // MARK: Anteprima

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        let p = project, inf = infos, sp = speech
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            guard p.clips.contains(where: { inf[$0.path] != nil }) else {
                self.pause()
                self.player.replaceCurrentItem(with: nil)
                self.previewDuration = 0
                return
            }
            self.building = true
            let built = try? await VideoProjectBuilder.build(p, infos: inf, speech: sp, maxSide: 1280)
            self.building = false
            guard !Task.isCancelled else { return }
            guard let built else {
                self.pause()
                self.player.replaceCurrentItem(with: nil)
                self.previewDuration = 0
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            let t = min(self.clock.time, max(0, built.duration - 0.05))
            let wasPlaying = self.clock.playing
            self.player.replaceCurrentItem(with: item)
            self.previewDuration = built.duration
            self.player.seek(to: VideoProjectBuilder.cm(t), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            self.clock.time = t
            if wasPlaying { self.player.play() }
        }
    }

    func togglePlay() { clock.playing ? pause() : play() }

    func play() {
        guard player.currentItem != nil, previewDuration > 0 else { NSSound.beep(); return }
        if clock.time >= previewDuration - 0.1 { seek(0) }
        player.play()
        clock.playing = true
    }

    func pause() {
        player.pause()
        clock.playing = false
    }

    func seek(_ t: Double) {
        let limit = previewDuration > 0 ? previewDuration : project.duration
        let v = min(max(0, t), max(0, limit))
        player.seek(to: VideoProjectBuilder.cm(v), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.time = v
    }

    // MARK: Comandi sulle clip

    func split(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { NSSound.beep(); return }
        let c = project.clips[hit.index]
        let l = hit.local
        guard l - c.inPoint > 0.1, c.outPoint - l > 0.1 else {
            notice = "Per dividere, porta l’indicatore dentro una clip (non sul bordo)."
            NSSound.beep()
            return
        }
        notice = nil
        change(undo, "Dividi") { p in
            var a = c, b = c
            a.outPoint = l
            b.id = UUID()
            b.inPoint = l
            p.clips.replaceSubrange(hit.index...hit.index, with: [a, b])
        }
    }

    func trimStartHere(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { NSSound.beep(); return }
        let i = hit.index, c = project.clips[i]
        guard c.outPoint - hit.local > 0.1 else { NSSound.beep(); return }
        let clipStart = project.starts[i]
        change(undo, "Taglia l’inizio") { $0.clips[i].inPoint = hit.local }
        seek(clipStart)
    }

    func trimEndHere(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { NSSound.beep(); return }
        let i = hit.index, c = project.clips[i]
        guard hit.local - c.inPoint > 0.1 else { NSSound.beep(); return }
        change(undo, "Taglia la fine") { $0.clips[i].outPoint = hit.local }
    }

    func restoreClip(_ undo: UndoManager?) {
        guard let i = targetIndex, let info = infos[project.clips[i].path] else { NSSound.beep(); return }
        change(undo, "Clip intera") { p in
            p.clips[i].inPoint = 0
            p.clips[i].outPoint = info.videoDuration
        }
    }

    func move(_ delta: Int, _ undo: UndoManager?) {
        guard let i = targetIndex else { NSSound.beep(); return }
        let j = i + delta
        guard project.clips.indices.contains(j) else { NSSound.beep(); return }
        let id = project.clips[i].id
        change(undo, "Sposta la clip") { $0.clips.swapAt(i, j) }
        selected = id
        seek(project.starts[j])
    }

    func deleteClip(_ undo: UndoManager?) {
        guard let i = targetIndex else { NSSound.beep(); return }
        change(undo, "Elimina la clip") { $0.clips.remove(at: i) }
        selected = nil
    }

    func newProject(_ undo: UndoManager?) {
        pause()
        change(undo, "Nuovo progetto") { $0 = VideoProject() }
        lastJob = nil
        notice = nil
    }

    // MARK: Musica

    func musicStartHere(_ undo: UndoManager?) {
        let t = clock.time
        change(undo, "Musica da qui") { $0.music?.offset = t }
    }

    /// Fa finire la canzone insieme al video (sceglie da che punto farla partire).
    func alignMusicEnd(_ undo: UndoManager?) {
        guard let m = project.music, let sd = songDuration else { return }
        let room = max(0, project.duration - m.offset)
        change(undo, "Finale insieme al video") { p in
            p.music?.inPoint = max(0, sd - room)
            p.music?.loop = false
        }
    }

    func removeMusic(_ undo: UndoManager?) {
        change(undo, "Togli la musica") { $0.music = nil }
    }

    // MARK: Esportazione

    func export() {
        guard !project.clips.isEmpty else { NSSound.beep(); return }
        guard project.duration > 0.1 else { notice = "Il montaggio è vuoto."; NSSound.beep(); return }
        if !analyzing.isEmpty {
            notice = "Un attimo: sto ancora trovando le voci nel video per abbassare la musica."
            NSSound.beep()
            return
        }
        pause()
        do {
            let snap = try VideoProjectExport.writeSnapshot(project, speech: speech)
            var seen = Set<String>()
            let files = project.clips.map { $0.url }.filter { seen.insert($0.path).inserted }
            guard let action = Catalog.action(id: "vproject", kind: .video) else { return }
            notice = nil
            lastJob = QueueStore.shared.enqueue(files: files, action: action, param: snap.path)
        } catch {
            notice = "Non riesco a preparare l’esportazione: \(error.localizedDescription)"
        }
    }

    /// Misura finale e peso stimato, per mostrarli prima di esportare.
    var estimate: (size: CGSize, bytes: Int64)? {
        let base = canvasSize
        guard base.width > 0, base.height > 0 else { return nil }
        let k = min(1, 3840 / max(base.width, base.height))
        let canvas = CGSize(width: base.width * k, height: base.height * k)
        let out = VideoProjectExport.outputSize(canvas: canvas, project: project).out
        let w = Double(out.width), h = Double(out.height)
        let fps = Double(VideoProjectBuilder.effectiveFPS(project, infos: infos))
        let bits = max(2_000_000, min(50_000_000, w * h * fps * 0.13)) + 160_000
        return (out, Int64(bits * project.duration / 8))
    }

    // MARK: Salvataggio automatico

    private func scheduleSave() {
        saveWork?.cancel()
        let p = project, url = saveURL
        let w = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(VideoProjectStore.withBookmarks(p)) { try? d.write(to: url, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Aggiunge (o rinfresca) i segnalibri prima di salvare.
    static func withBookmarks(_ p: VideoProject) -> VideoProject {
        var p = p
        for i in p.clips.indices { p.clips[i].bookmark = (try? p.clips[i].url.bookmarkData()) ?? p.clips[i].bookmark }
        if let m = p.music { p.music?.bookmark = (try? URL(fileURLWithPath: m.path).bookmarkData()) ?? m.bookmark }
        return p
    }

    static func resolve(_ data: Data?) -> String? {
        guard let data else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u.path
    }

    private func restore() {
        guard let d = try? Data(contentsOf: saveURL), var p = try? JSONDecoder().decode(VideoProject.self, from: d) else { return }
        let fm = FileManager.default
        let before = p.clips.count
        // File spostati o rinominati: li ritrova il segnalibro
        for i in p.clips.indices where !fm.fileExists(atPath: p.clips[i].path) {
            if let found = Self.resolve(p.clips[i].bookmark) { p.clips[i].path = found }
        }
        if let m = p.music, !fm.fileExists(atPath: m.path) { p.music?.path = Self.resolve(m.bookmark) ?? m.path }
        p.clips = p.clips.filter { fm.fileExists(atPath: $0.path) && $0.length > 0.05 }
        var lost: [String] = []
        if p.clips.count < before { lost.append(before - p.clips.count == 1 ? "1 clip" : "\(before - p.clips.count) clip") }
        if let m = p.music, !fm.fileExists(atPath: m.path) { p.music = nil; lost.append("la musica") }
        if !lost.isEmpty {
            notice = "Non trovo più \(lost.joined(separator: " e ")) del progetto: il file è stato cancellato o è su un disco scollegato."
        }
        project = p
        ensureLoaded()
        scheduleRebuild()
    }
}

// MARK: - La scheda

enum VideoEditTool: String, CaseIterable, Identifiable {
    case clips = "Clip", music = "Musica", original = "Audio originale", format = "Formato", export = "Esportazione"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clips: return "film.stack"
        case .music: return "music.note"
        case .original: return "speaker.wave.2"
        case .format: return "rectangle.portrait"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var s: VideoProjectStore
    @Environment(\.undoManager) private var undo
    @State private var tool: VideoEditTool = .clips
    @State private var targeted = false

    private let tint = Theme.color(.video)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if s.project.clips.isEmpty {
                MediaDropZone(kind: .video, title: "Trascina qui i video",
                              subtitle: "oppure clicca per sceglierli · MP4, MOV, M4V · più video vanno in fila · un brano audio diventa la musica",
                              targeted: targeted) { choose(audio: false) }
            } else {
                EditorPreview(s: s, clock: s.clock)
                ProjectTimeline(s: s, clock: s.clock, tint: tint) { tool = .music }
                    .frame(height: 118)
                toolRow
                strip
            }
            if let n = s.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let job = s.lastJob { JobStrip(job: job) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in s.add(urls, undo: undo) }
            return true
        }
        .onDisappear { s.pause() }
        .navigationTitle("Video")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.project.clips.isEmpty ? "Video" : "Progetto video")
                    .font(.system(size: s.project.clips.isEmpty ? 22 : 15, weight: .bold, design: s.project.clips.isEmpty ? .rounded : .default))
                if !s.project.clips.isEmpty {
                    Text("\(s.project.clips.count) clip · \(formatShort(s.project.duration))" + (s.project.music != nil ? " · con musica" : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if s.building { ProgressView().controlSize(.small).help("Preparo l’anteprima") }
            Spacer(minLength: 8)
            if !s.project.clips.isEmpty {
                Button { undo?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annulla (⌘Z)")
                Button { undo?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Ripeti (⇧⌘Z)")
                Button("Aggiungi video…") { choose(audio: false) }
                Button("Nuovo progetto") {
                    // 2.7.1 · Il progetto c'è uno solo: prima di cancellarlo si chiede.
                    let a = NSAlert()
                    a.messageText = "Iniziare un nuovo progetto?"
                    a.informativeText = "Il montaggio attuale verrà tolto. Puoi recuperarlo con ⌘Z finché OrbitLR resta aperta. I tuoi file originali non vengono toccati."
                    a.addButton(withTitle: "Nuovo progetto")
                    a.addButton(withTitle: "Annulla")
                    if a.runModal() == .alertFirstButtonReturn { s.newProject(undo) }
                }
                .help("Ricomincia da capo")
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(VideoEditTool.allCases) { t in
                Chip(title: t.rawValue, selected: tool == t, tint: tint) { tool = t }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Estrai l’audio (M4A)") { quick("to:m4a", param: "") }
                Button("Estrai l’audio (MP3)") { quick("to:mp3", param: "") }
                Button("GIF della clip") { quickGIF() }
                Button("Comprimi la clip a 25 MB") { quick("vcompress", param: "25") }
            } label: {
                Label("Altro", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Strumenti veloci sul file originale della clip")
        }
    }

    // MARK: Striscia: strumento · opzioni · riepilogo · Esporta

    private var strip: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Strumento")
                Text(tool.rawValue).font(.system(size: 14.5, weight: .bold)).lineLimit(1).fixedSize()
            }
            .frame(minWidth: 118, alignment: .leading)
            Divider().frame(height: 52)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 16) { options }
                    .padding(.vertical, 2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTime(s.project.duration)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                if let e = s.estimate {
                    Text("\(Int(e.size.width)) × \(Int(e.size.height)) · ≈ " + ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            Button("Esporta") { s.export() }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .keyboardShortcut("e", modifiers: .command)
                .help("Crea il video finale (⌘E)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(radius: 14)
    }

    @ViewBuilder private var options: some View {
        switch tool {
        case .clips: clipOptions
        case .music: musicOptions
        case .original: originalOptions
        case .format: formatOptions
        case .export: exportOptions
        }
    }

    private var clipOptions: some View {
        HStack(spacing: 8) {
            Button("Inizio qui") { s.trimStartHere(undo) }.help("Taglia la clip da qui in poi")
            Button("Fine qui") { s.trimEndHere(undo) }.help("Taglia la clip fino a qui")
            Button("Dividi") { s.split(undo) }
                .keyboardShortcut("s", modifiers: [])
                .help("Divide la clip nel punto dell’indicatore (S)")
            Divider().frame(height: 22)
            Button { s.move(-1, undo) } label: { Image(systemName: "arrow.left") }.help("Sposta la clip prima")
            Button { s.move(1, undo) } label: { Image(systemName: "arrow.right") }.help("Sposta la clip dopo")
            Button("Intera") { s.restoreClip(undo) }.help("Riporta la clip alla sua durata intera")
            Button(role: .destructive) { s.deleteClip(undo) } label: { Image(systemName: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Elimina la clip (si può annullare)")
        }
        .fixedSize()
    }

    @ViewBuilder private var musicOptions: some View {
        if let m = s.project.music {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                HStack(spacing: 6) {
                    Button("Cambia…") { choose(audio: true) }
                    Button(role: .destructive) { s.removeMusic(undo) } label: { Image(systemName: "trash") }.help("Togli la musica")
                }
                .controlSize(.small)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button("Parte qui nel video") { s.musicStartHere(undo) }
                        .help("La musica comincia nel punto dell’indicatore (oppure trascina la barra della musica)")
                    Button("Finale con il video") { s.alignMusicEnd(undo) }
                        .help("Sceglie da dove far partire la canzone perché finisca insieme al video")
                }
                .controlSize(.small)
                Toggle("Ripeti finché il video finisce", isOn: bind(\.loop, "Ripeti la musica")).toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            .fixedSize()
            if let sd = s.songDuration, sd > 1 {
                EditSlider(title: "Parte dal", value: m.inPoint, range: 0...max(1, sd - 1), text: formatShort(m.inPoint),
                           width: 150, s: s, undo: undo, name: "Punto della canzone") { p, v in p.music?.inPoint = v }
            }
            EditSlider(title: "Volume", value: m.volume, range: 0...1, text: "\(Int((m.volume * 100).rounded()))%",
                       width: 110, s: s, undo: undo, name: "Volume della musica") { p, v in p.music?.volume = v }
            EditSlider(title: "Entrata", value: m.fadeIn, range: 0...5, text: String(format: "%.1f s", m.fadeIn),
                       width: 90, s: s, undo: undo, name: "Dissolvenza in entrata") { p, v in p.music?.fadeIn = v }
            EditSlider(title: "Uscita", value: m.fadeOut, range: 0...5, text: String(format: "%.1f s", m.fadeOut),
                       width: 90, s: s, undo: undo, name: "Dissolvenza in uscita") { p, v in p.music?.fadeOut = v }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Abbassa quando si parla", isOn: bind(\.duck, "Abbassa quando si parla")).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                if !s.analyzing.isEmpty {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Cerco le voci…") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if m.duck && !s.project.originalAudible {
                    Text("L’audio originale è spento").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if m.duck {
                    Text("\(s.speechOnTimeline.count) tratti con voce").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        } else {
            Button { choose(audio: true) } label: { Label("Scegli la musica…", systemImage: "music.note") }
            Text("oppure trascina un brano sulla scheda").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func bind(_ key: WritableKeyPath<VPMusic, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { s.project.music?[keyPath: key] ?? false },
                set: { v in s.change(undo, name) { $0.music?[keyPath: key] = v } })
    }

    private var originalOptions: some View {
        HStack(spacing: 16) {
            Toggle("Muto", isOn: Binding(get: { s.project.originalMuted },
                                          set: { v in s.change(undo, v ? "Audio originale muto" : "Audio originale attivo") { $0.originalMuted = v } }))
                .toggleStyle(.checkbox)
            EditSlider(title: "Volume", value: s.project.originalVolume, range: 0...1,
                       text: "\(Int((s.project.originalVolume * 100).rounded()))%", width: 160, s: s, undo: undo,
                       name: "Volume dell’audio originale") { p, v in p.originalVolume = v }
                .disabled(s.project.originalMuted)
        }
        .fixedSize()
    }

    private var formatOptions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach([("orig", "Originale"), ("9x16", "9:16 Reels"), ("1x1", "1:1 Post"), ("4x5", "4:5 Feed"), ("16x9", "16:9 YouTube")], id: \.0) { item in
                    Chip(title: item.1, selected: s.project.aspect == item.0, tint: tint) {
                        s.change(undo, "Formato \(item.1)") { $0.aspect = item.0 }
                    }
                }
            }
            Toggle("Inquadra le persone", isOn: Binding(get: { s.project.follow },
                                                       set: { v in s.change(undo, "Inquadra le persone") { $0.follow = v } }))
                .toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(s.project.aspect == "orig")
                .help("Nel video finale l’inquadratura segue le persone con calma (in anteprima resta al centro)")
        }
        .fixedSize()
    }

    private var exportOptions: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Risoluzione").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([(720, "720p"), (1080, "1080p"), (2160, "4K")], id: \.0) { item in
                        Chip(title: item.1, selected: s.project.resolution == item.0, tint: tint) {
                            s.change(undo, "Risoluzione \(item.1)") { $0.resolution = item.0 }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Fluidità").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([30, 60], id: \.self) { f in
                        Chip(title: "\(f) fps", selected: s.project.fps == f, tint: tint) {
                            s.change(undo, "\(f) fotogrammi al secondo") { $0.fps = f }
                        }
                        .help(f == 60 ? "Solo se i video sono girati a 60: non si inventano fotogrammi" : "")
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Azioni

    private func choose(audio: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = !audio
        p.canChooseDirectories = false
        p.allowedContentTypes = audio ? [.audio] : [.movie]
        p.prompt = audio ? "Scegli" : "Aggiungi"
        guard p.runModal() == .OK else { return }
        if audio, let u = p.url {
            Task { @MainActor in await s.setMusic(u, undo: undo) }
        } else {
            s.add(p.urls, undo: undo)
        }
    }

    private var targetClip: VPClip? { s.targetIndex.map { s.project.clips[$0] } }

    private func quick(_ id: String, param: String) {
        guard let c = targetClip, let action = Catalog.action(id: id, kind: .video) else { NSSound.beep(); return }
        s.lastJob = QueueStore.shared.enqueue(files: [c.url], action: action, param: param)
    }

    private func quickGIF() {
        guard let c = targetClip, let action = Catalog.action(id: "gifcut", kind: .video) else { NSSound.beep(); return }
        let end = min(c.outPoint, c.inPoint + 15)
        s.lastJob = QueueStore.shared.enqueue(files: [c.url], action: action, param: String(format: "%.3f|%.3f", c.inPoint, end))
    }
}

/// Cursore che modifica il progetto: si vede subito, e tutto il trascinamento si annulla con un solo ⌘Z.
private struct EditSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    let width: CGFloat
    let s: VideoProjectStore
    let undo: UndoManager?
    let name: String
    let set: (inout VideoProject, Double) -> Void
    @State private var before: VideoProject? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { v in s.live { set(&$0, v) } }),
                   in: range,
                   onEditingChanged: { editing in
                if editing { before = s.project }
                else if let b = before { s.commit(from: b, undo, name); before = nil }
            })
            .controlSize(.small)
        }
        .frame(width: width)
    }
}

// MARK: - Anteprima

private struct EditorPreview: View {
    @ObservedObject var s: VideoProjectStore
    @ObservedObject var clock: PlayClock

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PlayerPreview(player: s.player)
                .background(Color.black)
            if let r = s.project.aspectRatio {
                FormatFrame(canvas: s.canvasSize, ratio: r).allowsHitTesting(false)
            }
            HStack {
                Button { s.togglePlay() } label: {
                    Image(systemName: clock.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.9)))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Riproduci / pausa (Spazio)")
                Spacer()
                Text("\(formatTime(clock.time)) / \(formatTime(s.project.duration))")
                    .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 200)
    }
}

/// Oscura quello che resta fuori dal formato scelto (al centro; nell'esportazione segue il soggetto).
private struct FormatFrame: View {
    let canvas: CGSize
    let ratio: Double
    var body: some View {
        GeometryReader { g in
            let vs = canvas.width > 0 && canvas.height > 0 ? canvas : CGSize(width: 16, height: 9)
            let fit = min(g.size.width / vs.width, g.size.height / vs.height)
            let vw = vs.width * fit, vh = vs.height * fit
            let vx = (g.size.width - vw) / 2, vy = (g.size.height - vh) / 2
            let cw = min(vw, vh * CGFloat(ratio))
            let ch = cw / CGFloat(ratio)
            let crop = CGRect(x: vx + (vw - cw) / 2, y: vy + (vh - ch) / 2, width: cw, height: ch)
            ZStack {
                Path { p in
                    p.addRect(CGRect(x: vx, y: vy, width: vw, height: vh))
                    p.addRect(crop)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
            }
        }
    }
}

// MARK: - Sequenza: righello, clip, musica, indicatore

/// Solo la linea dell'indicatore si ridisegna mentre il video scorre (non tutta la sequenza).
private struct PlayheadLine: View {
    @ObservedObject var clock: PlayClock
    let pps: CGFloat
    let size: CGSize
    var body: some View {
        Rectangle().fill(Theme.ink)
            .frame(width: 2, height: size.height)
            .offset(x: min(max(0, CGFloat(clock.time) * pps - 1), max(0, size.width - 2)))
    }
}

private struct ProjectTimeline: View {
    @ObservedObject var s: VideoProjectStore
    let clock: PlayClock
    let tint: Color
    let openMusic: () -> Void
    @Environment(\.undoManager) private var undo
    @State private var dragBefore: VideoProject? = nil
    @State private var dragStartOffset: Double = 0
    @State private var moving: UUID? = nil
    @State private var moveDX: CGFloat = 0
    @State private var trimBefore: VideoProject? = nil
    @State private var trimIn: Double = 0
    @State private var trimOut: Double = 0
    @State private var frozenPPS: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            let total = max(s.project.duration, 0.1)
            let pps = g.size.width / CGFloat(total)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler(total: total, pps: pps, width: g.size.width)
                        .frame(height: 16)
                    clipsRow(pps: pps)
                        .frame(height: 56)
                    musicRow(total: total, pps: pps, width: g.size.width)
                        .frame(height: 28)
                }
                PlayheadLine(clock: clock, pps: pps, size: g.size)
                    .allowsHitTesting(false)
            }
        }
    }

    // Righello: clic o trascinamento per spostarsi
    private func ruler(total: Double, pps: CGFloat, width: CGFloat) -> some View {
        let step: Double = total <= 20 ? 2 : total <= 60 ? 5 : total <= 180 ? 15 : total <= 600 ? 60 : 300
        let marks = Array(stride(from: 0.0, through: total, by: step))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.ink.opacity(0.05))
            ForEach(marks, id: \.self) { t in
                Text(formatShort(t)).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
                    .offset(x: min(CGFloat(t) * pps + 2, max(0, width - 28)), y: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            s.seek(Double(max(0, v.location.x) / pps))
        })
        .help("Clicca o trascina per spostarti")
    }

    private func clipsRow(pps: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(slots) { slot in
                let c = slot.clip, start = slot.start
                let w = max(4, CGFloat(c.length) * pps - 2)
                ClipBlock(clip: c, thumbs: s.thumbs[c.path] ?? [], fileDuration: s.infos[c.path]?.videoDuration ?? c.outPoint,
                          selected: s.selected == c.id, tint: tint,
                          speech: speechMarks(c, start: start))
                    .frame(width: w)
                    .overlay(alignment: .leading) {
                        if s.selected == c.id { trimHandle(c, start: start, left: true, pps: pps) }
                    }
                    .overlay(alignment: .trailing) {
                        if s.selected == c.id { trimHandle(c, start: start, left: false, pps: pps) }
                    }
                    // 2.7.2 · ✕ sulla clip selezionata: la togli senza cercare il comando
                    .overlay(alignment: .topTrailing) {
                        if s.selected == c.id && w > 40 {
                            Button { s.deleteClip(undo) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.black.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 3).padding(.trailing, 12)
                            .help("Togli la clip (⌫) · si può annullare con ⌘Z")
                        }
                    }
                    .offset(x: moving == c.id ? moveDX : 0)
                    .zIndex(moving == c.id ? 1 : 0)
                    .opacity(moving == c.id ? 0.85 : 1)
                    .shadow(color: .black.opacity(moving == c.id ? 0.3 : 0), radius: 6, y: 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { loc in
                        s.selected = s.selected == c.id ? nil : c.id
                        s.seek(start + Double(loc.x / pps))
                    }
                    // Trascina la clip per cambiarne il posto nella fila
                    .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { v in
                            moving = c.id
                            moveDX = v.translation.width
                        }
                        .onEnded { v in
                            let center = CGFloat(start) * pps + w / 2 + v.translation.width
                            let t = Double(center / max(pps, 0.0001))
                            let others = slots.filter { $0.id != c.id }
                            let newIndex = others.filter { $0.start + $0.clip.length / 2 < t }.count
                            moving = nil
                            moveDX = 0
                            guard let old = s.project.clips.firstIndex(where: { $0.id == c.id }), newIndex != old else { return }
                            s.change(undo, "Sposta la clip") { p in
                                let moved = p.clips.remove(at: old)
                                p.clips.insert(moved, at: min(newIndex, p.clips.count))
                            }
                            s.selected = c.id
                        })
                    .help(c.url.lastPathComponent + " · clic per sceglierla, trascina per spostarla")
            }
        }
    }

    /// Maniglia sul bordo della clip scelta: si trascina per tagliare inizio o fine, guardando l'anteprima.
    private func trimHandle(_ c: VPClip, start: Double, left: Bool, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.brass)
            .frame(width: 10)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 18))
            .padding(.vertical, 1)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if trimBefore == nil {
                        trimBefore = s.project
                        trimIn = c.inPoint
                        trimOut = c.outPoint
                        frozenPPS = max(pps, 0.0001)
                    }
                    let delta = Double(v.translation.width / frozenPPS)
                    let fileD = s.infos[c.path]?.videoDuration ?? c.outPoint
                    var shown = start
                    s.live { p in
                        guard let i = p.clips.firstIndex(where: { $0.id == c.id }) else { return }
                        if left {
                            p.clips[i].inPoint = min(max(0, trimIn + delta), p.clips[i].outPoint - 0.2)
                        } else {
                            p.clips[i].outPoint = max(min(fileD, trimOut + delta), p.clips[i].inPoint + 0.2)
                            shown = start + p.clips[i].length - 0.04
                        }
                    }
                    s.seek(shown)
                }
                .onEnded { _ in
                    if let b = trimBefore { s.commit(from: b, undo, left ? "Taglia l’inizio" : "Taglia la fine") }
                    trimBefore = nil
                })
            .help(left ? "Trascina per tagliare l’inizio" : "Trascina per tagliare la fine")
    }

    private struct Slot: Identifiable {
        let clip: VPClip
        let start: Double
        var id: UUID { clip.id }
    }
    private var slots: [Slot] {
        let starts = s.project.starts
        return s.project.clips.enumerated().map { Slot(clip: $0.element, start: starts[$0.offset]) }
    }

    /// Dove c'è una voce dentro la clip (frazioni 0…1 della clip), solo se serve per la musica.
    private func speechMarks(_ c: VPClip, start: Double) -> [ClosedRange<Double>] {
        guard let m = s.project.music, m.duck, s.project.originalAudible, c.length > 0 else { return [] }
        return (s.speech[c.path] ?? []).compactMap { r in
            let a = max(r.lowerBound, c.inPoint), b = min(r.upperBound, c.outPoint)
            return b > a ? ((a - c.inPoint) / c.length)...((b - c.inPoint) / c.length) : nil
        }
    }

    @ViewBuilder private func musicRow(total: Double, pps: CGFloat, width: CGFloat) -> some View {
        if let m = s.project.music {
            let start = min(max(0, m.offset), total)
            let end = s.musicEnd ?? total
            let w = max(24, CGFloat(max(0.1, end - start)) * pps)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.ink.opacity(0.04))
                HStack(spacing: 6) {
                    Image(systemName: m.loop ? "repeat" : "music.note").font(.system(size: 10, weight: .bold))
                    Text(m.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .foregroundStyle(Theme.ink)
                .frame(width: min(w, max(24, width - CGFloat(start) * pps)), height: 26, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.color(.audio).opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.color(.audio), lineWidth: 1))
                .offset(x: CGFloat(start) * pps)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if dragBefore == nil { dragBefore = s.project; dragStartOffset = m.offset }
                        let o = min(max(0, dragStartOffset + Double(v.translation.width / pps)), max(0, total - 0.5))
                        s.live { $0.music?.offset = o }
                    }
                    .onEnded { _ in
                        if let b = dragBefore { s.commit(from: b, undo, "Sposta la musica") }
                        dragBefore = nil
                    })
                .onTapGesture { openMusic() }
                .help("Trascina per decidere dove parte la musica nel video")
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Button(action: openMusic) {
                Label("Aggiungi musica", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ClipBlock: View {
    let clip: VPClip
    let thumbs: [NSImage]
    let fileDuration: Double
    let selected: Bool
    let tint: Color
    let speech: [ClosedRange<Double>]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(tint.opacity(0.35))
                let shown = visibleThumbs
                if !shown.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: g.size.width / CGFloat(shown.count), height: g.size.height)
                                .clipped()
                        }
                    }
                }
                // Tratti con voce: una riga sottile in basso
                ForEach(Array(speech.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Theme.color(.audio))
                        .frame(width: max(2, CGFloat(r.upperBound - r.lowerBound) * g.size.width), height: 4)
                        .offset(x: CGFloat(r.lowerBound) * g.size.width)
                }
                Text(formatShort(clip.length))
                    .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.55)))
                    .foregroundStyle(Color.white)
                    .padding(4)
                    .opacity(g.size.width > 44 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.brass : Color.black.opacity(0.15), lineWidth: selected ? 3 : 1))
        }
    }

    /// Le miniature del pezzo di file usato dalla clip (il file intero ne ha 16, distribuite).
    private var visibleThumbs: [NSImage] {
        guard !thumbs.isEmpty, fileDuration > 0 else { return [] }
        let n = thumbs.count
        let picked = thumbs.enumerated().filter { i, _ in
            let t = fileDuration * (Double(i) + 0.5) / Double(n)
            return t >= clip.inPoint - fileDuration / Double(n) / 2 && t <= clip.outPoint + fileDuration / Double(n) / 2
        }.map { $0.element }
        return picked.isEmpty ? [thumbs[min(n - 1, Int(clip.inPoint / fileDuration * Double(n)))]] : picked
    }
}
