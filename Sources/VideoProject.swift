import Foundation
import AppKit
import AVFoundation
import CoreImage
import SoundAnalysis

// ════════════════════════════════════════════════════════════════════
//  2.6.2 · Video come progetto (non distruttivo)
//  Le modifiche si vedono subito in anteprima; il file si crea solo con «Esporta».
//  • clip in fila (taglia, dividi, sposta, elimina)
//  • musica: punto di partenza nel video e nella canzone, ripetizione, volume, dissolvenze,
//    «abbassa quando si parla» (le voci si trovano con il riconoscimento dei suoni di macOS)
//  • audio originale: volume e muto
//  • esportazione: formato (anche 9:16 che segue il soggetto), risoluzione, fluidità
// ════════════════════════════════════════════════════════════════════

struct VPClip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var inPoint: Double
    var outPoint: Double
    var url: URL { URL(fileURLWithPath: path) }
    var length: Double { max(0, outPoint - inPoint) }
}

struct VPMusic: Codable, Equatable, Sendable {
    var path: String
    /// Dove parte nel video (secondi del montaggio).
    var offset: Double = 0
    /// Da che punto della canzone parte.
    var inPoint: Double = 0
    /// Ricomincia (dal punto scelto) finché il video non finisce.
    var loop = false
    var volume: Double = 0.8
    var fadeIn: Double = 1
    var fadeOut: Double = 2
    /// Abbassa la musica dove nel video c'è una voce.
    var duck = true
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

struct VideoProject: Codable, Equatable, Sendable {
    var clips: [VPClip] = []
    var music: VPMusic? = nil
    var originalVolume: Double = 1
    var originalMuted = false
    /// «orig», «9x16», «1x1», «4x5», «16x9»
    var aspect = "orig"
    var follow = true
    /// Lato corto del video esportato: 720, 1080, 2160 (mai più grande dell'originale)
    var resolution = 1080
    var fps = 30

    var duration: Double { clips.reduce(0) { $0 + $1.length } }
    var originalAudible: Bool { !originalMuted && originalVolume > 0.03 }

    /// Inizio di ogni clip nel montaggio.
    var starts: [Double] {
        var out: [Double] = []
        var t = 0.0
        for c in clips { out.append(t); t += c.length }
        return out
    }

    /// La clip sotto un istante del montaggio, con l'istante corrispondente nel file.
    func clip(at t: Double) -> (index: Int, local: Double)? {
        guard !clips.isEmpty else { return nil }
        var start = 0.0
        for (i, c) in clips.enumerated() {
            if t < start + c.length || i == clips.count - 1 {
                return (i, min(c.outPoint, max(c.inPoint, c.inPoint + (t - start))))
            }
            start += c.length
        }
        return nil
    }

    var aspectRatio: Double? {
        let a = aspect.split(separator: "x").compactMap { Double($0) }
        return a.count == 2 && a[0] > 0 && a[1] > 0 ? a[0] / a[1] : nil
    }
}

/// Quello che serve sapere di un file per montarlo (letto una volta sola).
struct VPMediaInfo: Sendable, Equatable {
    var duration: Double
    var videoDuration: Double
    var naturalSize: CGSize
    var transform: CGAffineTransform
    var displaySize: CGSize
    var fps: Double
    var hasVideo: Bool
    var hasAudio: Bool

    static func load(_ url: URL) async throws -> VPMediaInfo {
        let a = AVURLAsset(url: url)
        let d = try await a.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw NativeError("«\(url.lastPathComponent)» non si legge") }
        let v = try await a.loadTracks(withMediaType: .video).first
        let au = try await a.loadTracks(withMediaType: .audio).first
        var info = VPMediaInfo(duration: d, videoDuration: d, naturalSize: .zero, transform: .identity, displaySize: .zero,
                               fps: 30, hasVideo: v != nil, hasAudio: au != nil)
        if let v {
            let ns = try await v.load(.naturalSize)
            let t = try await v.load(.preferredTransform)
            let nominal = try await v.load(.nominalFrameRate)
            let rate = Double(nominal)
            let tr = try await v.load(.timeRange)
            let r = CGRect(origin: .zero, size: ns).applying(t)
            info.naturalSize = ns
            info.transform = t
            info.displaySize = CGSize(width: abs(r.width), height: abs(r.height))
            info.fps = rate.isFinite && rate > 0 ? rate : 30
            let vd = tr.end.seconds
            if vd.isFinite, vd > 0 { info.videoDuration = min(d, vd) }
        }
        return info
    }
}

// MARK: - Composizione (la stessa per l'anteprima e per l'esportazione)

struct VPBuilt {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let renderSize: CGSize
    let duration: Double
}

enum VideoProjectBuilder {
    static func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// La trasformazione del video «girata» e riportata con l'angolo in 0,0, qualunque sia il telefono.
    static func normalized(_ t: CGAffineTransform, natural: CGSize) -> CGAffineTransform {
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// Fine della musica nel montaggio (nil se non c'è musica o non si sa ancora quanto dura).
    static func musicEnd(_ p: VideoProject, songDuration: Double?) -> Double? {
        guard let m = p.music, let sd = songDuration, sd > 0 else { return nil }
        let total = p.duration
        let start = min(max(0, m.offset), total)
        let avail = max(0, sd - min(max(0, m.inPoint), sd))
        guard avail > 0.05 else { return start }
        return m.loop ? total : min(total, start + avail)
    }

    /// Momenti del montaggio in cui c'è una voce (da quelli trovati nei singoli file).
    static func speechOnTimeline(_ p: VideoProject, speech: [String: [ClosedRange<Double>]]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for (c, start) in zip(p.clips, p.starts) {
            for r in speech[c.path] ?? [] {
                let a = max(r.lowerBound, c.inPoint), b = min(r.upperBound, c.outPoint)
                if b > a { out.append((start + a - c.inPoint)...(start + b - c.inPoint)) }
            }
        }
        // Unisce i tratti vicini (pause brevi tra le parole): la musica non «pompa» su e giù
        out.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in out {
            if let last = merged.last, r.lowerBound - last.upperBound < 0.8 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    static func build(_ p: VideoProject, infos: [String: VPMediaInfo], speech: [String: [ClosedRange<Double>]],
                      maxSide: CGFloat) async throws -> VPBuilt {
        let comp = AVMutableComposition()
        guard let vT = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeError("non riesco a preparare il montaggio")
        }
        // Tela: la misura della prima clip (girata), lato lungo al massimo maxSide
        guard let firstInfo = p.clips.lazy.compactMap({ infos[$0.path] }).first(where: { $0.hasVideo }) else {
            throw NativeError("nessuna clip pronta")
        }
        let base = firstInfo.displaySize
        guard base.width > 0, base.height > 0 else { throw NativeError("dimensioni del video non valide") }
        let k = min(1, maxSide / max(base.width, base.height))
        let canvas = CGSize(width: CGFloat(Media.even(Double(base.width * k))), height: CGFloat(Media.even(Double(base.height * k))))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vT)
        var cursor = CMTime.zero
        for c in p.clips {
            guard let info = infos[c.path], info.hasVideo else { continue }
            let a = AVURLAsset(url: c.url)
            guard let v = try await a.loadTracks(withMediaType: .video).first else { continue }
            let s = min(max(0, c.inPoint), max(0, info.videoDuration - 0.05))
            let e = min(max(s + 0.05, c.outPoint), info.videoDuration)
            guard e - s >= 0.05 else { continue }
            let r = CMTimeRange(start: cm(s), end: cm(e))
            try vT.insertTimeRange(r, of: v, at: cursor)
            if info.hasAudio, let au = try await a.loadTracks(withMediaType: .audio).first {
                try? aT.insertTimeRange(r, of: au, at: cursor)
            }
            let ds = info.displaySize
            let fit = min(canvas.width / max(ds.width, 1), canvas.height / max(ds.height, 1))
            let tx = (canvas.width - ds.width * fit) / 2, ty = (canvas.height - ds.height * fit) / 2
            let t = normalized(info.transform, natural: info.naturalSize)
                .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(t, at: cursor)
            cursor = cursor + r.duration
        }
        guard cursor.seconds > 0.05 else { throw NativeError("il montaggio è vuoto") }
        let total = cursor.seconds

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instr.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = canvas
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, p.fps))))
        vc.instructions = [instr]
        // Uscita in SDR standard: i video HDR dell'iPhone vengono convertiti con i colori giusti
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        var params: [AVMutableAudioMixInputParameters] = []
        if aT.segments.isEmpty {
            comp.removeTrack(aT)
        } else {
            let op = AVMutableAudioMixInputParameters(track: aT)
            op.setVolume(Float(p.originalMuted ? 0 : min(1, max(0, p.originalVolume))), at: .zero)
            params.append(op)
        }

        // Musica
        if let m = p.music, let mi = infos[m.path], mi.hasAudio, mi.duration > 0.2 {
            let song = AVURLAsset(url: m.url)
            if let st = try await song.loadTracks(withMediaType: .audio).first,
               let mT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let start = min(max(0, m.offset), total)
                let inP = min(max(0, m.inPoint), max(0, mi.duration - 0.2))
                var t = start
                while t < total - 0.05 {
                    let len = min(mi.duration - inP, total - t)
                    guard len > 0.05 else { break }
                    try mT.insertTimeRange(CMTimeRange(start: cm(inP), duration: cm(len)), of: st, at: cm(t))
                    t += len
                    if !m.loop { break }
                }
                if mT.segments.isEmpty {
                    comp.removeTrack(mT)
                } else {
                    let duck = (m.duck && p.originalAudible) ? speechOnTimeline(p, speech: speech) : []
                    params.append(musicEnvelope(track: mT, music: m, start: start, end: t, duck: duck))
                }
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return VPBuilt(composition: comp, videoComposition: vc, audioMix: mix, renderSize: canvas, duration: total)
    }

    /// Il volume della musica nel tempo: dissolvenze e «abbassa quando si parla», senza scalini.
    static func musicEnvelope(track: AVAssetTrack, music m: VPMusic, start: Double, end: Double,
                              duck: [ClosedRange<Double>]) -> AVMutableAudioMixInputParameters {
        let v = min(1, max(0, m.volume))
        let span = max(0, end - start)
        let fi = min(max(0, m.fadeIn), span / 2), fo = min(max(0, m.fadeOut), span / 2)
        let attack = 0.3, release = 0.5, low = 0.25
        func level(_ t: Double) -> Double {
            var g = v
            if fi > 0, t < start + fi { g *= max(0, (t - start) / fi) }
            if fo > 0, t > end - fo { g *= max(0, (end - t) / fo) }
            var d = 1.0
            for r in duck where t >= r.lowerBound - attack && t <= r.upperBound + release {
                let k: Double
                if t < r.lowerBound { k = (r.lowerBound - t) / attack }
                else if t > r.upperBound { k = (t - r.upperBound) / release }
                else { k = 0 }
                d = min(d, low + (1 - low) * min(1, max(0, k)))
            }
            return min(1, max(0, g * d))
        }
        var points: [Double] = [start, end, start + fi, end - fo]
        for r in duck {
            points += [r.lowerBound - attack, r.lowerBound, r.upperBound, r.upperBound + release]
        }
        let sorted = points.filter { $0 >= start && $0 <= end }.sorted()
        var times: [Double] = []
        for t in sorted where times.last.map({ t - $0 > 0.01 }) ?? true { times.append(t) }
        let p = AVMutableAudioMixInputParameters(track: track)
        p.setVolume(Float(level(start)), at: cm(start))
        for i in 0..<max(0, times.count - 1) {
            let a = times[i], b = times[i + 1]
            p.setVolumeRamp(fromStartVolume: Float(level(a)), toEndVolume: Float(level(b)),
                            timeRange: CMTimeRange(start: cm(a), end: cm(b)))
        }
        return p
    }
}

// MARK: - Le voci nel video (riconoscimento dei suoni di macOS)

enum SpeechDetector {
    /// Tratti (in secondi del file) in cui si sente una persona parlare. Vuoto se non c'è audio o non si riesce.
    static func ranges(in url: URL) async -> [ClosedRange<Double>] {
        await Task.detached(priority: .utility) { () -> [ClosedRange<Double>] in
            (try? await detect(url)) ?? []
        }.value
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var found: [ClosedRange<Double>] = []
        let done = DispatchSemaphore(value: 0)
        var ranges: [ClosedRange<Double>] { lock.lock(); defer { lock.unlock() }; return found }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult,
                  let speech = r.classification(forIdentifier: "speech"), speech.confidence > 0.5 else { return }
            let a = r.timeRange.start.seconds, b = (r.timeRange.start + r.timeRange.duration).seconds
            guard a.isFinite, b.isFinite, b > a else { return }
            lock.lock(); found.append(a...b); lock.unlock()
        }
        func request(_ request: SNRequest, didFailWithError error: Error) { done.signal() }
        func requestDidComplete(_ request: SNRequest) { done.signal() }
    }

    private static func detect(_ url: URL) async throws -> [ClosedRange<Double>] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let rate = 16_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return [] }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var position: AVAudioFramePosition = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            let frames = len / 4
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let dst = buf.floatChannelData?[0] else { continue }
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: dst)
            buf.frameLength = AVAudioFrameCount(frames)
            analyzer.analyze(buf, atAudioFramePosition: position)
            position += AVAudioFramePosition(frames)
        }
        analyzer.completeAnalysis()
        _ = collector.done.wait(timeout: .now() + 20)
        return collector.ranges
    }
}

// MARK: - Esportazione (dalla Coda)

/// Quello che la Coda riceve: il progetto e le voci già trovate.
struct VPSnapshot: Codable {
    var project: VideoProject
    var speech: [String: [[Double]]]
}

enum VideoProjectExport {
    static func writeSnapshot(_ p: VideoProject, speech: [String: [ClosedRange<Double>]]) throws -> URL {
        let dir = Paths.support.appendingPathComponent("Progetti video")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // I vecchi file di esportazione (più di un giorno) si tolgono
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let limit = Date().addingTimeInterval(-86_400)
            for u in items where u.lastPathComponent.hasPrefix("esporta-") {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if d < limit { try? FileManager.default.removeItem(at: u) }
            }
        }
        let url = dir.appendingPathComponent("esporta-\(UUID().uuidString).json")
        let snap = VPSnapshot(project: p, speech: speech.mapValues { $0.map { [$0.lowerBound, $0.upperBound] } })
        try JSONEncoder().encode(snap).write(to: url, options: .atomic)
        return url
    }

    /// Misura del video finale: il formato scelto, ritagliato dalla tela, con il lato corto della risoluzione scelta.
    static func outputSize(canvas: CGSize, project p: VideoProject) -> (crop: CGSize, out: CGSize) {
        var cw = Double(canvas.width), ch = Double(canvas.height)
        if let r = p.aspectRatio {
            ch = cw / r
            if ch > Double(canvas.height) { ch = Double(canvas.height); cw = ch * r }
        }
        let k = min(1, Double(p.resolution) / max(1, min(cw, ch)))
        return (CGSize(width: cw, height: ch), CGSize(width: Media.even(cw * k), height: Media.even(ch * k)))
    }

    static func run(snapshot: URL, out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let snap = try JSONDecoder().decode(VPSnapshot.self, from: Data(contentsOf: snapshot))
        let p = snap.project
        let speech = snap.speech.mapValues { list in list.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil } }
        var infos: [String: VPMediaInfo] = [:]
        for path in Set(p.clips.map { $0.path } + (p.music.map { [$0.path] } ?? [])) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw NativeError("non trovo più «\(URL(fileURLWithPath: path).lastPathComponent)»")
            }
            infos[path] = try await VPMediaInfo.load(URL(fileURLWithPath: path))
        }
        let built = try await VideoProjectBuilder.build(p, infos: infos, speech: speech, maxSide: 3840)
        let canvas = built.renderSize
        let sizes = outputSize(canvas: canvas, project: p)
        let cropW = Double(sizes.crop.width), cropH = Double(sizes.crop.height)
        let W = Double(canvas.width), H = Double(canvas.height)
        let full = CMTimeRange(start: .zero, duration: VideoProjectBuilder.cm(built.duration))
        progress(0.01)
        var path: [Media.SubjectPoint] = []
        if p.aspectRatio != nil, p.follow, cropW < W - 2 || cropH < H - 2 {
            path = await Media.subjectPath(asset: built.composition, videoComposition: built.videoComposition, range: full) { f in
                progress(0.01 + f * 0.14)
            }
        }
        if job.cancelRequested { throw NativeError("annullato") }
        let track = Media.SubjectTrack(path)
        let sx = Double(sizes.out.width) / cropW, sy = Double(sizes.out.height) / cropH
        try await VideoPipeline.processComposition(asset: built.composition, videoComposition: built.videoComposition,
                                                   audioMix: built.audioMix, range: full, fps: Double(p.fps),
                                                   size: sizes.out, out: out, job: job,
                                                   progress: { f in progress(0.15 + f * 0.85) }) { img, t in
            var frame = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            let c = track.center(at: t)
            let ox = min(max(c.x * W - cropW / 2, 0), W - cropW)
            let oy = min(max(c.y * H - cropH / 2, 0), H - cropH)
            frame = frame.cropped(to: CGRect(x: ox, y: oy, width: cropW, height: cropH))
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            return sx == 1 && sy == 1 ? frame : frame.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        try? FileManager.default.removeItem(at: snapshot)
    }
}
