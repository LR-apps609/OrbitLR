import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Vision

// ════════════════════════════════════════════════════════════════════
//  2.6 · Video e audio con i motori di macOS (niente programmi da installare)
//  • social    formato verticale/quadrato per Reels, TikTok, YouTube (segue il soggetto)
//  • vmerge    unisci più video uno dopo l'altro
//  • music     aggiungi musica (sotto l'audio o al suo posto)
//  • ringtone  suoneria per iPhone (.m4r)
//  • whatsapp  vocale leggero
//  • amerge    unisci più audio
//  • tts       testo in voce
// ════════════════════════════════════════════════════════════════════

enum Media {
    static let ids: Set<String> = ["social", "vmerge", "music", "ringtone", "whatsapp", "amerge", "tts", "vproject"]
    /// Azioni che usano tutti i file insieme e danno un solo risultato.
    static let multi: Set<String> = ["vmerge", "amerge", "vproject"]

    static let ci = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Ingresso

    static func run(job: Job, file: URL, dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        switch job.action.id {
        case "social":
            let p = SocialParam(job.param)
            let out = Destination.unique(dir, base: "\(base) (\(p.label))", ext: "mp4")
            try await social(file, param: p, out: out, job: job, progress: progress)
            return out
        case "music":
            let p = job.param
            guard let bar = p.firstIndex(of: "|") else { throw NativeError("manca la musica da aggiungere") }
            let mode = String(p[p.startIndex..<bar])
            let music = URL(fileURLWithPath: String(p[p.index(after: bar)...]))
            guard FileManager.default.fileExists(atPath: music.path) else { throw NativeError("non trovo il file della musica") }
            let out = Destination.unique(dir, base: "\(base) (con musica)", ext: "mp4")
            try await addMusic(file, music: music, replace: mode == "replace", out: out, job: job, progress: progress)
            return out
        case "ringtone":
            let r = RingParam(job.param)
            let out = Destination.unique(dir, base: "\(base) (suoneria)", ext: "m4r")
            try await renderAudio([(file, r.start, r.end)], out: out, bitrate: 192_000, channels: 2,
                                  fadeIn: r.fade ? 0.6 : 0, fadeOut: r.fade ? 1.5 : 0, normalize: r.normalize,
                                  maxSeconds: 40, job: job, progress: progress)
            return out
        case "whatsapp":
            let out = Destination.unique(dir, base: "\(base) (WhatsApp)", ext: "m4a")
            try await renderAudio([(file, nil, nil)], out: out, bitrate: 64_000, channels: 1,
                                  fadeIn: 0, fadeOut: 0, normalize: true, maxSeconds: nil, job: job, progress: progress)
            return out
        case "tts":
            let text = try readText(file)
            let out = Destination.unique(dir, base: ttsName(text, fallback: base), ext: "m4a")
            // Parametro «voce|velocità» (entrambi facoltativi)
            let tp = job.param.components(separatedBy: "|")
            let voice = tp.first.flatMap { $0.isEmpty ? nil : $0 }
            let rate = tp.count > 1 ? Float(tp[1]) : nil
            try await Speech.write(text: text, voice: voice, rate: rate, out: out, job: job, progress: progress)
            return out
        default:
            throw NativeError("azione sconosciuta")
        }
    }

    static func runMulti(job: Job, files: [URL], dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let first = files.first else { throw NativeError("nessun file") }
        let base = first.deletingPathExtension().lastPathComponent
        switch job.action.id {
        case "vproject":
            let out = Destination.unique(dir, base: "\(base) (montaggio)", ext: "mp4")
            try await VideoProjectExport.run(snapshot: URL(fileURLWithPath: job.param), out: out, job: job, progress: progress)
            return out
        case "vmerge":
            let videos = files.filter { Catalog.kind(of: $0) == .video }
            guard videos.count >= 2 else { throw NativeError("servono almeno 2 video") }
            let out = Destination.unique(dir, base: "\(base) (\(videos.count) video uniti)", ext: "mp4")
            try await mergeVideos(videos, out: out, job: job, progress: progress)
            return out
        case "amerge":
            let audios = files.filter { [.audio, .video].contains(Catalog.kind(of: $0)) }
            guard audios.count >= 2 else { throw NativeError("servono almeno 2 file audio") }
            let out = Destination.unique(dir, base: "\(base) (\(audios.count) audio uniti)", ext: "m4a")
            try await renderAudio(audios.map { ($0, nil, nil) }, out: out, bitrate: 192_000, channels: 2,
                                  fadeIn: 0, fadeOut: 0, normalize: false, maxSeconds: nil, job: job, progress: progress)
            return out
        default:
            throw NativeError("azione sconosciuta")
        }
    }

    // MARK: - Parametri

    /// «9x16|1|inizio|fine»: formato, segui il soggetto (1/0), selezione facoltativa in secondi.
    struct SocialParam {
        var aw: Double = 9, ah: Double = 16
        var follow = true
        var start: Double? = nil, end: Double? = nil
        var label: String {
            switch (Int(aw), Int(ah)) {
            case (9, 16): return "9-16 Reels"
            case (1, 1): return "1-1 Post"
            case (4, 5): return "4-5 Feed"
            case (16, 9): return "16-9 YouTube"
            default: return "\(Int(aw))-\(Int(ah))"
            }
        }
        init(_ s: String) {
            let p = s.components(separatedBy: "|")
            let a = (p.first ?? "9x16").split(separator: "x").compactMap { Double($0) }
            if a.count == 2, a[0] > 0, a[1] > 0 { aw = a[0]; ah = a[1] }
            if p.count > 1 { follow = p[1] != "0" }
            if p.count > 2 { start = Double(p[2]) }
            if p.count > 3 { end = Double(p[3]) }
        }
    }

    /// «inizio|fine|dissolvenze(1/0)|volume uniforme(1/0)»
    struct RingParam {
        var start: Double? = nil, end: Double? = nil
        var fade = true, normalize = true
        init(_ s: String) {
            let p = s.components(separatedBy: "|")
            if p.count > 0 { start = Double(p[0]) }
            if p.count > 1 { end = Double(p[1]) }
            if p.count > 2 { fade = p[2] != "0" }
            if p.count > 3 { normalize = p[3] != "0" }
        }
    }

    private static func range(_ start: Double?, _ end: Double?, duration: Double) -> CMTimeRange {
        let s = max(0, min(start ?? 0, max(0, duration - 0.1)))
        var e = end ?? duration
        if !(e > s) || e > duration { e = duration }
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                           end: CMTime(seconds: e, preferredTimescale: 600))
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    // MARK: - Orientamento

    /// L'orientamento giusto dei fotogrammi «grezzi»: si prova e si confronta con il fotogramma che macOS
    /// mostra già girato, così vale per qualunque telefono o videocamera.
    private static func orientation(of asset: AVURLAsset, track: AVAssetTrack, at time: CMTime) async -> CGImagePropertyOrientation {
        let t = (try? await track.load(.preferredTransform)) ?? .identity
        var guess: CGImagePropertyOrientation = .up
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { guess = .right }
        else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { guess = .left }
        else if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { guess = .down }
        let raw = AVAssetImageGenerator(asset: asset)
        raw.appliesPreferredTrackTransform = false
        raw.maximumSize = CGSize(width: 320, height: 320)
        let shown = AVAssetImageGenerator(asset: asset)
        shown.appliesPreferredTrackTransform = true
        shown.maximumSize = CGSize(width: 320, height: 320)
        guard let r = try? await raw.image(at: time).image, let s = try? await shown.image(at: time).image else { return guess }
        let rawImg = CIImage(cgImage: r), target = CIImage(cgImage: s)
        var best = guess
        var bestScore = Float.greatestFiniteMagnitude
        for o in [guess, .up, .right, .left, .down] {
            let img = rawImg.oriented(o)
            let e = img.extent
            guard abs(e.width - target.extent.width) < 3, abs(e.height - target.extent.height) < 3 else { continue }
            let d = difference(img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)), target)
            if d < bestScore - 0.0001 { bestScore = d; best = o }
        }
        return best
    }

    /// Quanto due immagini (della stessa misura) sono diverse: media della differenza.
    static func difference(_ a: CIImage, _ b: CIImage) -> Float {
        let diff = CIFilter(name: "CIDifferenceBlendMode", parameters: [kCIInputImageKey: a, kCIInputBackgroundImageKey: b])
        guard let d = diff?.outputImage?.cropped(to: b.extent) else { return .greatestFiniteMagnitude }
        let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: d, kCIInputExtentKey: CIVector(cgRect: b.extent)])
        guard let o = avg?.outputImage else { return .greatestFiniteMagnitude }
        var px = [Float](repeating: 0, count: 4)
        ci.render(o, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: o.extent.origin, size: CGSize(width: 1, height: 1)),
                  format: .RGBAf, colorSpace: nil)
        return px[0] + px[1] + px[2]
    }

    // MARK: - Formato social

    private static func social(_ file: URL, param: SocialParam, out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else { throw NativeError("il file non contiene video") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NativeError("non riesco a leggere la durata") }
        let tr = range(param.start, param.end, duration: duration)
        let orient = await orientation(of: asset, track: vtrack, at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600))
        let natural = try await vtrack.load(.naturalSize)
        let sideways: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        let rotated = sideways.contains(orient)
        let W = Double(rotated ? natural.height : natural.width), H = Double(rotated ? natural.width : natural.height)
        guard W > 0, H > 0 else { throw NativeError("dimensioni del video non valide") }

        // Il riquadro più grande con le proporzioni scelte
        var cw = W, ch = W * param.ah / param.aw
        if ch > H { ch = H; cw = H * param.aw / param.ah }
        // Uscita: lato lungo fino a 1920 (mai ingrandito)
        let scale = min(1, 1920 / max(cw, ch))
        let outW = even(cw * scale), outH = even(ch * scale)

        progress(0.02)
        var path: [SubjectPoint] = []
        if param.follow && (cw < W - 2 || ch < H - 2) {
            path = await subjectPath(asset: asset, range: tr) { p in progress(0.02 + p * 0.13) }
        }
        if job.cancelRequested { throw NativeError("annullato") }
        let track = SubjectTrack(path)
        let cropW = cw, cropH = ch
        let sx = Double(outW) / cw, sy = Double(outH) / ch

        try await VideoPipeline.process(asset: asset, videoTrack: vtrack, range: tr, size: CGSize(width: outW, height: outH),
                                        out: out, job: job, progress: { p in progress(0.15 + p * 0.85) }) { raw, t in
            var img = raw.oriented(orient)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            let c = track.center(at: t)
            let ox = min(max(c.x * W - cropW / 2, 0), W - cropW)
            let oy = min(max(c.y * H - cropH / 2, 0), H - cropH)
            return img.cropped(to: CGRect(x: ox, y: oy, width: cropW, height: cropH))
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
    }

    struct SubjectPoint { let t: Double; var x: Double; var y: Double }

    /// Il centro del soggetto lungo il video, già ammorbidito (niente scatti).
    struct SubjectTrack {
        let points: [SubjectPoint]
        init(_ p: [SubjectPoint]) { points = p }
        func center(at t: Double) -> (x: Double, y: Double) {
            guard let first = points.first, let last = points.last else { return (0.5, 0.5) }
            if t <= first.t { return (first.x, first.y) }
            if t >= last.t { return (last.x, last.y) }
            var lo = 0, hi = points.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if points[mid].t <= t { lo = mid } else { hi = mid } }
            let a = points[lo], b = points[hi]
            let k = (t - a.t) / max(b.t - a.t, 0.0001)
            let s = k * k * (3 - 2 * k)          // passaggio dolce
            return (a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s)
        }
    }

    /// Persone (o, se non ci sono, ciò che attira lo sguardo) ogni mezzo secondo.
    static func subjectPath(asset: AVAsset, videoComposition: AVVideoComposition? = nil, range: CMTimeRange,
                            progress: @escaping (Double) -> Void) async -> [SubjectPoint] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let videoComposition { gen.videoComposition = videoComposition }
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let s = range.start.seconds, d = range.duration.seconds
        let count = max(2, min(240, Int(d / 0.5) + 1))
        var raw: [(Double, Double?, Double?)] = []
        for i in 0..<count {
            let t = s + d * Double(i) / Double(count - 1)
            var cx: Double? = nil, cy: Double? = nil
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                if let r = subjectBox(cg) { cx = Double(r.midX); cy = Double(r.midY) }
            }
            raw.append((t, cx, cy))
            progress(Double(i + 1) / Double(count))
        }
        // Buchi (nessun soggetto): si tiene l'ultimo punto noto, altrimenti il centro
        var pts: [SubjectPoint] = []
        var lastX = raw.first(where: { $0.1 != nil })?.1 ?? 0.5
        var lastY = raw.first(where: { $0.2 != nil })?.2 ?? 0.5
        for r in raw {
            if let x = r.1 { lastX = x }
            if let y = r.2 { lastY = y }
            pts.append(SubjectPoint(t: r.0, x: lastX, y: lastY))
        }
        // Ammorbidisce: media mobile su ~2 secondi, poi limita la velocità dell'inquadratura
        let radius = 2
        var smooth = pts
        for i in pts.indices {
            let lo = max(0, i - radius), hi = min(pts.count - 1, i + radius)
            let n = Double(hi - lo + 1)
            smooth[i].x = pts[lo...hi].reduce(0) { $0 + $1.x } / n
            smooth[i].y = pts[lo...hi].reduce(0) { $0 + $1.y } / n
        }
        for i in smooth.indices.dropFirst() {
            let dt = max(smooth[i].t - smooth[i - 1].t, 0.001)
            let maxStep = 0.25 * dt              // al massimo un quarto dell'immagine al secondo
            smooth[i].x = smooth[i - 1].x + min(max(smooth[i].x - smooth[i - 1].x, -maxStep), maxStep)
            smooth[i].y = smooth[i - 1].y + min(max(smooth[i].y - smooth[i - 1].y, -maxStep), maxStep)
        }
        return smooth
    }

    private static func subjectBox(_ cg: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        if (try? handler.perform([people])) != nil, let list = people.results, !list.isEmpty {
            let best = list.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            if let b = best?.boundingBox { return b }
        }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([attention])) != nil,
           let obs = attention.results?.first,
           let objs = obs.salientObjects, !objs.isEmpty {
            return objs.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?.boundingBox
        }
        return nil
    }

    // MARK: - Unisci video

    private static func mergeVideos(_ files: [URL], out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let comp = AVMutableComposition()
        guard let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeError("non riesco a preparare il video")
        }
        let aComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var segments: [(start: CMTime, transform: CGAffineTransform, size: CGSize, natural: CGSize)] = []
        var cursor = CMTime.zero
        var renderSize = CGSize.zero
        var maxFPS: Double = 24
        for f in files {
            let a = AVURLAsset(url: f)
            guard let v = try await a.loadTracks(withMediaType: .video).first else {
                throw NativeError("«\(f.lastPathComponent)» non contiene video")
            }
            let d = try await a.load(.duration)
            guard d.seconds.isFinite, d.seconds > 0 else { throw NativeError("«\(f.lastPathComponent)» non si legge") }
            let r = CMTimeRange(start: .zero, duration: d)
            try vComp.insertTimeRange(r, of: v, at: cursor)
            if let aud = try await a.loadTracks(withMediaType: .audio).first, let aComp {
                try? aComp.insertTimeRange(r, of: aud, at: cursor)
            }
            let ns = try await v.load(.naturalSize)
            let t = try await v.load(.preferredTransform)
            let rate = Double((try? await v.load(.nominalFrameRate)) ?? 30)
            if rate.isFinite, rate > maxFPS { maxFPS = min(60, rate) }
            let shown = CGRect(origin: .zero, size: ns).applying(t)
            let size = CGSize(width: abs(shown.width), height: abs(shown.height))
            if renderSize == .zero { renderSize = size }
            segments.append((cursor, t, size, ns))
            cursor = cursor + d
        }
        // Misura del primo video (lato lungo al massimo 1920), gli altri si adattano con le bande nere
        let k = min(1, 1920 / max(renderSize.width, renderSize.height))
        let rs = CGSize(width: even(renderSize.width * k), height: even(renderSize.height * k))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vComp)
        for s in segments {
            let fit = min(rs.width / s.size.width, rs.height / s.size.height)
            let tx = (rs.width - s.size.width * fit) / 2, ty = (rs.height - s.size.height * fit) / 2
            let t = VideoProjectBuilder.normalized(s.transform, natural: s.natural)
                .concatenating(CGAffineTransform(scaleX: fit, y: fit)).concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(t, at: s.start)
        }
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instr.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = rs
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, maxFPS.rounded())))
        vc.instructions = [instr]
        if let aComp, aComp.segments.isEmpty { comp.removeTrack(aComp) }
        try await export(comp, videoComposition: vc, audioMix: nil, out: out, job: job, progress: progress)
    }

    // MARK: - Aggiungi musica

    private static func addMusic(_ file: URL, music: URL, replace: Bool, out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let video = AVURLAsset(url: file)
        guard let v = try await video.loadTracks(withMediaType: .video).first else { throw NativeError("il file non contiene video") }
        let d = try await video.load(.duration)
        guard d.seconds.isFinite, d.seconds > 0 else { throw NativeError("non riesco a leggere la durata") }
        let song = AVURLAsset(url: music)
        guard let m = try await song.loadTracks(withMediaType: .audio).first else { throw NativeError("il file della musica non contiene audio") }
        let md = try await song.load(.duration)
        guard md.seconds.isFinite, md.seconds > 0.5 else { throw NativeError("la musica è troppo corta") }

        let comp = AVMutableComposition()
        guard let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let mComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeError("non riesco a preparare il video")
        }
        let full = CMTimeRange(start: .zero, duration: d)
        try vComp.insertTimeRange(full, of: v, at: .zero)
        vComp.preferredTransform = try await v.load(.preferredTransform)

        var params: [AVMutableAudioMixInputParameters] = []
        if !replace, let orig = try await video.loadTracks(withMediaType: .audio).first,
           let oComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try oComp.insertTimeRange(full, of: orig, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: oComp)
            p.setVolume(1, at: .zero)
            params.append(p)
        }
        // La musica si ripete finché il video non finisce
        var cursor = CMTime.zero
        while cursor < d {
            let left = d - cursor
            let piece = CMTimeMinimum(md, left)
            try mComp.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: m, at: cursor)
            cursor = cursor + piece
        }
        let mp = AVMutableAudioMixInputParameters(track: mComp)
        // Sotto l'audio originale la musica resta bassa; se il video è muto (o la si mette al posto dell'audio), piena
        let level: Float = (replace || params.isEmpty) ? 1 : 0.3
        mp.setVolume(level, at: .zero)
        let fade = min(2.0, d.seconds / 4)
        mp.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                         timeRange: CMTimeRange(start: CMTime(seconds: d.seconds - fade, preferredTimescale: 600),
                                                duration: CMTime(seconds: fade, preferredTimescale: 600)))
        params.append(mp)
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        try await export(comp, videoComposition: nil, audioMix: mix, out: out, job: job, progress: progress)
    }

    // MARK: - Esportazione con avanzamento e annullamento

    private static func export(_ asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
                               out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NativeError("questo video non si può esportare")
        }
        s.outputURL = out
        s.outputFileType = .mp4
        s.shouldOptimizeForNetworkUse = true
        s.videoComposition = videoComposition
        s.audioMix = audioMix
        try? FileManager.default.removeItem(at: out)
        job.exportSession = s
        let done = NativeEngine.DoneFlag()
        Task {
            while !done.value {
                progress(Double(s.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        done.value = true
        job.exportSession = nil
        switch s.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: out)
            throw NativeError("annullato")
        default:
            try? FileManager.default.removeItem(at: out)
            throw NativeError(s.error?.localizedDescription ?? "esportazione non riuscita")
        }
    }

    // MARK: - Audio: suoneria, vocale leggero, unione

    static let rate: Double = 44_100

    /// Legge (anche dai video), applica dissolvenze e volume, scrive AAC. Più file = uno dopo l'altro.
    static func renderAudio(_ inputs: [(URL, Double?, Double?)], out: URL, bitrate: Int, channels: Int,
                            fadeIn: Double, fadeOut: Double, normalize: Bool, maxSeconds: Double?,
                            job: Job, progress: @escaping (Double) -> Void) async throws {
        // Tratti da leggere
        var parts: [(AVURLAsset, AVAssetTrack, CMTimeRange)] = []
        for (url, s, e) in inputs {
            let a = AVURLAsset(url: url)
            guard let t = try await a.loadTracks(withMediaType: .audio).first else {
                throw NativeError("«\(url.lastPathComponent)» non contiene audio")
            }
            let d = try await a.load(.duration).seconds
            guard d.isFinite, d > 0 else { throw NativeError("«\(url.lastPathComponent)» non si legge") }
            var r = range(s, e, duration: d)
            if let maxS = maxSeconds, r.duration.seconds > maxS {
                r = CMTimeRange(start: r.start, duration: CMTime(seconds: maxS, preferredTimescale: 600))
            }
            parts.append((a, t, r))
        }
        let totalFrames = parts.reduce(0.0) { $0 + $1.2.duration.seconds } * rate
        guard totalFrames > 0 else { throw NativeError("niente audio da salvare") }

        // 1. Volume: misura picco e media, poi un solo guadagno (niente distorsione)
        var gain: Float = 1
        if normalize {
            var peak: Float = 0
            var sumSq: Double = 0
            var n: Double = 0
            for (a, t, r) in parts {
                try readPCM(a, track: t, range: r, channels: channels, job: job) { samples in
                    for v in samples {
                        let x = abs(v)
                        if x > peak { peak = x }
                        sumSq += Double(v * v)
                    }
                    n += Double(samples.count)
                    progress(min(0.3, 0.3 * n / Double(channels) / totalFrames))
                }
            }
            let rms = n > 0 ? sqrt(sumSq / n) : 0
            if rms > 0.0001, peak > 0.0001 {
                let wantRMS = pow(10, -16.0 / 20)                 // circa −16 dB: volume pieno ma naturale
                let byRMS = Float(wantRMS / rms)
                let byPeak = Float(0.89) / peak                  // il picco resta sotto −1 dB
                gain = min(max(min(byRMS, byPeak), 0.25), 8)
            }
        }

        // 2. Scrittura
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".orbitlr-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: tmp)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
        ]
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard let format = fmt else { throw NativeError("non riesco a preparare l’audio") }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw NativeError("non riesco a preparare l’audio") }
        writer.add(input)
        guard writer.startWriting() else { throw NativeError(writer.error?.localizedDescription ?? "non riesco a scrivere l’audio") }
        writer.startSession(atSourceTime: .zero)

        let fadeInFrames = fadeIn * rate, fadeOutFrames = fadeOut * rate
        var written: Double = 0
        let base = normalize ? 0.3 : 0.0
        do {
            for (a, t, r) in parts {
                try readPCM(a, track: t, range: r, channels: channels, job: job) { samples in
                    var buf = samples
                    let frames = buf.count / channels
                    for f in 0..<frames {
                        let pos = written + Double(f)
                        var g = gain
                        if fadeInFrames > 0, pos < fadeInFrames { g *= Float(pos / fadeInFrames) }
                        let left = totalFrames - pos
                        if fadeOutFrames > 0, left < fadeOutFrames { g *= Float(max(0, left) / fadeOutFrames) }
                        if g != 1 {
                            for c in 0..<channels {
                                let i = f * channels + c
                                buf[i] = min(1, max(-1, buf[i] * g))
                            }
                        }
                    }
                    let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate))
                    if let sb = makeSampleBuffer(buf, frames: frames, pts: pts, format: format) {
                        while !input.isReadyForMoreMediaData {
                            if job.cancelRequested { return }
                            usleep(5_000)
                        }
                        input.append(sb)
                    }
                    written += Double(frames)
                    progress(base + (1 - base) * min(1, written / totalFrames))
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if job.cancelRequested {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw NativeError("annullato")
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw NativeError(writer.error?.localizedDescription ?? "non riesco a scrivere l’audio")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        progress(1)
    }

    /// Campioni audio (Float, interleaved, 44,1 kHz) a blocchi.
    private static func readPCM(_ asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, channels: Int,
                                job: Job, _ body: ([Float]) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NativeError("non riesco a leggere l’audio") }
        reader.add(output)
        guard reader.startReading() else { throw NativeError(reader.error?.localizedDescription ?? "non riesco a leggere l’audio") }
        while let sb = output.copyNextSampleBuffer() {
            if job.cancelRequested { reader.cancelReading(); throw NativeError("annullato") }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            guard len >= 4 * channels else { continue }
            var data = [Float](repeating: 0, count: len / 4)
            data.withUnsafeMutableBytes { raw in
                if let p = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p) }
            }
            let usable = (data.count / channels) * channels
            if usable < data.count { data.removeLast(data.count - usable) }
            body(data)
        }
        if reader.status == .failed { throw NativeError(reader.error?.localizedDescription ?? "lettura dell’audio non riuscita") }
    }

    private static func makeSampleBuffer(_ samples: [Float], frames: Int, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard frames > 0 else { return nil }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let ok = samples.withUnsafeBytes { raw -> Bool in
            guard let p = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: p, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        }
        guard ok else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil,
                                                                   sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    // MARK: - Testo

    /// Il testo di un file (txt, md, rtf, docx, html…).
    static func readText(_ url: URL) throws -> String {
        let e = Catalog.norm(url.pathExtension)
        var text = ""
        if ["txt", "md", "srt", "csv"].contains(e) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            if e == "md" {
                text = text.replacingOccurrences(of: #"[#*_>`]+"#, with: "", options: .regularExpression)
            }
        } else if let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            text = a.string
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeError("il file non contiene testo da leggere") }
        return text
    }

    /// Nome del file audio: le prime parole del testo.
    static func ttsName(_ text: String, fallback: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).joined(separator: " ")
        let clean = words.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "", options: .regularExpression)
        let name = String(clean.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? fallback : name) + " (voce)"
    }
}

// MARK: - Pipeline video: legge i fotogrammi, li trasforma con Core Image, li riscrive (H.264 + AAC)

enum VideoPipeline {
    static let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    static let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 2,
    ]

    /// Un solo file: i fotogrammi «grezzi» della traccia video.
    static func process(asset: AVURLAsset, videoTrack: AVAssetTrack, range: CMTimeRange, size: CGSize, out: URL,
                        job: Job, progress: @escaping (Double) -> Void,
                        frame: @escaping (CIImage, Double) -> CIImage) async throws {
        let fps = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 30)
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let vOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: bgra)
        var aOut: AVAssetReaderOutput? = nil
        if let audioTrack { aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm) }
        try await run(reader: reader, vOut: vOut, aOut: aOut, range: range, fps: fps.isFinite && fps > 0 ? fps : 30,
                      size: size, out: out, job: job, progress: progress, frame: frame)
    }

    /// Un montaggio: i fotogrammi già composti (clip in fila, girati e adattati) e l'audio già mixato
    /// (musica, volumi, dissolvenze). I colori escono in SDR standard (Rec. 709) anche dai video HDR dell'iPhone.
    static func processComposition(asset: AVAsset, videoComposition: AVVideoComposition, audioMix: AVAudioMix?,
                                   range: CMTimeRange, fps: Double, size: CGSize, out: URL, job: Job,
                                   progress: @escaping (Double) -> Void,
                                   frame: @escaping (CIImage, Double) -> CIImage) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        guard !vTracks.isEmpty else { throw NativeError("il montaggio non contiene video") }
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: bgra)
        vOut.videoComposition = videoComposition
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        var aOut: AVAssetReaderOutput? = nil
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcm)
            o.audioMix = audioMix
            aOut = o
        }
        try await run(reader: reader, vOut: vOut, aOut: aOut, range: range, fps: fps, size: size, out: out,
                      job: job, progress: progress, frame: frame)
    }

    private static func run(reader: AVAssetReader, vOut: AVAssetReaderOutput, aOut proposedAudio: AVAssetReaderOutput?,
                            range: CMTimeRange, fps: Double, size: CGSize, out: URL, job: Job,
                            progress: @escaping (Double) -> Void,
                            frame: @escaping (CIImage, Double) -> CIImage) async throws {
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw NativeError("non riesco a leggere il video") }
        reader.add(vOut)

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let w = Int(size.width), h = Int(size.height)
        guard w >= 2, h >= 2 else { throw NativeError("dimensioni del video non valide") }
        let bitrate = max(2_000_000, min(50_000_000, Int(Double(w * h) * max(fps, 24) * 0.13)))
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            // Colori standard dei video HD: si vedono uguali su telefoni, Mac e social
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(vIn) else { throw NativeError("non riesco a preparare il video") }
        writer.add(vIn)
        // L'audio si legge solo se si può anche scrivere: un'uscita letta da nessuno bloccherebbe il video
        var aIn: AVAssetWriterInput? = nil
        var aOut: AVAssetReaderOutput? = nil
        if let o = proposedAudio {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            i.expectsMediaDataInRealTime = false
            o.alwaysCopiesSampleData = false
            if writer.canAdd(i), reader.canAdd(o) {
                writer.add(i); reader.add(o)
                aIn = i; aOut = o
            }
        }

        guard reader.startReading() else { throw NativeError(reader.error?.localizedDescription ?? "non riesco a leggere il video") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw NativeError(writer.error?.localizedDescription ?? "non riesco a scrivere il video")
        }
        writer.startSession(atSourceTime: range.start)

        let start = range.start.seconds, total = max(range.duration.seconds, 0.001)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        let group = DispatchGroup()
        let vQueue = DispatchQueue(label: "orbitlr.video"), aQueue = DispatchQueue(label: "orbitlr.audio")
        final class Box: @unchecked Sendable {
            var failed: String? = nil
            var videoDone = false, audioDone = false
        }
        /// Gli oggetti di AVFoundation usati dalle code di lavoro (ognuno da una sola coda alla volta).
        final class Parts: @unchecked Sendable {
            let vIn: AVAssetWriterInput, vOut: AVAssetReaderOutput
            let adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter
            let aIn: AVAssetWriterInput?, aOut: AVAssetReaderOutput?
            init(vIn: AVAssetWriterInput, vOut: AVAssetReaderOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                 writer: AVAssetWriter, aIn: AVAssetWriterInput?, aOut: AVAssetReaderOutput?) {
                self.vIn = vIn; self.vOut = vOut; self.adaptor = adaptor; self.writer = writer; self.aIn = aIn; self.aOut = aOut
            }
        }
        let box = Box()
        let pp = Parts(vIn: vIn, vOut: vOut, adaptor: adaptor, writer: writer, aIn: aIn, aOut: aOut)

        group.enter()
        pp.vIn.requestMediaDataWhenReady(on: vQueue) {
            // Chiude una volta sola (il blocco può essere richiamato)
            func end(_ problem: String? = nil) {
                guard !box.videoDone else { return }
                box.videoDone = true
                if let problem { box.failed = problem }
                pp.vIn.markAsFinished()
                group.leave()
            }
            guard !box.videoDone else { return }
            while pp.vIn.isReadyForMoreMediaData {
                if job.cancelRequested { end(); return }
                guard let sb = pp.vOut.copyNextSampleBuffer() else { end(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let img = frame(CIImage(cvPixelBuffer: pb), pts.seconds)
                guard let pool = pp.adaptor.pixelBufferPool else { end("memoria video non disponibile"); return }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuf)
                guard let ob = outBuf else { continue }
                Media.ci.render(img, to: ob, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: cs)
                if !pp.adaptor.append(ob, withPresentationTime: pts) {
                    end(pp.writer.error?.localizedDescription ?? "scrittura del video non riuscita"); return
                }
                progress(min(1, max(0, (pts.seconds - start) / total)))
            }
        }
        if let aIn = pp.aIn, pp.aOut != nil {
            group.enter()
            aIn.requestMediaDataWhenReady(on: aQueue) {
                func end() {
                    guard !box.audioDone else { return }
                    box.audioDone = true
                    pp.aIn?.markAsFinished()
                    group.leave()
                }
                guard !box.audioDone, let input = pp.aIn, let output = pp.aOut else { return }
                while input.isReadyForMoreMediaData {
                    if job.cancelRequested { end(); return }
                    guard let sb = output.copyNextSampleBuffer() else { end(); return }
                    if !input.append(sb) { end(); return }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        if job.cancelRequested || box.failed != nil || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            if job.cancelRequested { throw NativeError("annullato") }
            throw NativeError(box.failed ?? reader.error?.localizedDescription ?? "lettura del video non riuscita")
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError(writer.error?.localizedDescription ?? "scrittura del video non riuscita")
        }
        progress(1)
    }
}

// MARK: - Testo in voce

enum Speech {
    /// Le voci per una lingua, dalla più naturale (Premium) alla più semplice.
    static func voices(language prefix: String = "it") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Migliorata"
        default: return "Standard"
        }
    }

    static func voice(_ id: String?) -> AVSpeechSynthesisVoice? {
        if let id, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices().first ?? AVSpeechSynthesisVoice(language: "it-IT")
    }

    static func utterance(_ text: String, voice: String?, rate: Float?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(voice)
        if let rate { u.rate = rate }
        return u
    }

    /// Scrive il parlato in un file .m4a.
    /// Due passaggi: la voce si registra così com'è (PCM, il formato che produce lei, sempre accettato),
    /// poi si converte in AAC con il convertitore dell'app. Scrivere l'AAC direttamente falliva con alcune voci
    /// (errore «!dat»: le voci producono 22 kHz mono e l'encoder rifiutava quelle impostazioni).
    static func write(text: String, voice: String?, rate: Float?, out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-voce-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: raw) }
        let writer = SpeechFileWriter(out: raw, total: text.count, progress: { p in progress(p * 0.8) }, job: job)
        try await writer.run(utterance(text, voice: voice, rate: rate))
        if job.cancelRequested { throw NativeError("annullato") }
        try await Media.renderAudio([(raw, nil, nil)], out: out, bitrate: 96_000, channels: 1,
                                    fadeIn: 0, fadeOut: 0, normalize: false, maxSeconds: nil, job: job,
                                    progress: { p in progress(0.8 + p * 0.2) })
    }
}

/// Raccoglie l'audio prodotto dalla sintesi vocale e lo salva. Resta in vita finché la voce non ha finito.
final class SpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private var synth: AVSpeechSynthesizer?
    private let out: URL
    private let tmp: URL
    private let total: Int
    private let progress: (Double) -> Void
    private weak var job: Job?
    private var file: AVAudioFile?
    private var failure: String?
    private var cont: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var finished = false

    init(out: URL, total: Int, progress: @escaping (Double) -> Void, job: Job?) {
        self.out = out
        self.tmp = out.deletingLastPathComponent().appendingPathComponent(".orbitlr-\(UUID().uuidString).caf")
        self.total = max(1, total)
        self.progress = progress
        self.job = job
        super.init()
    }

    func run(_ u: AVSpeechUtterance) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); cont = c; lock.unlock()
            // La sintesi vocale va avviata dal filo principale (lì arrivano anche le sue notifiche)
            final class Holder: @unchecked Sendable { let u: AVSpeechUtterance; init(_ u: AVSpeechUtterance) { self.u = u } }
            let held = Holder(u)
            DispatchQueue.main.async {
                let s = AVSpeechSynthesizer()
                s.delegate = self
                self.synth = s
                s.write(held.u) { [weak self] buffer in self?.receive(buffer) }
            }
            // Rete di sicurezza: se la voce non parte entro 30 secondi
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let empty = self.file == nil && !self.finished; self.lock.unlock()
                if empty { self.finish(error: "la voce non è disponibile: prova un’altra voce") }
            }
        }
        _ = self        // tiene in vita il sintetizzatore fino alla fine
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if job?.cancelRequested == true {
            DispatchQueue.main.async { self.synth?.stopSpeaking(at: .immediate) }
            finish(error: "annullato"); return
        }
        if pcm.frameLength == 0 {
            // Un pezzo vuoto segna la fine, ma solo se è già arrivato dell'audio (alcune voci partono con un pezzo vuoto)
            lock.lock(); let started = file != nil; lock.unlock()
            if started { finish(error: nil) }
            return
        }
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do {
            if file == nil {
                // PCM nel formato esatto della voce: nessuna conversione qui, quindi nessun formato rifiutato
                file = try AVAudioFile(forWriting: tmp, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            failure = error.localizedDescription
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        progress(min(0.98, Double(characterRange.location + characterRange.length) / Double(total)))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Gli ultimi pezzi di audio possono arrivare subito dopo
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finish(error: nil) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(error: "annullato")
    }

    private func finish(error: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let hadAudio = file != nil
        file = nil                     // chiude il file
        let problem = error ?? failure ?? (hadAudio ? nil : "la voce non ha prodotto audio")
        let c = cont
        cont = nil
        lock.unlock()
        if let problem {
            try? FileManager.default.removeItem(at: tmp)
            c?.resume(throwing: NativeError(problem))
            return
        }
        do {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
            progress(1)
            c?.resume()
        } catch {
            c?.resume(throwing: NativeError("non riesco a salvare il file audio"))
        }
    }
}
