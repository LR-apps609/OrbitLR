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
        parts.append(ByteCountFormatter.string(fromByteCount: Job.size(of: url), countStyle: .file))
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
        if p.runModal() == .OK { load(p.urls, append: append) }
    }
}

func formatShort(_ t: Double) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Pezzi comuni

/// Intestazione della scheda: file aperto, dati, pulsanti.
private struct MediaHeader<Trailing: View>: View {
    let m: MediaTabModel
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let f = m.file {
                Text(f.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(m.info).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(m.videoTab ? "Video" : "Audio").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

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
                    Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if job.state == .running || job.state == .waiting || job.state == .done {
                    TunerBar(value: job.shownProgress, tint: Theme.green, done: job.state == .done, height: 18)
                }
            }
            if job.state == .running || job.state == .waiting {
                Button { QueueStore.shared.cancel(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Annulla")
            } else if job.state == .done, !job.outputs.isEmpty {
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
            return job.outputs.count == 1 ? "«\(job.outputs[0].lastPathComponent)» in \(folder)"
                : "\(job.outputs.count) file in \(folder)"
        case .failed: return job.failures.first ?? "Non riuscito"
        case .cancelled: return "Annullato"
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
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.brass)
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

// MARK: - Scheda Audio (C: schede strumento)

enum AudioTool: String, CaseIterable, Identifiable {
    case ringtone, cut, normalize, tts, whatsapp, merge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ringtone: return "Suoneria iPhone"
        case .cut: return "Taglia"
        case .normalize: return "Volume uniforme"
        case .tts: return "Testo in voce"
        case .whatsapp: return "Per WhatsApp"
        case .merge: return "Unisci audio"
        }
    }
    /// 2.8.4 · Cosa fare adesso, in una frase.
    var hint: String {
        switch self {
        case .ringtone: return "Sposta il riquadro sul pezzo che ti piace (fino a 30 secondi) e premi il pulsante: ottieni il file .m4r per iPhone."
        case .cut: return "Trascina le maniglie per tenere solo il pezzo che serve. ⌘Z annulla uno spostamento."
        case .normalize: return "Rende il volume uniforme: né troppo basso né distorto. Va bene per vocali e registrazioni."
        case .tts: return "Scrivi o incolla il testo, scegli la voce e ascolta l’anteprima prima di creare il file."
        case .whatsapp: return "Crea un vocale leggero con la voce chiara, pronto da mandare."
        case .merge: return "Trascina altri file audio: si uniscono in un solo file, nell’ordine in cui li aggiungi."
        }
    }

    var subtitle: String {
        switch self {
        case .ringtone: return "Fino a 30 secondi, pronta per iPhone"
        case .cut: return "Tieni solo la parte che serve"
        case .normalize: return "Né troppo basso né distorto"
        case .tts: return "Scrivi e OrbitLR legge"
        case .whatsapp: return "Vocale leggero, voce chiara"
        case .merge: return "Più file in uno"
        }
    }
    var symbol: String {
        switch self {
        case .ringtone: return "bell.and.waves.left.and.right"
        case .cut: return "scissors"
        case .normalize: return "speaker.wave.2"
        case .tts: return "text.bubble"
        case .whatsapp: return "message"
        case .merge: return "square.stack.3d.up"
        }
    }
}

/// Ascolto di prova della sintesi vocale.
final class SpeechPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    @Published var speaking = false
    override init() { super.init(); synth.delegate = self }
    func speak(_ text: String, voice: String?, rate: Float) {
        stop()
        let sample = String(text.prefix(400))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        synth.speak(Speech.utterance(sample, voice: voice, rate: rate))
        speaking = true
    }
    func stop() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }; speaking = false }
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
    @State private var text = ""
    @State private var voiceId = ""
    @State private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var allLanguages = false
    @State private var targeted = false
    @StateObject private var preview = SpeechPreview()

    private let tint = Theme.color(.audio)

    /// 2.8.6 · Il contenuto, al centro e largo al massimo 1100 punti.
    private var page: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaHeader(m: m, tint: tint) {
                if let trim = m.trim, tool != .tts {
                    PlayButton(trim: trim, tint: tint)
                }
                if m.file != nil {
                    Button("Cambia file…") { m.choose(append: false) }
                    Button { m.close() } label: { Image(systemName: "xmark") }.help("Chiudi il file")
                }
            }
            topArea.frame(height: 210)
            // 2.8.5 · I progetti audio, come i Progetti del Video
            if m.file == nil && tool != .tts && !m.audioProjects.isEmpty { AudioProjectsRow(m: m, tint: tint) }
            HStack(alignment: .top, spacing: 16) {
                cards
                panel.frame(width: 310)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if let n = m.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let job = m.lastJob {
                JobStrip(job: job)
                SendToPhoneStrip(job: job)          // 2.9.5 · sotto la suoneria pronta
            }
        }
        .padding(20)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        // 2.8.6 · Se la finestra è bassa la pagina scorre, invece di uscire dai bordi
        ViewThatFits(in: .vertical) {
            page.frame(maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical) { page }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                m.load(urls, append: m.file != nil && tool == .merge)
                if tool == .tts { tool = .ringtone }
            }
            return true
        }
        .onAppear { applyTrimRules(); m.currentTool = tool.rawValue; m.refreshProjects() }
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
        .navigationTitle("Audio")
    }

    /// Suoneria: selezione di 20–30 secondi, anche per i file aperti dopo.
    private func applyTrimRules() {
        let ring = tool == .ringtone
        m.trimDefaultLength = ring ? ringLength : nil
        // 2.9.4 · Al massimo 30 s: è il limite di «Usa come suoneria» sull'iPhone (iOS 26)
        m.trimMaxLength = ring ? 30 : nil
        m.trim?.maxLength = ring ? 30 : nil
    }

    @ViewBuilder private var topArea: some View {
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
                Text("\(text.count) caratteri").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if let trim = m.trim {
            AudioWave(trim: trim, tint: tint)
        } else {
            MediaDropZone(kind: .audio, title: "Trascina qui un file audio",
                          subtitle: "oppure clicca per sceglierlo · MP3, M4A, WAV… anche un video, per usarne l’audio",
                          targeted: targeted) { m.choose(append: false) }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(AudioTool.allCases) { t in
                    ToolCard(title: t.title, subtitle: t.subtitle, symbol: t.symbol, tint: tint, selected: tool == t) { tool = t }
                }
            }
            // 2.8.4 · Come nel Video: una frase che dice cosa fare adesso
            // 2.8.6 · Niente «fixedSize» qui: con la larghezza libera faceva crescere la finestra a dismisura
            Label(tool.hint, systemImage: "lightbulb")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }


    // Il riquadro con le opzioni dello strumento scelto e il pulsante finale
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: tool.title)
            panelOptions
            Spacer(minLength: 4)
            Button(action: start) {
                Text(actionTitle).font(.system(size: 13.5, weight: .bold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            // Mentre si scrive il testo, Invio va a capo e non avvia
            .keyboardShortcut(tool == .tts ? nil : KeyboardShortcut.defaultAction)
            .disabled(!canStart)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(radius: 14)
    }

    @ViewBuilder private var panelOptions: some View {
        switch tool {
        case .ringtone:
            Text("Durata").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Picker("", selection: $ringLength) {
                Text("20 s").tag(20.0); Text("30 s").tag(30.0)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: ringLength) { _, v in m.trim?.setLength(v); applyTrimRules() }
            Toggle("Dissolvenza all’inizio e alla fine", isOn: $fade).toggleStyle(.checkbox)
            Toggle("Volume uniforme", isOn: $normalize).toggleStyle(.checkbox)
            hint("Sposta il riquadro sul pezzo che ti piace. Poi trascina il file .m4r sull’iPhone nel Finder.")
        case .cut:
            if let trim = m.trim { SelectionText(trim: trim) }
            hint("Trascina le maniglie. I e O mentre ascolti.")
        case .normalize:
            hint("Per vocali, lezioni e podcast: né troppo basso né distorto.")
        case .tts:
            Picker("Voce", selection: $voiceId) {
                Text("La più naturale disponibile").tag("")
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name) · \(Speech.qualityLabel(v))" + (allLanguages ? " · \(v.language)" : "")).tag(v.identifier)
                }
            }
            Toggle("Mostra le voci di tutte le lingue", isOn: $allLanguages).toggleStyle(.checkbox)
            HStack {
                Text("Velocità").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate + 0.25)...Double(AVSpeechUtteranceMaximumSpeechRate - 0.25))
            }
            HStack {
                Button(preview.speaking ? "Ferma" : "Ascolta una prova") {
                    if preview.speaking { preview.stop() } else { preview.speak(text, voice: voiceId.isEmpty ? nil : voiceId, rate: Float(rate)) }
                }
                Button("Voci più naturali…") { openVoiceSettings() }
                    .help("Impostazioni di Sistema → Accessibilità → Contenuti letti → Voce di sistema → Gestisci voci")
            }
            hint("Le voci «Premium» sono le più naturali. Il file va in Download.")
        case .whatsapp:
            hint("Leggero e chiaro: parte subito anche con poca rete.")
        case .merge:
            if m.file == nil {
                hint("Apri il primo file, poi aggiungi gli altri.")
            } else {
                MergeList(m: m, tint: tint)
            }
        }
    }

    private var voices: [AVSpeechSynthesisVoice] {
        allLanguages ? Speech.voices(language: "") : Speech.voices(language: "it")
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var actionTitle: String {
        switch tool {
        case .ringtone: return "Crea la suoneria"
        case .cut: return "Taglia"
        case .normalize: return "Uniforma il volume"
        case .tts: return "Crea il file audio"
        case .whatsapp: return "Crea il vocale"
        case .merge: return m.allFiles.count >= 2 ? "Unisci \(m.allFiles.count) file" : "Unisci"
        }
    }

    private var canStart: Bool {
        switch tool {
        case .tts: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .merge: return m.allFiles.count >= 2
        default: return m.file != nil
        }
    }

    private func start() {
        preview.stop()
        guard let trim = m.trim else {
            if tool == .tts { startTTS() }
            return
        }
        let sel = String(format: "%.3f|%.3f", trim.start, trim.end)
        switch tool {
        case .ringtone: m.run("ringtone", param: sel + "|\(fade ? 1 : 0)|\(normalize ? 1 : 0)")
        case .cut: m.run("cut", param: sel)
        case .normalize: m.run("normalize", param: "")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrimTimeline(m: trim, tint: tint)
                .overlay { if trim.loading { ProgressView().controlSize(.small) } }
                .padding(.top, 6)
            HStack {
                Text("0:00").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(formatTime(trim.start)) → \(formatTime(trim.end)) · \(formatTime(max(0, trim.end - trim.start)))")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                Spacer()
                Button("Inizio qui") { trim.markIn() }.keyboardShortcut("i", modifiers: []).controlSize(.small)
                Button("Fine qui") { trim.markOut() }.keyboardShortcut("o", modifiers: []).controlSize(.small)
                Text(formatTime(trim.duration)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(16)
        .card(radius: 14)
    }
}

private struct ToolCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.15))))
                Text(title).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? tint : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
