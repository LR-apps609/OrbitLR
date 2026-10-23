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
    /// 2.7.1 · Segnalibro di macOS: ritrova il file anche se lo sposti o lo rinomini.
    var bookmark: Data? = nil
    /// 2.7.4 · Audio di questa clip spento (per un solo tratto: si divide la clip e si spegne quel pezzo).
    var muted: Bool? = nil
    var isMuted: Bool { muted ?? false }
    /// 2.9 · Filtro e regolazioni solo di questa clip (nil = quelli di tutto il progetto).
    var look: VPLook? = nil
    /// 2.9.2 · Transizione tra la clip precedente e questa (nil = taglio netto).
    var transition: VPTransition? = nil
    /// 2.9.8 · Effetti di questa clip (velocità, zoom lento, capovolgi e ruota, sfocatura, dissolvenze).
    var fx: VPEffects? = nil
    var url: URL { URL(fileURLWithPath: path) }
    /// Velocità della clip (0,25×–4×).
    var speed: Double { min(4, max(0.25, fx?.speed ?? 1)) }
    /// Il pezzo di file usato, in secondi del file.
    var sourceLength: Double { max(0, outPoint - inPoint) }
    /// Quanto dura nel montaggio (con la velocità).
    var length: Double { sourceLength / speed }
}

/// 2.9.8 · Effetti di una clip.
struct VPEffects: Codable, Equatable, Sendable {
    var speed = 1.0
    /// «none», «in» (si avvicina piano), «out» (si allontana piano)
    var zoom = "none"
    var flipH = false
    var flipV = false
    /// 0, 90, 180, 270 (in senso orario)
    var rotate = 0
    /// 0…1
    var blur = 0.0
    /// Secondi
    var fadeIn = 0.0
    var fadeOut = 0.0

    var isIdentity: Bool {
        abs(speed - 1) < 0.001 && zoom == "none" && !flipH && !flipV && rotate % 360 == 0 && blur < 0.001 && fadeIn < 0.01 && fadeOut < 0.01
    }

    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    /// Capovolgi e ruota nello spazio dell'immagine diritta (origine in alto a sinistra), larga w e alta h.
    func orientation(width w: CGFloat, height h: CGFloat) -> (CGAffineTransform, CGSize) {
        var t = CGAffineTransform.identity
        if flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        if flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) }
        switch ((rotate % 360) + 360) % 360 {
        case 90: return (t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)), CGSize(width: h, height: w))
        case 180: return (t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)), CGSize(width: w, height: h))
        case 270: return (t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)), CGSize(width: h, height: w))
        default: return (t, CGSize(width: w, height: h))
        }
    }
}

/// 2.9.3 · Passaggio tra due clip.
struct VPTransition: Codable, Equatable, Sendable {
    /// «fade» dissolvenza, «black» al nero, «white» al bianco, «slide» scorrimento, «zoom», «blur» sfocatura
    var kind = "fade"
    var duration = 0.6

    static let kinds: [(id: String, name: String, symbol: String)] = [
        ("fade", "Dissolvenza", "circle.lefthalf.filled"), ("black", "Al nero", "moon.fill"), ("white", "Al bianco", "sun.max.fill"),
        ("slide", "Scorrimento", "arrow.left.square"), ("zoom", "Zoom", "plus.magnifyingglass"), ("blur", "Sfocatura", "drop.fill"),
    ]
    static func name(_ id: String) -> String { kinds.first { $0.id == id }?.name ?? "Dissolvenza" }
}

struct VPMusic: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data? = nil
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
    /// 2.7.3 · Nome del progetto nella schermata Progetti.
    var name: String? = nil
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
    /// 2.9 · Filtro e regolazioni di tutto il progetto (una clip può avere i suoi).
    var look: VPLook? = nil
    /// 2.9.8 · Zone da sfocare su tutto il montaggio (un logo, una scritta), come «Nascondi filigrana».
    var hide: String? = nil
    /// 2.9.9 · Testi animati sopra il video.
    var texts: [VPText]? = nil

    /// Il look che si vede su una clip: il suo, altrimenti quello del progetto.
    func effectiveLook(_ c: VPClip) -> VPLook? { c.look ?? look }

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
                return (i, min(c.outPoint, max(c.inPoint, c.inPoint + (t - start) * c.speed)))
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
        for (c, start) in zip(p.clips, p.starts) where !c.isMuted {      // clip senza audio: nessuna voce da rispettare
            for r in speech[c.path] ?? [] {
                let a = max(r.lowerBound, c.inPoint), b = min(r.upperBound, c.outPoint)
                if b > a { out.append((start + (a - c.inPoint) / c.speed)...(start + (b - c.inPoint) / c.speed)) }
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

    /// La fluidità scelta, ma mai più dei video di partenza (60 fps da un video a 30 sarebbero fotogrammi ripetuti).
    static func effectiveFPS(_ p: VideoProject, infos: [String: VPMediaInfo]) -> Int {
        let source = p.clips.compactMap { infos[$0.path]?.fps }.max() ?? 30
        return max(24, min(60, min(p.fps, Int(source.rounded()))))
    }

    /// 2.9 · `.frames`: ogni fotogramma si disegna con Core Image (posizione, rotazione e filtri).
    /// `.layers`: il vecchio modo (solo posizione), tenuto per confrontare i due nei test.
    enum Engine { case frames, layers }

    /// Opzioni → Video → «Motore video classico»: la rete di sicurezza se il motore nuovo desse problemi.
    static let classicKey = "videoEngineClassic"
    static var preferredEngine: Engine { UserDefaults.standard.bool(forKey: classicKey) ? .layers : .frames }

    /// Dove sta una clip nel montaggio e come si disegna.
    struct Placement: Sendable {
        let start: Double
        let end: Double
        let transform: CGAffineTransform
        let look: VPLook?
        /// 2.9.8 · effetti e zona della clip sulla tela (origine in basso)
        var fx: VPEffects? = nil
        var area: CGRect = .null
        var trackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    }

    /// 2.9.3 · Durata vera di una transizione: mai più del 40% di ciascuna delle due clip, mai più di 2 secondi.
    static func transitionDuration(_ tr: VPTransition?, before a: Double, after b: Double) -> Double {
        guard let tr else { return 0 }
        return max(0, min(tr.duration, 2, 0.4 * a, 0.4 * b))
    }

    static func build(_ p: VideoProject, infos: [String: VPMediaInfo], speech: [String: [ClosedRange<Double>]],
                      maxSide: CGFloat, engine: Engine = VideoProjectBuilder.preferredEngine) async throws -> VPBuilt {
        let comp = AVMutableComposition()
        guard let vT = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeError("non riesco a preparare il montaggio")
        }
        // Tela: la misura della prima clip (girata), lato lungo al massimo maxSide
        guard let firstInfo = p.clips.lazy.compactMap({ infos[$0.path] }).first(where: { $0.hasVideo }) else {
            throw NativeError("nessuna clip pronta")
        }
        var base = firstInfo.displaySize
        // 2.9.8 · Prima clip ruotata di 90°: la tela segue
        if let f = p.clips.first(where: { infos[$0.path]?.hasVideo == true })?.fx, (((f.rotate % 360) + 360) % 360) % 180 == 90 {
            base = CGSize(width: base.height, height: base.width)
        }
        guard base.width > 0, base.height > 0 else { throw NativeError("dimensioni del video non valide") }
        let k = min(1, maxSide / max(base.width, base.height))
        let canvas = CGSize(width: CGFloat(Media.even(Double(base.width * k))), height: CGFloat(Media.even(Double(base.height * k))))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vT)
        // 2.9.3 · Motore a fotogrammi: due tracce video (Item tiene vivo il file: senza, la traccia non si può più inserire) che si alternano, così due clip possono sovrapporsi in una transizione
        let vT2: AVMutableCompositionTrack? = engine == .frames
            ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        struct Item { let clip: VPClip; let asset: AVURLAsset; let v: AVAssetTrack; let s: Double; let e: Double; let info: VPMediaInfo; let start: CMTime
            /// 2.9.8 · velocità
            var sp: Double { clip.speed }
        }
        /// 2.9.8 · Un pezzo del file nel montaggio, accelerato o rallentato per durare `len` secondi.
        func put(_ tr: AVMutableCompositionTrack, _ v: AVAssetTrack, from src: Double, duration dur: Double, at: CMTime, lasting len: Double) throws {
            try tr.insertTimeRange(CMTimeRange(start: cm(src), duration: cm(dur)), of: v, at: at)
            if abs(dur - len) > 0.0005 { tr.scaleTimeRange(CMTimeRange(start: at, duration: cm(dur)), toDuration: cm(len)) }
        }
        var items: [Item] = []
        var cursor = CMTime.zero
        var placements: [Placement] = []
        for c in p.clips {
            guard let info = infos[c.path], info.hasVideo else { continue }
            let a = AVURLAsset(url: c.url)
            guard let v = try await a.loadTracks(withMediaType: .video).first else { continue }
            let s = min(max(0, c.inPoint), max(0, info.videoDuration - 0.05))
            let e = min(max(s + 0.05, c.outPoint), info.videoDuration)
            guard e - s >= 0.05 else { continue }
            let len = (e - s) / c.speed
            let lenT = cm(len)
            if engine == .layers { try put(vT, v, from: s, duration: e - s, at: cursor, lasting: len) }
            items.append(Item(clip: c, asset: a, v: v, s: s, e: e, info: info, start: cursor))
            if info.hasAudio, !c.isMuted, let au = try await a.loadTracks(withMediaType: .audio).first {
                try? put(aT, au, from: s, duration: e - s, at: cursor, lasting: len)
            }
            // 2.9.8 · Capovolgi e ruota: prima di adattare alla tela
            let (orient, ds) = (c.fx ?? VPEffects()).orientation(width: info.displaySize.width, height: info.displaySize.height)
            let fit = min(canvas.width / max(ds.width, 1), canvas.height / max(ds.height, 1))
            let tx = (canvas.width - ds.width * fit) / 2, ty = (canvas.height - ds.height * fit) / 2
            let t = normalized(info.transform, natural: info.naturalSize)
                .concatenating(orient)
                .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(t, at: cursor)
            // Dove sta la clip sulla tela, con l'origine in basso (come Core Image)
            let area = CGRect(x: tx, y: canvas.height - ty - ds.height * fit, width: ds.width * fit, height: ds.height * fit)
            placements.append(Placement(start: cursor.seconds, end: (cursor + lenT).seconds, transform: t, look: p.effectiveLook(c),
                                        fx: c.fx, area: area))
            cursor = cursor + lenT
        }
        guard cursor.seconds > 0.05 else { throw NativeError("il montaggio è vuoto") }
        let total = cursor.seconds

        // 2.9.3 · Le clip sulle due tracce, con il pezzo in più che serve alle transizioni
        var instructions: [VPCompositionInstruction] = []
        if engine == .frames, let vT2 {
            let tracks = [vT, vT2]
            let lens = items.map { ($0.e - $0.s) / $0.sp }
            var half = [Double](repeating: 0, count: items.count)       // metà della transizione prima della clip i
            for i in items.indices.dropFirst() {
                let d = transitionDuration(items[i].clip.transition, before: lens[i - 1], after: lens[i])
                half[i] = d >= 0.05 ? d / 2 : 0
            }
            for (i, it) in items.enumerated() {
                let tr = tracks[i % 2]
                let start = it.start.seconds
                let frame = 1 / max(1, it.info.fps)
                // prima: il pezzo che precede l'inizio (se c'è), altrimenti il primo fotogramma fermo
                if half[i] > 0 {
                    let at = cm(start - half[i])
                    if it.s - half[i] * it.sp >= 0 {
                        try put(tr, it.v, from: it.s - half[i] * it.sp, duration: half[i] * it.sp, at: at, lasting: half[i])
                    } else {
                        try tr.insertTimeRange(CMTimeRange(start: cm(it.s), duration: cm(frame)), of: it.v, at: at)
                        tr.scaleTimeRange(CMTimeRange(start: at, duration: cm(frame)), toDuration: cm(half[i]))
                    }
                }
                try put(tr, it.v, from: it.s, duration: it.e - it.s, at: it.start, lasting: lens[i])
                // dopo: il pezzo che segue la fine (se c'è), altrimenti l'ultimo fotogramma fermo
                let next = i + 1 < items.count ? half[i + 1] : 0
                if next > 0 {
                    let at = cm(start + lens[i])
                    if it.e + next * it.sp <= it.info.videoDuration - 0.02 {
                        try put(tr, it.v, from: it.e, duration: next * it.sp, at: at, lasting: next)
                    } else {
                        try tr.insertTimeRange(CMTimeRange(start: cm(max(it.s, it.e - frame)), duration: cm(frame)), of: it.v, at: at)
                        tr.scaleTimeRange(CMTimeRange(start: at, duration: cm(frame)), toDuration: cm(next))
                    }
                }
                placements[i].trackID = tr.trackID
            }
            // Le istruzioni: un tratto per ogni clip da sola e uno per ogni transizione, uno dopo l'altro senza buchi
            var t0 = 0.0
            for i in items.indices {
                let start = items[i].start.seconds
                if half[i] > 0 {
                    let b = start + half[i]
                    instructions.append(VPCompositionInstruction(range: (t0, b), from: placements[i - 1], to: placements[i],
                                                                 transition: items[i].clip.transition, canvas: canvas,
                                                                 hide: HideMark.parse(p.hide ?? ""), texts: p.texts ?? []))
                    t0 = b
                }
                let soloEnd = i + 1 < items.count ? items[i + 1].start.seconds - half[i + 1] : total
                if soloEnd - t0 > 0.0001 {
                    instructions.append(VPCompositionInstruction(range: (t0, soloEnd), from: placements[i], to: nil,
                                                                 transition: nil, canvas: canvas,
                                                                 hide: HideMark.parse(p.hide ?? ""), texts: p.texts ?? []))
                }
                t0 = max(t0, soloEnd)
            }
        }

        let vc: AVMutableVideoComposition
        switch engine {
        case .layers:
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: cursor)
            instr.layerInstructions = [layer]
            vc = AVMutableVideoComposition()
            vc.instructions = [instr]
        case .frames:
            vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = VPCompositor.self
            vc.instructions = instructions
        }
        vc.renderSize = canvas
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(effectiveFPS(p, infos: infos)))
        // Il ritmo dei fotogrammi lo decide frameDuration (la fluidità scelta), non il video di partenza
        vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        // Uscita in SDR standard: i video HDR dell'iPhone vengono convertiti con i colori giusti
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        var params: [AVMutableAudioMixInputParameters] = []
        if aT.segments.isEmpty {
            comp.removeTrack(aT)
        } else {
            let op = AVMutableAudioMixInputParameters(track: aT)
            let vol = Float(p.originalMuted ? 0 : min(1, max(0, p.originalVolume)))
            op.setVolume(vol, at: .zero)
            // 2.9.8 · Dissolvenze delle clip anche nell'audio
            for (i, pl) in placements.enumerated() {
                guard let fx = pl.fx else { continue }
                let len = pl.end - pl.start
                if fx.fadeIn > 0.01 {
                    op.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: cm(pl.start), duration: cm(min(fx.fadeIn, len))))
                }
                if fx.fadeOut > 0.01 {
                    let d = min(fx.fadeOut, len)
                    op.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: cm(pl.end - d), duration: cm(d)))
                    let nextFades = i + 1 < placements.count && (placements[i + 1].fx?.fadeIn ?? 0) > 0.01
                    if !nextFades { op.setVolume(vol, at: cm(pl.end)) }
                }
            }
            op.audioTimePitchAlgorithm = .spectral        // 2.9.8 · velocità diverse: la voce non cambia tono
            params.append(op)
        }

        // Musica
        if let m = p.music, let mi = infos[m.path], mi.hasAudio, mi.duration > 0.2 {
            let song = AVURLAsset(url: m.url)
            if let st = try await song.loadTracks(withMediaType: .audio).first,
               let mT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                // La traccia audio può finire qualche millesimo prima del file: si usa la sua fine vera
                let trackEnd = (try? await st.load(.timeRange))?.end.seconds ?? mi.duration
                let songLen = min(mi.duration, trackEnd.isFinite && trackEnd > 0 ? trackEnd : mi.duration)
                let start = min(max(0, m.offset), total)
                let inP = min(max(0, m.inPoint), max(0, songLen - 0.2))
                var t = start
                while t < total - 0.05 {
                    let len = min(songLen - inP, total - t)
                    guard len > 0.05 else { break }
                    do {
                        try mT.insertTimeRange(CMTimeRange(start: cm(inP), duration: cm(len)), of: st, at: cm(t))
                    } catch { break }          // la musica non deve mai impedire l'anteprima del video
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

    /// 2.9 · Un fotogramma del montaggio: la clip girata e messa in tela come prima, poi il suo filtro.
    /// Le trasformazioni sono pensate con l'origine in alto a sinistra; Core Image ce l'ha in basso: si capovolge prima e dopo.
    static func renderFrame(_ source: CIImage, at t: Double, placements: [Placement], canvas: CGSize) -> CIImage {
        let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: canvas))
        guard let pl = placements.last(where: { t >= $0.start - 0.0005 }) ?? placements.first else { return bg }
        return place(source, pl, canvas: canvas, at: t).composited(over: bg).cropped(to: bg.extent)
    }

    /// La clip girata, messa in tela e con il suo filtro (senza sfondo).
    static func place(_ source: CIImage, _ pl: Placement, canvas: CGSize, at t: Double) -> CIImage {
        let src = source.extent
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -src.minX, ty: src.maxY)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        let placed = source.transformed(by: flipIn.concatenating(pl.transform).concatenating(flipOut))
        guard let fx = pl.fx, !fx.isIdentity else {
            // Il filtro tocca solo la clip, non le bande nere intorno
            return VideoLooks.apply(pl.look, to: placed)
        }
        return effects(fx, on: placed, pl, canvas: canvas, at: t)
    }

    /// 2.9.8 · Sfocatura, filtro, zoom lento e dissolvenza di una clip già messa in tela.
    static func effects(_ fx: VPEffects, on placed: CIImage, _ pl: Placement, canvas: CGSize, at t: Double) -> CIImage {
        let area = placed.extent
        var img = placed
        if fx.blur > 0.001 {
            let r = fx.blur * 0.03 * Double(max(canvas.width, canvas.height))
            img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": r]).cropped(to: area)
        }
        img = VideoLooks.apply(pl.look, to: img)
        let len = max(0.001, pl.end - pl.start)
        let x = min(1, max(0, (t - pl.start) / len))
        if fx.zoom == "in" || fx.zoom == "out" {
            let s = fx.zoom == "in" ? 1 + 0.18 * x : 1.18 - 0.18 * x
            let c = CGPoint(x: area.midX, y: area.midY)
            img = img.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))).cropped(to: area)
        }
        var f = 1.0
        if fx.fadeIn > 0.01 { f = min(f, (t - pl.start) / fx.fadeIn) }
        if fx.fadeOut > 0.01 { f = min(f, (pl.end - t) / fx.fadeOut) }
        f = min(1, max(0, f))
        if f < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            ])
        }
        return img
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
        return try analyze(asset: asset, track: track)
    }

    /// Lettura e analisi (sincrone: girano già in sottofondo).
    private static func analyze(asset: AVURLAsset, track: AVAssetTrack) throws -> [ClosedRange<Double>] {
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
        let speech = snap.speech.mapValues { list in list.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil } }
        try await run(project: snap.project, speech: speech, out: out, job: job, progress: progress)
        try? FileManager.default.removeItem(at: snapshot)
    }

    static func run(project p: VideoProject, speech: [String: [ClosedRange<Double>]], out: URL, job: Job,
                    progress: @escaping (Double) -> Void) async throws {
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
                                                   audioMix: built.audioMix, range: full,
                                                   fps: Double(VideoProjectBuilder.effectiveFPS(p, infos: infos)),
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
    }
}

extension VPClip {
    /// 2.7.7 · Come VoiceOver legge la clip: «Clip 2 di 3, 0:05, senza audio».
    func spokenLabel(index: Int, of count: Int) -> String {
        "Clip \(index + 1) di \(count), \(formatShort(length))" + (isMuted ? ", senza audio" : "")
    }
}
