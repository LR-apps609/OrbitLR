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
    /// 5.1 · Salvataggio unico: il progetto si salva da solo mentre lavori (entro un secondo da ogni modifica).
    /// `saved` è quello che c'è sul disco; `opened` com'era quando l'hai aperto («Ripristina…» e «Prima / dopo»).
    @Published private(set) var saved = VideoProject()
    @Published private(set) var opened = VideoProject()
    /// 5.1 · L'ora dell'ultimo salvataggio, per «Salvato alle 14:32»
    @Published private(set) var savedAt: Date? = nil
    /// 2.9.10 · «Prima/dopo»: l'anteprima mostra il progetto com'era all'apertura
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
    /// 5.0.1 · L'onda della musica (o dell'audio staccato), per disegnarla dentro la sua barra: 50 punti al secondo.
    @Published private(set) var musicPeaks: [Float] = []
    /// 5.0.1 · Zoom della sequenza (1 = tutto il montaggio nella larghezza): fino al millisecondo
    @Published var timelineZoom: Double = 1
    /// 5.1 · Lo strumento aperto a destra (Clip, Testi, Audio…): torna com'era riaprendo il progetto
    @Published var lastTool: String = VideoEditTool.clip.rawValue
    private var musicPeaksPath: String? = nil
    static let musicPeaksRate = 50.0
    func loadMusicPeaks() {
        guard let m = project.music, let d = songDuration, d > 0 else { return }
        guard musicPeaksPath != m.path else { return }
        musicPeaksPath = m.path
        musicPeaks = []
        let path = m.path
        Task { @MainActor [weak self] in
            let bins = max(10, min(200_000, Int(d * Self.musicPeaksRate)))
            let p = await TrimModel.waveformLevels(url: URL(fileURLWithPath: path), duration: d, bins: bins).peaks
            guard let self, self.musicPeaksPath == path else { return }
            self.musicPeaks = p
        }
    }
    var musicEnd: Double? { VideoProjectBuilder.musicEnd(project, songDuration: songDuration) }
    var speechOnTimeline: [ClosedRange<Double>] { VideoProjectBuilder.speechOnTimeline(project, speech: speech) }

    /// La clip su cui agiscono i comandi: quella scelta, altrimenti quella sotto l'indicatore.
    var targetIndex: Int? {
        if let s = selected, let i = project.clips.firstIndex(where: { $0.id == s }) { return i }
        return project.clip(at: clock.time)?.index
    }

    // MARK: 5.1 · Salvataggio unico

    /// Il progetto è cambiato da quando l'hai aperto (per «Ripristina…» e «Prima / dopo»).
    var changedSinceOpen: Bool { currentID != nil && project != opened }

    /// ⌘S: niente da confermare, scrive subito sul disco quello che c'è.
    func applyChanges() {
        saved = project
        saveNow()
    }

    /// «Ripristina…»: il progetto torna com'era quando l'hai aperto. Si annulla con ⌘Z.
    func revertToOpened(_ undo: UndoManager?) {
        guard changedSinceOpen else { return }
        showingBefore = false
        let before = project
        apply(opened)
        registerUndo(undo, String(localized: "Ripristina com’era all’apertura"), before: before)
    }

    // MARK: Modifiche (ognuna si può annullare con ⌘Z)

    func change(_ undo: UndoManager?, _ name: String, _ body: (inout VideoProject) -> Void) {
        let before = project
        var p = project
        body(&p)
        guard p != before else { return }
        Self.followClips(&p, from: before)
        apply(p)
        registerUndo(undo, name, before: before)
    }

    /// 4.1.5 · Clip tagliate, divise, spostate, eliminate o accelerate: i testi le seguono
    /// (se la modifica non ha già sistemato i testi da sé, come «Togli i silenzi»).
    static func followClips(_ p: inout VideoProject, from before: VideoProject) {
        guard let texts = p.texts, !texts.isEmpty, p.texts == before.texts,
              p.timingSignature != before.timingSignature else { return }
        p.texts = VideoProject.retimeTexts(texts, from: before, to: p)
    }

    /// Durante un trascinamento: si vede subito, l'annullamento si registra alla fine (uno solo).
    func live(_ body: (inout VideoProject) -> Void) {
        var p = project
        body(&p)
        if p != project { apply(p) }
    }

    func commit(from before: VideoProject, _ undo: UndoManager?, _ name: String) {
        guard before != project else { return }
        // 4.1.5 · Alla fine di un trascinamento sulle clip, anche i testi si spostano
        var p = project
        Self.followClips(&p, from: before)
        if p != project { apply(p) }
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
        // 5.1 · Ogni modifica si salva da sola (entro un secondo): un crash non perde più il lavoro
        if currentID != nil, p != saved {
            saved = p
            scheduleSave()
        }
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
            notice = String(localized: "Qui si aprono video (e un brano audio, per la musica).")
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
            notice = otherVideos.count == 1
                ? String(localized: "Preparo «\(otherVideos[0].lastPathComponent)»: entrano nel progetto tra poco.")
                : String(localized: "Preparo \(otherVideos.count) video: entrano nel progetto tra poco.")
            AutoConvert.prepare(otherVideos, to: "mp4", kind: .video) { [weak self] ready in
                self?.notice = nil
                self?.add(ready, undo: undo)
            }
        }
        if let a = otherAudio {
            notice = String(localized: "Preparo «\(a.lastPathComponent)» per la musica…")
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
                    guard info.hasVideo else { self.notice = String(localized: "«\(u.lastPathComponent)» non contiene video."); continue }
                    self.infos[u.path] = info
                    loaded.append(VPClip(path: u.path, inPoint: 0, outPoint: info.videoDuration))
                    self.loadThumbs(u.path, duration: info.videoDuration)
                } catch {
                    self.notice = String(localized: "«\(u.lastPathComponent)» non si apre: \(error.localizedDescription)")
                }
            }
            if !loaded.isEmpty {
                self.change(undo, loaded.count == 1 ? String(localized: "Aggiungi video") : String(localized: "Aggiungi \(loaded.count) video")) { $0.clips += loaded }
            }
            if let a = okAudio { await self.setMusic(a, undo: undo) }
        }
    }

    @MainActor
    func setMusic(_ url: URL, undo: UndoManager?) async {
        do {
            let info = try await VPMediaInfo.load(url)
            guard info.hasAudio else { notice = String(localized: "«\(url.lastPathComponent)» non contiene audio."); NSSound.beep(); return }
            infos[url.path] = info
            change(undo, String(localized: "Aggiungi musica")) { p in
                var m = p.music ?? VPMusic(path: url.path)
                m.path = url.path
                m.inPoint = 0
                // Brano più corto del video: di base si ripete, così il video non resta muto a metà
                m.loop = info.duration < max(0, p.duration - m.offset) - 0.5
                p.music = m
            }
        } catch {
            notice = String(localized: "La musica non si apre: \(error.localizedDescription)")
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
                    self.notice = String(localized: "«\(URL(fileURLWithPath: path).lastPathComponent)» non si apre più.")
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

    /// 5.0.2 · Il motore dell'anteprima: quello a fotogrammi (transizioni, filtri per clip); se macOS lo rifiuta,
    /// per il resto della sessione si usa quello semplice.
    private var previewEngine: VideoProjectBuilder.Engine = VideoProjectBuilder.preferredEngine

    /// Aspetta che il lettore dica se il montaggio si può riprodurre (al massimo 3 secondi).
    static func playable(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<60 {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return item.status != .failed
    }

    /// 5.0.2 · Una riga nel registro dell'app (va nelle segnalazioni, senza nomi di file).
    static func log(_ text: String) {
        let line = "[\(Date())] Montaggio: \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Paths.log) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: Paths.log)
        }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        Perf.begin(.previewRebuild)
        let p = showingBefore ? opened : project, inf = infos, sp = speech
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
            var engine = self.previewEngine
            var built: VPBuilt?
            do { built = try await VideoProjectBuilder.build(p, infos: inf, speech: sp, maxSide: 1280, engine: engine) }
            catch {
                Self.log("anteprima del montaggio non costruita (\(engine)): \(error.localizedDescription)")
                if engine == .frames {
                    engine = .layers
                    built = try? await VideoProjectBuilder.build(p, infos: inf, speech: sp, maxSide: 1280, engine: .layers)
                }
            }
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
            var next = AVPlayer(playerItem: item)
            next.automaticallyWaitsToMinimizeStalling = false
            // 5.0.2 · Se il lettore rifiuta il montaggio (succedeva su macOS 14 con più clip: anteprima vuota),
            // si scrive il motivo nel registro e si riprova con il motore semplice: l'anteprima non sparisce mai
            if await !Self.playable(item) {
                Self.log("anteprima del montaggio rifiutata (\(engine), \(p.clips.count) clip): \(item.error?.localizedDescription ?? "?")")
                if engine == .frames, let simple = try? await VideoProjectBuilder.build(p, infos: inf, speech: sp, maxSide: 1280, engine: .layers) {
                    self.previewEngine = .layers
                    let it2 = AVPlayerItem(asset: simple.composition)
                    it2.videoComposition = simple.videoComposition
                    it2.audioMix = simple.audioMix
                    it2.audioTimePitchAlgorithm = .spectral
                    next = AVPlayer(playerItem: it2)
                    next.automaticallyWaitsToMinimizeStalling = false
                }
            }
            guard !Task.isCancelled else { return }
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

    /// 5.1 · Mai un «bip» muto: si dice sempre perché non si può.
    func refuse(_ message: String) {
        notice = message
        NSSound.beep()
    }

    func play() {
        guard player.currentItem != nil, previewDuration > 0 else { refuse(String(localized: "Non c’è ancora niente da riprodurre.")); return }
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
        guard let hit = project.clip(at: clock.time) else { refuse(String(localized: "Porta l’indicatore sopra una clip.")); return }
        let c = project.clips[hit.index]
        let l = hit.local
        guard l - c.inPoint > 0.1, c.outPoint - l > 0.1 else {
            notice = String(localized: "Per dividere, porta l’indicatore dentro una clip (non sul bordo).")
            NSSound.beep()
            return
        }
        notice = nil
        change(undo, String(localized: "Dividi")) { p in
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
        guard let hit = project.clip(at: clock.time) else { refuse(String(localized: "Porta l’indicatore sopra una clip.")); return }
        let i = hit.index, c = project.clips[i]
        guard c.outPoint - hit.local > 0.1 else { refuse(String(localized: "L’indicatore è troppo vicino al bordo della clip.")); return }
        let clipStart = project.starts[i]
        change(undo, String(localized: "Taglia l’inizio")) { $0.clips[i].inPoint = hit.local }
        seek(clipStart)
    }

    func trimEndHere(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { refuse(String(localized: "Porta l’indicatore sopra una clip.")); return }
        let i = hit.index, c = project.clips[i]
        guard hit.local - c.inPoint > 0.1 else { refuse(String(localized: "L’indicatore è troppo vicino al bordo della clip.")); return }
        change(undo, String(localized: "Taglia la fine")) { $0.clips[i].outPoint = hit.local }
    }

    func restoreClip(_ undo: UndoManager?) {
        guard let i = targetIndex else { refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        guard let info = infos[project.clips[i].path] else { refuse(String(localized: "Sto ancora leggendo questa clip: riprova tra un attimo.")); return }
        change(undo, String(localized: "Clip intera")) { p in
            p.clips[i].inPoint = 0
            p.clips[i].outPoint = info.videoDuration
        }
    }

    func move(_ delta: Int, _ undo: UndoManager?) {
        guard let i = targetIndex else { refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        let j = i + delta
        guard project.clips.indices.contains(j) else { refuse(delta > 0 ? String(localized: "La clip è già l’ultima.") : String(localized: "La clip è già la prima.")); return }
        let id = project.clips[i].id
        change(undo, String(localized: "Sposta la clip")) { $0.clips.swapAt(i, j) }
        selected = id
        seek(project.starts[j])
    }

    /// 2.7.4 · Accende o spegne l'audio della clip scelta.
    func toggleClipAudio(_ undo: UndoManager?) {
        guard let i = targetIndex else { refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        let off = !project.clips[i].isMuted
        change(undo, off ? String(localized: "Spegni l’audio della clip") : String(localized: "Riaccendi l’audio della clip")) { $0.clips[i].muted = off ? true : nil }
    }

    /// 2.7.4 · Toglie l'audio da qui alla fine della clip (divide nel punto dell'indicatore).
    func muteFromHere(_ undo: UndoManager?) {
        guard let hit = project.clip(at: clock.time) else { refuse(String(localized: "Porta l’indicatore sopra una clip.")); return }
        let c = project.clips[hit.index]
        guard hit.local - c.inPoint > 0.1, c.outPoint - hit.local > 0.1 else {
            change(undo, String(localized: "Spegni l’audio della clip")) { $0.clips[hit.index].muted = true }
            return
        }
        change(undo, String(localized: "Spegni l’audio da qui")) { p in
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
        guard let i = targetIndex else { refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        change(undo, String(localized: "Elimina la clip")) { $0.clips.remove(at: i) }
        selected = nil
    }

    /// 2.7.3 · Apre un progetto nuovo e vuoto (quello aperto resta salvato tra i Progetti).
    /// 3.9 · `vertical`: parte già in 9:16 (TikTok, Reels, Shorts), a 1080p.
    func newProject(_ undo: UndoManager?, vertical: Bool = false) {
        // 5.1 · Il progetto aperto resta salvato com'è; si dice dove trovarlo
        let previous = currentID != nil && !project.clips.isEmpty ? VideoProjectLibrary.displayName(project) : nil
        closeProject(undo)
        var p = VideoProject()
        if vertical { p.aspect = "9x16"; p.resolution = 1080; p.fps = 30 }
        p.name = VideoProjectLibrary.uniqueName(existing: library.map { $0.name })
        currentID = UUID()
        if folder == VideoProjectLibrary.folder { Self.rememberOpen(currentID) }
        project = p
        saved = p
        opened = p
        savedAt = nil
        if let previous { notice = String(localized: "Progetto nuovo. «\(previous)» è salvato in Progetti.") }
        scheduleRebuild()
    }

    /// 2.7.3 · Riapre un progetto salvato, ritrovando i file spostati.
    func openProject(_ id: UUID, undo: UndoManager?) {
        closeProject(undo)
        guard var p = VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: folder)) else {
            notice = String(localized: "Questo progetto non si apre più.")
            refreshLibrary()
            return
        }
        notice = Self.relink(&p)
        currentID = id
        if folder == VideoProjectLibrary.folder { Self.rememberOpen(id) }
        project = p
        saved = p
        opened = p
        savedAt = (try? VideoProjectLibrary.url(for: id, in: folder).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // 5.1 · Si torna dov'eri: indicatore, zoom e strumento di questo progetto
        if let v = Self.viewState(id) {
            clock.time = min(max(0, v.time), max(0, p.duration - 0.05))
            timelineZoom = max(1, v.zoom)
            lastTool = v.tool
        }
        ensureLoaded()
        ensureSpeech()
        scheduleRebuild()
    }

    /// 5.1 · Dove eri in un progetto (non fa parte del progetto: spostare l'indicatore non è una modifica).
    struct ViewState: Codable { var time: Double; var zoom: Double; var tool: String }
    private static func viewKey(_ id: UUID) -> String { "video.view.\(id.uuidString)" }
    static func viewState(_ id: UUID) -> ViewState? {
        guard let d = UserDefaults.standard.data(forKey: viewKey(id)) else { return nil }
        return try? JSONDecoder().decode(ViewState.self, from: d)
    }
    /// Si chiama chiudendo il progetto e uscendo dall'app.
    func rememberView() {
        guard let id = currentID, let d = try? JSONEncoder().encode(ViewState(time: clock.time, zoom: timelineZoom, tool: lastTool)) else { return }
        UserDefaults.standard.set(d, forKey: Self.viewKey(id))
    }

    /// 2.7.3 · Chiude il progetto (resta salvato) e torna alla schermata Progetti.
    func closeProject(_ undo: UndoManager?) {
        rememberView()
        pause()
        rebuildTask?.cancel()
        saveWork?.cancel()
        // 5.1 · Chiudere tiene tutto (il salvataggio è continuo); un progetto chiuso vuoto va nel Cestino
        saved = project
        showingBefore = false
        saveNow()
        if let id = currentID, project.clips.isEmpty, project.music == nil, (project.missing ?? []).isEmpty,
           FileManager.default.fileExists(atPath: VideoProjectLibrary.url(for: id, in: folder).path) {
            VideoProjectLibrary.trash(id, in: folder)
        }
        if folder == VideoProjectLibrary.folder { Self.rememberOpen(nil) }
        undo?.removeAllActions(withTarget: self)        // il ⌘Z di un progetto non deve toccare un altro
        if let id = currentID { covers[id] = nil }      // la copertina si rifà: la prima clip può essere cambiata
        currentID = nil
        project = VideoProject()
        saved = project
        opened = project
        savedAt = nil
        timelineZoom = 1                                  // 5.1 · lo zoom è del progetto, non passa al prossimo
        lastTool = VideoEditTool.clip.rawValue
        selected = nil
        selectedText = nil
        notice = nil
        // 5.1 · Chiudendo mentre esporta, la striscia resta (anche in Progetti): l'esportazione non è più invisibile
        if let j = lastJob, j.state != .running && j.state != .waiting { lastJob = nil }
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
        if id == currentID { project.name = n; saved.name = n; opened.name = n; scheduleSave() } else { VideoProjectLibrary.rename(id, to: n, in: folder) }
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
        change(undo, String(localized: "Musica da qui")) { p in
            p.music?.offset = t
            if let e = p.music?.end, e < t + 0.2 { p.music?.end = nil }     // la fine resta dopo l'inizio
        }
    }

    /// 5.0.1 · La musica finisce nel punto dell'indicatore.
    func musicEndHere(_ undo: UndoManager?) {
        guard let m = project.music, clock.time > m.offset + 0.2 else { refuse(project.music == nil ? String(localized: "Non c’è una musica.") : String(localized: "Porta l’indicatore sopra la musica.")); return }
        let t = clock.time
        change(undo, String(localized: "Musica fino a qui")) { $0.music?.end = t }
    }

    /// 5.0.1 · La musica torna ad andare fino alla fine del video.
    func musicToEnd(_ undo: UndoManager?) {
        change(undo, String(localized: "Musica fino alla fine")) { $0.music?.end = nil }
    }

    /// 5.0.1 · «Stacca l'audio»: l'audio della clip diventa la traccia audio sotto il video (come nei programmi di
    /// montaggio): si sposta, si accorcia e si taglia da solo, e la clip resta muta. Una traccia sola: se c'è già
    /// una musica, prima si toglie.
    func detachClipAudio(_ undo: UndoManager?) {
        guard let i = targetIndex, project.clips.indices.contains(i) else { refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        let c = project.clips[i]
        guard project.music == nil else {
            notice = String(localized: "C’è già una musica: c’è posto per una traccia audio sola. Togli la musica e riprova.")
            NSSound.beep(); return
        }
        guard abs(c.speed - 1) < 0.001 else {
            notice = String(localized: "Prima riporta la clip a velocità 1×: l’audio staccato va alla velocità normale.")
            NSSound.beep(); return
        }
        guard infos[c.path]?.hasAudio != false else { notice = String(localized: "Questa clip non ha audio."); NSSound.beep(); return }
        let start = project.starts[i]
        change(undo, String(localized: "Stacca l’audio")) { p in
            var m = VPMusic(path: c.path)
            m.bookmark = c.bookmark
            m.offset = start
            m.inPoint = c.inPoint
            m.end = start + c.length
            m.loop = false
            m.volume = 1
            m.fadeIn = 0
            m.fadeOut = 0
            m.duck = false
            p.music = m
            p.clips[i].muted = true
        }
    }

    /// Fa finire la canzone insieme al video (sceglie da che punto farla partire).
    func alignMusicEnd(_ undo: UndoManager?) {
        guard let m = project.music, let sd = songDuration else { return }
        let room = max(0, project.duration - m.offset)
        change(undo, String(localized: "Finale insieme al video")) { p in
            p.music?.inPoint = max(0, sd - room)
            p.music?.loop = false
        }
    }

    func removeMusic(_ undo: UndoManager?) {
        change(undo, String(localized: "Rimuovi la musica")) { $0.music = nil }
    }

    // MARK: Esportazione

    func export() {
        guard !project.clips.isEmpty else { refuse(String(localized: "Aggiungi almeno un video per esportare.")); return }
        guard project.duration > 0.1 else { notice = String(localized: "Il montaggio è vuoto."); NSSound.beep(); return }
        if !analyzing.isEmpty {
            notice = String(localized: "Un attimo: sto ancora trovando le voci nel video per abbassare la musica.")
            NSSound.beep()
            return
        }
        pause()
        applyChanges()          // 2.9.10 · si esporta quello che si vede, e diventa definitivo
        do {
            let snap = try VideoProjectExport.writeSnapshot(project, speech: speech, bytes: estimate?.bytes)
            var seen = Set<String>()
            let files = project.clips.map { $0.url }.filter { seen.insert($0.path).inserted }
            guard let action = Catalog.action(id: "vproject", kind: .video) else { return }
            notice = nil
            lastJob = QueueStore.shared.enqueue(files: files, action: action, param: snap.path)
        } catch {
            notice = String(localized: "Non riesco a preparare l’esportazione: \(error.localizedDescription)")
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
        let w = DispatchWorkItem { [weak self] in
            VideoProjectLibrary.save(p, to: url)
            DispatchQueue.main.async { self?.savedAt = Date() }
        }
        saveWork = w
        VideoProjectLibrary.queue.asyncAfter(deadline: .now() + 0.6, execute: w)
    }


    /// Salva subito (alla chiusura del progetto).
    func saveNow() {
        guard let url = saveURL else { return }
        saveWork?.cancel()
        let p = saved
        VideoProjectLibrary.queue.sync { VideoProjectLibrary.save(p, to: url) }   // in coda dopo eventuali salvataggi in corso
        savedAt = Date()
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

    /// Ritrova i file spostati. 5.1 · Quelli che non si trovano non si perdono più: le clip escono dalla sequenza
    /// e restano nel progetto (`missing`), la musica resta com'è; restituisce l'avviso da mostrare (nil se va tutto bene).
    static func relink(_ p: inout VideoProject) -> String? {
        let fm = FileManager.default
        // File spostati o rinominati: li ritrova il segnalibro
        for i in p.clips.indices where !fm.fileExists(atPath: p.clips[i].path) {
            if let found = Self.resolve(p.clips[i].bookmark) { p.clips[i].path = found }
        }
        if let m = p.music, !fm.fileExists(atPath: m.path) { p.music?.path = Self.resolve(m.bookmark) ?? m.path }
        var missing = p.missing ?? []
        for (i, c) in p.clips.enumerated().reversed() where !fm.fileExists(atPath: c.path) {
            missing.append(VPMissingClip(clip: c, index: i))
            p.clips.remove(at: i)
        }
        p.clips = p.clips.filter { $0.length > 0.05 }
        missing.sort { $0.index < $1.index }
        p.missing = missing.isEmpty ? nil : missing
        let musicLost = p.music.map { !fm.fileExists(atPath: $0.path) } ?? false
        return missingNotice(clips: missing.count, music: musicLost)
    }

    static func missingNotice(clips: Int, music: Bool) -> String? {
        guard clips > 0 || music else { return nil }
        if clips == 0 { return String(localized: "Non trovo la musica di questo progetto. Resta nel progetto finché non la ritrovi.") }
        if clips == 1 { return String(localized: "Non trovo 1 video di questo progetto. Resta nel progetto finché non lo ritrovi.") }
        return String(localized: "Non trovo \(clips) video di questo progetto. Restano nel progetto finché non li ritrovi.")
    }

    var hasMissing: Bool {
        !(project.missing ?? []).isEmpty || (project.music.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    /// 5.1 · «Trova…»: i file scelti (o quelli dentro le cartelle scelte) con lo stesso nome tornano al loro posto.
    func findMissing(in urls: [URL], undo: UndoManager?) {
        let files = PieController.expand(urls)
        let byName = Dictionary(files.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        change(undo, String(localized: "Ritrova i file")) { p in
            var still: [VPMissingClip] = []
            for m in p.missing ?? [] {
                if let u = byName[m.name] {
                    var c = m.clip
                    c.path = u.path
                    c.bookmark = try? u.bookmarkData()
                    p.clips.insert(c, at: min(m.index, p.clips.count))
                } else { still.append(m) }
            }
            p.missing = still.isEmpty ? nil : still
            if let m = p.music, !FileManager.default.fileExists(atPath: m.path), let u = byName[URL(fileURLWithPath: m.path).lastPathComponent] {
                p.music?.path = u.path
            }
        }
        let musicLost = project.music.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        notice = Self.missingNotice(clips: project.missing?.count ?? 0, music: musicLost)
        ensureLoaded()
    }

    // MARK: 5.1 · Riaprire dove eri

    static let openKey = "video.openProject"

    static func rememberOpen(_ id: UUID?) {
        if let id { UserDefaults.standard.set(id.uuidString, forKey: openKey) } else { UserDefaults.standard.removeObject(forKey: openKey) }
    }

    /// All'avvio: il progetto che era aperto (anche dopo un crash) torna aperto, nel Montaggio.
    func restoreLastOpen() {
        guard currentID == nil, folder == VideoProjectLibrary.folder,
              let s = UserDefaults.standard.string(forKey: Self.openKey), let id = UUID(uuidString: s),
              FileManager.default.fileExists(atPath: VideoProjectLibrary.url(for: id, in: folder).path) else { return }
        openProject(id, undo: nil)
        AppState.shared.videoMode = .montage
    }
}

/// 3.9 · Le impostazioni giuste per ogni social, in un clic.
struct SocialPreset {
    let id: String, name: String, hint: String
    let aspect: String?, resolution: Int, fps: Int

    static let all: [SocialPreset] = [
        SocialPreset(id: "tiktok", name: "TikTok", hint: String(localized: "Verticale 9:16, Full HD"), aspect: "9x16", resolution: 1080, fps: 30),
        SocialPreset(id: "reels", name: "Reels", hint: String(localized: "Instagram e Facebook: verticale 9:16, Full HD"), aspect: "9x16", resolution: 1080, fps: 30),
        SocialPreset(id: "shorts", name: "Shorts", hint: String(localized: "YouTube Shorts: verticale 9:16, Full HD"), aspect: "9x16", resolution: 1080, fps: 30),
        SocialPreset(id: "youtube", name: "YouTube", hint: String(localized: "Orizzontale 16:9, Full HD"), aspect: "16x9", resolution: 1080, fps: 30),
        SocialPreset(id: "whatsapp", name: "WhatsApp", hint: String(localized: "Forma originale, HD 720p: leggero da mandare, nitido sul telefono"), aspect: nil, resolution: 720, fps: 30),
    ]

    func apply(_ p: inout VideoProject) {
        if let a = aspect { p.aspect = a }
        p.resolution = resolution
        p.fps = fps
    }

    func matches(_ p: VideoProject) -> Bool {
        (aspect == nil ? p.aspect == "orig" : p.aspect == aspect) && p.resolution == resolution && p.fps == fps
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
        case .clip: return String(localized: "Taglia, dividi, sposta e togli le clip. I bordi d’ottone di una clip si trascinano per accorciarla.")
        case .looks: return String(localized: "Un filtro per tutto il video o solo per la clip scelta, e le regolazioni di luce e colore.")
        case .effects: return String(localized: "Effetti della clip scelta: velocità, zoom lento, gira, sfocatura, dissolvenze.")
        case .texts: return String(localized: "Titoli e scritte: premi «Testo» sull’anteprima (o il tasto T), poi trascinali dove vuoi.")
        case .audio: return String(localized: "Il volume dei tuoi video e la musica.")
        case .format: return String(localized: "La forma del video e la qualità dell’esportazione.")
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var s: VideoProjectStore
    @Environment(\.undoManager) private var undo
    @State private var tool: VideoEditTool = .clip

    init(s: VideoProjectStore, startTool: VideoEditTool? = nil) {
        self.s = s
        _tool = State(initialValue: startTool ?? VideoEditTool(rawValue: s.lastTool) ?? .clip)
    }
    @State private var targeted = false
    /// 5.1 · «Ripristina…» chiede conferma (e si annulla con ⌘Z)
    @State private var askRevert = false
    /// 5.0.1 · «Salvato» per un attimo dopo «Salva progetto»
    @State private var savedFlash = false

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
                MediaDropZone(kind: .video, title: String(localized: "Trascina qui i video"),
                              subtitle: String(localized: "oppure clicca per sceglierli · MP4, MOV, M4V · più video vanno in fila · un brano audio diventa la musica"),
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
        .onChange(of: tool) { _, t in s.lastTool = t.rawValue }
        .onChange(of: s.lastTool) { _, v in if let t = VideoEditTool(rawValue: v), t != tool { tool = t } }
        .background(EditorKeys(s: s))
        .confirmationDialog("Ripristinare il progetto com’era quando l’hai aperto?", isPresented: $askRevert) {
            Button("Ripristina", role: .destructive) { s.revertToOpened(undo) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Le modifiche fatte da allora spariscono. Puoi riaverle con ⌘Z.")
        }
    }

    /// 5.1 · «Salvato alle 14:32 · »
    private var savedLine: String {
        guard let d = s.savedAt else { return "" }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return String(localized: "Salvato alle \(f.string(from: d))") + " · "
    }

    private func findMissing() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = String(localized: "Scegli i file del progetto, o la cartella dove sono adesso")
        Sheet.choose(p) { urls in if !urls.isEmpty { s.findMissing(in: urls, undo: undo) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VideoProjectLibrary.displayName(s.project))
                    .font(.system(size: s.project.clips.isEmpty ? 22 : 15, weight: .bold, design: s.project.clips.isEmpty ? .rounded : .default))
                    .lineLimit(1)
                if !s.project.clips.isEmpty {
                    Text(savedLine + String(localized: "\(s.project.clips.count) clip · \(formatShort(s.project.duration))") + (s.project.music != nil ? String(localized: " · con musica") : "")
                         + (s.estimate.map { " · ≈ " + Fmt.bytes($0.bytes) } ?? ""))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                // 5.1 · File non trovati: restano nel progetto, «Trova…» li rimette al loro posto
                if s.hasMissing {
                    Button { findMissing() } label: { Label("Trova i file…", systemImage: "magnifyingglass") }
                        .controlSize(.small)
                        .help("Scegli i file o la cartella dove sono adesso: tornano al loro posto nel progetto")
                }
            }
            if s.building { ProgressView().controlSize(.small).help("Preparo l’anteprima") }
            Spacer(minLength: 8)
            if !s.project.clips.isEmpty {
                Button { undo?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annulla l’ultima modifica (⌘Z)").accessibilityLabel("Annulla l’ultima modifica")
                Button { undo?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Ripeti (⇧⌘Z)").accessibilityLabel(String(localized: "edit.redo", defaultValue: "Ripeti", comment: "Rifà la modifica annullata (⇧⌘Z)"))
                Button { choose(audio: false) } label: { Label("Video", systemImage: "plus") }
                    .help("Aggiungi altri video in fondo")
                // 5.0.1 · Salva il progetto quando vuoi (le modifiche in sospeso diventano definitive)
                Button {
                    s.applyChanges()
                    s.saveNow()
                    withAnimation(Motion.quick) { savedFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(Motion.quick) { savedFlash = false } }
                } label: {
                    Label(savedFlash ? String(localized: "Salvato") : String(localized: "Salva progetto"),
                          systemImage: savedFlash ? "checkmark" : "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .help("Salva il progetto adesso (⌘S). Lo ritrovi in Progetti")
                Button("Esporta") { s.export() }
                    .primaryButton(true)               // 5.1 · l'unico pulsante principale del Montaggio
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Crea il video finale (⌘E). Le modifiche in sospeso vengono applicate")
            }
            // 2.7.3 · ✕ in alto a destra: chiude il progetto (resta salvato) e torna ai Progetti
            Button { s.closeProject(undo) } label: {
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
            if s.changedSinceOpen || s.showingBefore { pendingBar }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 5.1 · Tutto è già salvato: qui si confronta con com'era all'apertura, e si può tornarci.
    private var pendingBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Text("Prima / dopo")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(s.showingBefore ? Theme.brass.opacity(0.35) : Theme.ink.opacity(0.07)))
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, perform: {}, onPressingChanged: { s.showingBefore = $0 })
                    .help("Tieni premuto per vedere com’era quando hai aperto il progetto")
                    .accessibilityAddTraits(.isButton)
                Spacer(minLength: 4)
                Button("Ripristina…") { askRevert = true }
                    .help("Riporta il progetto com’era quando l’hai aperto (chiede conferma, si annulla con ⌘Z)")
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
                Text(String(localized: "Clip \(i + 1) di \(s.project.clips.count) · \(formatShort(c.length))") + (abs(c.speed - 1) > 0.001 ? " · " + EffectOptions.speedLabel(c.speed) : ""))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            // 5.0.1 · «Funzioni»: tagli, spostamenti e la velocità della clip, nello stesso posto
            SectionLabel(text: String(localized: "Funzioni"))
            HStack(spacing: 6) {
                Button("Inizio qui") { s.trimStartHere(undo) }.help("Taglia la clip da qui in poi")
                Button("Fine qui") { s.trimEndHere(undo) }.help("Taglia la clip fino a qui")
                Button("Dividi") { s.split(undo) }
                    .keyboardShortcut(s.typing ? nil : KeyboardShortcut("s", modifiers: []))
                    .help("Divide la clip nel punto dell’indicatore (S)")
            }
            HStack(spacing: 6) {
                Button { s.move(-1, undo) } label: { Label(String(localized: "clip.moveEarlier", defaultValue: "Prima", comment: "Sposta la clip prima"), systemImage: "arrow.left") }.help("Sposta la clip prima")
                Button { s.move(1, undo) } label: { Label(String(localized: "clip.moveLater", defaultValue: "Dopo", comment: "Sposta la clip dopo"), systemImage: "arrow.right") }.help("Sposta la clip dopo")
                Button("Intera") { s.restoreClip(undo) }.help("Riporta la clip alla sua durata intera")
            }
            if let i = s.targetIndex, s.project.clips.indices.contains(i) {
                HStack(spacing: 6) {
                    Text("Velocità").font(.system(size: 12))
                    Menu {
                        ForEach(VPEffects.speeds, id: \.self) { v in
                            Button(EffectOptions.speedLabel(v)) { setSpeed(v) }
                        }
                    } label: {
                        Label(EffectOptions.speedLabel(s.project.clips[i].speed), systemImage: "speedometer")
                    }
                    .menuStyle(.button).fixedSize()
                    .help("Velocità della clip: la voce non cambia tono")
                }
            }
            // 4.0 · Le pause lunghe spariscono da sole (tagli netti, come nei video dei social)
            Button { s.removeSilences(undo) } label: { Label("Togli i silenzi", systemImage: "waveform.badge.minus") }
                .help("Ascolta la clip e toglie le pause lunghe: restano solo i pezzi in cui si parla. ⌘Z per tornare indietro")
            SectionLabel(text: String(localized: "Audio della clip"))
            HStack(spacing: 6) { clipAudioButtons }
            if let i = s.targetIndex, i > 0, s.project.clips.indices.contains(i) {
                SectionLabel(text: String(localized: "Transizione prima di questa clip"))
                Text("Oppure clicca il pallino tra due clip nella sequenza.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                TransitionOptions(s: s, clipID: s.project.clips[i].id, tint: tint, undo: undo, compact: true)
            }
            SectionLabel(text: String(localized: "Altro"))
            HStack(spacing: 6) {
                Button(role: .destructive) { s.deleteClip(undo) } label: { Label("Togli", systemImage: "trash") }
                    .keyboardShortcut(s.typing ? nil : KeyboardShortcut(.delete, modifiers: []))
                    .help("Togli la clip dal montaggio (⌫ · si può annullare con ⌘Z; il tuo video resta dov’è)")
                otherMenu
            }
        }
    }

    /// 5.0.1 · La velocità della clip scelta (la stessa di «Effetti»).
    private func setSpeed(_ v: Double) {
        guard let i = s.targetIndex else { s.refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        s.change(undo, String(localized: "Velocità")) { p in
            guard p.clips.indices.contains(i) else { return }
            var e = p.clips[i].fx ?? VPEffects()
            e.speed = v
            p.clips[i].fx = e.isIdentity ? nil : e
        }
    }

    private var otherMenu: some View {
        Menu {
            // 5.0.1 · Solo il pezzo che hai tenuto nella clip (prima era tutto il video originale)
            Button("Estrai l’audio della clip (M4A)") { extractClipAudio() }
            Button("Estrai l’audio di tutto il video (MP3)") { quick("to:mp3", param: "") }
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
        SectionLabel(text: String(localized: "Musica"))
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
                    // 5.0.1 · La fine della musica
                    Button("Finisce qui") { s.musicEndHere(undo) }
                        .help("La musica finisce nel punto dell’indicatore (oppure trascina il bordo destro della sua barra)")
                    if m.end != nil {
                        Button("Fino alla fine") { s.musicToEnd(undo) }
                            .help("La musica torna ad andare fino alla fine del video")
                    }
                }
                .controlSize(.small)
                Button("Finisce col video") { s.alignMusicEnd(undo) }
                    .help("Sceglie da dove far partire la canzone perché finisca insieme al video")
                    .controlSize(.small)
                Toggle("Ripeti finché il video finisce", isOn: bind(\.loop, String(localized: "Ripeti la musica"))).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                if let sd = s.songDuration, sd > 1 {
                    EditSlider(title: String(localized: "Parte dal"), value: m.inPoint, range: 0...max(1, sd - 1), text: formatShort(m.inPoint),
                               width: 260, s: s, undo: undo, name: String(localized: "Punto della canzone")) { p, v in p.music?.inPoint = v }
                }
                EditSlider(title: String(localized: "Volume"), value: m.volume, range: 0...1, text: "\(Int((m.volume * 100).rounded()))%",
                           width: 260, s: s, undo: undo, name: String(localized: "Volume della musica")) { p, v in p.music?.volume = v }
                HStack(spacing: 12) {
                    EditSlider(title: String(localized: "Entrata"), value: m.fadeIn, range: 0...5, text: Fmt.secs(m.fadeIn),
                               width: 124, s: s, undo: undo, name: String(localized: "Dissolvenza in entrata")) { p, v in p.music?.fadeIn = v }
                    EditSlider(title: String(localized: "Uscita"), value: m.fadeOut, range: 0...5, text: Fmt.secs(m.fadeOut),
                               width: 124, s: s, undo: undo, name: String(localized: "Dissolvenza in uscita")) { p, v in p.music?.fadeOut = v }
                }
                Toggle("Abbassa quando si parla", isOn: bind(\.duck, String(localized: "Abbassa quando si parla"))).toggleStyle(.checkbox)
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
            Label(muted ? String(localized: "Riaccendi") : String(localized: "Spegni"), systemImage: muted ? "speaker.wave.2" : "speaker.slash")
        }
        .help(muted ? String(localized: "Riaccende l’audio di questa clip") : String(localized: "Spegne l’audio solo di questa clip (la musica resta)"))
        Button { s.muteFromHere(undo) } label: { Label("Spegni da qui", systemImage: "speaker.slash.circle") }
            .help("Spegne l’audio dall’indicatore alla fine della clip. Per un tratto in mezzo: dividi (S) e togli l’audio solo da quel pezzo")
        // 5.0.1 · L'audio della clip diventa una traccia sua, da spostare e tagliare
        Button { s.detachClipAudio(undo) } label: { Label("Stacca l’audio", systemImage: "waveform.badge.plus") }
            .help("L’audio della clip diventa la traccia audio sotto il video: lo sposti, lo accorci e lo tagli da solo. La clip resta muta")
    }

    @ViewBuilder private var originalOptions: some View {
        // 5.0.1 · Prima la clip scelta (un pezzo diviso è una clip a sé), poi tutti i video insieme
        if let i = s.targetIndex, s.project.clips.indices.contains(i) {
            let c = s.project.clips[i]
            SectionLabel(text: String(localized: "Audio di questa clip"))
            Text("Clip \(i + 1) di \(s.project.clips.count): vale solo per questo pezzo").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Toggle("Muta questa clip", isOn: Binding(get: { c.isMuted }, set: { v in
                s.change(undo, v ? String(localized: "Spegni l’audio della clip") : String(localized: "Riaccendi l’audio della clip")) { $0.clips[i].muted = v ? true : nil }
            }))
            .toggleStyle(.checkbox)
            EditSlider(title: String(localized: "Volume"), value: c.clipVolume, range: 0...1,
                       text: "\(Int((c.clipVolume * 100).rounded()))%", width: 260, s: s, undo: undo,
                       name: String(localized: "Volume della clip")) { p, v in if p.clips.indices.contains(i) { p.clips[i].volume = v >= 0.995 ? nil : v } }
                .disabled(c.isMuted)
            Divider()
        }
        SectionLabel(text: String(localized: "Tutti i video insieme"))
        Toggle("Muti tutti", isOn: Binding(get: { s.project.originalMuted },
                                      set: { v in s.change(undo, v ? String(localized: "Audio originale muto") : String(localized: "Audio originale attivo")) { $0.originalMuted = v } }))
            .toggleStyle(.checkbox)
        EditSlider(title: String(localized: "Volume"), value: s.project.originalVolume, range: 0...1,
                   text: "\(Int((s.project.originalVolume * 100).rounded()))%", width: 260, s: s, undo: undo,
                   name: String(localized: "Volume dell’audio originale")) { p, v in p.originalVolume = v }
            .disabled(s.project.originalMuted)
    }

    @ViewBuilder private var formatOptions: some View {
        // 3.9 · Pronto per…: un clic imposta forma, qualità e fluidità giuste per dove va il video
        SectionLabel(text: String(localized: "Pronto per"))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(SocialPreset.all, id: \.id) { preset in
                Chip(title: preset.name, selected: preset.matches(s.project), tint: tint) {
                    s.change(undo, String(localized: "Pronto per \(preset.name)")) { preset.apply(&$0) }
                }
                .help(preset.hint)
            }
        }
        SectionLabel(text: String(localized: "Forma"))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach([("orig", String(localized: "Originale")), ("9x16", "9:16 Reels"), ("1x1", String(localized: "1:1 Post")), ("4x5", String(localized: "4:5 Feed")), ("16x9", "16:9 YouTube")], id: \.0) { item in
                Chip(title: item.1, selected: s.project.aspect == item.0, tint: tint) {
                    s.change(undo, String(localized: "Formato \(item.1)")) { $0.aspect = item.0 }
                }
            }
        }
        Toggle("Inquadra le persone", isOn: Binding(get: { s.project.follow },
                                                   set: { v in s.change(undo, String(localized: "Inquadra le persone")) { $0.follow = v } }))
            .toggleStyle(.checkbox).font(.system(size: 12))
            .disabled(s.project.aspect == "orig")
            .help("Nel video finale l’inquadratura segue le persone con calma (in anteprima resta al centro)")
        SectionLabel(text: String(localized: "Qualità dell’esportazione"))
        HStack(spacing: 6) {
            ForEach([(720, "HD 720p"), (1080, "Full HD 1080p"), (2160, "4K")], id: \.0) { item in
                Chip(title: item.1, selected: s.project.resolution == item.0, tint: tint) {
                    s.change(undo, String(localized: "Risoluzione \(item.1)")) { $0.resolution = item.0 }
                }
            }
        }
        HStack(spacing: 6) {
            ForEach([30, 60], id: \.self) { f in
                Chip(title: f == 60 ? String(localized: "Più fluido (60)") : String(localized: "Normale (30)"), selected: s.project.fps == f, tint: tint) {
                    s.change(undo, String(localized: "\(f) fotogrammi al secondo")) { $0.fps = f }
                }
                .help(f == 60 ? String(localized: "Solo se i video sono girati a 60: non si inventano fotogrammi") : "")
            }
        }
        if let e = s.estimate {
            Text(String(localized: "\(Int(e.size.width)) × \(Int(e.size.height)) · circa \(Fmt.bytes(e.bytes))"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Azioni

    private func choose(audio: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = !audio
        p.canChooseDirectories = false
        p.allowedContentTypes = audio ? [.audio, .movie] : [.movie]
        p.prompt = audio ? String(localized: "Scegli") : String(localized: "Aggiungi")
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
        guard let c = targetClip, let action = Catalog.action(id: id, kind: .video) else { s.refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        s.lastJob = QueueStore.shared.enqueue(files: [c.url], action: action, param: param)
    }

    /// 5.0.1 · L'audio del pezzo tenuto nella clip, in un file M4A accanto al video.
    private func extractClipAudio() {
        guard let c = targetClip else { s.refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
        s.lastJob = QueueStore.shared.enqueue(files: [c.url], action: QuickMedia.clipAudio, param: String(format: "%.3f|%.3f", c.inPoint, c.outPoint))
    }

    private func quickGIF() {
        guard let c = targetClip, let action = Catalog.action(id: "gifcut", kind: .video) else { s.refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
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
            // 5.0.1 · ⌥ ← → un millisecondo
            key(.leftArrow, .option) { arrow(-1) { s.step(-0.001) } }
            key(.rightArrow, .option) { arrow(1) { s.step(0.001) } }
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
        self.init(title: String(localized: String.LocalizationValue(tool.rawValue)), symbol: tool.symbol, hint: tool.hint, selected: selected, used: used, tint: tint, action: action)
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
            .accessibilityLabel(clock.playing ? String(localized: "Pausa") : String(localized: "Riproduci"))
            Spacer()
            Text("\(s.timelineZoom > 1.01 ? formatTimeMs(clock.time) : formatTime(clock.time)) / \(formatTime(s.project.duration))")
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
    /// 5.0.1 · La fine della musica all'inizio del trascinamento
    @State private var dragStartEnd: Double? = nil
    @State private var moving: UUID? = nil
    @State private var moveDX: CGFloat = 0
    @State private var trimBefore: VideoProject? = nil
    @State private var trimIn: Double = 0
    @State private var trimOut: Double = 0
    @State private var frozenPPS: CGFloat = 1
    @State private var transitionFor: UUID? = nil

    /// 5.0.1 · Lo zoom più forte: fino a 4000 punti al secondo (un millisecondo = 4 punti), senza superare
    /// una sequenza larga 16 000 punti (oltre, macOS non disegna più le immagini).
    private func maxZoom(total: Double, width: CGFloat) -> Double {
        max(1, min(4000 * total, 16_000) / Double(max(width, 1)))
    }

    var body: some View {
        GeometryReader { g in
            let total = max(s.project.duration, 0.1)
            let zoom = min(max(1, s.timelineZoom), maxZoom(total: total, width: g.size.width))
            let width = g.size.width * CGFloat(zoom)
            let pps = width / CGFloat(total)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                    ZStack(alignment: .topLeading) {
                        // Il punto dell'indicatore: lo zoom lo tiene in vista
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(0, CGFloat(clock.time) * pps), height: 1)
                            Color.clear.frame(width: 1, height: 1).id("indicatore")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ruler(total: total, pps: pps, width: width)
                                .frame(height: 16)
                            clipsRow(pps: pps)
                                .frame(height: 52)
                            textsRow(total: total, pps: pps, width: width)
                                .frame(height: 22)
                            musicRow(total: total, pps: pps, width: width)
                                .frame(height: 26)
                        }
                        PlayheadLine(clock: clock, pps: pps, size: CGSize(width: width, height: g.size.height))
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, height: g.size.height, alignment: .topLeading)
                }
                .scrollDisabled(zoom <= 1.01)
                .onChange(of: s.timelineZoom) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("indicatore", anchor: .center) }
                }
                .gesture(MagnifyGesture().onChanged { v in
                    if zoomStart == nil { zoomStart = s.timelineZoom }
                    s.timelineZoom = min(max(1, (zoomStart ?? 1) * v.magnification), maxZoom(total: total, width: g.size.width))
                }.onEnded { _ in zoomStart = nil })
                .overlay(alignment: .topTrailing) { zoomControls(total: total, width: g.size.width) }
            }
        }
    }

    @State private var zoomStart: Double? = nil

    /// 5.0.1 · − / + e «Adatta»: lo zoom della sequenza (anche con due dita sul trackpad, ⌘+ e ⌘−)
    private func zoomControls(total: Double, width: CGFloat) -> some View {
        let mz = maxZoom(total: total, width: width)
        return HStack(spacing: 2) {
            Button { s.timelineZoom = max(1, s.timelineZoom / 1.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Meno zoom (⌘−)")
            Button { s.timelineZoom = min(mz, s.timelineZoom * 1.8) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .help("Più zoom, fino al millisecondo (⌘+, oppure due dita sul trackpad). ⌥← → sposta di un millisecondo")
            if s.timelineZoom > 1.01 {
                Button { s.timelineZoom = 1 } label: { Image(systemName: "arrow.left.and.right.square") }
                    .help("Tutto il montaggio nella larghezza")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.ink.opacity(0.7))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.background.opacity(0.92)))
        .offset(y: -2)
    }

    // Righello: clic o trascinamento per spostarsi
    private func ruler(total: Double, pps: CGFloat, width: CGFloat) -> some View {
        // 5.0.1 · Con lo zoom il righello arriva ai millesimi
        let step = TrimTimeline.tickStep(span: total, width: width * 0.75)
        let marks = Array(stride(from: 0.0, through: total, by: step))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.ink.opacity(0.05))
            ForEach(marks, id: \.self) { t in
                Text(step < 1 ? TrimTimeline.tickLabel(t, step: step) : formatShort(t)).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
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

    @ViewBuilder private func clipMenu(_ c: VPClip) -> some View {
        let pick = { s.selected = c.id }
        Button(c.isMuted ? String(localized: "Riaccendi l’audio della clip") : String(localized: "Spegni l’audio della clip")) { pick(); s.toggleClipAudio(undo) }
        Button("Stacca l’audio") { pick(); s.detachClipAudio(undo) }
        Divider()
        Button("Sposta la clip prima") { pick(); s.move(-1, undo) }
        Button("Sposta la clip dopo") { pick(); s.move(1, undo) }
        Button("Clip intera") { pick(); s.restoreClip(undo) }
        Divider()
        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
        Divider()
        Button("Togli la clip") { pick(); s.deleteClip(undo) }
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
                    // 5.1 · Clic destro con le azioni della clip; doppio clic apre lo strumento Clip
                    .contextMenu { clipMenu(c) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        s.selected = c.id
                        s.lastTool = VideoEditTool.clip.rawValue
                    })
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
                            s.change(undo, String(localized: "Sposta la clip")) { p in
                                let moved = p.clips.remove(at: old)
                                p.clips.insert(moved, at: min(newIndex, p.clips.count))
                            }
                            s.selected = c.id
                        })
                    .help(String(localized: "\(c.url.lastPathComponent) · clic per sceglierla, trascina per spostarla"))
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
        .help(tr == nil ? String(localized: "Aggiungi una transizione") : String(localized: "Transizione: \(VPTransition.name(tr!.kind))"))
        .accessibilityLabel(tr == nil ? String(localized: "Aggiungi transizione") : String(localized: "Transizione \(VPTransition.name(tr!.kind))"))
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
                    if let b = trimBefore { s.commit(from: b, undo, left ? String(localized: "Taglia l’inizio") : String(localized: "Taglia la fine")) }
                    trimBefore = nil
                })
            .help(left ? String(localized: "Trascina per tagliare l’inizio") : String(localized: "Trascina per tagliare la fine"))
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
                    Text(t.text.isEmpty ? String(localized: "Testo") : t.text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
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
                // 5.1 · Clic destro sul testo
                .contextMenu {
                    Button("Modifica il testo") { s.selectedText = t.id; openTexts(); s.seek(t.start + 0.05) }
                    Button("Vai all’inizio del testo") { s.seek(t.start) }
                    Divider()
                    Button("Rimuovi il testo") {
                        let id = t.id
                        s.change(undo, String(localized: "Rimuovi il testo")) { p in
                            p.texts?.removeAll { $0.id == id }
                            if p.texts?.isEmpty == true { p.texts = nil }
                        }
                        if s.selectedText == id { s.selectedText = nil }
                    }
                }
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
        // 4.0 · Cambiando l'inizio, le parole restano accese nel momento in cui vengono dette
        let words = mode == 1 ? dragBefore?.texts?.first(where: { $0.id == d.id })?.wordTimes : nil
        s.live { p in
            guard let i = p.texts?.firstIndex(where: { $0.id == d.id }) else { return }
            p.texts![i].start = start
            p.texts![i].end = end
            if let w = words { p.texts![i].wordTimes = w.map { max(0, d.start + $0 - start) } }
        }
    }

    private func endTextDrag() {
        Snap.reset()
        if let b = dragBefore { s.commit(from: b, undo, String(localized: "Sposta il testo")) }
        dragBefore = nil
        textDrag = nil
    }

    @ViewBuilder private func musicRow(total: Double, pps: CGFloat, width: CGFloat) -> some View {
        if let m = s.project.music {
            let start = min(max(0, m.offset), total)
            let end = s.musicEnd ?? VideoProjectBuilder.musicStop(m, total: total)
            let w = max(24, CGFloat(max(0.1, end - start)) * pps)
            let shown = min(w, max(24, width - CGFloat(start) * pps))
            let color = Theme.color(.audio)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.ink.opacity(0.04))
                // 5.0.1 · Barra trasparente con dentro l'onda: si vede dove c'è suono e dove no
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12))
                    MusicWave(peaks: s.musicPeaks, rate: VideoProjectStore.musicPeaksRate, inPoint: m.inPoint,
                              songDuration: s.songDuration ?? 0, loop: m.loop, pps: pps, color: color)
                    HStack(spacing: 5) {
                        Image(systemName: m.loop ? "repeat" : "music.note").font(.system(size: 9, weight: .bold))
                        Text(m.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(Theme.ink)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                }
                .frame(width: shown, height: 26, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 1))
                .contentShape(Rectangle())
                .offset(x: CGFloat(start) * pps)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if dragBefore == nil { dragBefore = s.project; dragStartOffset = m.offset; dragStartEnd = m.end }
                        let raw = min(max(0, dragStartOffset + Double(v.translation.width / pps)), max(0, total - 0.5))
                        let o = min(max(0, Snap.to(raw, Snap.marks(s.project, playhead: clock.time), pps: pps, id: "m")), max(0, total - 0.5))
                        let shift = o - dragStartOffset
                        s.live { p in
                            p.music?.offset = o
                            if let e = dragStartEnd { p.music?.end = e + shift }      // la fine si sposta con lei
                        }
                    }
                    .onEnded { _ in
                        Snap.reset()
                        if let b = dragBefore { s.commit(from: b, undo, String(localized: "Sposta la musica")) }
                        dragBefore = nil
                    })
                .onTapGesture { openMusic() }
                .help("Trascina per decidere dove parte la musica nel video; trascina il bordo destro per farla finire prima")
                // 5.1 · Clic destro sulla musica
                .contextMenu {
                    Button("Apri le opzioni della musica") { openMusic() }
                    Button("Musica fino a qui") { s.musicEndHere(undo) }
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.path)]) }
                    Divider()
                    Button("Rimuovi la musica") { s.removeMusic(undo) }
                }
                // 5.0.1 · Il bordo destro: dove finisce la musica
                Rectangle().fill(color)
                    .frame(width: 6, height: 26)
                    .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle().inset(by: -4))
                    .offset(x: CGFloat(start) * pps + shown - 6)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if dragBefore == nil { dragBefore = s.project; dragStartEnd = end }
                            let base = dragStartEnd ?? end
                            let raw = base + Double(v.translation.width / pps)
                            let e = min(max(start + 0.2, Snap.to(raw, Snap.marks(s.project, playhead: clock.time), pps: pps, id: "me")), total)
                            s.live { $0.music?.end = e >= total - 0.01 ? nil : e }
                        }
                        .onEnded { _ in
                            Snap.reset()
                            if let b = dragBefore { s.commit(from: b, undo, String(localized: "Fine della musica")) }
                            dragBefore = nil
                            dragStartEnd = nil
                        })
                    .help("Trascina per far finire la musica prima")
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: m.path + "\(s.songDuration ?? 0)") { s.loadMusicPeaks() }
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
    /// 5.0.1 · Di base solo la clip scelta: quello che fai a un pezzo diviso resta su quel pezzo
    @State private var onlyClip = true

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
                        s.change(undo, String(localized: "Filtro \(preset.name)")) { p in edit(&p) { $0.preset = preset.id; if $0.amount < 0.05 { $0.amount = 1 } } }
                    }
                }
            }
            EditSlider(title: String(localized: "Forza del filtro"), value: look.amount, range: 0...1, text: "\(Int((look.amount * 100).rounded()))%",
                       width: 260, s: s, undo: undo, name: String(localized: "Forza del filtro")) { p, v in edit(&p) { $0.amount = v } }
                .disabled(look.preset == "none")
            SectionLabel(text: String(localized: "Regolazioni"))
            adjust(String(localized: "Luminosità"), \.brightness, range: -1...1)
            adjust(String(localized: "Contrasto"), \.contrast, range: -1...1)
            adjust(String(localized: "Saturazione"), \.saturation, range: -1...1)
            adjust(String(localized: "Calore"), \.warmth, range: -1...1)
            adjust(String(localized: "Nitidezza"), \.sharpness, range: 0...1)
            adjust(String(localized: "Vignetta"), \.vignette, range: 0...1)
            Button("Ripristina") {
                s.change(undo, String(localized: "Rimuovi il filtro")) { p in
                    if let i = clipIndex, p.clips.indices.contains(i) { p.clips[i].look = nil } else { p.look = nil }
                }
            }
            .controlSize(.small)
            .help(onlyClip ? String(localized: "Toglie filtro e regolazioni da questa clip (torna quello del video)") : String(localized: "Toglie filtro e regolazioni da tutto il video"))
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
                chip(nil, String(localized: "Nessuna"), "minus")
                ForEach(VPTransition.kinds, id: \.id) { k in chip(k.id, k.name, k.symbol) }
            }
            if let tr = current {
                HStack {
                    Text("Durata").font(.callout)
                    Slider(value: Binding(get: { tr.duration }, set: { v in set { $0?.duration = v } }), in: 0.2...2, step: 0.1) { editing in
                        if editing { before = s.project } else if let b = before { s.commit(from: b, undo, String(localized: "Durata della transizione")); before = nil }
                    }
                        .frame(width: compact ? 130 : 160)
                    Text(Fmt.secs(tr.duration)).font(.callout).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("Se una clip è corta, la transizione si accorcia da sola.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Applica a tutte le clip") {
                    s.change(undo, String(localized: "Transizione a tutte")) { p in
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
            s.change(undo, id == nil ? String(localized: "Rimuovi la transizione") : String(localized: "Transizione")) { p in
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
        guard let i = index else { s.refuse(String(localized: "Scegli prima una clip nella sequenza.")); return }
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
                            Button(Self.speedLabel(v)) { change(String(localized: "Velocità")) { $0.speed = v } }
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
                    Picker("", selection: Binding(get: { fx.zoom }, set: { v in change(String(localized: "Zoom lento")) { $0.zoom = v } })) {
                        Text("No").tag("none")
                        Image(systemName: "plus.magnifyingglass").tag("in").help("Si avvicina piano")
                        Image(systemName: "minus.magnifyingglass").tag("out").help("Si allontana piano")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("Gira").font(.system(size: 12))
                    Spacer()
                    Toggle(isOn: Binding(get: { fx.flipH }, set: { v in change(String(localized: "Capovolgi")) { $0.flipH = v } })) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .toggleStyle(.button).help("Specchia (destra ↔ sinistra)")
                    Toggle(isOn: Binding(get: { fx.flipV }, set: { v in change(String(localized: "Capovolgi")) { $0.flipV = v } })) {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .toggleStyle(.button).help("Capovolgi (sopra ↔ sotto)")
                    Button { change(String(localized: "Ruota")) { $0.rotate = ($0.rotate + 90) % 360 } } label: {
                        Image(systemName: "rotate.right")
                    }
                    .help("Ruota di 90° · ora \(fx.rotate)°")
                }
                EditSlider(title: String(localized: "Sfocatura"), value: fx.blur, range: 0...1, text: fx.blur < 0.01 ? String(localized: "No") : "\(Int(fx.blur * 100))%",
                           width: 260, s: s, undo: undo, name: String(localized: "Sfocatura")) { p, v in Self.edit(&p, i) { $0.blur = v } }
                HStack(spacing: 12) {
                    EditSlider(title: String(localized: "Entrata"), value: fx.fadeIn, range: 0...2, text: fx.fadeIn < 0.05 ? String(localized: "No") : Fmt.secs(fx.fadeIn),
                               width: 124, s: s, undo: undo, name: String(localized: "Dissolvenza in entrata")) { p, v in Self.edit(&p, i) { $0.fadeIn = v < 0.05 ? 0 : v } }
                    EditSlider(title: String(localized: "Uscita"), value: fx.fadeOut, range: 0...2, text: fx.fadeOut < 0.05 ? String(localized: "No") : Fmt.secs(fx.fadeOut),
                               width: 124, s: s, undo: undo, name: String(localized: "Dissolvenza in uscita")) { p, v in Self.edit(&p, i) { $0.fadeOut = v < 0.05 ? 0 : v } }
                }
                HStack(spacing: 6) {
                    Button("A tutte le clip") {
                        let e = fx
                        s.change(undo, String(localized: "Effetti a tutte le clip")) { p in
                            for k in p.clips.indices { p.clips[k].fx = e.isIdentity ? nil : e }
                        }
                    }
                    .help("Copia questi effetti su tutte le clip")
                    Button("Ripristina") { change(String(localized: "Rimuovi gli effetti")) { $0 = VPEffects() } }
                        .disabled(fx.isIdentity)
                }
                .controlSize(.small)
            } else {
                Text("Scegli una clip nella sequenza (clic sulla clip) per darle i suoi effetti.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Divider()
            SectionLabel(text: String(localized: "Su tutto il video"))
            hideButton
        }
        .sheet(isPresented: $showHide) { hideSheet }
    }

    /// 2.9.8 · Nascondi un logo su tutto il montaggio (sfocatura o pixel).
    private var hideButton: some View {
        HStack(spacing: 6) {
            Button { showHide = true } label: { Label(s.project.hide == nil ? String(localized: "Nascondi un logo…") : String(localized: "Logo nascosto ✓"), systemImage: "eye.slash") }
                .controlSize(.small).help("Sfoca o copri a pixel un logo o una scritta in tutto il video")
            if s.project.hide != nil {
                Button("Rimuovi") { s.change(undo, String(localized: "Rimuovi la copertura")) { $0.hide = nil } }.controlSize(.small)
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
            if let v { s.change(undo, String(localized: "Nascondi un logo")) { $0.hide = v } }
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

/// 5.0.1 · L'onda della musica dentro la sua barra nel Montaggio. Segue il punto della canzone da cui parte
/// e, se si ripete, ricomincia da lì.
private struct MusicWave: View {
    let peaks: [Float]
    let rate: Double
    let inPoint: Double
    let songDuration: Double
    let loop: Bool
    let pps: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, pps > 0, songDuration > 0 else { return }
            let avail = max(0.05, songDuration - inPoint)
            let step: CGFloat = 2.5
            let mid = size.height / 2 + 4                  // un filo sotto il nome
            let maxH = (size.height - 10) / 2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                var t = Double(x / pps)
                if t >= avail { if loop { t = t.truncatingRemainder(dividingBy: avail) } else { break } }
                let a = Int((inPoint + t) * rate), b = Int((inPoint + t + Double(step / pps)) * rate)
                var v: Float = 0
                if a < peaks.count {
                    for j in max(0, a)...min(peaks.count - 1, max(a, b)) where peaks[j] > v { v = peaks[j] }
                }
                let h = max(0.5, CGFloat(v) * maxH)
                path.addRect(CGRect(x: x, y: mid - h, width: step - 1, height: h * 2))
                x += step
            }
            ctx.fill(path, with: .color(color.opacity(0.75)))
        }
        .allowsHitTesting(false)
    }
}
