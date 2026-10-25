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
    /// 4.1 · Da fare appena la forma d'onda è pronta (per esempio proporre il ritornello)
    var onLoaded: (() -> Void)?
    /// Durata massima della selezione (es. 30 s per le suonerie), nil = libera.
    var maxLength: Double? = nil

    // 3.8 · Zoom: in larghezza (tempo, fino al millesimo di secondo) e in altezza (onda più alta)
    /// 1 = tutto il file; 4 = si vede un quarto del file.
    @Published var zoom: Double = 1
    /// Il primo secondo visibile quando lo zoom è attivo.
    @Published var viewStart: Double = 0
    /// Altezza dell'onda: 1 = normale, fino a 8.
    @Published var gain: Double = 1
    /// L'onda a più risoluzioni: levels[0] = un picco ogni millesimo di secondo, ogni livello dopo la metà.
    private(set) var levels: [[Float]] = []
    static let hiresRate = 1000.0

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
            // 3.8 · Con lo zoom la vista segue chi ascolta, una pagina alla volta
            if self.playing && self.zoom > 1 && (s < self.viewStart || s > self.viewStart + self.span) {
                self.pan(to: s - self.span * 0.05)
            }
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
        // Un picco al millesimo di secondo (al massimo 4 milioni: più di un'ora), poi i livelli più radi
        let hiresBins = max(700, min(4_000_000, Int(dur * TrimModel.hiresRate)))
        let hires = await TrimModel.waveform(url: url, duration: dur, bins: hiresBins)
        let built = await Task.detached(priority: .userInitiated) { TrimModel.pyramid(hires) }.value
        levels = built
        peaks = built.first(where: { $0.count <= 1400 }) ?? built.last ?? []
        if video { thumbs = await TrimModel.thumbnails(url: url, count: 12, duration: dur) }
        loading = false
        onLoaded?()
        onLoaded = nil
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
        start = min(max(0, t), max(0, end - 0.01))
        if let maxL = maxLength, end - start > maxL { end = min(duration, start + maxL) }
        if !playing { seek(start) }
    }

    func setEnd(_ t: Double) {
        end = max(min(duration, t), start + 0.01)
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

    // MARK: Zoom

    /// La parte di file visibile, in secondi.
    var span: Double { max(0.001, duration / zoom) }
    /// Al massimo si vedono 0,25 secondi su tutta la larghezza: meno di un millesimo per punto.
    var maxZoom: Double { max(1, duration / 0.25) }

    /// Cambia lo zoom tenendo fermo un momento (dove c'è il puntatore, o la testina se si vede, o il centro).
    func setZoom(_ z: Double, around anchor: Double? = nil) {
        let old = span
        let a: Double = anchor ?? ((playhead >= viewStart && playhead <= viewStart + old) ? playhead : viewStart + old / 2)
        let rel = (a - viewStart) / old
        zoom = min(max(1, z), maxZoom)
        viewStart = clampedView(a - rel * span)
    }

    func zoomIn(around a: Double? = nil) { setZoom(zoom * 2, around: a) }
    func zoomOut(around a: Double? = nil) { setZoom(zoom / 2, around: a) }

    /// Torna a vedere tutto il file con l'altezza normale.
    func zoomReset() { zoom = 1; viewStart = 0; gain = 1 }

    /// Ingrandisce sulla selezione (con un po' di margine), per rifinire inizio e fine.
    func zoomToSelection() {
        let len = max(0.05, end - start)
        let z = min(max(1, duration / (len * 1.25)), maxZoom)
        zoom = z
        viewStart = clampedView((start + end) / 2 - span / 2)
    }

    func pan(by seconds: Double) { viewStart = clampedView(viewStart + seconds) }
    func pan(to s: Double) { viewStart = clampedView(s) }

    private func clampedView(_ s: Double) -> Double { min(max(0, s), max(0, duration - span)) }

    /// I picchi da disegnare per la parte visibile: `count` barre, prese dal livello giusto (veloce anche su file lunghi).
    func visiblePeaks(count: Int) -> [Float] {
        guard count > 0, duration > 0, let base = levels.first, !base.isEmpty else { return [] }
        let rate0 = Double(base.count) / duration                 // picchi al secondo del livello 0
        let perBar = span * rate0 / Double(count)
        var k = 0
        while k + 1 < levels.count && perBar >= Double(1 << (k + 1)) { k += 1 }
        let lv = levels[k]
        let rate = rate0 / Double(1 << k)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t0 = viewStart + span * Double(i) / Double(count)
            let t1 = viewStart + span * Double(i + 1) / Double(count)
            var a = Int(t0 * rate), b = Int(t1 * rate)
            a = min(max(0, a), lv.count - 1)
            b = min(max(a, b), lv.count - 1)
            var mx: Float = 0
            if b > a { for j in a..<b where lv[j] > mx { mx = lv[j] } } else { mx = lv[a] }
            out[i] = mx
        }
        return out
    }

    /// Ogni livello è il precedente con i picchi a coppie.
    static func pyramid(_ base: [Float]) -> [[Float]] {
        var out = [base]
        var cur = base
        while cur.count > 700 {
            var next = [Float](repeating: 0, count: (cur.count + 1) / 2)
            for i in 0..<next.count {
                let a = cur[2 * i]
                next[i] = 2 * i + 1 < cur.count ? max(a, cur[2 * i + 1]) : a
            }
            out.append(next)
            cur = next
        }
        return out
    }

    // MARK: Il ritornello

    /// 4.1 · Dove comincia il pezzo più «pieno» della canzone (di solito il ritornello): la finestra di
    /// `length` secondi con il volume medio più alto, lontano dall'introduzione e dal finale.
    static func loudestWindow(peaks: [Float], duration: Double, length: Double) -> Double {
        let n = peaks.count
        guard n > 4, duration > length + 1 else { return 0 }
        let perSec = Double(n) / duration
        let w = max(1, Int(length * perSec))
        let from = Int(duration * 0.12 * perSec), to = Int((duration * 0.92 - length) * perSec)
        guard to > from, to + w <= n else { return max(0, min(duration - length, duration * 0.3)) }
        var sum: Float = peaks[from..<(from + w)].reduce(0, +)
        var best = sum, bestAt = from
        for i in (from + 1)...to {
            sum += peaks[i + w - 1] - peaks[i - 1]
            if sum > best { best = sum; bestAt = i }
        }
        // Si parte un attimo prima, sul battere più vicino: mezzo secondo di respiro
        return max(0, Double(bestAt) / perSec - 0.5)
    }

    /// Mette la selezione sul ritornello (e ci porta la testina).
    func suggestChorus(length: Double) {
        let s = Self.loudestWindow(peaks: levels.first(where: { $0.count <= 20_000 }) ?? peaks, duration: duration, length: length)
        start = s
        end = min(duration, s + length)
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
    // 3.5.2 · Decimali con la virgola, all'italiana
    if h > 0 { return String(format: "%d:%02d:%04.1f", h, m, s).replacingOccurrences(of: ".", with: ",") }
    return String(format: "%d:%04.1f", m, s).replacingOccurrences(of: ".", with: ",")
}

/// 3.8 · Con i millesimi (zoom attivo): 1:02,345
func formatTimeMs(_ t: Double) -> String {
    guard t.isFinite else { return "0:00,000" }
    let total = max(0, t)
    let h = Int(total) / 3600
    let m = (Int(total) % 3600) / 60
    let s = total - Double(h * 3600 + m * 60)
    if h > 0 { return String(format: "%d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: ",") }
    return String(format: "%d:%06.3f", m, s).replacingOccurrences(of: ".", with: ",")
}

/// 3.5.2 · Numeri scritti sempre all'italiana (virgola per i decimali), qualunque sia la lingua del Mac.
enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let t = ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        guard Locale.current.decimalSeparator == "." else { return t }
        return String(t.map { $0 == "." ? "," : ($0 == "," ? "." : $0) })
    }
    static func secs(_ x: Double) -> String { String(format: "%.1f s", x).replacingOccurrences(of: ".", with: ",") }
    static func decimal(_ x: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", x).replacingOccurrences(of: ".", with: ",")
    }
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
        if mode == .ringtone { model.maxLength = 30 }
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
                 ? "Fino a 30 secondi. Si crea un file .m4r: collega l’iPhone, aprilo nel Finder e trascinaci la suoneria."
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

    /// Quante barre disegnare per una larghezza.
    private func bars(_ w: CGFloat) -> Int { max(40, Int(w / 2.2)) }

    /// L'onda come forma (solo per le foto automatiche): le barre dentro o fuori dalla selezione.
    private func wave(peaks: [Float], w: CGFloat, h: CGFloat, xs: CGFloat, xe: CGFloat, inside: Bool) -> Path {
        var path = Path()
        let n = peaks.count
        guard n > 0 else { return path }
        let top: CGFloat = m.isVideo ? h * 0.5 : 0
        let area = h - top
        let bw = w / CGFloat(n)
        for (i, p) in peaks.enumerated() {
            let x = CGFloat(i) * bw
            guard (x >= xs && x <= xe) == inside else { continue }
            let bh = barHeight(p, area: area)
            path.addRoundedRect(in: CGRect(x: x, y: top + (area - bh) / 2, width: max(1, bw - 0.6), height: bh),
                                cornerSize: CGSize(width: min(1.5, bw / 2), height: min(1.5, bw / 2)))
        }
        return path
    }

    private func barHeight(_ p: Float, area: CGFloat) -> CGFloat {
        min(area - 4, max(2, CGFloat(p) * CGFloat(m.gain) * (area - 10)))
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            // 3.8 · Si vede solo la parte scelta con lo zoom: da viewStart per `span` secondi
            let v0 = m.zoom > 1 ? m.viewStart : 0
            let span = m.zoom > 1 ? m.span : max(m.duration, 0.001)
            let toX = { (t: Double) -> CGFloat in CGFloat((t - v0) / span) * w }
            let toT = { (x: CGFloat) -> Double in v0 + Double(x / max(w, 1)) * span }
            let xs = toX(m.start)
            let xe = toX(m.end)
            let xp = toX(m.playhead)
            let peaks = m.zoom > 1 || m.levels.isEmpty ? m.visiblePeaks(count: bars(w)) : m.peaks
            ZStack(alignment: .topLeading) {
                // Sfondo: clic = sposta la testina
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.parchment.opacity(0.55))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
                        m.seek(toT(v.location.x))
                    })

                if m.isVideo && !m.thumbs.isEmpty && m.zoom <= 1 {
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

                Group {
                    if GPULayer.off {
                        // Foto automatiche (Mac virtuale senza scheda grafica): la stessa onda, fatta di forme
                        ZStack(alignment: .topLeading) {
                            wave(peaks: peaks, w: w, h: h, xs: xs, xe: xe, inside: true).fill(tint)
                            wave(peaks: peaks, w: w, h: h, xs: xs, xe: xe, inside: false).fill(Theme.ink.opacity(0.22))
                        }
                    } else {
                        Canvas { ctx, size in
                            let n = peaks.count
                            guard n > 0 else { return }
                            let top: CGFloat = m.isVideo ? size.height * 0.5 : 0
                            let area = size.height - top
                            let bw = size.width / CGFloat(n)
                            for (i, p) in peaks.enumerated() {
                                let x = CGFloat(i) * bw
                                let bh = barHeight(p, area: area)
                                let inside = x >= xs && x <= xe
                                let rect = CGRect(x: x, y: top + (area - bh) / 2, width: max(1, bw - 0.6), height: bh)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, bw / 2)),
                                         with: .color(inside ? tint : Theme.ink.opacity(0.22)))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)

                // Zone escluse un po' scure
                let cs = min(max(0, xs), w), ce = min(max(0, xe), w)
                Rectangle().fill(Theme.cream.opacity(0.65)).frame(width: cs, height: h).allowsHitTesting(false)
                Rectangle().fill(Theme.cream.opacity(0.65)).frame(width: max(0, w - ce), height: h).offset(x: ce).allowsHitTesting(false)

                // Bordo della selezione (solo la parte visibile)
                if ce > cs || (xe >= 0 && xs <= w) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint, lineWidth: 2)
                        .frame(width: max(4, ce - cs), height: h).offset(x: cs).allowsHitTesting(false)
                }

                // Testina
                if xp >= -1 && xp <= w + 1 {
                    Rectangle().fill(Theme.ink).frame(width: 2, height: h + 10).offset(x: xp - 1, y: -5)
                        .shadow(color: Theme.ivory, radius: 1).allowsHitTesting(false)
                }

                // Maniglie (solo se si vedono)
                if xs >= -7 && xs <= w + 7 {
                    handle(height: h).offset(x: xs - 7, y: -6)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                            if dragBefore == nil { dragBefore = (m.start, m.end) }
                            m.setStart(toT(v.location.x))
                        }.onEnded { _ in endDrag("Sposta l’inizio") })
                }
                if xe >= -7 && xe <= w + 7 {
                    handle(height: h).offset(x: xe - 7, y: -6)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                            if dragBefore == nil { dragBefore = (m.start, m.end) }
                            m.setEnd(toT(v.location.x))
                        }.onEnded { _ in endDrag("Sposta la fine") })
                }

                // Rotellina e trackpad: scorrere sposta la vista (con lo zoom), pizzicare ingrandisce
                WaveGestures(
                    onScroll: { dx in if m.zoom > 1 { m.pan(by: -Double(dx / max(w, 1)) * span) } },
                    onMagnify: { f, x in m.setZoom(m.zoom * f, around: toT(x)) },
                    canScroll: m.zoom > 1)
            }
            .coordinateSpace(name: "timeline")
            .clipped()
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

/// 3.8 · Rotellina, scorrimento a due dita e pizzico sopra la forma d'onda. I clic passano sotto.
struct WaveGestures: NSViewRepresentable {
    /// Spostamento orizzontale in punti (positivo = verso destra).
    let onScroll: (CGFloat) -> Void
    /// Fattore di zoom e posizione x del puntatore.
    let onMagnify: (Double, CGFloat) -> Void
    /// Senza zoom lo scorrimento passa alla finestra.
    var canScroll = true

    func makeNSView(context: Context) -> V { let v = V(); updateNSView(v, context: context); return v }
    func updateNSView(_ v: V, context: Context) { v.onScroll = onScroll; v.onMagnify = onMagnify; v.canScroll = canScroll }

    final class V: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onMagnify: ((Double, CGFloat) -> Void)?
        var canScroll = true
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                if e.type == .magnify {
                    self.onMagnify?(1 + Double(e.magnification), p.x)
                    return nil
                }
                // ⌘ + rotellina = zoom; altrimenti scorre (anche la rotellina verticale del mouse)
                if e.modifierFlags.contains(.command) {
                    let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
                    self.onMagnify?(pow(1.01, Double(dy)), p.x)
                    return nil
                }
                guard self.canScroll else { return e }
                let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
                self.onScroll?(e.hasPreciseScrollingDeltas ? dx : dx * 10)
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

/// Anteprima video senza controlli (li gestiamo noi).
struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer
    /// 3.5 · Chiamato una volta quando la prima immagine è pronta sullo schermo
    var onReady: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        context.coordinator.watch(v, onReady)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }          // 3.5 · niente riassegnazioni a ogni fotogramma
        context.coordinator.watch(v, onReady)
    }

    final class Coordinator {
        private var token: NSKeyValueObservation?
        private var fired = false

        func watch(_ v: AVPlayerView, _ onReady: (() -> Void)?) {
            guard let onReady else { token = nil; return }
            guard token == nil, !fired else { return }
            if v.isReadyForDisplay { fired = true; DispatchQueue.main.async { onReady() }; return }
            // 3.5.1 · L'avviso può arrivare da un altro thread: tutto si decide sul principale
            token = v.observe(\.isReadyForDisplay, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    guard let self, !self.fired, view.isReadyForDisplay else { return }
                    self.fired = true
                    self.token = nil
                    onReady()
                }
            }
        }
    }
}
