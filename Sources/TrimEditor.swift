import SwiftUI
import AVFoundation
import AVKit

// MARK: - Modello: riproduzione, forma d'onda, selezione

final class TrimModel: ObservableObject, @unchecked Sendable {
    let url: URL
    let isVideo: Bool
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var playhead: Double = 0
    @Published var playing = false
    @Published var loop = false
    @Published var peaks: [Float] = []
    @Published var thumbs: [NSImage] = []
    @Published var loading = true
    /// Durata massima della selezione (es. 40 s per le suonerie), nil = libera.
    var maxLength: Double? = nil

    private var observer: Any?

    init(url: URL, isVideo: Bool, defaultLength: Double?) {
        self.url = url
        self.isVideo = isVideo
        self.player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            self.playhead = s
            if self.playing && s >= self.end {
                if self.loop { self.seek(self.start) } else { self.pause(); self.seek(self.start) }
            }
        }
        Task { await self.load(defaultLength: defaultLength) }
    }

    deinit {
        if let o = observer { player.removeTimeObserver(o) }
        player.pause()
    }

    @MainActor
    private func load(defaultLength: Double?) async {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration))?.seconds ?? 0
        duration = d.isFinite && d > 0 ? d : 0
        start = 0
        end = defaultLength.map { min($0, duration) } ?? duration
        let dur = duration
        let video = isVideo
        peaks = await TrimModel.waveform(url: url, duration: dur, bins: 700)
        if video { thumbs = await TrimModel.thumbnails(url: url, count: 12, duration: dur) }
        loading = false
    }

    // MARK: Comandi

    func seek(_ t: Double) {
        let v = min(max(0, t), duration)
        player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = v
    }

    func togglePlay() {
        if playing { pause(); return }
        if playhead < start || playhead >= end - 0.05 { seek(start) }
        player.play()
        playing = true
    }

    func pause() { player.pause(); playing = false }

    func setStart(_ t: Double) {
        start = min(max(0, t), max(0, end - 0.1))
        if let maxL = maxLength, end - start > maxL { end = min(duration, start + maxL) }
        if !playing { seek(start) }
    }

    func setEnd(_ t: Double) {
        end = max(min(duration, t), start + 0.1)
        if let maxL = maxLength, end - start > maxL { start = max(0, end - maxL) }
        if !playing { seek(max(start, end - 0.5)) }
    }

    /// Selezione di una durata precisa a partire dall'inizio attuale (es. suoneria da 30 s).
    func setLength(_ seconds: Double) {
        let s = min(start, max(0, duration - seconds))
        start = max(0, s)
        end = min(duration, start + seconds)
        if !playing { seek(start) }
    }

    func markIn() { setStart(playhead) }
    func markOut() { setEnd(playhead) }

    /// 2.8.4 · ⌘Z sulla selezione: si registra una volta, alla fine del trascinamento.
    func commitSelection(from before: (Double, Double), undo: UndoManager?, name: String = "Cambia la selezione") {
        let after = (start, end)
        guard abs(before.0 - after.0) > 0.001 || abs(before.1 - after.1) > 0.001, let undo else { return }
        undo.registerUndo(withTarget: self) { m in m.restoreSelection(before, redo: after, undo: undo, name: name) }
        undo.setActionName(name)
    }

    private func restoreSelection(_ sel: (Double, Double), redo: (Double, Double), undo: UndoManager, name: String) {
        start = sel.0
        end = sel.1
        if !playing { seek(start) }
        undo.registerUndo(withTarget: self) { m in m.restoreSelection(redo, redo: sel, undo: undo, name: name) }
        undo.setActionName(name)
    }

    // MARK: Analisi del file (in sottofondo)

    /// Picchi del volume, normalizzati 0…1, per disegnare la forma d'onda.
    static func waveform(url: URL, duration: Double, bins: Int) async -> [Float] {
        await Task.detached(priority: .userInitiated) { () -> [Float] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let rate = 8000.0
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: rate,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }
            let perBin = max(1, Int(duration * rate / Double(bins)))
            var peaks: [Float] = []
            peaks.reserveCapacity(bins + 8)
            var cur: Float = 0
            var n = 0
            while let sb = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let len = CMBlockBufferGetDataLength(block)
                guard len > 1 else { continue }
                var data = [Int16](repeating: 0, count: len / 2)
                data.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: base) }
                }
                for v in data {
                    let a = Float(abs(Int32(v))) / 32768
                    if a > cur { cur = a }
                    n += 1
                    if n >= perBin { peaks.append(cur); cur = 0; n = 0 }
                }
            }
            if n > 0 { peaks.append(cur) }
            let m = peaks.max() ?? 0
            return m > 0 ? peaks.map { sqrt($0 / m) } : peaks      // radice: anche le parti basse restano visibili
        }.value
    }

    /// Fotogrammi distribuiti lungo il video, per la striscia sotto la forma d'onda.
    static func thumbnails(url: URL, count: Int, duration: Double) async -> [NSImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        var out: [NSImage] = []
        guard duration > 0 else { return out }
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let r = try? await gen.image(at: t) {
                out.append(NSImage(cgImage: r.image, size: .zero))
            }
        }
        return out
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "0:00.0" }
    let total = max(0, t)
    let h = Int(total) / 3600
    let m = (Int(total) % 3600) / 60
    let s = total - Double(h * 3600 + m * 60)
    if h > 0 { return String(format: "%d:%02d:%04.1f", h, m, s) }
    return String(format: "%d:%04.1f", m, s)
}

// MARK: - Vista

struct TrimEditorView: View {
    @StateObject private var m: TrimModel
    let mode: ParamKind
    let tint: Color
    let fileName: String
    let onDone: (String?) -> Void

    @State private var startText = ""
    @State private var endText = ""

    init(url: URL, mode: ParamKind, onDone: @escaping (String?) -> Void) {
        let kind = Catalog.kind(of: url)
        let model = TrimModel(url: url, isVideo: kind == .video,
                              defaultLength: mode == .gifcut ? 5 : (mode == .ringtone ? 30 : nil))
        if mode == .ringtone { model.maxLength = 40 }
        _m = StateObject(wrappedValue: model)
        self.mode = mode
        self.tint = Theme.color(kind)
        self.fileName = url.lastPathComponent
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                KindBadge(kind: m.isVideo ? Kind.video : Kind.audio, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .gifcut ? "GIF da un pezzo" : (mode == .ringtone ? "Suoneria iPhone" : "Taglia")).font(.system(size: 16, weight: .bold))
                    Text(fileName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("Durata totale \(formatTime(m.duration))").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if m.isVideo {
                PlayerPreview(player: m.player)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            }

            TrimTimeline(m: m, tint: tint)
                .frame(height: m.isVideo ? 110 : 140)
                .overlay {
                    if m.loading { ProgressView().controlSize(.small) }
                }

            HStack(spacing: 10) {
                Button { m.togglePlay() } label: {
                    Label(m.playing ? "Pausa" : "Riproduci la selezione", systemImage: m.playing ? "pause.fill" : "play.fill")
                        .frame(minWidth: 170)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(tint)
                Toggle("Ripeti", isOn: $m.loop).toggleStyle(.checkbox)
                Spacer()
                Button("Inizio qui") { m.markIn() }.keyboardShortcut("i", modifiers: []).help("Tasto I")
                Button("Fine qui") { m.markOut() }.keyboardShortcut("o", modifiers: []).help("Tasto O")
            }

            HStack(spacing: 18) {
                timeField("Inizio", text: $startText, minus: { m.setStart(m.start - 0.1) }, plus: { m.setStart(m.start + 0.1) }) {
                    if let v = parseTime(startText) { m.setStart(v) } else { startText = formatTime(m.start) }
                }
                timeField("Fine", text: $endText, minus: { m.setEnd(m.end - 0.1) }, plus: { m.setEnd(m.end + 0.1) }) {
                    if let v = parseTime(endText) { m.setEnd(v) } else { endText = formatTime(m.end) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selezione").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(formatTime(max(0, m.end - m.start))).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                }
                Spacer()
            }

            Text(mode == .ringtone
                 ? "Fino a 40 secondi. Si crea un file .m4r: collega l’iPhone, aprilo nel Finder e trascinaci la suoneria."
                 : "Trascina le maniglie colorate, clicca sulla forma d’onda per spostarti. Spazio = riproduci, I/O = inizio/fine.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annulla") { m.pause(); onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(mode == .gifcut ? "Crea la GIF" : (mode == .ringtone ? "Crea la suoneria" : "Taglia")) {
                    m.pause()
                    onDone(String(format: "%.3f|%.3f", m.start, m.end) + (mode == .ringtone ? "|1|1" : ""))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(m.duration <= 0)
            }
        }
        .padding(22)
        .frame(width: 760)
        .onAppear { startText = formatTime(m.start); endText = formatTime(m.end) }
        .onChange(of: m.start) { _, v in startText = formatTime(v) }
        .onChange(of: m.end) { _, v in endText = formatTime(v) }
        .onDisappear { m.pause() }
    }

    private func timeField(_ title: String, text: Binding<String>, minus: @escaping () -> Void,
                           plus: @escaping () -> Void, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button(action: minus) { Image(systemName: "minus") }.help("−0,1 s")
                TextField("0:00.0", text: text).frame(width: 84).multilineTextAlignment(.center).onSubmit(commit)
                Button(action: plus) { Image(systemName: "plus") }.help("+0,1 s")
            }
        }
    }
}

/// Forma d'onda (e fotogrammi per i video) con selezione trascinabile e testina.
struct TrimTimeline: View {
    @Environment(\.undoManager) private var undoManager
    /// 2.8.4 · Selezione all'inizio del trascinamento, per ⌘Z.
    @State private var dragBefore: (Double, Double)? = nil

    private func endDrag(_ name: String) {
        if let b = dragBefore { m.commitSelection(from: b, undo: undoManager, name: name) }
        dragBefore = nil
    }

    @ObservedObject var m: TrimModel
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = max(m.duration, 0.001)
            let xs = CGFloat(m.start / d) * w
            let xe = CGFloat(m.end / d) * w
            let xp = CGFloat(m.playhead / d) * w
            let peaks = m.peaks
            ZStack(alignment: .topLeading) {
                // Sfondo: clic = sposta la testina
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.parchment.opacity(0.55))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
                        m.seek(Double(v.location.x / w) * d)
                    })

                if m.isVideo && !m.thumbs.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(m.thumbs.indices, id: \.self) { i in
                            Image(nsImage: m.thumbs[i]).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(m.thumbs.count), height: h * 0.5).clipped()
                        }
                    }
                    .opacity(0.6)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
                }

                Canvas { ctx, size in
                    let n = peaks.count
                    guard n > 0 else { return }
                    let top: CGFloat = m.isVideo ? size.height * 0.5 : 0
                    let area = size.height - top
                    let bw = size.width / CGFloat(n)
                    for (i, p) in peaks.enumerated() {
                        let x = CGFloat(i) * bw
                        let bh = max(2, CGFloat(p) * (area - 10))
                        let inside = x >= xs && x <= xe
                        let rect = CGRect(x: x, y: top + (area - bh) / 2, width: max(1, bw - 0.6), height: bh)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, bw / 2)),
                                 with: .color(inside ? tint : Theme.ink.opacity(0.22)))
                    }
                }
                .allowsHitTesting(false)

                // Zone escluse un po' scure
                Rectangle().fill(Theme.cream.opacity(0.65)).frame(width: max(0, xs), height: h).allowsHitTesting(false)
                Rectangle().fill(Theme.cream.opacity(0.65)).frame(width: max(0, w - xe), height: h).offset(x: xe).allowsHitTesting(false)

                // Bordo della selezione
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint, lineWidth: 2)
                    .frame(width: max(4, xe - xs), height: h).offset(x: xs).allowsHitTesting(false)

                // Testina
                Rectangle().fill(Theme.ink).frame(width: 2, height: h + 10).offset(x: xp - 1, y: -5)
                    .shadow(color: Theme.ivory, radius: 1).allowsHitTesting(false)

                // Maniglie
                handle(height: h).offset(x: xs - 7, y: -6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        if dragBefore == nil { dragBefore = (m.start, m.end) }
                        m.setStart(Double(v.location.x / w) * d)
                    }.onEnded { _ in endDrag("Sposta l’inizio") })
                handle(height: h).offset(x: xe - 7, y: -6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        if dragBefore == nil { dragBefore = (m.start, m.end) }
                        m.setEnd(Double(v.location.x / w) * d)
                    }.onEnded { _ in endDrag("Sposta la fine") })
            }
            .coordinateSpace(name: "timeline")
        }
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 14, height: height + 12)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 3, height: 24))
            .shadow(color: tint.opacity(0.5), radius: 6)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

/// Anteprima video senza controlli (li gestiamo noi).
struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}
