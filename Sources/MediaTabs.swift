import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

// ════════════════════════════════════════════════════════════════════
//  2.6 · Scheda «Audio» (schede strumento) e pezzi comuni alle schede (la scheda Video è in VideoEditor.swift)
// ════════════════════════════════════════════════════════════════════

/// Il file aperto in una scheda (resta caricato anche cambiando scheda).
final class MediaTabModel: ObservableObject, @unchecked Sendable {
    let videoTab: Bool
    @Published var file: URL? = nil
    @Published var trim: TrimModel? = nil
    @Published var info = ""
    /// Misura del video così come si vede (già girato), per l'anteprima del formato social.
    @Published var videoSize: CGSize = .zero
    /// Altri file per «Unisci» (il primo è sempre `file`).
    @Published var extra: [URL] = []
    @Published var lastJob: Job? = nil
    @Published var notice: String? = nil
    /// Selezione iniziale e massima dei file che si aprono (es. suoneria: 30 s, al massimo 30).
    var trimDefaultLength: Double? = nil
    var trimMaxLength: Double? = nil

    /// 2.8.4 · Gli ultimi file aperti, per riprenderli con un clic (solo quelli che esistono ancora).
    @Published private(set) var recents: [URL] = []
    private var recentsKey: String { videoTab ? "videoTabRecents" : "audioTabRecents" }
    static let maxRecents = 6

    // 2.8.5 · Progetti audio (vedi AudioProjects.swift)
    @Published var audioProjects: [AudioProject] = []
    /// Lo strumento da rimettere quando si riprende un progetto (lo legge la scheda e lo azzera).
    @Published var restoredTool: String? = nil
    var currentProject: UUID? = nil
    var currentTool = "ringtone"
    var restoringProject = false
    var projectSave: DispatchWorkItem? = nil
    var restoreCancellable: AnyCancellable? = nil
    private var selectionCancellable: AnyCancellable? = nil
    let projectsFolder: URL

    init(videoTab: Bool, projectsFolder: URL = AudioProjectLibrary.folder) {
        self.videoTab = videoTab
        self.projectsFolder = projectsFolder
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recents = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshProjects()
    }

    /// La scheda avvisa quando cambia strumento: si ricorda nel progetto.
    func toolChanged(_ id: String) {
        guard id != currentTool else { return }
        currentTool = id
        scheduleProjectSave()
    }

    func remember(_ url: URL) {
        recents = Self.pushRecent(url, into: recents, max: Self.maxRecents)
        UserDefaults.standard.set(recents.map { $0.path }, forKey: recentsKey)
    }

    func forgetRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    /// In cima l'ultimo aperto, niente doppioni, al massimo `max`.
    static func pushRecent(_ url: URL, into list: [URL], max: Int) -> [URL] {
        Array(([url] + list.filter { $0.standardizedFileURL.path != url.standardizedFileURL.path }).prefix(max))
    }

    /// Formati che i motori di macOS leggono direttamente.
    static let readable: Set<String> = ["mp4", "mov", "m4v", "3gp", "mp3", "m4a", "wav", "aiff", "aac", "flac", "caf",
                                        "m4b", "aifc"]          // 2.9.6

    var accepted: Set<Kind> { videoTab ? [.video] : [.audio, .video] }
    var allFiles: [URL] { (file.map { [$0] } ?? []) + extra }

    /// File trascinati o scelti: il primo si apre, gli altri restano pronti per «Unisci».
    func load(_ urls: [URL], append: Bool = false) {
        var seenPaths = Set<String>()
        let right = PieController.expand(urls)
            .filter { u in Catalog.kind(of: u).map { accepted.contains($0) } ?? false }
            .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }      // lo stesso file una volta sola
        // Formati che macOS non sa leggere da solo: si preparano da soli e poi si aprono
        let ok = right.filter { Self.readable.contains(Catalog.norm($0.pathExtension)) }
        let other = right.filter { !Self.readable.contains(Catalog.norm($0.pathExtension)) }
        if !other.isEmpty {
            notice = other.count == 1 ? "Preparo «\(other[0].lastPathComponent)»: si apre tra poco." : "Preparo \(other.count) file: si aprono tra poco."
            let target = videoTab ? "mp4" : "m4a"
            let kind: Kind = videoTab ? .video : (Catalog.kind(of: other[0]) ?? .audio)
            AutoConvert.prepare(other, to: target, kind: kind) { [weak self] ready in
                guard let self else { return }
                self.notice = nil
                self.load(ready, append: self.file != nil)
            }
        }
        guard !ok.isEmpty else {
            if right.isEmpty {
                notice = videoTab ? "Qui si aprono solo i video." : "Qui si aprono file audio (o video, per usarne l’audio)."
                NSSound.beep()
            }
            return
        }
        if other.isEmpty { notice = nil }
        if append, file != nil {
            for u in ok where !allFiles.contains(u) { extra.append(u) }
            scheduleProjectSave()
            return
        }
        extra = Array(ok.dropFirst())
        open(ok[0])
    }

    func open(_ url: URL) {
        trim?.pause()
        trim?.cancelLoading()
        file = url
        remember(url)
        lastJob = nil
        let t = TrimModel(url: url, isVideo: videoTab, defaultLength: trimDefaultLength)
        t.maxLength = trimMaxLength
        trim = t
        // 2.8.5 · Ogni spostamento della selezione si salva nel progetto (dopo una breve pausa)
        selectionCancellable = t.$start.combineLatest(t.$end).dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleProjectSave() }
        startProject(for: url)
        info = ""
        videoSize = .zero
        Task { await self.loadInfo(url) }
    }

    func close() {
        trim?.pause()
        trim?.cancelLoading()
        scheduleProjectSave()
        selectionCancellable = nil
        restoreCancellable = nil
        currentProject = nil
        trim = nil
        file = nil
        extra = []
        info = ""
        lastJob = nil
        // il salvataggio parte tra un attimo: l'elenco si rilegge dopo
        AudioProjectLibrary.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            DispatchQueue.main.async { self?.refreshProjects() }
        }
    }

    func removeExtra(_ u: URL) {
        extra.removeAll { $0 == u }
        scheduleProjectSave()
    }

    @MainActor
    private func loadInfo(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first,
           let ns = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: ns).applying(t)
            let size = CGSize(width: abs(r.width), height: abs(r.height))
            if videoTab { videoSize = size }
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 { parts.append(formatShort(d)) }
        parts.append(Fmt.bytes(Job.size(of: url)))
        guard file == url else { return }
        info = parts.joined(separator: " · ")
    }

    /// Mette in coda un lavoro e lo tiene d'occhio nella scheda.
    func run(_ actionId: String, param: String, files: [URL]? = nil, dest: URL? = nil) {
        let list = files ?? allFiles.prefix(1).map { $0 }
        guard !list.isEmpty else { NSSound.beep(); return }
        let kind = Catalog.kind(of: list[0]) ?? (videoTab ? .video : .audio)
        guard let action = Catalog.action(id: actionId, kind: kind) else { NSSound.beep(); return }
        trim?.pause()
        lastJob = QueueStore.shared.enqueue(files: list, action: action, param: param, dest: dest)
    }

    func choose(append: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = videoTab ? [.movie] : [.audio, .movie]
        p.prompt = append ? "Aggiungi" : "Apri"
        Sheet.choose(p) { [weak self] urls in if !urls.isEmpty { self?.load(urls, append: append) } }
    }
}

func formatShort(_ t: Double) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Pezzi comuni

/// Area vuota: trascina un file o clicca per sceglierlo.
struct MediaDropZone: View {
    let kind: Kind
    let title: String
    let subtitle: String
    let targeted: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.color(kind).opacity(0.16)).frame(width: 96, height: 96)
                    Image(systemName: Theme.symbol(kind)).font(.system(size: 36, weight: .semibold)).foregroundStyle(Theme.color(kind))
                }
                Text(targeted ? "Rilascia per aprire" : title).font(.system(size: 19, weight: .bold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.color(kind).opacity(targeted ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.color(kind).opacity(targeted ? 0.9 : 0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Avanzamento dell'ultimo lavoro avviato dalla scheda, con «Mostra nel Finder» alla fine.
struct JobStrip: View {
    @ObservedObject var job: Job
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.action.title).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if job.state == .running || job.state == .waiting || job.state == .done {
                    TunerBar(value: job.shownProgress, tint: Theme.green, done: job.state == .done, height: 18)
                }
            }
            if job.state == .running || job.state == .waiting {
                Button { QueueStore.shared.cancel(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Interrompi")
                    .accessibilityLabel("Interrompi")
            } else if job.state == .done, !job.outputs.isEmpty {
                // 3.1 · Prima e dopo, a un clic
                let pairs = job.comparePairs
                if !pairs.isEmpty {
                    Button { CompareController.shared.show(pairs, title: job.title) } label: { Label("Confronta", systemImage: "square.split.2x1") }
                        .help("Originale e risultato fianco a fianco, con la linea da trascinare")
                }
                UseInMenu(url: job.outputs[0])          // 3.0 · il passo successivo, in un clic
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
            }
            // 2.7.5 · Errore: il pulsante che lo risolve, subito accanto
            if let fix = Fix.best(for: job) {
                Button { QueueStore.shared.apply(fix, to: job) } label: { Label(fix.label, systemImage: fix.symbol) }
                    .buttonStyle(.borderedProminent).tint(Theme.brass)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .card(radius: 12)
    }

    static func folderName(_ u: URL) -> String {
        let d = u.deletingLastPathComponent()
        let home = Paths.home.path
        switch d.path {
        case home + "/Desktop": return "Scrivania"
        case home + "/Downloads": return "Download"
        case home + "/Documents": return "Documenti"
        case home + "/Movies": return "Filmati"
        case home + "/Music": return "Musica"
        case home + "/Pictures": return "Immagini"
        default: return "«" + d.lastPathComponent + "»"
        }
    }

    private var statusText: String {
        switch job.state {
        case .waiting: return "In attesa"
        case .running: return job.status
        case .done:
            // Sempre anche la cartella: il file creato si trova subito
            let folder = job.outputs.first.map { Self.folderName($0) } ?? ""
            let gain = job.gainText.isEmpty ? "" : " · " + job.gainText
            return (job.outputs.count == 1 ? "«\(job.outputs[0].lastPathComponent)» in \(folder)"
                : "\(job.outputs.count) file in \(folder)") + gain
        case .failed: return job.failures.first ?? "Non riuscito"
        case .cancelled: return "Interrotto"
        }
    }
}

/// Pulsante «a pastiglia» per scegliere tra poche opzioni.
struct Chip: View {
    let title: String
    let selected: Bool
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Theme.ivory)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.clear : Theme.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.brass)
    }
}

/// Elenco dei file da unire, con l'ordine e il pulsante per aggiungerne.
private struct MergeList: View {
    @ObservedObject var m: MediaTabModel
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(m.allFiles.enumerated()), id: \.element) { i, u in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(tint.gradient))
                    Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if i > 0 {
                        Button { m.removeExtra(u) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Togli dall’elenco")
                    }
                }
            }
            Button { m.choose(append: true) } label: { Label("Aggiungi…", systemImage: "plus") }
        }
    }
}

// MARK: - Scheda Audio (3.0: come il Video, con il pannello degli strumenti a destra)

enum AudioTool: String, CaseIterable, Identifiable {
    case ringtone, cut, normalize, voiceclean, speed, silence, transcribe, tts, whatsapp, merge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ringtone: return "Suoneria iPhone"
        case .cut: return "Taglia"
        case .normalize: return "Volume uniforme"
        case .voiceclean: return "Voce più pulita"
        case .speed: return "Velocità"
        case .silence: return "Rimuovi i silenzi"
        case .transcribe: return "Trascrivi"
        case .tts: return "Testo in voce"
        case .whatsapp: return "Per WhatsApp"
        case .merge: return "Unisci"
        }
    }
    /// Il nome breve, sul pulsante del pannello.
    var short: String {
        switch self {
        case .ringtone: return "Suoneria"
        case .normalize: return "Volume"
        case .voiceclean: return "Pulisci"
        case .silence: return "Silenzi"
        case .tts: return "Voce"
        case .whatsapp: return "WhatsApp"
        default: return title
        }
    }
    /// 2.8.4 · Cosa fare adesso, in una frase.
    var hint: String {
        switch self {
        case .ringtone: return "Sposta il riquadro sul pezzo che ti piace (fino a 30 secondi): ottieni la suoneria per iPhone."
        case .cut: return "Trascina le maniglie per tenere solo il pezzo che serve. Tasti I e O mentre ascolti."
        case .normalize: return "Rende il volume uniforme: né troppo basso né distorto. Per vocali, lezioni e podcast."
        case .voiceclean: return "Attenua il ronzio e il fruscio di fondo e rende il volume uniforme. La voce resta naturale."
        case .speed: return "Più lento o più veloce, su tutto il file. La voce mantiene il suo tono."
        case .silence: return "Toglie le pause lunghe, su tutto il file. Ottimo per lezioni e registrazioni."
        case .transcribe: return "Le parole diventano testo e sottotitoli, sul Mac, senza internet."
        case .tts: return "Scrivi o incolla un testo: una voce naturale lo legge in un file audio."
        case .whatsapp: return "Un vocale leggero con la voce chiara, che parte subito anche con poca rete."
        case .merge: return "Più file audio in uno solo, nell’ordine dell’elenco."
        }
    }
    var symbol: String {
        switch self {
        case .ringtone: return "bell.and.waves.left.and.right"
        case .cut: return "scissors"
        case .normalize: return "speaker.wave.2"
        case .voiceclean: return "waveform.and.mic"
        case .speed: return "speedometer"
        case .silence: return "waveform.badge.minus"
        case .transcribe: return "captions.bubble"
        case .tts: return "text.bubble"
        case .whatsapp: return "message"
        case .merge: return "square.stack.3d.up"
        }
    }
    /// Lavora sulla selezione (le maniglie) e non su tutto il file.
    var usesSelection: Bool { self == .ringtone || self == .cut }
}

/// Ascolto di prova della sintesi vocale.
final class SpeechPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// 3.4.2 · La voce si prepara solo quando serve: crearla subito rallentava l'apertura della scheda Audio
    private lazy var synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        return s
    }()
    private var started = false
    @Published var speaking = false
    override init() { super.init() }
    func speak(_ text: String, voice: String?, rate: Float) {
        stop()
        let sample = String(text.prefix(400))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        started = true
        synth.speak(Speech.utterance(sample, voice: voice, rate: rate))
        speaking = true
    }
    func stop() { if started, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }; speaking = false }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.speaking = false } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { self.speaking = false } }
}

struct AudioTabView: View {
    @ObservedObject var m: MediaTabModel
    @State private var tool: AudioTool = .ringtone

    init(m: MediaTabModel, startTool: AudioTool = .ringtone) {
        self.m = m
        _tool = State(initialValue: startTool)
    }
    @State private var ringLength: Double = 30
    @State private var fade = true
    @State private var normalize = true
    @State private var speed = "1.25"
    @State private var text = ""
    @State private var voiceId = ""
    @State private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var allLanguages = false
    @State private var targeted = false
    @StateObject private var preview = SpeechPreview()
    /// 4.1 · «Da un link…»
    @State private var showLink = false

    private let tint = Theme.color(.audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    mainArea
                    // 2.8.5 · I progetti audio, come i progetti del Video
                    if m.file == nil && tool != .tts && !m.audioProjects.isEmpty { AudioProjectsRow(m: m, tint: tint) }
                }
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                inspector.frame(width: 290)
            }
            .frame(maxHeight: .infinity)
            if let n = m.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let job = m.lastJob {
                JobStrip(job: job)
                SendToPhoneStrip(job: job)          // 2.9.5 · sotto la suoneria pronta
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                Sounds.drop()
                m.load(urls, append: m.file != nil && tool == .merge)
                if tool == .tts { tool = .ringtone }
            }
            return true
        }
        .onAppear { applyTrimRules(); m.currentTool = tool.rawValue; m.refreshProjects() }
        // 3.5.1 · Solo il cambio di scheda, non ogni modifica dell'app: la scheda nascosta non si ridisegna
        .onReceive(AppState.shared.$selection.dropFirst().removeDuplicates()) { now in
            if now == .audio { m.refreshProjects() } else { preview.stop(); m.trim?.pause() }
        }
        .onChange(of: m.restoredTool) { _, v in
            // 2.8.5 · progetto ripreso: torna lo strumento che usavi
            if let v, let t = AudioTool(rawValue: v) { tool = t }
            m.restoredTool = nil
        }
        .onChange(of: tool) { _, t in
            m.toolChanged(t.rawValue)
            applyTrimRules()
            if t == .ringtone { m.trim?.setLength(ringLength) }
            if t != .tts { preview.stop() }
        }
        .onDisappear { preview.stop(); m.trim?.pause() }
        .sheet(isPresented: $showLink) {
            LinkSheet(onDone: { file in
                m.load([file])
                // Suoneria: il riquadro va già sul ritornello
                if tool == .ringtone, let t = m.trim {
                    let len = ringLength
                    if t.loading { t.onLoaded = { [weak t] in t?.suggestChorus(length: len) } } else { t.suggestChorus(length: len) }
                }
            }, close: { showLink = false })
        }
    }

    // MARK: Intestazione

    private var header: some View {
        HStack(spacing: 10) {
            TitleAccent(color: Theme.color(.audio)).padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                if tool == .tts {
                    // 3.0 · In «Testo in voce» non c'è un file aperto: niente nome di file
                    Text("Testo in voce").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Scrivi un testo: diventa un file audio").font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else if let f = m.file {
                    Text(f.deletingPathExtension().lastPathComponent).font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    Text(([Catalog.norm(f.pathExtension).uppercased()] + [m.info]).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Audio").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Suonerie, tagli, volume, voce e altro").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let trim = m.trim, tool != .tts { PlayButton(trim: trim, tint: tint) }
            // 4.1 · Discreto: un pulsante come gli altri, accanto ad «Apri un altro…»
            if tool != .tts {
                Button { showLink = true } label: { Label("Da un link…", systemImage: "link") }
                    .help("Incolla il link di una canzone: arriva qui, pronta per suoneria e taglio")
            }
            if m.file != nil && tool != .tts {
                Button("Apri un altro…") { m.choose(append: false) }
                    .help("Apri un altro file audio (questo resta tra i progetti)")
                Button { m.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.ink.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Chiudi il file (resta tra i progetti)")
                .accessibilityLabel("Chiudi il file")
            }
        }
    }

    // MARK: A sinistra: l'onda, il testo o lo spazio per trascinare

    @ViewBuilder private var mainArea: some View {
        if tool == .tts {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                    if text.isEmpty {
                        Text("Scrivi o incolla qui il testo da leggere…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 16).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .card(radius: 14)
                Text(text.count == 1 ? "1 carattere" : "\(text.count) caratteri").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if let trim = m.trim {
            AudioWave(trim: trim, tint: tint, selection: tool.usesSelection)
        } else {
            MediaDropZone(kind: .audio, title: "Trascina qui un file audio",
                          subtitle: "oppure clicca per sceglierlo · MP3, M4A, WAV e altri · anche un video, per usarne l’audio",
                          targeted: targeted) { m.choose(append: false) }
                .frame(minHeight: 200)
        }
    }

    // MARK: A destra: strumenti, opzioni, pulsante

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(AudioTool.allCases) { t in
                    ToolTab(title: t.short, symbol: t.symbol, hint: t.title + ": " + t.hint, selected: tool == t, tint: tint) { tool = t }
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: tool.title)
                    Text(tool.hint).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    options
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            Divider()
            Button(action: start) {
                Text(actionTitle).font(.system(size: 13.5, weight: .bold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            // Mentre si scrive il testo, Invio va a capo e non avvia
            .keyboardShortcut(tool == .tts ? nil : KeyboardShortcut.defaultAction)
            .disabled(!canStart)
            .help(canStart ? "" : (tool == .tts ? "Scrivi prima un testo" : (tool == .merge ? "Servono almeno due file" : "Apri prima un file audio")))
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Suoneria: selezione di 20–30 secondi, anche per i file aperti dopo.
    private func applyTrimRules() {
        let ring = tool == .ringtone
        m.trimDefaultLength = ring ? ringLength : nil
        // 2.9.4 · Al massimo 30 s: è il limite di «Usa come suoneria» sull'iPhone (iOS 26)
        m.trimMaxLength = ring ? 30 : nil
        m.trim?.maxLength = ring ? 30 : nil
    }

    @ViewBuilder private var options: some View {
        switch tool {
        case .ringtone:
            Text("Durata").font(.system(size: 12.5)).foregroundStyle(.secondary)
            Picker("", selection: $ringLength) {
                Text("20 secondi").tag(20.0); Text("30 secondi").tag(30.0)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: ringLength) { _, v in m.trim?.setLength(v); applyTrimRules() }
            if let t = m.trim {
                Button { t.suggestChorus(length: ringLength) } label: { Label("Vai al ritornello", systemImage: "music.note") }
                    .controlSize(.small)
                    .help("Sposta il riquadro sul pezzo più pieno della canzone, di solito il ritornello")
            }
            Toggle("Dissolvenza all’inizio e alla fine", isOn: $fade).toggleStyle(.checkbox)
            Toggle("Volume uniforme", isOn: $normalize).toggleStyle(.checkbox)
            note("Alla fine puoi mandarla all’iPhone con AirDrop o con il codice QR.")
        case .cut:
            if let trim = m.trim { SelectionText(trim: trim) }
        case .normalize, .voiceclean, .silence, .whatsapp, .transcribe:
            EmptyView()
        case .speed:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach([("0.5", "0,5×"), ("0.75", "0,75×"), ("1.25", "1,25×"), ("1.5", "1,5×"), ("2", "2×")], id: \.0) { v in
                    Chip(title: v.1, selected: speed == v.0, tint: tint) { speed = v.0 }
                }
            }
            note(speedNote)
        case .tts:
            Picker("Voce", selection: $voiceId) {
                Text("La più naturale").tag("")
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name) · \(Speech.qualityLabel(v))" + (allLanguages ? " · \(v.language)" : "")).tag(v.identifier)
                }
            }
            Toggle("Mostra le voci di tutte le lingue", isOn: $allLanguages).toggleStyle(.checkbox)
            HStack {
                Text("Velocità").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate + 0.25)...Double(AVSpeechUtteranceMaximumSpeechRate - 0.25))
            }
            HStack {
                Button(preview.speaking ? "Ferma" : "Ascolta una prova") {
                    if preview.speaking { preview.stop() } else { preview.speak(text, voice: voiceId.isEmpty ? nil : voiceId, rate: Float(rate)) }
                }
                Button("Altre voci…") { openVoiceSettings() }
                    .help("Impostazioni di Sistema → Accessibilità → Contenuti letti → Voce di sistema → Gestisci voci")
            }
            note("Le voci «Premium» sono le più naturali. Il file va in Download.")
        case .merge:
            if m.file == nil {
                note("Apri il primo file, poi aggiungi gli altri.")
            } else {
                MergeList(m: m, tint: tint)
            }
        }
    }

    private var speedNote: String {
        guard let d = m.trim?.duration, d > 0, let v = Double(speed), v > 0 else { return "Su tutto il file." }
        return "Su tutto il file: da \(formatShort(d)) a circa \(formatShort(d / v))."
    }

    private var voices: [AVSpeechSynthesisVoice] {
        allLanguages ? Speech.voices(language: "") : Speech.voices(language: "it")
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var actionTitle: String {
        switch tool {
        case .ringtone: return "Crea la suoneria"
        case .cut: return "Taglia"
        case .normalize: return "Rendi uniforme il volume"
        case .voiceclean: return "Pulisci la voce"
        case .speed: return "Cambia la velocità"
        case .silence: return "Rimuovi i silenzi"
        case .transcribe: return "Trascrivi"
        case .tts: return "Crea il file audio"
        case .whatsapp: return "Crea il vocale"
        case .merge: return m.allFiles.count >= 2 ? "Unisci \(m.allFiles.count) file" : "Unisci"
        }
    }

    private var canStart: Bool {
        switch tool {
        case .tts: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .merge: return m.allFiles.count >= 2
        // 4.1.4 · Suoneria e Taglia aspettano la forma d'onda: prima la selezione vale 0–0
        default: return m.file != nil && !(tool.usesSelection && (m.trim?.loading ?? true))
        }
    }

    private func start() {
        preview.stop()
        if tool == .tts { startTTS(); return }
        guard let trim = m.trim else { return }
        let sel = String(format: "%.3f|%.3f", trim.start, trim.end)
        switch tool {
        case .ringtone: m.run("ringtone", param: sel + "|\(fade ? 1 : 0)|\(normalize ? 1 : 0)")
        case .cut: m.run("cut", param: sel)
        case .normalize: m.run("normalize", param: "")
        case .voiceclean: m.run("voiceclean", param: "")
        case .speed: m.run("speed", param: speed)
        case .silence: m.run("silence", param: "")
        case .transcribe: m.run("transcribe", param: "")
        case .tts: startTTS()
        case .whatsapp: m.run("whatsapp", param: "")
        case .merge: m.run("amerge", param: "", files: m.allFiles)
        }
    }

    /// Il testo va in un file di appoggio; il risultato finisce in Download (o nella cartella fissa delle Opzioni).
    private func startTTS() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { NSSound.beep(); return }
        let dir = Paths.support.appendingPathComponent("Testo in voce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Media.ttsName(t, fallback: "Testo").replacingOccurrences(of: " (voce)", with: "")
        let src = dir.appendingPathComponent(name + ".txt")
        do { try t.write(to: src, atomically: true, encoding: .utf8) } catch { NSSound.beep(); return }
        let prefs = ScriptPrefs.load()
        var dest = Paths.home.appendingPathComponent("Downloads")
        if prefs["dest"] == "fixed", let d = prefs["destpath"], FileManager.default.fileExists(atPath: d) { dest = URL(fileURLWithPath: d) }
        let param = voiceId + "|" + String(format: "%.3f", rate)
        guard let action = Catalog.action(id: "tts", kind: .doc) else { return }
        m.lastJob = QueueStore.shared.enqueue(files: [src], action: action, param: param, dest: dest)
    }

    private func openVoiceSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.preference.universalaccess"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}

private struct PlayButton: View {
    @ObservedObject var trim: TrimModel
    let tint: Color
    var body: some View {
        Button { trim.togglePlay() } label: {
            Label(trim.playing ? "Pausa" : "Ascolta la selezione", systemImage: trim.playing ? "pause.fill" : "play.fill")
        }
        .keyboardShortcut(.space, modifiers: [])
        .help("Spazio")
    }
}

private struct SelectionText: View {
    @ObservedObject var trim: TrimModel
    var body: some View {
        Text("\(formatTime(trim.start)) → \(formatTime(trim.end)) · \(formatTime(max(0, trim.end - trim.start)))")
            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
    }
}

private struct AudioWave: View {
    @ObservedObject var trim: TrimModel
    let tint: Color
    /// 3.0 · Solo Suoneria e Taglia usano la selezione: gli altri strumenti lavorano su tutto il file.
    var selection = true

    /// 3.8 · Con lo zoom i tempi si leggono al millesimo.
    private func t(_ x: Double) -> String { trim.zoom > 1 ? formatTimeMs(x) : formatTime(x) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            zoomBar
            // 4.1.1 · Bassa di base; «Altezza +» allarga il riquadro (le barre restano in proporzione)
            TrimTimeline(m: trim, tint: tint, showSelection: selection, showRuler: true)
                .frame(height: 96 * trim.gain)
                .animation(.easeOut(duration: 0.18), value: trim.gain)
                .overlay { if trim.loading { ProgressView().controlSize(.small) } }
                .padding(.top, 6)
            if trim.zoom > 1 { WaveOverview(m: trim, tint: tint).frame(height: 14) }
            HStack {
                Text(t(trim.zoom > 1 ? trim.viewStart : 0)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if selection {
                    Text("\(t(trim.start)) → \(t(trim.end)) · \(t(max(0, trim.end - trim.start)))")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Spacer()
                    Button("Inizio qui") { trim.markIn() }.keyboardShortcut("i", modifiers: []).controlSize(.small)
                        .help("La selezione comincia dove stai ascoltando (I)")
                    Button("Fine qui") { trim.markOut() }.keyboardShortcut("o", modifiers: []).controlSize(.small)
                        .help("La selezione finisce dove stai ascoltando (O)")
                } else {
                    Text("Su tutto il file").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(t(trim.zoom > 1 ? trim.viewStart + trim.span : trim.duration))
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(16)
        .card(radius: 14)
    }

    /// Zoom in larghezza (tempo) e in altezza (onda), più «Selezione» e «Tutto».
    private var zoomBar: some View {
        HStack(spacing: 10) {
            Text(trim.zoom > 1 ? "Zoom \(Fmt.decimal(trim.zoom, digits: trim.zoom < 10 ? 1 : 0))×" : "Tutto il file")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            zoomPair(icon: "arrow.left.and.right", label: "Larghezza",
                     minus: { trim.zoomOut() }, plus: { trim.zoomIn() },
                     canMinus: trim.zoom > 1, canPlus: trim.zoom < trim.maxZoom,
                     help: "Allarga o restringi il tempo: al massimo si vede un quarto di secondo, per tagliare al millesimo. Anche pizzicando il trackpad o con ⌘ e la rotellina.")
            zoomPair(icon: "arrow.up.and.down", label: "Altezza",
                     minus: { trim.gain = max(1, trim.gain / 1.5) }, plus: { trim.gain = min(TrimModel.maxGain, trim.gain * 1.5) },
                     canMinus: trim.gain > 1.01, canPlus: trim.gain < TrimModel.maxGain - 0.01,
                     help: "Riquadro più alto: si vedono meglio i suoni bassi e i silenzi")
            if selection {
                Button("Selezione") { trim.zoomToSelection() }.controlSize(.small)
                    .help("Ingrandisce sul pezzo scelto, per rifinire inizio e fine")
            }
            Button("Tutto") { trim.zoomReset() }.controlSize(.small)
                .disabled(trim.zoom <= 1 && trim.gain <= 1)
                .help("Torna a vedere tutto il file")
        }
    }

    private func zoomPair(icon: String, label: String, minus: @escaping () -> Void, plus: @escaping () -> Void,
                          canMinus: Bool, canPlus: Bool, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.trailing, 2).accessibilityHidden(true)
            Button(action: minus) { Image(systemName: "minus.magnifyingglass") }
                .disabled(!canMinus).accessibilityLabel("\(label): meno")
            Button(action: plus) { Image(systemName: "plus.magnifyingglass") }
                .disabled(!canPlus).accessibilityLabel("\(label): più")
        }
        .controlSize(.small)
        .help(help)
    }
}

/// 3.8 · Sotto l'onda ingrandita: tutto il file in piccolo, con il riquadro di ciò che si vede (trascinabile).
private struct WaveOverview: View {
    @ObservedObject var m: TrimModel
    let tint: Color
    @State private var grab: Double? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = max(m.duration, 0.001)
            let vx = CGFloat(m.viewStart / d) * w
            let vw = max(8, CGFloat(m.span / d) * w)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.ink.opacity(0.08))
                // La selezione, nel colore della scheda
                Capsule().fill(tint.opacity(0.45))
                    .frame(width: max(2, CGFloat((m.end - m.start) / d) * w), height: h * 0.5)
                    .offset(x: CGFloat(m.start / d) * w, y: h * 0.25)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.55), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.ink.opacity(0.10)))
                    .frame(width: vw, height: h)
                    .offset(x: vx)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let t = Double(v.location.x / max(w, 1)) * d
                if grab == nil {
                    // Presa dentro il riquadro: lo si sposta da lì; fuori: il riquadro salta lì al centro
                    let inside = v.startLocation.x >= vx && v.startLocation.x <= vx + vw
                    grab = inside ? t - m.viewStart : m.span / 2
                }
                m.pan(to: t - (grab ?? 0))
            }.onEnded { _ in grab = nil })
            .help("Trascina per scorrere lungo il file")
        }
    }
}
