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
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NativeError("questa clip non ha audio")
        }
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

        // Livello (dB) ogni 20 ms
        let window = Int(rate * 0.02)
        var levels: [Double] = []
        var acc = 0.0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let p = ptr else { continue }
            let count = length / MemoryLayout<Float>.size
            p.withMemoryRebound(to: Float.self, capacity: count) { f in
                for i in 0..<count {
                    let v = Double(f[i]); acc += v * v; n += 1
                    if n == window {
                        levels.append(10 * log10(max(acc / Double(n), 1e-12)))
                        acc = 0; n = 0
                    }
                }
            }
        }
        if n > 0 { levels.append(10 * log10(max(acc / Double(n), 1e-12))) }
        return ranges(levels: levels, step: 0.02, offset: start, end: end)
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
        for (i, l) in levels.enumerated() {
            if l > threshold { if startIdx == nil { startIdx = i } }
            else if let s = startIdx { raw.append((Double(s) * step, Double(i) * step)); startIdx = nil }
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
            .map { max(offset, offset + $0.0 - pad)...min(end, offset + $0.1 + pad) }
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
            change(undo, "Togli i silenzi") { $0.clips.replaceSubrange(now...now, with: pieces) }
            let saved = c.sourceLength - kept
            notice = "Tolti \(Fmt.decimal(saved)) secondi di pause in \(parts.count) pezzi. ⌘Z per tornare indietro."
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
