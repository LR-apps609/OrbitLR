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
    /// 2.9.10 · L'ultima versione confermata (salvata). Le modifiche si vedono subito in `project`;
    /// diventano definitive con «Applica», oppure si buttano con «Annulla».
    @Published private(set) var saved = VideoProject()
    /// 2.9.10 · «Prima/dopo»: l'anteprima mostra la versione confermata
    @Published var showingBefore = false { didSet { if showingBefore != oldValue { scheduleRebuild() } } }
    /// 2.9.10 · Chiede al pannello Testi di mettere il cursore nel campo del testo
    @Published var focusTextPending = false
    /// 2.9.10 · Si sta scrivendo in un campo: i tasti singoli (Spazio, S, ⌫) non comandano il video.
    /// Era il guasto dei testi della 2.9.9: scrivendo una «s» la clip si divideva, con ⌫ spariva.
    @Published var typing = false
    @Published private(set) var infos: [String: VPMediaInfo] = [:]
    @Published private(set) var speech: [String: [ClosedRange<Double>]] = [:]
    @Published private(set) var analyzing: Set<String> = []
    @Published private(set) var thumbs: [String: [NSImage]] = [:]
    @Published private(set) var building = false
    @Published var selected: UUID? = nil
    /// 2.9.9 · il testo che si sta modificando
    @Published var selectedText: UUID? = nil
    @Published var notice: String? = nil
    @Published var lastJob: Job? = nil
    /// 2.7.3 · Il progetto aperto (nil = si vede la schermata Progetti) e l'elenco dei progetti salvati.
    @Published private(set) var currentID: UUID? = nil
    @Published private(set) var library: [VPEntry] = []
    @Published private(set) var covers: [UUID: NSImage] = [:]
    let folder: URL

    let clock = PlayClock()
    /// 3.4.6 · Il lettore dell'anteprima. Dopo una modifica se ne prepara uno nuovo e si scambia solo quando
    /// è pronto sullo stesso punto: niente schermo nero tra la versione vecchia e quella nuova.
    @Published private(set) var player = AVPlayer()
    /// 3.5 · Il lettore nuovo, già sul punto giusto, che aspetta di avere l'immagine pronta sullo schermo
    @Published private(set) var incoming: AVPlayer? = nil
    /// I lettori da mostrare: quello attuale e, durante lo scambio, quello nuovo (invisibile finché non è pronto)
    var screens: [AVPlayer] { incoming.map { [player, $0] } ?? [player] }
    private var promoteFallback: DispatchWorkItem?
    private var observer: Any?
    /// 3.4.6 · Spostamenti dell'indicatore «a inseguimento»: uno alla volta, sempre verso l'ultimo punto chiesto
    private var seekTarget: Double? = nil
    private var seeking = false
    private var rebuildTask: Task<Void, Never>?
    private var saveWork: DispatchWorkItem?
    private var loading: Set<String> = []
    private(set) var previewDuration: Double = 0
    /// 3.5.1 · La durata del lettore nuovo, in attesa dello scambio
    private var pendingDuration: Double? = nil

    private var saveURL: URL? { currentID.map { VideoProjectLibrary.url(for: $0, in: folder) } }

    init(folder: URL = VideoProjectLibrary.folder) {
        self.folder = folder
        attachObserver()
        if folder == VideoProjectLibrary.folder { VideoProjectLibrary.migrateLegacy(to: folder) }
        refreshLibrary()
    }

    /// L'indicatore segue la riproduzione a 60 immagini al secondo (prima 20: si muoveva a scatti).
    private func attachObserver() {
        if let o = observer { observerPlayer?.removeTimeObserver(o) }
        observerPlayer = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            guard let self, !self.seeking else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            if abs(self.clock.time - s) > 0.001 { self.clock.time = s }
            if self.clock.playing, self.previewDuration > 0, s >= self.previewDuration - 0.04 { self.pause() }
        }
    }
    private weak var observerPlayer: AVPlayer?

    // MARK: Stato derivato

    var canvasSize: CGSize {
        guard let c = project.clips.first(where: { self.infos[$0.path]?.hasVideo == true }), let i = infos[c.path] else { return .zero }
        // 2.9.8 · prima clip ruotata di 90°: la tela è girata
        if let f = c.fx, (((f.rotate % 360) + 360) % 360) % 180 == 90 { return CGSize(width: i.displaySize.height, height: i.displaySize.width) }
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

    // MARK: 2.9.10 · Modifiche da confermare

    /// Ci sono modifiche visibili nell'anteprima ma non ancora confermate.
    var hasPending: Bool { currentID != nil && project != saved }

    /// «Applica»: le modifiche diventano definitive e si salvano.
    func applyChanges() {
        guard project != saved else { return }
        saved = project
        scheduleSave()
    }

    /// «Annulla»: si torna all'ultima versione confermata.
    func discardChanges(_ undo: UndoManager?) {
        guard project != saved else { return }
        showingBefore = false
        apply(saved)
        undo?.removeAllActions(withTarget: self)
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
        // 2.9.10 · niente salvataggio qui: si salva con «Applica» (o chiudendo il progetto, o esportando)
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
            // 3.0 · Prima un fotogramma solo, a metà clip: le miniature dei filtri sono pronte subito
            let middle = await TrimModel.thumbnails(url: URL(fileURLWithPath: path), count: 1, duration: duration)
            if let m = middle.first { self?.warmLooks(path, frame: m) }
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
        Perf.begin(.previewRebuild)
        let p = showingBefore ? saved : project, inf = infos, sp = speech
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            guard p.clips.contains(where: { inf[$0.path] != nil }) else {
                self.pause()
                self.player.replaceCurrentItem(with: nil)
                self.incoming = nil
                self.previewDuration = 0; self.pendingDuration = nil
                return
            }
            self.building = true
            let built = try? await VideoProjectBuilder.build(p, infos: inf, speech: sp, maxSide: 1280)
            self.building = false
            guard !Task.isCancelled else { return }
            guard let built else {
                self.pause()
                self.player.replaceCurrentItem(with: nil)
                self.incoming = nil
                self.previewDuration = 0; self.pendingDuration = nil
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral          // 2.9.8 · clip più veloci o lente: la voce non cambia tono
            let t = min(self.clock.time, max(0, built.duration - 0.05))
            // 3.4.6 · Il lettore nuovo si prepara dietro le quinte, già sul punto giusto; poi si scambia
            let next = AVPlayer(playerItem: item)
            next.automaticallyWaitsToMinimizeStalling = false
            _ = await next.seek(to: VideoProjectBuilder.cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            let now = min(self.clock.time, max(0, built.duration - 0.05))
            if abs(now - t) > 0.02 { _ = await next.seek(to: VideoProjectBuilder.cm(now), toleranceBefore: .zero, toleranceAfter: .zero) }
            guard !Task.isCancelled else { return }
            self.pendingDuration = built.duration
            // Si mostra, invisibile, sopra quello vecchio; lo scambio avviene quando ha l'immagine pronta
            // (o dopo mezzo secondo al massimo, se nessuno lo sta guardando)
            if let pending = self.incoming, pending !== next { pending.replaceCurrentItem(with: nil) }
            self.incoming = next
            Perf.end(.previewRebuild)                          // il lettore nuovo è pronto sul punto giusto
            self.promoteFallback?.cancel()
            // Nessuna finestra la mostra (app in barra, test): niente da aspettare, si scambia subito
            guard AppState.shared.mainWindow?.isVisible == true else { self.promote(next); return }
            let w = DispatchWorkItem { [weak self, weak next] in if let next { self?.promote(next) } }
            self.promoteFallback = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
    }

    /// 3.5 · Il lettore nuovo prende il posto di quello vecchio, senza fotogrammi neri in mezzo.
    func promote(_ next: AVPlayer) {
        guard incoming === next else { return }
        promoteFallback?.cancel()
        let wasPlaying = clock.playing
        let old = player
        // 3.5.1 · La durata nuova vale solo da adesso: fino allo scambio il lettore vecchio usa la sua
        if let d = pendingDuration { previewDuration = d; pendingDuration = nil }
        let now = min(clock.time, max(0, previewDuration - 0.05))
        let needsSeek = abs(next.currentTime().seconds - now) > 0.05
        old.pause()
        player = next
        incoming = nil
        attachObserver()
        old.replaceCurrentItem(with: nil)
        if needsSeek {
            // L'indicatore non torna indietro e il video riparte solo quando l'immagine è sul punto giusto
            seeking = true
            next.seek(to: VideoProjectBuilder.cm(now), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.seeking = false
                    if wasPlaying, self.clock.playing, self.player === next { next.play() }
                    self.chaseSeek()
                }
            }
        } else if wasPlaying {
            next.play()
        }
    }

    func togglePlay() { clock.playing ? pause() : play() }

    /// 3.4.8 · Passo dalla tastiera: un fotogramma (1/30 s) o un secondo, avanti o indietro.
    func step(_ seconds: Double) {
        if clock.playing { pause() }
        seek(clock.time + seconds)
    }

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
        clock.time = v                      // l'indicatore si sposta subito, l'immagine lo raggiunge
        seekTarget = v
        chaseSeek()
    }

    /// 3.4.6 · Un solo spostamento alla volta; quando finisce, se nel frattempo il dito è andato altrove, si va lì.
    /// Così trascinando l'indicatore l'immagine segue senza accumulare ritardo.
    private func chaseSeek() {
        guard !seeking, let target = seekTarget else { return }
        seekTarget = nil
        seeking = true
        let p = player
        p.seek(to: VideoProjectBuilder.cm(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.player !== p, self.seekTarget == nil { self.seekTarget = target }      // lettore scambiato nel frattempo
                self.chaseSeek()
            }
        }
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
            Self.splitExtras(&a, &b)
            p.clips.replaceSubrange(hit.index...hit.index, with: [a, b])
        }
    }

    /// 2.9.8 · Dividendo una clip: la transizione resta prima del primo pezzo, la dissolvenza in entrata al primo,
    /// quella in uscita al secondo (prima finivano su entrambi).
    static func splitExtras(_ a: inout VPClip, _ b: inout VPClip) {
        b.transition = nil
        a.fx?.fadeOut = 0
        b.fx?.fadeIn = 0
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

    /// 2.7.4 · Accende o spegne l'audio della clip scelta.
    func toggleClipAudio(_ undo: UndoManager?) {
        guard let i = targetIndex else { NSSound.beep(); return }
        let off = !project.clips[i].isMuted
        change(undo, off ? "Spegni l’audio della clip" : "Riaccendi l’audio della clip") { $0.clips[i].muted = off ? true : nil }
    }

    /// 2.7.4 · Toglie l'audio da qui alla fine della clip (divide nel punto dell'indicatore).
    func muteFromHere(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { NSSound.beep(); return }
        let c = project.clips[hit.index]
        guard hit.local - c.inPoint > 0.1, c.outPoint - hit.local > 0.1 else {
            change(undo, "Spegni l’audio della clip") { $0.clips[hit.index].muted = true }
            return
        }
        change(undo, "Spegni l’audio da qui") { p in
            var a = c, b = c
            a.outPoint = hit.local
            b.id = UUID()
            b.inPoint = hit.local
            Self.splitExtras(&a, &b)
            b.muted = true
            p.clips.replaceSubrange(hit.index...hit.index, with: [a, b])
        }
    }

    func deleteClip(_ undo: UndoManager?) {
        guard let i = targetIndex else { NSSound.beep(); return }
        change(undo, "Elimina la clip") { $0.clips.remove(at: i) }
        selected = nil
    }

    /// 2.7.3 · Apre un progetto nuovo e vuoto (quello aperto resta salvato tra i Progetti).
    func newProject(_ undo: UndoManager?) {
        closeProject(undo)
        var p = VideoProject()
        p.name = VideoProjectLibrary.uniqueName(existing: library.map { $0.name })
        currentID = UUID()
        project = p
        saved = p
        scheduleRebuild()
    }

    /// 2.7.3 · Riapre un progetto salvato, ritrovando i file spostati.
    func openProject(_ id: UUID, undo: UndoManager?) {
        closeProject(undo)
        guard var p = VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: folder)) else {
            notice = "Questo progetto non si apre più."
            refreshLibrary()
            return
        }
        notice = Self.relink(&p)
        currentID = id
        project = p
        saved = p
        ensureLoaded()
        ensureSpeech()
        scheduleRebuild()
    }

    /// 2.7.3 · Chiude il progetto (resta salvato) e torna alla schermata Progetti.
    func closeProject(_ undo: UndoManager?) {
        pause()
        rebuildTask?.cancel()
        saveWork?.cancel()
        // 2.9.10 · Chiudere tiene le modifiche (la finestra chiede prima, se ce ne sono da confermare)
        saved = project
        showingBefore = false
        saveNow()
        undo?.removeAllActions(withTarget: self)        // il ⌘Z di un progetto non deve toccare un altro
        if let id = currentID { covers[id] = nil }      // la copertina si rifà: la prima clip può essere cambiata
        currentID = nil
        project = VideoProject()
        saved = project
        selected = nil
        selectedText = nil
        notice = nil
        lastJob = nil
        player.replaceCurrentItem(with: nil)
        incoming?.replaceCurrentItem(with: nil)
        incoming = nil
        previewDuration = 0; pendingDuration = nil
        clock.time = 0
        refreshLibrary()
    }

    func renameProject(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if id == currentID { project.name = n; saved.name = n; scheduleSave() } else { VideoProjectLibrary.rename(id, to: n, in: folder) }
        refreshLibrary()
    }

    func duplicateProject(_ id: UUID) {
        if id == currentID { saveNow() }
        _ = VideoProjectLibrary.duplicate(id, in: folder, existing: library.map { $0.name })
        refreshLibrary()
    }

    func deleteProject(_ id: UUID, undo: UndoManager?) {
        if id == currentID { closeProject(undo) }
        VideoProjectLibrary.trash(id, in: folder)
        covers[id] = nil
        refreshLibrary()
    }

    func refreshLibrary() {
        library = VideoProjectLibrary.list(in: folder)
        for e in library where covers[e.id] == nil {
            guard let path = e.coverPath else { continue }
            let id = e.id, t = e.coverTime
            Task { @MainActor [weak self] in
                if let img = await VideoProjectLibrary.cover(path: path, at: t) { self?.covers[id] = img }
            }
        }
    }

    // MARK: 2.9 · Miniature dei filtri

    private var lookThumbCache: [String: NSImage] = [:]

    /// La miniatura della clip con un filtro pronto (fatta una volta, poi ricordata).
    /// Il fotogramma usato per le miniature dei filtri, per ogni clip.
    private var lookFrames: [String: NSImage] = [:]

    /// 3.0 · Prepara tutte le miniature dei filtri appena c'è un fotogramma, prima che si apra «Filtri».
    private func warmLooks(_ path: String, frame: NSImage) {
        lookFrames[path] = frame
        for p in VideoLooks.presets {
            var look = VPLook()
            look.preset = p.id
            if lookThumbCache[path + "|" + p.id] == nil, let img = VideoLooks.thumbnail(frame, look: look) {
                lookThumbCache[path + "|" + p.id] = img
            }
        }
        objectWillChange.send()
    }

    func lookThumbnail(_ preset: String, clip i: Int) -> NSImage? {
        guard project.clips.indices.contains(i) else { return nil }
        let path = project.clips[i].path
        let key = path + "|" + preset
        if let hit = lookThumbCache[key] { return hit }
        guard let source = lookFrames[path] ?? thumbs[path].flatMap({ $0.isEmpty ? nil : $0[$0.count / 2] }) else { return nil }
        var look = VPLook()
        look.preset = preset
        guard let img = VideoLooks.thumbnail(source, look: look) else { return nil }
        if lookThumbCache.count > 400 { lookThumbCache.removeAll() }
        lookThumbCache[key] = img
        return img
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
        change(undo, "Rimuovi la musica") { $0.music = nil }
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
        applyChanges()          // 2.9.10 · si esporta quello che si vede, e diventa definitivo
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
        guard let url = saveURL else { return }
        let p = saved
        let w = DispatchWorkItem { VideoProjectLibrary.save(p, to: url) }
        saveWork = w
        VideoProjectLibrary.queue.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Salva subito (alla chiusura del progetto).
    func saveNow() {
        guard let url = saveURL else { return }
        let p = saved
        VideoProjectLibrary.queue.sync { VideoProjectLibrary.save(p, to: url) }   // in coda dopo eventuali salvataggi in corso
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

    /// Ritrova i file spostati; toglie quelli spariti e restituisce l'avviso da mostrare (nil se va tutto bene).
    static func relink(_ p: inout VideoProject) -> String? {
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
        guard !lost.isEmpty else { return nil }
        return "Non trovo più \(lost.joined(separator: " e ")) del progetto: il file è stato cancellato o è su un disco scollegato."
    }
}

// MARK: - La scheda

/// 2.9.10 · Gli strumenti del Video, per categoria (niente più passi numerati): si usa quello che serve, nell'ordine che vuoi.
enum VideoEditTool: String, CaseIterable, Identifiable {
    case clip = "Clip", looks = "Filtri", effects = "Effetti", texts = "Testi", audio = "Audio", format = "Formato"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clip: return "scissors"
        case .looks: return "camera.filters"
        case .effects: return "sparkles"
        case .texts: return "textformat"
        case .audio: return "music.note"
        case .format: return "rectangle.portrait"
        }
    }
    /// Cosa si fa qui, in una frase.
    var hint: String {
        switch self {
        case .clip: return "Taglia, dividi, sposta e togli le clip. I bordi d’ottone di una clip si trascinano per accorciarla."
        case .looks: return "Un filtro per tutto il video o solo per la clip scelta, e le regolazioni di luce e colore."
        case .effects: return "Effetti della clip scelta: velocità, zoom lento, gira, sfocatura, dissolvenze."
        case .texts: return "Titoli e scritte: premi «Testo» sull’anteprima (o il tasto T), poi trascinali dove vuoi."
        case .audio: return "Il volume dei tuoi video e la musica."
        case .format: return "La forma del video e la qualità dell’esportazione."
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var s: VideoProjectStore
    @Environment(\.undoManager) private var undo
    @State private var tool: VideoEditTool = .clip

    init(s: VideoProjectStore, startTool: VideoEditTool = .clip) {
        self.s = s
        _tool = State(initialValue: startTool)
    }
    @State private var targeted = false
    @State private var askClose = false

    private let tint = Theme.color(.video)

    var body: some View {
        if s.currentID == nil {
            VideoProjectsView(s: s)        // 2.7.3 · fase «pre»: prima si sceglie il progetto
        } else {
            editor
        }
    }

    // MARK: 2.9.10 · Disposizione: anteprima e pannello in alto, sequenza sotto

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if s.project.clips.isEmpty {
                MediaDropZone(kind: .video, title: "Trascina qui i video",
                              subtitle: "oppure clicca per sceglierli · MP4, MOV, M4V · più video vanno in fila · un brano audio diventa la musica",
                              targeted: targeted) { choose(audio: false) }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    EditorPreview(s: s, clock: s.clock, editTexts: tool == .texts) { addText() }
                        .frame(minWidth: 280, maxWidth: .infinity)
                    inspector
                        .frame(width: 290)
                }
                .frame(maxHeight: .infinity)
                ProjectTimeline(s: s, clock: s.clock, tint: tint, openMusic: {
                    tool = .audio
                    if s.project.music == nil { choose(audio: true) }
                }, openTexts: { tool = .texts })
                    .frame(height: 142)
            }
            if let n = s.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let job = s.lastJob { JobStrip(job: job) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in Sounds.drop(); s.add(urls, undo: undo) }
            return true
        }
        .onDisappear { s.pause() }
        .background(EditorKeys(s: s))
        .confirmationDialog("Ci sono modifiche non applicate", isPresented: $askClose) {
            Button("Applica e chiudi") { s.applyChanges(); s.closeProject(undo) }
            Button("Scarta e chiudi", role: .destructive) { s.discardChanges(undo); s.closeProject(undo) }
            Button("Continua a modificare", role: .cancel) {}
        } message: {
            Text("Vuoi tenere le modifiche che vedi nell’anteprima?")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VideoProjectLibrary.displayName(s.project))
                    .font(.system(size: s.project.clips.isEmpty ? 22 : 15, weight: .bold, design: s.project.clips.isEmpty ? .rounded : .default))
                    .lineLimit(1)
                if !s.project.clips.isEmpty {
                    Text("\(s.project.clips.count) clip · \(formatShort(s.project.duration))" + (s.project.music != nil ? " · con musica" : "")
                         + (s.estimate.map { " · ≈ " + Fmt.bytes($0.bytes) } ?? ""))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if s.building { ProgressView().controlSize(.small).help("Preparo l’anteprima") }
            Spacer(minLength: 8)
            if !s.project.clips.isEmpty {
                Button { undo?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annulla l’ultima modifica (⌘Z)").accessibilityLabel("Annulla l’ultima modifica")
                Button { undo?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Ripeti (⇧⌘Z)").accessibilityLabel("Ripeti")
                Button { choose(audio: false) } label: { Label("Video", systemImage: "plus") }
                    .help("Aggiungi altri video in fondo")
                Button("Esporta") { s.export() }
                    .primaryButton(!s.hasPending)      // 3.0 · un solo pulsante principale: con modifiche in sospeso è «Applica»
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Crea il video finale (⌘E). Le modifiche in sospeso vengono applicate")
            }
            // 2.7.3 · ✕ in alto a destra: chiude il progetto (resta salvato) e torna ai Progetti
            Button { if s.hasPending { askClose = true } else { s.closeProject(undo) } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.ink.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [.command])
            .accessibilityLabel("Chiudi il progetto")
            .help("Chiudi il progetto e torna ai Progetti · ⌘Esc")
        }
    }

    // MARK: Pannello a destra: strumenti · opzioni · Annulla/Applica

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(VideoEditTool.allCases) { t in
                    ToolTab(tool: t, selected: tool == t, used: used(t), tint: tint) { tool = t }
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tool.hint).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    options
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            if s.hasPending || s.showingBefore { pendingBar }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 2.9.10 · Le modifiche si vedono subito; qui si confermano o si buttano.
    private var pendingBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Text("Prima / dopo")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(s.showingBefore ? Theme.brass.opacity(0.35) : Theme.ink.opacity(0.07)))
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, perform: {}, onPressingChanged: { s.showingBefore = $0 })
                    .help("Tieni premuto per vedere com’era prima delle modifiche")
                    .accessibilityAddTraits(.isButton)
                Spacer(minLength: 4)
                Button("Scarta") { s.discardChanges(undo) }
                    .help("Butta le modifiche non applicate e torna all’ultima versione applicata")
                Button("Applica") { s.applyChanges() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Rendi definitive le modifiche (⌘↩)")
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .background(Theme.brass.opacity(0.08))
    }

    /// Un pallino sullo strumento se nel progetto c'è già qualcosa di suo.
    private func used(_ t: VideoEditTool) -> Bool {
        switch t {
        case .clip: return s.project.clips.count > 1
        case .looks: return !(s.project.look?.isIdentity ?? true) || s.project.clips.contains { !($0.look?.isIdentity ?? true) }
        case .effects: return s.project.clips.contains { !($0.fx?.isIdentity ?? true) } || s.project.hide != nil
        case .texts: return !(s.project.texts ?? []).isEmpty
        case .audio: return s.project.music != nil || s.project.originalMuted
        case .format: return s.project.aspect != "orig"
        }
    }

    @ViewBuilder private var options: some View {
        switch tool {
        case .clip: clipOptions
        case .looks: LookOptions(s: s, undo: undo, tint: tint)
        case .effects: EffectOptions(s: s, undo: undo, tint: tint)
        case .texts: TextOptions(s: s, undo: undo, tint: tint, add: addText)
        case .audio:
            originalOptions
            Divider()
            musicOptions
        case .format: formatOptions
        }
    }

    private func addText() {
        tool = .texts
        TextOptions.addText(s, undo: undo)
    }

    private var clipOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let i = s.targetIndex, s.project.clips.indices.contains(i) {
                let c = s.project.clips[i]
                Text("Clip \(i + 1) di \(s.project.clips.count) · \(formatShort(c.length))" + (abs(c.speed - 1) > 0.001 ? " · " + EffectOptions.speedLabel(c.speed) : ""))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            SectionLabel(text: "Taglia")
            HStack(spacing: 6) {
                Button("Inizio qui") { s.trimStartHere(undo) }.help("Taglia la clip da qui in poi")
                Button("Fine qui") { s.trimEndHere(undo) }.help("Taglia la clip fino a qui")
                Button("Dividi") { s.split(undo) }
                    .keyboardShortcut(s.typing ? nil : KeyboardShortcut("s", modifiers: []))
                    .help("Divide la clip nel punto dell’indicatore (S)")
            }
            HStack(spacing: 6) {
                Button { s.move(-1, undo) } label: { Label("Prima", systemImage: "arrow.left") }.help("Sposta la clip prima")
                Button { s.move(1, undo) } label: { Label("Dopo", systemImage: "arrow.right") }.help("Sposta la clip dopo")
                Button("Intera") { s.restoreClip(undo) }.help("Riporta la clip alla sua durata intera")
            }
            // 4.0 · Le pause lunghe spariscono da sole (tagli netti, come nei video dei social)
            Button { s.removeSilences(undo) } label: { Label("Togli i silenzi", systemImage: "waveform.badge.minus") }
                .help("Ascolta la clip e toglie le pause lunghe: restano solo i pezzi in cui si parla. ⌘Z per tornare indietro")
            SectionLabel(text: "Audio della clip")
            HStack(spacing: 6) { clipAudioButtons }
            if let i = s.targetIndex, i > 0, s.project.clips.indices.contains(i) {
                SectionLabel(text: "Transizione prima di questa clip")
                Text("Oppure clicca il pallino tra due clip nella sequenza.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                TransitionOptions(s: s, clipID: s.project.clips[i].id, tint: tint, undo: undo, compact: true)
            }
            SectionLabel(text: "Altro")
            HStack(spacing: 6) {
                Button(role: .destructive) { s.deleteClip(undo) } label: { Label("Togli", systemImage: "trash") }
                    .keyboardShortcut(s.typing ? nil : KeyboardShortcut(.delete, modifiers: []))
                    .help("Togli la clip dal montaggio (⌫ · si può annullare con ⌘Z; il tuo video resta dov’è)")
                otherMenu
            }
        }
    }

    private var otherMenu: some View {
        Menu {
            Button("Estrai l’audio (M4A)") { quick("to:m4a", param: "") }
            Button("Estrai l’audio (MP3)") { quick("to:mp3", param: "") }
            Button("GIF della clip") { quickGIF() }
            Button("Comprimi la clip a 25 MB") { quick("vcompress", param: "25") }
        } label: {
            Label("Dal video originale", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Audio, GIF o versione compressa del video originale di questa clip")
    }

    @ViewBuilder private var musicOptions: some View {
        SectionLabel(text: "Musica")
        if let m = s.project.music {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(m.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Cambia…") { choose(audio: true) }
                    Button(role: .destructive) { s.removeMusic(undo) } label: { Image(systemName: "trash") }.help("Rimuovi la musica")
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    Button("Parte qui") { s.musicStartHere(undo) }
                        .help("La musica comincia nel punto dell’indicatore (oppure trascina la barra della musica)")
                    Button("Finisce col video") { s.alignMusicEnd(undo) }
                        .help("Sceglie da dove far partire la canzone perché finisca insieme al video")
                }
                .controlSize(.small)
                Toggle("Ripeti finché il video finisce", isOn: bind(\.loop, "Ripeti la musica")).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                if let sd = s.songDuration, sd > 1 {
                    EditSlider(title: "Parte dal", value: m.inPoint, range: 0...max(1, sd - 1), text: formatShort(m.inPoint),
                               width: 260, s: s, undo: undo, name: "Punto della canzone") { p, v in p.music?.inPoint = v }
                }
                EditSlider(title: "Volume", value: m.volume, range: 0...1, text: "\(Int((m.volume * 100).rounded()))%",
                           width: 260, s: s, undo: undo, name: "Volume della musica") { p, v in p.music?.volume = v }
                HStack(spacing: 12) {
                    EditSlider(title: "Entrata", value: m.fadeIn, range: 0...5, text: Fmt.secs(m.fadeIn),
                               width: 124, s: s, undo: undo, name: "Dissolvenza in entrata") { p, v in p.music?.fadeIn = v }
                    EditSlider(title: "Uscita", value: m.fadeOut, range: 0...5, text: Fmt.secs(m.fadeOut),
                               width: 124, s: s, undo: undo, name: "Dissolvenza in uscita") { p, v in p.music?.fadeOut = v }
                }
                Toggle("Abbassa quando si parla", isOn: bind(\.duck, "Abbassa quando si parla")).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                if !s.analyzing.isEmpty {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Cerco le voci…") }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if m.duck && !s.project.originalAudible {
                    Text("L’audio originale è spento").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if m.duck {
                    Text("\(s.speechOnTimeline.count) tratti con voce").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        } else {
            Button { choose(audio: true) } label: { Label("Scegli la musica…", systemImage: "music.note") }
            Text("oppure trascina un brano sulla scheda").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func bind(_ key: WritableKeyPath<VPMusic, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { s.project.music?[keyPath: key] ?? false },
                set: { v in s.change(undo, name) { $0.music?[keyPath: key] = v } })
    }

    /// 2.7.4 · L'audio della singola clip: spento tutto, o da un punto in poi.
    @ViewBuilder private var clipAudioButtons: some View {
        let muted = s.targetIndex.map { s.project.clips[$0].isMuted } ?? false
        Button { s.toggleClipAudio(undo) } label: {
            Label(muted ? "Riaccendi" : "Spegni", systemImage: muted ? "speaker.wave.2" : "speaker.slash")
        }
        .help(muted ? "Riaccende l’audio di questa clip" : "Spegne l’audio solo di questa clip (la musica resta)")
        Button { s.muteFromHere(undo) } label: { Label("Spegni da qui", systemImage: "speaker.slash.circle") }
            .help("Spegne l’audio dall’indicatore alla fine della clip. Per un tratto in mezzo: dividi (S) e togli l’audio solo da quel pezzo")
    }

    @ViewBuilder private var originalOptions: some View {
        SectionLabel(text: "Audio dei video")
        Toggle("Muto", isOn: Binding(get: { s.project.originalMuted },
                                      set: { v in s.change(undo, v ? "Audio originale muto" : "Audio originale attivo") { $0.originalMuted = v } }))
            .toggleStyle(.checkbox)
        EditSlider(title: "Volume", value: s.project.originalVolume, range: 0...1,
                   text: "\(Int((s.project.originalVolume * 100).rounded()))%", width: 260, s: s, undo: undo,
                   name: "Volume dell’audio originale") { p, v in p.originalVolume = v }
            .disabled(s.project.originalMuted)
    }

    @ViewBuilder private var formatOptions: some View {
        SectionLabel(text: "Forma")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
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
        SectionLabel(text: "Qualità dell’esportazione")
        HStack(spacing: 6) {
            ForEach([(720, "HD 720p"), (1080, "Full HD 1080p"), (2160, "4K")], id: \.0) { item in
                Chip(title: item.1, selected: s.project.resolution == item.0, tint: tint) {
                    s.change(undo, "Risoluzione \(item.1)") { $0.resolution = item.0 }
                }
            }
        }
        HStack(spacing: 6) {
            ForEach([30, 60], id: \.self) { f in
                Chip(title: f == 60 ? "Più fluido (60)" : "Normale (30)", selected: s.project.fps == f, tint: tint) {
                    s.change(undo, "\(f) fotogrammi al secondo") { $0.fps = f }
                }
                .help(f == 60 ? "Solo se i video sono girati a 60: non si inventano fotogrammi" : "")
            }
        }
        if let e = s.estimate {
            Text("\(Int(e.size.width)) × \(Int(e.size.height)) · circa " + Fmt.bytes(e.bytes))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Azioni

    private func choose(audio: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = !audio
        p.canChooseDirectories = false
        p.allowedContentTypes = audio ? [.audio, .movie] : [.movie]
        p.prompt = audio ? "Scegli" : "Aggiungi"
        let store = s, undo = undo
        Sheet.choose(p) { urls in
            guard !urls.isEmpty else { return }
            if audio, let u = urls.first {
                Task { @MainActor in await store.setMusic(u, undo: undo) }
            } else {
                store.add(urls, undo: undo)
            }
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

/// 3.4.8 · I tasti del montaggio. Spenti mentre scrivi un testo (così le lettere restano lettere).
private struct EditorKeys: View {
    @ObservedObject var s: VideoProjectStore

    var body: some View {
        Group {
            key("j", []) { s.step(-1) }
            key("k", []) { s.pause() }
            key("l", []) { if !s.clock.playing { s.play() } }
            key(.leftArrow, []) { arrow(-1) { s.step(-1.0 / 30) } }
            key(.rightArrow, []) { arrow(1) { s.step(1.0 / 30) } }
            key(.leftArrow, .shift) { arrow(-1) { s.step(-1) } }
            key(.rightArrow, .shift) { arrow(1) { s.step(1) } }
            key(.home, []) { s.pause(); s.seek(0) }
            key(.end, []) { s.pause(); s.seek(s.project.duration) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(s.typing || s.project.clips.isEmpty)
    }

    private func key(_ k: KeyEquivalent, _ m: EventModifiers, _ action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: m).buttonStyle(.plain)
    }

    /// 3.5.2 · Se hai scelto un cursore (o un selettore) con la tastiera, le frecce muovono lui, non l'indicatore.
    private func arrow(_ dir: Int, otherwise: () -> Void) {
        if let r = NSApp.keyWindow?.firstResponder as? NSView,
           r is NSSlider || r is NSStepper || r is NSSegmentedControl || r is NSPopUpButton {
            NSApp.sendAction(dir < 0 ? #selector(NSResponder.moveLeft(_:)) : #selector(NSResponder.moveRight(_:)), to: r, from: nil)
            return
        }
        otherwise()
    }
}

/// 2.9.10 · Uno strumento del pannello: icona e nome, sempre visibili (3.0: lo usano Video e Audio).
struct ToolTab: View {
    let title: String
    let symbol: String
    let hint: String
    let selected: Bool
    var used = false
    let tint: Color
    let action: () -> Void

    init(tool: VideoEditTool, selected: Bool, used: Bool, tint: Color, action: @escaping () -> Void) {
        self.init(title: tool.rawValue, symbol: tool.symbol, hint: tool.hint, selected: selected, used: used, tint: tint, action: action)
    }

    init(title: String, symbol: String, hint: String, selected: Bool, used: Bool = false, tint: Color, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.hint = hint
        self.selected = selected; self.used = used; self.tint = tint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? tint : Theme.ink.opacity(0.05)))
            .overlay(alignment: .topTrailing) {
                if used && !selected { Circle().fill(Theme.brass).frame(width: 6, height: 6).padding(5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(Pressable())
        .help(hint)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
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
    /// 3.5 · Non osservato qui: solo la barra in basso (e i testi) si aggiornano 60 volte al secondo
    let clock: PlayClock
    /// 2.9.9 · nel passo «Testi» i testi si trascinano sull'anteprima
    var editTexts = false
    /// 2.9.10 · «T+ Testo» sull'anteprima
    var addText: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 3.5 · Due lettori sovrapposti durante lo scambio: quello nuovo resta invisibile finché
            // non ha davvero l'immagine pronta, poi prende il posto del vecchio (niente nero)
            ZStack {
                ForEach(s.screens, id: \.self) { p in
                    PlayerPreview(player: p, onReady: p === s.incoming ? { s.promote(p) } : nil)
                        .opacity(p === s.incoming ? 0.001 : 1)
                }
            }
            .background(Color.black)
            if let r = s.project.aspectRatio {
                FormatFrame(canvas: s.canvasSize, ratio: r).allowsHitTesting(false)
            }
            if editTexts { TextDragLayer(s: s, clock: clock) }
            // 2.9.10 · Aggiungere un testo è sempre a un clic, sopra al video
            VStack {
                HStack {
                    if s.showingBefore {
                        Text("PRIMA").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.brass)).foregroundStyle(.white)
                    }
                    Spacer()
                    Button(action: addText) {
                        Label("Testo", systemImage: "textformat")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .help("Aggiungi un testo qui (T)")
                    .keyboardShortcut(s.typing ? nil : KeyboardShortcut("t", modifiers: []))
                }
                Spacer()
            }
            .padding(10)
            PlaybackBar(s: s, clock: clock)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 200)
    }
}

/// 3.5 · Riproduci/pausa e tempo: l'unica parte dell'anteprima che cambia a ogni fotogramma.
private struct PlaybackBar: View {
    @ObservedObject var s: VideoProjectStore
    @ObservedObject var clock: PlayClock

    var body: some View {
        HStack {
            Button { s.togglePlay() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.9)))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(Pressable())
            .keyboardShortcut(s.typing ? nil : KeyboardShortcut(.space, modifiers: []))
            .help("Riproduci / pausa (Spazio)")
            .accessibilityLabel(clock.playing ? "Pausa" : "Riproduci")
            Spacer()
            Text("\(formatTime(clock.time)) / \(formatTime(s.project.duration))")
                .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(10)
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

/// 3.4.5 · Aggancio morbido nella sequenza: entro 6 punti da un bordo di clip, dall'inizio o dall'indicatore,
/// il valore si ferma lì, con un piccolo colpo del trackpad (una volta sola per aggancio).
enum Snap {
    static let reach: CGFloat = 6
    private static var engaged: [String: Double] = [:]

    /// Inizio, fine di ogni clip e indicatore, in secondi del montaggio.
    static func marks(_ p: VideoProject, playhead: Double) -> [Double] {
        var m: [Double] = [0, playhead, p.duration]
        for (c, st) in zip(p.clips, p.starts) { m.append(st); m.append(st + c.length) }
        return m
    }

    static func to(_ value: Double, _ marks: [Double], pps: CGFloat, id: String) -> Double {
        let near = marks.min { abs($0 - value) < abs($1 - value) }
        guard let n = near, CGFloat(abs(n - value)) * pps <= reach else { engaged[id] = nil; return value }
        if engaged[id] != n {
            engaged[id] = n
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return n
    }

    static func reset() { engaged = [:] }
}

private struct ProjectTimeline: View {
    @ObservedObject var s: VideoProjectStore
    let clock: PlayClock
    let tint: Color
    let openMusic: () -> Void
    /// 2.9.10 · clic su un testo della sequenza: si apre lo strumento Testi
    var openTexts: () -> Void = {}
    @Environment(\.undoManager) private var undo
    @State private var dragBefore: VideoProject? = nil
    @State private var textDrag: (id: UUID, start: Double, end: Double, mode: Int)? = nil
    @State private var dragStartOffset: Double = 0
    @State private var moving: UUID? = nil
    @State private var moveDX: CGFloat = 0
    @State private var trimBefore: VideoProject? = nil
    @State private var trimIn: Double = 0
    @State private var trimOut: Double = 0
    @State private var frozenPPS: CGFloat = 1
    @State private var transitionFor: UUID? = nil

    var body: some View {
        GeometryReader { g in
            let total = max(s.project.duration, 0.1)
            let pps = g.size.width / CGFloat(total)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler(total: total, pps: pps, width: g.size.width)
                        .frame(height: 16)
                    clipsRow(pps: pps)
                        .frame(height: 52)
                    textsRow(total: total, pps: pps, width: g.size.width)
                        .frame(height: 22)
                    musicRow(total: total, pps: pps, width: g.size.width)
                        .frame(height: 26)
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
                    .equatable()
                    .frame(width: w)
                    // 2.7.7 · VoiceOver: «Clip 2 di 3, 0:05, senza audio»
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.spokenLabel(index: s.project.clips.firstIndex { $0.id == c.id } ?? 0, of: s.project.clips.count))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(s.selected == c.id ? .isSelected : [])
                    .accessibilityAction { s.selected = c.id }
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
                            .accessibilityLabel("Togli la clip")
                        }
                    }
                    // 2.9.3 · Il pallino tra due clip: la transizione
                    .overlay(alignment: .bottomLeading) {
                        if c.id != s.project.clips.first?.id && moving == nil {
                            transitionButton(c)
                                .offset(x: -10, y: -4)
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

    /// 2.9.3 · Pulsante della transizione prima della clip `c`.
    private func transitionButton(_ c: VPClip) -> some View {
        let tr = c.transition
        let symbol = tr.flatMap { t in VPTransition.kinds.first { $0.id == t.kind }?.symbol } ?? "plus"
        return Button { transitionFor = c.id } label: {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tr == nil ? Theme.ink.opacity(0.7) : Color.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tr == nil ? Theme.cream : Theme.brass))
                .overlay(Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .help(tr == nil ? "Aggiungi una transizione" : "Transizione: " + VPTransition.name(tr!.kind))
        .accessibilityLabel(tr == nil ? "Aggiungi transizione" : "Transizione " + VPTransition.name(tr!.kind))
        .popover(isPresented: Binding(get: { transitionFor == c.id }, set: { if !$0 { transitionFor = nil } }), arrowEdge: .top) {
            TransitionOptions(s: s, clipID: c.id, tint: tint, undo: undo)
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
                    // 2.9.8 · I punti sulla sequenza sono secondi del montaggio: nel file valgono «velocità» volte tanto
                    let delta = Double(v.translation.width / frozenPPS) * c.speed
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
            return b > a ? ((a - c.inPoint) / c.sourceLength)...((b - c.inPoint) / c.sourceLength) : nil
        }
    }

    /// 2.9.10 · La riga dei testi: ogni testo è un blocco. Clic = sceglilo; trascina il centro = spostalo;
    /// trascina i bordi = cambia inizio e fine.
    @ViewBuilder private func textsRow(total: Double, pps: CGFloat, width: CGFloat) -> some View {
        let texts = s.project.texts ?? []
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.04))
            if texts.isEmpty {
                Text("Testi: premi «Testo» sull’anteprima").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.leading, 8).frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            ForEach(texts) { t in
                let x = CGFloat(t.start) * pps, w = max(14, CGFloat(t.end - t.start) * pps)
                let on = s.selectedText == t.id
                HStack(spacing: 0) {
                    edge(t, mode: 1, pps: pps, total: total)
                    Text(t.text.isEmpty ? "Testo" : t.text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in moveText(t, by: v.translation.width, pps: pps, total: total, mode: 0) }
                            .onEnded { _ in endTextDrag() })
                        .onTapGesture { s.selectedText = t.id; openTexts(); s.seek(t.start + 0.05) }
                    edge(t, mode: 2, pps: pps, total: total)
                }
                .frame(width: w, height: 20)
                .foregroundStyle(on ? Color.white : Theme.ink)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.brass : Theme.brass.opacity(0.35)))
                .offset(x: x, y: 1)
                .help("\(t.text) · \(formatShort(t.start))–\(formatShort(t.end)) · trascina per spostarlo, i bordi per allungarlo")
            }
        }
    }

    private func edge(_ t: VPText, mode: Int, pps: CGFloat, total: Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 6)
            .overlay(Capsule().fill(Color.white.opacity(0.8)).frame(width: 2, height: 10))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in moveText(t, by: v.translation.width, pps: pps, total: total, mode: mode) }
                .onEnded { _ in endTextDrag() })
    }

    /// mode 0 sposta, 1 cambia l'inizio, 2 cambia la fine
    private func moveText(_ t: VPText, by dx: CGFloat, pps: CGFloat, total: Double, mode: Int) {
        if textDrag?.id != t.id {
            textDrag = (t.id, t.start, t.end, mode)
            dragBefore = s.project
            s.selectedText = t.id
        }
        guard let d = textDrag else { return }
        let delta = Double(dx / max(pps, 0.0001))
        // 3.4.5 · Aggancio morbido: vicino all'inizio o alla fine di una clip, o all'indicatore, il testo si ferma lì
        let marks = Snap.marks(s.project, playhead: clock.time)
        let len = d.end - d.start
        var start = d.start, end = d.end
        switch mode {
        case 1: start = min(max(0, Snap.to(d.start + delta, marks, pps: pps, id: "t1")), d.end - 0.3)
        case 2: end = max(min(total, Snap.to(d.end + delta, marks, pps: pps, id: "t2")), d.start + 0.3)
        default:
            var st = min(max(0, d.start + delta), max(0, total - len))
            let snappedStart = Snap.to(st, marks, pps: pps, id: "t0")
            if snappedStart != st { st = snappedStart } else {
                let snappedEnd = Snap.to(st + len, marks, pps: pps, id: "t3")
                if snappedEnd != st + len { st = snappedEnd - len }
            }
            start = min(max(0, st), max(0, total - len)); end = start + len
        }
        s.live { p in
            guard let i = p.texts?.firstIndex(where: { $0.id == d.id }) else { return }
            p.texts![i].start = start
            p.texts![i].end = end
        }
    }

    private func endTextDrag() {
        Snap.reset()
        if let b = dragBefore { s.commit(from: b, undo, "Sposta il testo") }
        dragBefore = nil
        textDrag = nil
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
                        let raw = min(max(0, dragStartOffset + Double(v.translation.width / pps)), max(0, total - 0.5))
                        let o = min(max(0, Snap.to(raw, Snap.marks(s.project, playhead: clock.time), pps: pps, id: "m")), max(0, total - 0.5))
                        s.live { $0.music?.offset = o }
                    }
                    .onEnded { _ in
                        Snap.reset()
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

/// 3.4.5 · Una clip si ridisegna solo se cambia qualcosa di suo (non a ogni movimento delle altre).
private struct ClipBlock: View, Equatable {
    static func == (a: ClipBlock, b: ClipBlock) -> Bool {
        a.clip == b.clip && a.selected == b.selected && a.fileDuration == b.fileDuration && a.speech == b.speech
            && a.thumbs.count == b.thumbs.count && a.thumbs.first === b.thumbs.first
    }

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
                if abs(clip.speed - 1) > 0.001 || !(clip.fx?.isIdentity ?? true) {
                    // 2.9.8 · clip con effetti: la velocità si legge subito
                    Text(abs(clip.speed - 1) > 0.001 ? EffectOptions.speedLabel(clip.speed) : "✦")
                        .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.brass.opacity(0.9)))
                        .foregroundStyle(Color.white)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .opacity(g.size.width > 70 ? 1 : 0)
                }
                if !(clip.look?.isIdentity ?? true) {
                    // 2.9 · clip con un suo filtro
                    Image(systemName: "camera.filters")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(x: clip.isMuted ? 18 : 0)
                }
                if clip.isMuted {
                    // 2.7.4 · clip senza audio: si vede a colpo d'occhio
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
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

// MARK: - 2.9 · Filtri

/// Il passo «Filtri»: filtro pronto con miniatura, forza, sei regolazioni; per tutto il video o per una clip.
private struct LookOptions: View {
    @ObservedObject var s: VideoProjectStore
    let undo: UndoManager?
    let tint: Color
    @State private var onlyClip = false

    private var clipIndex: Int? { onlyClip ? s.targetIndex : nil }

    /// Il look che si sta modificando (della clip o del progetto).
    private var look: VPLook {
        if let i = clipIndex, s.project.clips.indices.contains(i) { return s.project.clips[i].look ?? s.project.look ?? VPLook() }
        return s.project.look ?? VPLook()
    }

    private func edit(_ p: inout VideoProject, _ f: (inout VPLook) -> Void) {
        if let i = clipIndex, p.clips.indices.contains(i) {
            var l = p.clips[i].look ?? p.look ?? VPLook()
            f(&l)
            p.clips[i].look = l
        } else {
            var l = p.look ?? VPLook()
            f(&l)
            p.look = l
        }
    }

    var body: some View {
        // 2.9.10 · In colonna, nel pannello a destra
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $onlyClip) {
                Text("Tutto il video").tag(false)
                Text("Solo questa clip").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(s.targetIndex == nil && !onlyClip)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                ForEach(VideoLooks.presets) { preset in
                    PresetChip(preset: preset, selected: look.preset == preset.id, tint: tint,
                               image: s.lookThumbnail(preset.id, clip: s.targetIndex ?? 0)) {
                        s.change(undo, "Filtro \(preset.name)") { p in edit(&p) { $0.preset = preset.id; if $0.amount < 0.05 { $0.amount = 1 } } }
                    }
                }
            }
            EditSlider(title: "Forza del filtro", value: look.amount, range: 0...1, text: "\(Int((look.amount * 100).rounded()))%",
                       width: 260, s: s, undo: undo, name: "Forza del filtro") { p, v in edit(&p) { $0.amount = v } }
                .disabled(look.preset == "none")
            SectionLabel(text: "Regolazioni")
            adjust("Luminosità", \.brightness, range: -1...1)
            adjust("Contrasto", \.contrast, range: -1...1)
            adjust("Saturazione", \.saturation, range: -1...1)
            adjust("Calore", \.warmth, range: -1...1)
            adjust("Nitidezza", \.sharpness, range: 0...1)
            adjust("Vignetta", \.vignette, range: 0...1)
            Button("Ripristina") {
                s.change(undo, "Rimuovi il filtro") { p in
                    if let i = clipIndex, p.clips.indices.contains(i) { p.clips[i].look = nil } else { p.look = nil }
                }
            }
            .controlSize(.small)
            .help(onlyClip ? "Toglie filtro e regolazioni da questa clip (torna quello del video)" : "Toglie filtro e regolazioni da tutto il video")
        }
    }

    private func adjust(_ title: String, _ key: WritableKeyPath<VPLook, Double>, range: ClosedRange<Double>) -> some View {
        let v = look[keyPath: key]
        let text = range.lowerBound < 0 ? (v > 0.005 ? "+" : "") + "\(Int((v * 100).rounded()))" : "\(Int((v * 100).rounded()))%"
        return EditSlider(title: title, value: v, range: range, text: text, width: 260, s: s, undo: undo, name: title) { p, nv in
            edit(&p) { $0[keyPath: key] = abs(nv) < 0.03 ? 0 : nv }       // vicino allo zero si «aggancia» a com'era
        }
    }
}

private struct PresetChip: View {
    let preset: VPLookPreset
    let selected: Bool
    let tint: Color
    let image: NSImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.15))
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                }
                .frame(width: 70, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.brass : Color.black.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(preset.name).font(.system(size: 10.5, weight: selected ? .bold : .regular)).lineLimit(1).minimumScaleFactor(0.8).frame(width: 76)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filtro \(preset.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 2.9.3 · Transizioni

struct TransitionOptions: View {
    @ObservedObject var s: VideoProjectStore
    let clipID: UUID
    let tint: Color
    /// Quello della finestra: il popover ne avrebbe uno suo (o nessuno) e ⌘Z non annullerebbe.
    let undo: UndoManager?
    /// 2.9.10 · Dentro il pannello: più stretto, senza titolo
    var compact = false
    @State private var before: VideoProject? = nil

    private var current: VPTransition? { s.project.clips.first { $0.id == clipID }?.transition }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact { Text("Transizione").font(.headline) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(compact ? 80 : 78), spacing: 6), count: compact ? 3 : 4), spacing: 6) {
                chip(nil, "Nessuna", "minus")
                ForEach(VPTransition.kinds, id: \.id) { k in chip(k.id, k.name, k.symbol) }
            }
            if let tr = current {
                HStack {
                    Text("Durata").font(.callout)
                    Slider(value: Binding(get: { tr.duration }, set: { v in set { $0?.duration = v } }), in: 0.2...2, step: 0.1) { editing in
                        if editing { before = s.project } else if let b = before { s.commit(from: b, undo, "Durata della transizione"); before = nil }
                    }
                        .frame(width: compact ? 130 : 160)
                    Text(Fmt.secs(tr.duration)).font(.callout).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("Se una clip è corta, la transizione si accorcia da sola.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Applica a tutte le clip") {
                    s.change(undo, "Transizione a tutte") { p in
                        for i in p.clips.indices.dropFirst() { p.clips[i].transition = tr }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(compact ? 0 : 14)
        .frame(width: compact ? nil : 360)
    }

    private func chip(_ id: String?, _ name: String, _ symbol: String) -> some View {
        let on = current?.kind == id
        return Button {
            s.change(undo, id == nil ? "Rimuovi la transizione" : "Transizione") { p in
                guard let i = p.clips.firstIndex(where: { $0.id == clipID }) else { return }
                if let id {
                    p.clips[i].transition = VPTransition(kind: id, duration: p.clips[i].transition?.duration ?? 0.6)
                } else {
                    p.clips[i].transition = nil
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(name).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 78, height: 48)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint.opacity(0.22) : Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? tint : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Cambio della durata mentre si trascina: si vede subito, un solo passo di annulla alla fine.
    private func set(_ f: (inout VPTransition?) -> Void) {
        s.live { p in
            guard let i = p.clips.firstIndex(where: { $0.id == clipID }) else { return }
            f(&p.clips[i].transition)
        }
    }
}

// MARK: - 2.9.8 · Effetti della clip

private struct EffectOptions: View {
    @ObservedObject var s: VideoProjectStore
    let undo: UndoManager?
    let tint: Color
    @State private var showHide = false

    private var index: Int? { s.targetIndex }
    private var fx: VPEffects {
        guard let i = index, s.project.clips.indices.contains(i) else { return VPEffects() }
        return s.project.clips[i].fx ?? VPEffects()
    }

    private func change(_ name: String, _ f: @escaping (inout VPEffects) -> Void) {
        guard let i = index else { NSSound.beep(); return }
        s.change(undo, name) { p in
            guard p.clips.indices.contains(i) else { return }
            var e = p.clips[i].fx ?? VPEffects()
            f(&e)
            p.clips[i].fx = e.isIdentity ? nil : e
        }
    }

    var body: some View {
        // 2.9.10 · In colonna, nel pannello a destra
        VStack(alignment: .leading, spacing: 10) {
            if let i = index, s.project.clips.indices.contains(i) {
                Text("Clip \(i + 1) di \(s.project.clips.count)").font(.system(size: 12.5, weight: .semibold))
                HStack {
                    Text("Velocità").font(.system(size: 12))
                    Spacer()
                    Menu {
                        ForEach(VPEffects.speeds, id: \.self) { v in
                            Button(Self.speedLabel(v)) { change("Velocità") { $0.speed = v } }
                        }
                    } label: {
                        Label(Self.speedLabel(fx.speed), systemImage: "speedometer")
                    }
                    .menuStyle(.button).fixedSize()
                    .help("Velocità della clip: la voce non cambia tono")
                }
                HStack {
                    Text("Zoom lento").font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(get: { fx.zoom }, set: { v in change("Zoom lento") { $0.zoom = v } })) {
                        Text("No").tag("none")
                        Image(systemName: "plus.magnifyingglass").tag("in").help("Si avvicina piano")
                        Image(systemName: "minus.magnifyingglass").tag("out").help("Si allontana piano")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("Gira").font(.system(size: 12))
                    Spacer()
                    Toggle(isOn: Binding(get: { fx.flipH }, set: { v in change("Capovolgi") { $0.flipH = v } })) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .toggleStyle(.button).help("Specchia (destra ↔ sinistra)")
                    Toggle(isOn: Binding(get: { fx.flipV }, set: { v in change("Capovolgi") { $0.flipV = v } })) {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .toggleStyle(.button).help("Capovolgi (sopra ↔ sotto)")
                    Button { change("Ruota") { $0.rotate = ($0.rotate + 90) % 360 } } label: {
                        Image(systemName: "rotate.right")
                    }
                    .help("Ruota di 90° · ora \(fx.rotate)°")
                }
                EditSlider(title: "Sfocatura", value: fx.blur, range: 0...1, text: fx.blur < 0.01 ? "No" : "\(Int(fx.blur * 100))%",
                           width: 260, s: s, undo: undo, name: "Sfocatura") { p, v in Self.edit(&p, i) { $0.blur = v } }
                HStack(spacing: 12) {
                    EditSlider(title: "Entrata", value: fx.fadeIn, range: 0...2, text: fx.fadeIn < 0.05 ? "No" : Fmt.secs(fx.fadeIn),
                               width: 124, s: s, undo: undo, name: "Dissolvenza in entrata") { p, v in Self.edit(&p, i) { $0.fadeIn = v < 0.05 ? 0 : v } }
                    EditSlider(title: "Uscita", value: fx.fadeOut, range: 0...2, text: fx.fadeOut < 0.05 ? "No" : Fmt.secs(fx.fadeOut),
                               width: 124, s: s, undo: undo, name: "Dissolvenza in uscita") { p, v in Self.edit(&p, i) { $0.fadeOut = v < 0.05 ? 0 : v } }
                }
                HStack(spacing: 6) {
                    Button("A tutte le clip") {
                        let e = fx
                        s.change(undo, "Effetti a tutte le clip") { p in
                            for k in p.clips.indices { p.clips[k].fx = e.isIdentity ? nil : e }
                        }
                    }
                    .help("Copia questi effetti su tutte le clip")
                    Button("Ripristina") { change("Rimuovi gli effetti") { $0 = VPEffects() } }
                        .disabled(fx.isIdentity)
                }
                .controlSize(.small)
            } else {
                Text("Scegli una clip nella sequenza (clic sulla clip) per darle i suoi effetti.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Divider()
            SectionLabel(text: "Su tutto il video")
            hideButton
        }
        .sheet(isPresented: $showHide) { hideSheet }
    }

    /// 2.9.8 · Nascondi un logo su tutto il montaggio (sfocatura o pixel).
    private var hideButton: some View {
        HStack(spacing: 6) {
            Button { showHide = true } label: { Label(s.project.hide == nil ? "Nascondi una scritta o un logo…" : "Scritta o logo nascosti ✓", systemImage: "eye.slash") }
                .controlSize(.small).help("Sfoca o copri a pixel un logo o una scritta in tutto il video")
            if s.project.hide != nil {
                Button("Rimuovi") { s.change(undo, "Rimuovi la copertura") { $0.hide = nil } }.controlSize(.small)
            }
        }
    }

    private var hideSheet: some View {
        let project = s.project, infos = s.infos
        var plain = project
        plain.hide = nil
        plain.texts = nil
        let frames = MontageFrames(project: plain, infos: infos)
        return HideMarkEditor(url: URL(fileURLWithPath: "/montaggio.mp4"), onDone: { v in
            showHide = false
            if let v { s.change(undo, "Nascondi una scritta o un logo") { $0.hide = v } }
        }, frameSource: { t in await frames.frame(at: t) }, montageDuration: project.duration,
           initial: HideMark.parse(project.hide ?? ""), allowAI: false)
    }

    static func edit(_ p: inout VideoProject, _ i: Int, _ f: (inout VPEffects) -> Void) {
        guard p.clips.indices.contains(i) else { return }
        var e = p.clips[i].fx ?? VPEffects()
        f(&e)
        p.clips[i].fx = e.isIdentity ? nil : e
    }

    static func speedLabel(_ v: Double) -> String {
        let t = v == v.rounded() ? String(Int(v)) : String(format: "%g", v).replacingOccurrences(of: ".", with: ",")
        return t + "×"
    }
}

/// 2.9.8 · Fotogrammi del montaggio (senza logo nascosto e senza testi), per disegnare le zone.
final class MontageFrames: @unchecked Sendable {
    private let project: VideoProject
    private let infos: [String: VPMediaInfo]
    private var built: VPBuilt?
    private let lock = NSLock()

    init(project: VideoProject, infos: [String: VPMediaInfo]) {
        self.project = project
        self.infos = infos
    }

    func frame(at t: Double) async -> CGImage? {
        var b = lock.withLock { built }
        if b == nil {
            b = try? await VideoProjectBuilder.build(project, infos: infos, speech: [:], maxSide: 1100, engine: .frames)
            let fresh = b
            lock.withLock { built = fresh }
        }
        guard let b else { return nil }
        let g = AVAssetImageGenerator(asset: b.composition)
        g.videoComposition = b.videoComposition
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        return try? await g.image(at: CMTime(seconds: min(t, max(0, b.duration - 0.05)), preferredTimescale: 600)).image
    }
}
