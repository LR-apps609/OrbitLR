import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.6 · Schede «Video» (striscia in basso) e «Audio» (schede strumento)
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
    /// Selezione iniziale e massima dei file che si aprono (es. suoneria: 30 s, al massimo 40).
    var trimDefaultLength: Double? = nil
    var trimMaxLength: Double? = nil

    init(videoTab: Bool) { self.videoTab = videoTab }

    /// Formati che i motori di macOS leggono direttamente.
    static let readable: Set<String> = ["mp4", "mov", "m4v", "3gp", "mp3", "m4a", "wav", "aiff", "aac", "flac", "caf"]

    var accepted: Set<Kind> { videoTab ? [.video] : [.audio, .video] }
    var allFiles: [URL] { (file.map { [$0] } ?? []) + extra }

    /// File trascinati o scelti: il primo si apre, gli altri restano pronti per «Unisci».
    func load(_ urls: [URL], append: Bool = false) {
        let right = PieController.expand(urls).filter { u in Catalog.kind(of: u).map { accepted.contains($0) } ?? false }
        // Formati che macOS non sa leggere da solo: prima si convertono (in Conversione, con ffmpeg)
        let ok = right.filter { Self.readable.contains(Catalog.norm($0.pathExtension)) }
        guard !ok.isEmpty else {
            if !right.isEmpty {
                notice = "Questo formato non si apre qui: convertilo prima in " + (videoTab ? "MP4" : "M4A") + " dalla scheda Conversione."
            } else {
                notice = videoTab ? "Qui si aprono solo i video." : "Qui si aprono file audio (o video, per usarne l’audio)."
            }
            NSSound.beep()
            return
        }
        notice = right.count > ok.count ? "Alcuni file sono in un formato che qui non si apre: convertili prima dalla scheda Conversione." : nil
        if append, file != nil {
            for u in ok where !allFiles.contains(u) { extra.append(u) }
            return
        }
        extra = Array(ok.dropFirst())
        open(ok[0])
    }

    func open(_ url: URL) {
        trim?.pause()
        file = url
        lastJob = nil
        let t = TrimModel(url: url, isVideo: videoTab, defaultLength: trimDefaultLength)
        t.maxLength = trimMaxLength
        trim = t
        info = ""
        videoSize = .zero
        Task { await self.loadInfo(url) }
    }

    func close() {
        trim?.pause()
        trim = nil
        file = nil
        extra = []
        info = ""
        lastJob = nil
    }

    func removeExtra(_ u: URL) { extra.removeAll { $0 == u } }

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
private struct MediaDropZone: View {
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
private struct JobStrip: View {
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
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .card(radius: 12)
    }

    private var statusText: String {
        switch job.state {
        case .waiting: return "In attesa"
        case .running: return job.status
        case .done: return job.outputs.count == 1 ? "Creato «\(job.outputs[0].lastPathComponent)»" : "Fatto"
        case .failed: return job.failures.first ?? "Non riuscito"
        case .cancelled: return "Annullato"
        }
    }
}

/// Pulsante «a pastiglia» per scegliere tra poche opzioni.
private struct Chip: View {
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

private struct SectionLabel: View {
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

// MARK: - Scheda Video (B: striscia in basso)

enum VideoTool: String, CaseIterable, Identifiable {
    case cut = "Taglia", social = "Formato social", merge = "Unisci video", music = "Aggiungi musica",
         extract = "Estrai audio", gif = "In GIF", compress = "Comprimi"
    var id: String { rawValue }
}

struct VideoTabView: View {
    @ObservedObject var m: MediaTabModel
    @State private var tool: VideoTool = .social
    @State private var aspect = "9x16"
    @State private var follow = true
    @State private var onlySelection = false
    @State private var mb = "25"
    @State private var audioFormat = "m4a"
    @State private var music: URL? = nil
    @State private var replaceAudio = false
    @State private var targeted = false

    private let tint = Theme.color(.video)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaHeader(m: m, tint: tint) {
                if m.file != nil {
                    Button("Cambia video…") { m.choose(append: false) }
                    Button { m.close() } label: { Image(systemName: "xmark") }.help("Chiudi il video")
                }
            }
            if let trim = m.trim {
                VideoWorkArea(m: m, trim: trim, tool: $tool, aspect: aspect)
                toolRow
                strip(trim)
            } else {
                MediaDropZone(kind: .video, title: "Trascina qui un video",
                              subtitle: "oppure clicca per sceglierlo · MP4, MOV, M4V · più video insieme per unirli",
                              targeted: targeted) { m.choose(append: false) }
            }
            if let n = m.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let job = m.lastJob { JobStrip(job: job) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in m.load(urls, append: m.file != nil && tool == .merge) }
            return true
        }
        .onDisappear { m.trim?.pause() }
        .navigationTitle("Video")
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(VideoTool.allCases) { t in
                Chip(title: t.rawValue, selected: tool == t, tint: tint) { tool = t }
            }
            Spacer(minLength: 0)
        }
    }

    // La striscia: nome dello strumento · opzioni · riepilogo · pulsante
    private func strip(_ trim: TrimModel) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Strumento")
                Text(tool.rawValue).font(.system(size: 14.5, weight: .bold)).lineLimit(1).fixedSize()
            }
            .frame(minWidth: 120, alignment: .leading)
            Divider().frame(height: 40)
            options(trim)
            Spacer(minLength: 8)
            VideoSummary(trim: trim, tool: tool, mb: mb, aspect: aspect, onlySelection: onlySelection, size: m.videoSize)
            Button(actionTitle) { start(trim) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(radius: 14)
    }

    @ViewBuilder private func options(_ trim: TrimModel) -> some View {
        switch tool {
        case .cut:
            Text("Tieni il tratto tra le maniglie gialle").font(.system(size: 12)).foregroundStyle(.secondary)
        case .social:
            HStack(spacing: 6) {
                Chip(title: "9:16 Reels, TikTok", selected: aspect == "9x16", tint: tint) { aspect = "9x16" }
                Chip(title: "1:1 Post", selected: aspect == "1x1", tint: tint) { aspect = "1x1" }
                Chip(title: "4:5 Feed", selected: aspect == "4x5", tint: tint) { aspect = "4x5" }
                Chip(title: "16:9 YouTube", selected: aspect == "16x9", tint: tint) { aspect = "16x9" }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Segui il soggetto", isOn: $follow).toggleStyle(.checkbox)
                Toggle("Solo la selezione", isOn: $onlySelection).toggleStyle(.checkbox)
            }
            .font(.system(size: 12))
        case .merge:
            Text(m.allFiles.count < 2 ? "Trascina qui altri video (o «Aggiungi…»): si uniscono nell’ordine dell’elenco"
                 : "\(m.allFiles.count) video, uno dopo l’altro")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button { m.choose(append: true) } label: { Label("Aggiungi…", systemImage: "plus") }
        case .music:
            Button(music == nil ? "Scegli la musica…" : music!.lastPathComponent) { chooseMusic() }
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            Picker("", selection: $replaceAudio) {
                Text("Sotto l’audio").tag(false)
                Text("Al posto dell’audio").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
        case .extract:
            HStack(spacing: 6) {
                Chip(title: "M4A", selected: audioFormat == "m4a", tint: tint) { audioFormat = "m4a" }
                Chip(title: "MP3", selected: audioFormat == "mp3", tint: tint) { audioFormat = "mp3" }
            }
            Text("Tutto l’audio del video").font(.system(size: 12)).foregroundStyle(.secondary)
        case .gif:
            Text(trim.end - trim.start > 15 ? "Meglio un tratto breve: oltre 15 secondi la GIF diventa pesante"
                 : "Il tratto tra le maniglie diventa un’animazione")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .compress:
            HStack(spacing: 6) {
                ForEach(["8", "16", "25", "50", "100"], id: \.self) { v in
                    Chip(title: v + " MB", selected: mb == v, tint: tint) { mb = v }
                }
            }
        }
    }

    private var actionTitle: String {
        switch tool {
        case .cut: return "Taglia"
        case .social: return "Esporta"
        case .merge: return "Unisci"
        case .music: return "Aggiungi"
        case .extract: return "Estrai"
        case .gif: return "Crea la GIF"
        case .compress: return "Comprimi"
        }
    }

    private var canStart: Bool {
        switch tool {
        case .merge: return m.allFiles.count >= 2
        case .music: return music != nil
        default: return m.file != nil
        }
    }

    private func start(_ trim: TrimModel) {
        let sel = String(format: "%.3f|%.3f", trim.start, trim.end)
        switch tool {
        case .cut: m.run("cut", param: sel)
        case .social:
            m.run("social", param: "\(aspect)|\(follow ? 1 : 0)" + (onlySelection ? "|" + sel : ""))
        case .merge: m.run("vmerge", param: "", files: m.allFiles)
        case .music:
            guard let music else { return }
            m.run("music", param: (replaceAudio ? "replace" : "mix") + "|" + music.path)
        case .extract: m.run("to:" + audioFormat, param: "")
        case .gif: m.run("gifcut", param: sel)
        case .compress: m.run("vcompress", param: mb)
        }
    }

    private func chooseMusic() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.audio]
        p.prompt = "Scegli"
        if p.runModal() == .OK { music = p.url }
    }
}

/// Anteprima grande e sequenza con le maniglie.
private struct VideoWorkArea: View {
    @ObservedObject var m: MediaTabModel
    @ObservedObject var trim: TrimModel
    @Binding var tool: VideoTool
    let aspect: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                PlayerPreview(player: trim.player)
                    .background(Color.black)
                if tool == .social { CropOverlay(videoSize: m.videoSize, aspect: aspect).allowsHitTesting(false) }
                HStack {
                    Button { trim.togglePlay() } label: {
                        Image(systemName: trim.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.9)))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Riproduci la selezione (Spazio)")
                    Spacer()
                    Text("\(formatTime(trim.playhead)) / \(formatTime(trim.duration))")
                        .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(Color.white.opacity(0.9))
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TrimTimeline(m: trim, tint: Theme.brass)
                .frame(height: 92)
                .overlay { if trim.loading { ProgressView().controlSize(.small) } }
                .padding(.top, 6)
            HStack {
                Text("Selezione \(formatTime(trim.start)) → \(formatTime(trim.end)) · \(formatTime(max(0, trim.end - trim.start)))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Inizio qui") { trim.markIn() }.keyboardShortcut("i", modifiers: []).help("Tasto I")
                Button("Fine qui") { trim.markOut() }.keyboardShortcut("o", modifiers: []).help("Tasto O")
                Button("Tutto") { trim.setStart(0); trim.setEnd(trim.duration) }
            }
            .controlSize(.small)
        }
    }
}

/// Oscura ciò che resta fuori dal formato scelto (anteprima al centro; l'inquadratura vera segue il soggetto).
private struct CropOverlay: View {
    let videoSize: CGSize
    let aspect: String
    var body: some View {
        GeometryReader { g in
            let a = aspect.split(separator: "x").compactMap { Double($0) }
            let ratio: Double = a.count == 2 && a[1] > 0 ? a[0] / a[1] : 9.0 / 16.0
            let vs = videoSize == .zero ? CGSize(width: 16, height: 9) : videoSize
            let fit = min(g.size.width / vs.width, g.size.height / vs.height)
            let vw = vs.width * fit, vh = vs.height * fit
            let vx = (g.size.width - vw) / 2, vy = (g.size.height - vh) / 2
            let cw0 = min(vw, vh * CGFloat(ratio))
            let ch0 = cw0 / CGFloat(ratio)
            let crop = CGRect(x: vx + (vw - cw0) / 2, y: vy + (vh - ch0) / 2, width: cw0, height: ch0)
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

/// Durata e peso stimato prima di esportare.
private struct VideoSummary: View {
    @ObservedObject var trim: TrimModel
    let tool: VideoTool
    let mb: String
    let aspect: String
    let onlySelection: Bool
    let size: CGSize

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(durationText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            if let w = weightText { Text(w).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .fixedSize()
    }

    private var selected: Double { max(0, trim.end - trim.start) }
    private var seconds: Double {
        switch tool {
        case .cut, .gif: return selected
        case .social: return onlySelection ? selected : trim.duration
        default: return trim.duration
        }
    }
    private var durationText: String { formatTime(seconds) }
    private var weightText: String? {
        switch tool {
        case .compress: return "al massimo \(mb) MB"
        case .social:
            guard size.width > 0, size.height > 0 else { return nil }
            let a = aspect.split(separator: "x").compactMap { Double($0) }
            guard a.count == 2 else { return nil }
            var cw = Double(size.width), ch = cw * a[1] / a[0]
            if ch > Double(size.height) { ch = Double(size.height); cw = ch * a[0] / a[1] }
            let k = min(1, 1920 / max(cw, ch))
            let bits = max(2_000_000, min(16_000_000, cw * k * ch * k * 30 * 0.13)) + 160_000
            let bytes = bits * seconds / 8
            return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        default: return nil
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
    var subtitle: String {
        switch self {
        case .ringtone: return "Fino a 40 secondi, pronta per iPhone"
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

    var body: some View {
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
            HStack(alignment: .top, spacing: 16) {
                cards
                panel.frame(width: 310)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if let n = m.notice {
                Label(n, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let job = m.lastJob { JobStrip(job: job) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                m.load(urls, append: m.file != nil && tool == .merge)
                if tool == .tts { tool = .ringtone }
            }
            return true
        }
        .onAppear { applyTrimRules() }
        .onChange(of: tool) { _, t in
            applyTrimRules()
            if t == .ringtone { m.trim?.setLength(ringLength) }
            if t != .tts { preview.stop() }
        }
        .onDisappear { preview.stop(); m.trim?.pause() }
        .navigationTitle("Audio")
    }

    /// Suoneria: selezione di 20–40 secondi, anche per i file aperti dopo.
    private func applyTrimRules() {
        let ring = tool == .ringtone
        m.trimDefaultLength = ring ? ringLength : nil
        m.trimMaxLength = ring ? 40 : nil
        m.trim?.maxLength = ring ? 40 : nil
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(AudioTool.allCases) { t in
                ToolCard(title: t.title, subtitle: t.subtitle, symbol: t.symbol, tint: tint, selected: tool == t) { tool = t }
            }
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
            .keyboardShortcut(.defaultAction)
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
                Text("20 s").tag(20.0); Text("30 s").tag(30.0); Text("40 s").tag(40.0)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: ringLength) { _, v in m.trim?.setLength(v); applyTrimRules() }
            Toggle("Dissolvenza all’inizio e alla fine", isOn: $fade).toggleStyle(.checkbox)
            Toggle("Volume uniforme", isOn: $normalize).toggleStyle(.checkbox)
            hint("Sposta il riquadro sulla forma d’onda per scegliere il pezzo. Si crea un file .m4r: collega l’iPhone, aprilo nel Finder e trascinaci la suoneria.")
        case .cut:
            if let trim = m.trim { SelectionText(trim: trim) }
            hint("Trascina le maniglie sulla forma d’onda. I e O segnano inizio e fine mentre ascolti.")
        case .normalize:
            hint("Alza le parti troppo basse e tiene sotto controllo i picchi: utile per vocali, lezioni e podcast. Il file resta nel suo formato.")
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
            hint("Le voci «Premium» e «Migliorate» sono molto più naturali: si scaricano una volta dalle Impostazioni di Sistema. Il file si salva in Download.")
        case .whatsapp:
            hint("Mono, voce chiara e volume uniforme, in un file M4A leggero: si manda in un attimo anche con poca rete.")
        case .merge:
            if m.file == nil {
                hint("Apri il primo file, poi aggiungi gli altri: si uniscono nell’ordine dell’elenco.")
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
