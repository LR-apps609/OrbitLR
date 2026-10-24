import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

// ════════════════════════════════════════════════════════════════════
//  3.6 · Video grandi e qualità prima di tutto.
//  • Taglio istantaneo e senza perdita (nessuna ricodifica) quando il formato lo permette:
//    anche su un film di 2 ore ci vogliono secondi.
//  • Compressione con il chip video del Mac: un solo passaggio, in streaming (un file da 5 GB
//    non va mai tutto in memoria), con colori e HDR rispettati.
//  • La qualità decide: prima si toglie ciò che non si vede (bit sprecati, fotogrammi oltre i 30
//    se mancano bit), e la risoluzione scende solo se ogni punto dell'immagine resterebbe senza dati.
// ════════════════════════════════════════════════════════════════════

enum SmartVideo {
    enum Codec: String { case h264, hevc }

    /// Cosa uscirà: misura, fotogrammi al secondo, dati per il video e per l'audio.
    struct Plan: Equatable {
        var width: Int
        var height: Int
        var fps: Double
        var videoBitrate: Int
        var audioBitrate: Int
        var codec: Codec
        var copyAudio: Bool

        /// Peso previsto (byte).
        func bytes(duration: Double) -> Int64 {
            Int64(Double(videoBitrate + audioBitrate) * duration / 8 * 1.01)
        }
    }

    struct Source: Equatable {
        var width: Double          // già raddrizzato (un video verticale ha width < height)
        var height: Double
        var fps: Double
        var duration: Double
        var videoBitrate: Double
        var audioBitrate: Double
        var codec: String          // «avc1», «hvc1», «ap4h»…
        var audioIsAAC: Bool
        var hdr: Bool
        var hdrTransfer: String? = nil      // HLG o PQ, da conservare uguale
    }

    enum Outcome: Equatable { case plan(Plan), alreadyLight, tooLong }

    /// Dati minimi per ogni punto dell'immagine e per fotogramma, sotto i quali si vedono i quadretti.
    static func minBitsPerPixel(_ c: Codec) -> Double { c == .hevc ? 0.045 : 0.065 }
    /// Dati con cui un video sembra identico all'originale a occhio (oltre: bit sprecati).
    static func transparentBitsPerPixel(_ c: Codec) -> Double { c == .hevc ? 0.075 : 0.11 }

    static let shortSides: [Double] = [2160, 1440, 1080, 720, 540, 480, 360, 240]

    // MARK: Il piano (puro: si prova nei test)

    /// Peso massimo (`targetBytes`), oppure nil = «stessa qualità, meno peso».
    static func plan(_ s: Source, targetBytes: Int64?, codec: Codec) -> Outcome {
        guard s.width > 0, s.height > 0, s.duration > 0 else { return .tooLong }
        let srcShort = min(s.width, s.height)
        var fps = s.fps.isFinite && s.fps > 0 ? min(s.fps, 60) : 30

        func size(_ short: Double) -> (Int, Int) {
            let k = min(1, short / srcShort)
            return (even(s.width * k), even(s.height * k))
        }

        if let target = targetBytes {
            let budget = Double(target) * 8 * 0.93 / s.duration           // bit al secondo, con margine per il contenitore
            // Senza audio, tutti i dati vanno all'immagine
            let abps: Int = s.audioBitrate <= 0 && !s.audioIsAAC ? 0 : budget >= 1_500_000 ? 128_000 : budget >= 500_000 ? 96_000 : 64_000
            var vbps = budget - Double(abps)
            guard vbps >= 120_000 else { return .tooLong }
            // Mai più dati dell'originale, mai più di quanto serve per sembrare identico
            let full = size(srcShort)
            let cap = Double(full.0 * full.1) * fps * transparentBitsPerPixel(codec)
            vbps = min(vbps, cap, s.videoBitrate > 0 ? s.videoBitrate : .infinity)
            // Prima si rinuncia ai fotogrammi in più (60 → 30), poi alla risoluzione
            // (la metà esatta: 60 → 30, 50 → 25, 59,94 → 29,97, così il movimento resta regolare)
            if fps > 31, vbps / (Double(full.0 * full.1) * fps) < minBitsPerPixel(codec) { fps = fps / 2 }
            // Prima la misura originale, poi i gradini più piccoli: si scende solo se i dati non bastano
            let candidates = [srcShort] + shortSides.filter { $0 < srcShort - 1 }
            var chosen = size(candidates.last!)
            for short in candidates {
                let (w, h) = size(short)
                if vbps / (Double(w * h) * fps) >= minBitsPerPixel(codec) { chosen = (w, h); break }
            }
            return .plan(Plan(width: chosen.0, height: chosen.1, fps: fps, videoBitrate: Int(vbps), audioBitrate: abps,
                              codec: codec, copyAudio: false))
        }

        // Stessa qualità: stessa misura, stessi fotogrammi, solo i bit che si vedono
        let full = size(srcShort)
        let transparent = Double(full.0 * full.1) * fps * transparentBitsPerPixel(codec)
        let src = s.videoBitrate > 0 ? s.videoBitrate : transparent * 2
        let efficiency: Double
        switch (s.codec.lowercased(), codec) {
        case ("avc1", .hevc), ("h264", .hevc): efficiency = 0.6          // HEVC: stessa resa con circa il 40% di dati in meno
        case ("hvc1", .h264), ("hev1", .h264), ("hevc", .h264): efficiency = 1.5
        case let (c, _) where c.hasPrefix("ap") || c.hasPrefix("raw") || c.hasPrefix("mjp"): efficiency = 0.1   // ProRes e simili
        default: efficiency = 1.0
        }
        let vbps = max(300_000, min(src * efficiency, transparent))
        guard vbps < src * 0.85 else { return .alreadyLight }
        return .plan(Plan(width: full.0, height: full.1, fps: fps, videoBitrate: Int(vbps),
                          audioBitrate: s.audioIsAAC ? Int(s.audioBitrate) : 192_000, codec: codec, copyAudio: s.audioIsAAC))
    }

    static func even(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }

    // MARK: Lettura della sorgente

    static func source(of asset: AVURLAsset) async throws -> (Source, AVAssetTrack) {
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw NativeError("il file non contiene video") }
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0.05 else { throw NativeError("non riesco a leggere la durata") }
        let (natural, transform, fps, rate, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        var codec = "", hdr = false, transfer: String? = nil
        if let f = formats.first {
            let t = CMFormatDescriptionGetMediaSubType(f)
            codec = String(bytes: [UInt8(t >> 24 & 255), UInt8(t >> 16 & 255), UInt8(t >> 8 & 255), UInt8(t & 255)], encoding: .ascii) ?? ""
            if let tf = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    hdr = true; transfer = AVVideoTransferFunction_ITU_R_2100_HLG
                } else if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    hdr = true; transfer = AVVideoTransferFunction_SMPTE_ST_2084_PQ
                }
            }
        }
        var abps = 0.0, aac = false
        if let a = try await asset.loadTracks(withMediaType: .audio).first {
            let (ar, af) = try await a.load(.estimatedDataRate, .formatDescriptions)
            abps = Double(ar)
            aac = af.first.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
        }
        let s = Source(width: abs(r.width), height: abs(r.height), fps: Double(fps), duration: d,
                       videoBitrate: Double(rate), audioBitrate: abps, codec: codec, audioIsAAC: aac, hdr: hdr, hdrTransfer: transfer)
        return (s, v)
    }

    // MARK: Spazio libero

    /// Prima di partire: c'è posto per il risultato? (Meglio dirlo subito che fallire dopo mezz'ora.)
    static func ensureSpace(in dir: URL, for bytes: Int64) throws {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Alcuni dischi esterni o di rete non dicono lo spazio «importante»: si usa quello normale
        var free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        if free <= 0 { free = Int64(v?.volumeAvailableCapacity ?? 0) }
        guard free > 0 else { return }
        let need = Int64(Double(bytes) * 1.15) + 200_000_000
        if free < need {
            throw NativeError("spazio libero insufficiente: servono circa \(Fmt.bytes(need)), ce ne sono \(Fmt.bytes(free)). Libera un po' di spazio e riprova")
        }
    }

    // MARK: Taglio senza perdita

    /// Taglio istantaneo: i dati originali si copiano così come sono. Falso se il formato non lo permette.
    static func trimLossless(_ file: URL, range: CMTimeRange, out: URL, job: Job?, progress: @escaping (Double) -> Void) async throws -> Bool {
        let asset = AVURLAsset(url: file)
        let type: AVFileType = out.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type),
              let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        s.outputURL = out
        s.outputFileType = type
        s.timeRange = range
        s.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: out)
        job?.exportSession = s
        let done = NativeEngine.DoneFlag()
        Task {
            while !done.value { progress(Double(s.progress)); try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        done.value = true
        job?.exportSession = nil
        switch s.status {
        case .completed: progress(1); return true
        case .cancelled: try? FileManager.default.removeItem(at: out); throw NativeError("annullato")
        default: try? FileManager.default.removeItem(at: out); return false
        }
    }

    // MARK: Codifica

    /// Un passaggio solo, con il chip video del Mac. Orientamento, colori (anche HDR) e dati del file restano.
    static func encode(asset: AVURLAsset, track: AVAssetTrack, source: Source, plan: Plan, out: URL, job: Job?,
                       progress: @escaping (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: out)
        let keepHDR = source.hdr && plan.codec == .hevc
        // Una composizione fatta a mano: solo questa traccia, raddrizzata (anche i video girati dell'iPhone)
        // e già alla misura finale. Così la misura è sempre esatta e il contenuto mai tagliato o stirato.
        let (natural, pt, timeRange) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        let box = CGRect(origin: .zero, size: natural).applying(pt)
        guard abs(box.width) > 0, abs(box.height) > 0 else { throw NativeError("dimensioni del video non valide") }
        let fit = pt.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                    .concatenating(CGAffineTransform(scaleX: CGFloat(plan.width) / abs(box.width), y: CGFloat(plan.height) / abs(box.height)))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(fit, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        let assetDuration = try await asset.load(.duration)
        instruction.timeRange = CMTimeRange(start: .zero, end: max(timeRange.end, assetDuration))
        instruction.layerInstructions = [layer]
        let comp = AVMutableVideoComposition()
        comp.instructions = [instruction]
        comp.renderSize = CGSize(width: plan.width, height: plan.height)
        comp.frameDuration = CMTime(seconds: 1 / max(1, plan.fps), preferredTimescale: 60_000)
        if keepHDR {
            comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            comp.colorTransferFunction = source.hdrTransfer ?? AVVideoTransferFunction_ITU_R_2100_HLG
            comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            // HDR dell'iPhone → colori standard che si vedono uguali ovunque
            comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        let reader = try AVAssetReader(asset: asset)
        let pixel = keepHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixel])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw NativeError("non riesco a leggere il video") }
        reader.add(vOut)

        let fileType: AVFileType = out.pathExtension.lowercased() == "mov" ? .mov : .mp4

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(plan.fps.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,                        // si salta avanti e indietro senza attese
            AVVideoAllowFrameReorderingKey: true,                              // più qualità a parità di peso
        ]
        let codecType: AVVideoCodecType
        switch plan.codec {
        case .h264:
            codecType = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            codecType = .hevc
            compression[AVVideoProfileLevelKey] = keepHDR ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
                                                          : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        settings[AVVideoColorPropertiesKey] = keepHDR ? [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: source.hdrTransfer ?? AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ] : [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]

        // Audio: copiato com'è quando si può (nessuna perdita), altrimenti AAC
        var aOut: AVAssetReaderOutput? = nil
        var audioSettings: [String: Any]? = nil
        var audioHint: CMFormatDescription? = nil
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let o: AVAssetReaderTrackOutput
            if plan.copyAudio {
                o = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
                audioHint = try await at.load(.formatDescriptions).first
            } else {
                o = AVAssetReaderTrackOutput(track: at, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                 AVEncoderBitRateKey: plan.audioBitrate]
            }
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        /// Lo scrittore con i suoi ingressi (si può rifare da capo, per esempio senza i dati del file).
        func makeWriter(metadata: [AVMetadataItem]) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?) {
            try? FileManager.default.removeItem(at: out)
            let w = try AVAssetWriter(outputURL: out, fileType: fileType)
            w.shouldOptimizeForNetworkUse = true
            w.metadata = metadata
            // Prima si chiede se il Mac sa scrivere così: impostazioni non accettate farebbero chiudere l'app
            guard w.canApply(outputSettings: settings, forMediaType: .video) else { throw NativeError("questo Mac non sa scrivere questo formato video") }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            v.expectsMediaDataInRealTime = false
            guard w.canAdd(v) else { throw NativeError("questo Mac non sa scrivere questo formato video") }
            w.add(v)
            var a: AVAssetWriterInput? = nil
            if aOut != nil, audioSettings == nil || w.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioHint)
                i.expectsMediaDataInRealTime = false
                if w.canAdd(i) { w.add(i); a = i }
            }
            return (w, v, a)
        }

        // Data, luogo e modello restano; se il formato non li accetta, si rinuncia solo a quelli
        let meta = (try? await asset.load(.metadata)) ?? []
        var (writer, vIn, aIn) = try makeWriter(metadata: meta)
        if !writer.startWriting() {
            guard !meta.isEmpty else { throw NativeError(writer.error?.localizedDescription ?? "non riesco a scrivere il video") }
            (writer, vIn, aIn) = try makeWriter(metadata: [])
            guard writer.startWriting() else { throw NativeError(writer.error?.localizedDescription ?? "non riesco a scrivere il video") }
        }
        guard reader.startReading() else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: out)
            throw NativeError(reader.error?.localizedDescription ?? "non riesco a leggere il video")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(source.duration, 0.001)
        /// Lo stato condiviso tra le code, sempre sotto chiave.
        final class State: @unchecked Sendable {
            private let lock = NSLock(); private var _failed = false; private var lastStep = -1
            var failed: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _failed }
                set { lock.lock(); _failed = newValue; lock.unlock() }
            }
            /// Vero solo quando l'avanzamento sale di almeno 1% (niente migliaia di aggiornamenti al secondo).
            func step(_ f: Double) -> Bool {
                let k = Int(f * 100)
                lock.lock(); defer { lock.unlock() }
                if k > lastStep { lastStep = k; return true }
                return false
            }
        }
        /// Un gruppo che si chiude una volta sola, chiunque arrivi prima (il lavoro o la sorveglianza).
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var done = false; let group = DispatchGroup()
            init() { group.enter() }
            func finish() { lock.lock(); defer { lock.unlock() }; if !done { done = true; group.leave() } }
            var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        }
        let state = State()
        let videoDone = Once(), audioDone = Once()
        let vq = DispatchQueue(label: "orbitlr.smart.video", qos: .userInitiated)
        let aq = DispatchQueue(label: "orbitlr.smart.audio", qos: .userInitiated)
        let video = vIn

        video.requestMediaDataWhenReady(on: vq) {
            while video.isReadyForMoreMediaData && !videoDone.isDone {
                if job?.cancelRequested == true || state.failed { reader.cancelReading(); video.markAsFinished(); videoDone.finish(); return }
                guard let sb = vOut.copyNextSampleBuffer() else { video.markAsFinished(); videoDone.finish(); return }
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if !video.append(sb) { state.failed = true; video.markAsFinished(); videoDone.finish(); return }
                if t.isFinite { let f = min(0.99, max(0, t / total)); if state.step(f) { progress(f) } }
            }
        }
        if let aOut, let audio = aIn {
            audio.requestMediaDataWhenReady(on: aq) {
                while audio.isReadyForMoreMediaData && !audioDone.isDone {
                    if job?.cancelRequested == true || state.failed { audio.markAsFinished(); audioDone.finish(); return }
                    guard let sb = aOut.copyNextSampleBuffer() else { audio.markAsFinished(); audioDone.finish(); return }
                    if !audio.append(sb) { state.failed = true; audio.markAsFinished(); audioDone.finish(); return }
                }
            }
        } else if let aOut {
            // Audio che non si può scrivere: si legge e si butta, altrimenti bloccherebbe la lettura del video
            aq.async { while aOut.copyNextSampleBuffer() != nil {}; audioDone.finish() }
        } else {
            audioDone.finish()
        }
        // Sorveglianza: se lo scrittore si ferma o annulli, non si resta mai appesi
        let w = writer
        Task.detached {
            while !(videoDone.isDone && audioDone.isDone) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if w.status == .failed || job?.cancelRequested == true {
                    if w.status == .failed { state.failed = true }
                    reader.cancelReading()
                    videoDone.finish(); audioDone.finish()
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in videoDone.group.notify(queue: .global()) { c.resume() } }
        // L'audio finisce subito dopo il video; se lo scrittore si è fermato, non si resta appesi per sempre
        let audioOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: audioDone.group.wait(timeout: .now() + 120) == .success) }
        }
        if !audioOK { state.failed = true; audioDone.finish() }
        // Si aspetta che nessun blocco stia ancora scrivendo, prima di chiudere o annullare
        vq.sync {}
        aq.sync {}

        if job?.cancelRequested == true {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: out)
            throw NativeError("annullato")
        }
        if state.failed || reader.status == .failed || writer.status == .failed {
            let why = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "codifica non riuscita"
            writer.cancelWriting(); try? FileManager.default.removeItem(at: out)
            throw NativeError(why)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError(writer.error?.localizedDescription ?? "non riesco a completare il video")
        }
        progress(1)
    }

    // MARK: I lavori completi

    /// Comprimi: a un peso massimo (`targetBytes`) o «stessa qualità, meno peso» (nil).
    static func compress(_ file: URL, targetBytes: Int64?, out: URL, job: Job?, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let (src, track) = try await source(of: asset)
        let size = Job.size(of: file)
        if let t = targetBytes, size <= t {
            throw NativeError("«\(file.lastPathComponent)» pesa già meno di \(mb(t)): non serve comprimerlo")
        }
        // Peso scelto: compatibile ovunque (H.264). Stessa qualità: HEVC, che a parità di qualità pesa molto meno
        let codec: Codec = targetBytes == nil ? .hevc : .h264
        do {
            try await compress(asset: asset, track: track, src: src, size: size, targetBytes: targetBytes, codec: codec,
                               file: file, out: out, job: job, progress: progress)
        } catch let e as NativeError where codec == .hevc && !e.message.contains("annullato") && !e.message.hasPrefix("«")
                                            && !e.message.hasPrefix("spazio") && !e.message.hasPrefix("il video è troppo") {
            // Mac che non scrive HEVC (o lo scrive male): stessa idea con H.264
            try await compress(asset: asset, track: track, src: src, size: size, targetBytes: targetBytes, codec: .h264,
                               file: file, out: out, job: job, progress: progress)
        }
    }

    /// «25 MB», «9 MB»: il peso come lo hai scelto.
    static func mb(_ bytes: Int64) -> String {
        let v = Double(bytes) / 1_048_576
        return (v == v.rounded() ? "\(Int(v))" : Fmt.decimal(v)) + " MB"
    }

    private static func compress(asset: AVURLAsset, track: AVAssetTrack, src: Source, size: Int64, targetBytes: Int64?, codec: Codec,
                                 file: URL, out: URL, job: Job?, progress: @escaping (Double) -> Void) async throws {
        switch plan(src, targetBytes: targetBytes, codec: codec) {
        case .tooLong:
            throw NativeError("il video è troppo lungo per stare in \(mb(targetBytes ?? 0)): scegli un peso maggiore o taglialo prima")
        case .alreadyLight:
            throw NativeError("«\(file.lastPathComponent)» è già compresso al meglio: ricomprimerlo lo peggiorerebbe senza farlo pesare meno")
        case .plan(var p):
            try ensureSpace(in: out.deletingLastPathComponent(), for: p.bytes(duration: src.duration))
            try await encode(asset: asset, track: track, source: src, plan: p, out: out, job: job, progress: { progress($0 * 0.97) })
            let got = Job.size(of: out)
            if let t = targetBytes { print("TEMPO: comprimi tentativo 1: \(got / 1000) KB su \(t / 1000) KB (\(p.width)×\(p.height), \(p.videoBitrate / 1000) kbps)") }
            if let t = targetBytes, got > t {
                // Il chip ha usato più dati del previsto (capita con immagini piene di dettagli minuti).
                // Fino a tre giri in più, rifacendo il piano: scende anche la misura invece di riempirsi di quadretti.
                // Quanto il codificatore sfora rispetto a quanto chiesto: si ricorda da un giro all'altro,
                // così ogni giro si avvicina invece di ripartire da capo
                var last = got
                var factor = 1.0
                var expected = p.bytes(duration: src.duration)
                for attempt in 1...3 {
                    factor *= Double(expected) / Double(max(1, last))
                    if case .plan(let next) = plan(src, targetBytes: Int64(Double(t) * factor * 0.95), codec: codec) {
                        p = next
                    } else {
                        p.videoBitrate = max(80_000, Int(Double(p.videoBitrate) * Double(t) / Double(last) * 0.9))
                    }
                    expected = p.bytes(duration: src.duration)
                    let base = 0.97 + Double(attempt - 1) * 0.01
                    try await encode(asset: asset, track: track, source: src, plan: p, out: out, job: job,
                                     progress: { _ in progress(base) })
                    last = Job.size(of: out)
                    print("TEMPO: comprimi tentativo \(attempt + 1): \(last / 1000) KB su \(t / 1000) KB (\(p.width)×\(p.height), \(p.videoBitrate / 1000) kbps)")
                    if last <= t { break }
                }
                if last > t {
                    try? FileManager.default.removeItem(at: out)
                    throw NativeError("non riesco a farlo stare in \(mb(t)): scegli un peso un po' maggiore")
                }
            } else if targetBytes == nil, got >= size {
                try? FileManager.default.removeItem(at: out)
                throw NativeError("«\(file.lastPathComponent)» è già compresso al meglio: ricomprimerlo lo peggiorerebbe senza farlo pesare meno")
            }
            progress(1)
        }
    }

    /// Cambia la grandezza: il lato corto diventa `short` (mai ingrandire), qualità piena per la nuova misura.
    static func resize(_ file: URL, shortSide short: Double, out: URL, job: Job?, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        let (src, track) = try await source(of: asset)
        let srcShort = min(src.width, src.height)
        guard short < srcShort - 1 else {
            throw NativeError("«\(file.lastPathComponent)» è già di \(Int(srcShort))p o meno: non serve rimpicciolirlo")
        }
        let k = min(1, short / srcShort)
        let w = even(src.width * k), h = even(src.height * k)
        let fps = min(src.fps > 0 ? src.fps : 30, 60)
        let bps = Int(min(Double(w * h) * fps * transparentBitsPerPixel(.h264), src.videoBitrate > 0 ? src.videoBitrate : .infinity))
        let p = Plan(width: w, height: h, fps: fps, videoBitrate: max(300_000, bps), audioBitrate: src.audioIsAAC ? Int(src.audioBitrate) : 160_000,
                     codec: .h264, copyAudio: src.audioIsAAC)
        try ensureSpace(in: out.deletingLastPathComponent(), for: p.bytes(duration: src.duration))
        try await encode(asset: asset, track: track, source: src, plan: p, out: out, job: job, progress: progress)
    }
}

