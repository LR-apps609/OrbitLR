import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  2.6.3 · Taglia, Comprimi, GIF e Volume uniforme con i motori di macOS.
//  Prima servivano programmi da installare (ffmpeg): ora, per i formati che macOS legge,
//  funzionano subito. Gli altri formati passano ancora al motore classico.
// ════════════════════════════════════════════════════════════════════

enum QuickMedia {
    static let ids: Set<String> = ["cut", "gifcut", "vcompress", "normalize"]
    static let videoIn: Set<String> = ["mp4", "mov", "m4v"]
    static let audioIn: Set<String> = ["m4a", "mp3", "wav", "aiff", "aac", "caf"]

    /// Vero se macOS sa fare da solo questo lavoro su questi file.
    static func handles(_ job: Job) -> Bool {
        let id = job.action.id
        guard ids.contains(id) else { return false }
        let exts = job.mainFiles.map { Catalog.norm($0.pathExtension) }
        guard !exts.isEmpty else { return false }
        switch id {
        case "vcompress", "gifcut": return exts.allSatisfy { videoIn.contains($0) }
        case "cut": return exts.allSatisfy { videoIn.contains($0) || audioIn.contains($0) }
        case "normalize": return exts.allSatisfy { audioIn.contains($0) }     // i video restano al motore classico
        default: return false
        }
    }

    static func run(job: Job, file: URL, dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let e = Catalog.norm(file.pathExtension)
        let parts = job.param.components(separatedBy: "|")
        let start = parts.first.flatMap { Double($0) }
        let end = parts.count > 1 ? Double(parts[1]) : nil
        switch job.action.id {
        case "cut":
            if videoIn.contains(e) {
                let ext = e == "mov" ? "mov" : "mp4"
                let out = Destination.unique(dir, base: "\(base) (taglio)", ext: ext)
                try await cutVideo(file, start: start, end: end, out: out, job: job, progress: progress)
                return out
            }
            let (fmt, ext) = audioFormat(for: e)
            let out = Destination.unique(dir, base: "\(base) (taglio)", ext: ext)
            try await Media.renderAudio([(file, start, end)], out: out, bitrate: 256_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                        normalize: false, maxSeconds: nil, format: fmt, job: job, progress: progress)
            return out
        case "normalize":
            let (fmt, ext) = audioFormat(for: e)
            let out = Destination.unique(dir, base: "\(base) (normalizzato)", ext: ext)
            try await Media.renderAudio([(file, nil, nil)], out: out, bitrate: 256_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                        normalize: true, maxSeconds: nil, format: fmt, job: job, progress: progress)
            return out
        case "gifcut":
            let out = Destination.unique(dir, base: "\(base) (pezzo)", ext: "gif")
            try await gif(file, start: start, end: end, out: out, job: job, progress: progress)
            return out
        case "vcompress":
            let mb = max(1, Int(job.param.trimmingCharacters(in: .whitespaces)) ?? 25)
            let out = Destination.unique(dir, base: "\(base) (\(mb) MB)", ext: "mp4")
            try await compress(file, megabytes: mb, out: out, job: job, progress: progress)
            return out
        default:
            throw NativeError("azione sconosciuta")
        }
    }

    /// WAV e AIFF restano tali (senza perdita); MP3 e gli altri diventano M4A (macOS non scrive MP3).
    private static func audioFormat(for e: String) -> (Media.AudioOut, String) {
        switch e {
        case "wav": return (.wav, "wav")
        case "aiff": return (.aiff, "aiff")
        default: return (.aac, "m4a")
        }
    }

    private static func range(_ start: Double?, _ end: Double?, duration: Double) -> CMTimeRange {
        let s = max(0, min(start ?? 0, max(0, duration - 0.1)))
        var e = end ?? duration
        if !(e > s) || e > duration { e = duration }
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), end: CMTime(seconds: e, preferredTimescale: 600))
    }

    // MARK: Taglia (video)

    private static func cutVideo(_ file: URL, start: Double?, end: Double?, out: URL, job: Job,
                                 progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw NativeError("non riesco a leggere la durata") }
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NativeError("questo video non si può tagliare")
        }
        s.outputURL = out
        s.outputFileType = out.pathExtension == "mov" ? .mov : .mp4
        s.timeRange = range(start, end, duration: d)
        s.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: out)
        job.exportSession = s
        let done = NativeEngine.DoneFlag()
        Task {
            while !done.value {
                progress(Double(s.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        done.value = true
        job.exportSession = nil
        switch s.status {
        case .completed: progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: out)
            throw NativeError("annullato")
        default:
            try? FileManager.default.removeItem(at: out)
            throw NativeError(s.error?.localizedDescription ?? "taglio non riuscito")
        }
    }

    // MARK: GIF

    private static func gif(_ file: URL, start: Double?, end: Double?, out: URL, job: Job,
                            progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw NativeError("non riesco a leggere la durata") }
        let r = range(start, end ?? ((start ?? 0) + 5), duration: d)
        let fps = 12.0
        let count = max(2, min(360, Int(r.duration.seconds * fps)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        try? FileManager.default.removeItem(at: out)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw NativeError("non riesco a creare la GIF")
        }
        let loop: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        let delay: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / fps,
                                                                              kCGImagePropertyGIFUnclampedDelayTime as String: 1.0 / fps]]
        let frameProps = delay as CFDictionary
        var added = 0
        for i in 0..<count {
            if job.cancelRequested { try? FileManager.default.removeItem(at: out); throw NativeError("annullato") }
            let t = CMTime(seconds: r.start.seconds + Double(i) / fps, preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image {
                CGImageDestinationAddImage(dest, img, frameProps)
                added += 1
            }
            progress(Double(i + 1) / Double(count) * 0.95)
        }
        guard added > 0, CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError("non riesco a creare la GIF")
        }
        progress(1)
    }

    // MARK: Comprimi a un peso massimo

    private static func compress(_ file: URL, megabytes mb: Int, out: URL, job: Job,
                                 progress: @escaping (Double) -> Void) async throws {
        let size = Job.size(of: file)
        let limit = Int64(mb) * 1_048_576
        if size <= limit {
            throw NativeError("«\(file.lastPathComponent)» pesa già meno di \(mb) MB: non serve comprimerlo")
        }
        let asset = AVURLAsset(url: file)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else { throw NativeError("il file non contiene video") }
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0.1 else { throw NativeError("non riesco a leggere la durata") }
        let abps = mb <= 10 ? 64_000 : 128_000
        var vbps = Int(Double(mb) * 8_388_608 * 0.92 / d) - abps
        guard vbps >= 100_000 else {
            throw NativeError("il video è troppo lungo per stare in \(mb) MB: scegli un peso maggiore o taglialo prima")
        }
        let orient = await Media.orientation(of: asset, track: vtrack, at: CMTime(seconds: min(1, d / 2), preferredTimescale: 600))
        let natural = try await vtrack.load(.naturalSize)
        let sideways: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        let W = Double(sideways.contains(orient) ? natural.height : natural.width)
        let H = Double(sideways.contains(orient) ? natural.width : natural.height)
        guard W > 0, H > 0 else { throw NativeError("dimensioni del video non valide") }
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 600))

        // Fino a tre tentativi: se il file supera il peso, il successivo corregge i dati in proporzione
        // (e, se serve molto meno, scende anche di risoluzione). Così il peso scelto è garantito.
        var shrink = 1.0
        for attempt in 0..<3 {
            let longSide: Double = (vbps < 700_000 ? 854 : vbps < 1_800_000 ? 1280 : vbps < 4_500_000 ? 1920 : 3840) * shrink
            let k = min(1, longSide / max(W, H))
            let outW = Media.even(W * k), outH = Media.even(H * k)
            let sx = Double(outW) / W, sy = Double(outH) / H
            let base = Double(attempt) / 3
            try await VideoPipeline.process(asset: asset, videoTrack: vtrack, range: full, size: CGSize(width: outW, height: outH),
                                            out: out, job: job, videoBitrate: vbps, audioBitrate: abps,
                                            progress: { p in progress(base + p / 3) }) { raw, _ in
                var img = raw.oriented(orient)
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                return img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            let got = Job.size(of: out)
            if got <= limit { progress(1); return }
            let over = Double(got) / Double(limit)
            vbps = max(80_000, Int(Double(vbps) / over * 0.9))
            if over > 1.3 { shrink *= 0.75 }
        }
        try? FileManager.default.removeItem(at: out)
        throw NativeError("non riesco a farlo stare in \(mb) MB: scegli un peso un po' maggiore")
    }
}

// MARK: - Formati che macOS non apre da solo: si preparano in automatico (niente «convertilo prima»)

enum AutoConvert {
    /// Cartella nascosta per i file preparati: l'utente non si ritrova copie che non ha chiesto.
    static var folder: URL { Paths.support.appendingPathComponent("Preparati") }

    /// Converte con il motore classico e, quando ha finito, passa i file pronti a `done` (sul filo principale).
    @discardableResult
    static func prepare(_ urls: [URL], to ext: String, kind: Kind, done: @escaping ([URL]) -> Void) -> Job? {
        guard !urls.isEmpty, let action = Catalog.action(id: "to:" + ext, kind: kind) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = QueueStore.shared.enqueue(files: urls, action: action, param: "", dest: folder)
        Task { @MainActor in
            while job.state == .waiting || job.state == .running {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if job.state == .done, !job.outputs.isEmpty { done(job.outputs) }
        }
        return job
    }
}
