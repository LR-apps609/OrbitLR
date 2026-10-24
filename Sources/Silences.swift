import Foundation
import AVFoundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  4.0 · «Togli i silenzi» nel montaggio: le pause lunghe spariscono da sole,
//  la clip si divide nei pezzi in cui si parla (tagli netti, come nei video dei social).
//  Si ascolta solo il pezzo usato della clip; la soglia si adatta al rumore di fondo
//  di quel video (una stanza silenziosa e una strada non si giudicano allo stesso modo).
// ════════════════════════════════════════════════════════════════════

enum Silences {
    /// Una pausa più corta di così resta (il respiro tra due frasi non va tagliato).
    static let minSilence = 0.55
    /// Un po' d'aria prima e dopo ogni pezzo, per non mozzare le parole.
    static let pad = 0.12
    /// Pezzi parlati più corti di così non valgono un taglio (un colpo di tosse, un clic).
    static let minVoice = 0.25

    /// I tratti parlati del file tra `start` e `end` (secondi del file), già con un po' d'aria ai bordi.
    static func voiced(in url: URL, start: Double, end: Double) async throws -> [ClosedRange<Double>] {
        guard end > start + 0.05 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NativeError("questa clip non ha audio")
        }
        // La lettura è lunga e sincrona: fuori dal thread dell'interfaccia
        return try await Task.detached(priority: .utility) {
            try Self.read(asset: asset, track: track, start: start, end: end)
        }.value
    }

    private static func read(asset: AVURLAsset, track: AVAssetTrack, start: Double, end: Double) throws -> [ClosedRange<Double>] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let rate = 16_000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(out) else { throw NativeError("non riesco a leggere l'audio") }
        reader.add(out)
        guard reader.startReading() else { throw NativeError("non riesco a leggere l'audio") }

        // Livello ogni 20 ms, messo al suo posto grazie al tempo di ogni pacchetto
        // (audio che parte dopo il video o con dei buchi: i buchi contano come silenzio)
        let step = 0.02
        let window = rate * step
        let buckets = max(1, Int(((end - start) / step).rounded(.up)))
        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var samples = [Float]()
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            // Copia sicura anche quando il pacchetto è spezzato in più pezzi di memoria
            let ok = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!) == noErr
            }
            guard ok else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let first = pts.isNumeric ? (pts.seconds - start) * rate : 0
            for i in 0..<count {
                let b = Int(((first + Double(i)) / window).rounded(.down))
                guard b >= 0, b < buckets else { continue }
                let v = Double(samples[i]); sums[b] += v * v; counts[b] += 1
            }
        }
        if reader.status != .completed {
            throw NativeError(reader.error.map { "lettura dell'audio interrotta: \($0.localizedDescription)" } ?? "lettura dell'audio interrotta")
        }
        let levels = (0..<buckets).map { counts[$0] > 0 ? 10 * log10(max(sums[$0] / Double(counts[$0]), 1e-12)) : -120 }
        return ranges(levels: levels, step: step, offset: start, end: end)
    }

    /// Dai livelli ai tratti parlati (puro: si prova nei test).
    static func ranges(levels: [Double], step: Double, offset: Double, end: Double) -> [ClosedRange<Double>] {
        guard !levels.isEmpty else { return [] }
        // Rumore di fondo: il livello sotto cui sta il 15% del tempo; si parla se si è ben sopra
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let peak = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = max(-50, min(floor + 10, peak - 12))
        var raw: [(Double, Double)] = []
        var startIdx: Int? = nil
        // Si entra nella voce sopra la soglia e se ne esce solo 6 dB sotto:
        // le sillabe deboli e i finali di parola non vengono mozzati
        for (i, l) in levels.enumerated() {
            if startIdx == nil { if l > threshold { startIdx = i } }
            else if l <= threshold - 6, let s = startIdx { raw.append((Double(s) * step, Double(i) * step)); startIdx = nil }
        }
        if let s = startIdx { raw.append((Double(s) * step, Double(levels.count) * step)) }
        // Le pause brevi non dividono
        var merged: [(Double, Double)] = []
        for r in raw {
            if let last = merged.last, r.0 - last.1 < minSilence { merged[merged.count - 1].1 = r.1 }
            else { merged.append(r) }
        }
        return merged
            .filter { $0.1 - $0.0 >= minVoice }
            .compactMap { r -> ClosedRange<Double>? in
                let lo = max(offset, offset + r.0 - pad), hi = min(end, offset + r.1 + pad)
                return lo < hi ? lo...hi : nil
            }
    }

    /// Dove finisce un istante del montaggio dopo aver diviso la clip (che iniziava a `clipStart`) nei pezzi `parts`.
    /// Un istante dentro una pausa tolta va all'inizio del pezzo dopo; dopo la clip tutto si sposta indietro.
    static func remap(_ t: Double, clipStart: Double, clip c: VPClip, parts: [ClosedRange<Double>]) -> Double {
        let speed = max(0.01, c.speed)
        let oldEnd = clipStart + c.length
        let newLength = parts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / speed
        guard t > clipStart else { return t }
        guard t < oldEnd else { return t - (c.length - newLength) }
        let f = c.inPoint + (t - clipStart) * speed     // secondi del file
        var before = 0.0
        for r in parts {
            if f < r.lowerBound { return clipStart + before }
            if f <= r.upperBound { return clipStart + before + (f - r.lowerBound) / speed }
            before += (r.upperBound - r.lowerBound) / speed
        }
        return clipStart + before
    }

    /// I testi del montaggio spostati insieme ai tagli; spariscono quelli che stavano solo in una pausa tolta.
    static func remap(_ texts: [VPText], clipStart: Double, clip: VPClip, parts: [ClosedRange<Double>]) -> [VPText] {
        texts.compactMap { t in
            var n = t
            n.start = remap(t.start, clipStart: clipStart, clip: clip, parts: parts)
            n.end = remap(t.end, clipStart: clipStart, clip: clip, parts: parts)
            guard n.end - n.start > 0.15 || t.end - t.start <= 0.15 else { return nil }
            if let w = t.wordTimes {
                n.wordTimes = w.map { max(0, remap(t.start + $0, clipStart: clipStart, clip: clip, parts: parts) - n.start) }
            }
            return n
        }
    }
}

extension VideoProjectStore {
    /// 4.0 · Toglie le pause lunghe dalla clip scelta (o da quella sotto l'indicatore). Si annulla con ⌘Z.
    @MainActor
    func removeSilences(_ undo: UndoManager?) {
        guard let i = targetIndex, project.clips.indices.contains(i) else { NSSound.beep(); return }
        let c = project.clips[i]
        notice = "Ascolto la clip e cerco le pause…"
        Task { @MainActor in
            let parts: [ClosedRange<Double>]
            do { parts = try await Silences.voiced(in: c.url, start: c.inPoint, end: c.outPoint) }
            catch { notice = (error as? NativeError)?.message.capitalizedFirst ?? "Non riesco ad ascoltare questa clip."; return }
            // La clip potrebbe essere cambiata mentre ascoltavo
            guard let now = project.clips.firstIndex(where: { $0.id == c.id }), project.clips[now] == c else { notice = nil; return }
            let kept = parts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            guard !parts.isEmpty else { notice = "In questa clip non ho sentito voci: non tolgo niente."; return }
            guard parts.count > 1 || kept < c.sourceLength - 0.5 else { notice = "Nessuna pausa lunga da togliere in questa clip."; return }
            let pieces: [VPClip] = parts.enumerated().map { k, r in
                var p = c
                if k > 0 { p.id = UUID(); p.transition = nil; p.fx?.fadeIn = 0 }
                if k < parts.count - 1 { p.fx?.fadeOut = 0 }
                p.inPoint = r.lowerBound
                p.outPoint = r.upperBound
                return p
            }
            let clipStart = project.starts[now]
            change(undo, "Togli i silenzi") {
                $0.clips.replaceSubrange(now...now, with: pieces)
                // Testi e sottotitoli seguono i tagli
                if let tx = $0.texts { $0.texts = Silences.remap(tx, clipStart: clipStart, clip: c, parts: parts) }
            }
            let saved = (c.sourceLength - kept) / max(0.01, c.speed)      // secondi del montaggio
            notice = "Tolti \(Fmt.decimal(saved)) secondi di pause in \(parts.count) pezzi. ⌘Z per tornare indietro."
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
