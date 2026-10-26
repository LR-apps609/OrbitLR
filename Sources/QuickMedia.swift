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
    static let ids: Set<String> = ["cut", "gifcut", "vcompress", "normalize", "vresize"]
    static let videoIn: Set<String> = ["mp4", "mov", "m4v"]
    static let audioIn: Set<String> = ["m4a", "mp3", "wav", "aiff", "aac", "caf"]

    /// Vero se macOS sa fare da solo questo lavoro su questi file.
    static func handles(_ job: Job) -> Bool {
        let id = job.action.id
        guard ids.contains(id) else { return false }
        let exts = job.mainFiles.map { Catalog.norm($0.pathExtension) }
        guard !exts.isEmpty else { return false }
        switch id {
        case "vcompress", "gifcut", "vresize": return exts.allSatisfy { videoIn.contains($0) }
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
                let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("taglio")))", ext: ext)
                try await cutVideo(file, start: start, end: end, out: out, job: job, progress: progress)
                return out
            }
            let (fmt, ext) = audioFormat(for: e)
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("taglio")))", ext: ext)
            try await Media.renderAudio([(file, start, end)], out: out, bitrate: 256_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                        normalize: false, maxSeconds: nil, format: fmt, job: job, progress: progress)
            return out
        case "normalize":
            let (fmt, ext) = audioFormat(for: e)
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("normalizzato")))", ext: ext)
            try await Media.renderAudio([(file, nil, nil)], out: out, bitrate: 256_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                        normalize: true, maxSeconds: nil, format: fmt, job: job, progress: progress)
            return out
        case "gifcut":
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("pezzo")))", ext: "gif")
            try await gif(file, start: start, end: end, out: out, job: job, progress: progress)
            return out
        case "vcompress":
            // 3.6 · «best» = stessa qualità, meno peso; un numero = peso massimo in MB
            let p = job.param.trimmingCharacters(in: .whitespaces)
            if let mb = Double(p.replacingOccurrences(of: ",", with: ".")), mb > 0 {
                let label = mb == mb.rounded() ? "\(Int(mb)) MB" : Fmt.decimal(mb) + " MB"
                let out = Destination.unique(dir, base: "\(base) (\(label))", ext: "mp4")
                try await SmartVideo.compress(file, targetBytes: Int64(mb * 1_048_576), out: out, job: job, progress: progress)
                return out
            }
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("più leggero")))", ext: "mp4")
            try await SmartVideo.compress(file, targetBytes: nil, out: out, job: job, progress: progress)
            return out
        case "vresize":
            // 3.6 · Nativo: chip video del Mac, qualità piena per la nuova misura; «hevc» = stessa misura, meno peso
            if job.param == "hevc" {
                let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("più leggero")))", ext: "mp4")
                try await SmartVideo.compress(file, targetBytes: nil, out: out, job: job, progress: progress)
                return out
            }
            let short = Double(job.param) ?? 1080
            let out = Destination.unique(dir, base: "\(base) (\(Int(short))p)", ext: "mp4")
            try await SmartVideo.resize(file, shortSide: short, out: out, job: job, progress: progress)
            return out
        default:
            throw NativeError(String(localized: "azione sconosciuta"))
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
        guard d.isFinite, d > 0 else { throw NativeError(String(localized: "non riesco a leggere la durata")) }
        // 3.6 · Prima il taglio istantaneo e senza perdita (anche su un film di 2 ore: secondi);
        // solo se il formato non lo permette, si ricodifica
        if try await SmartVideo.trimLossless(file, range: range(start, end, duration: d), out: out, job: job, progress: progress) { return }
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NativeError(String(localized: "questo video non si può tagliare"))
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
            throw NativeError(s.error?.localizedDescription ?? String(localized: "taglio non riuscito"))
        }
    }

    // MARK: GIF

    private static func gif(_ file: URL, start: Double?, end: Double?, out: URL, job: Job,
                            progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw NativeError(String(localized: "non riesco a leggere la durata")) }
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
            throw NativeError(String(localized: "non riesco a creare la GIF"))
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
            throw NativeError(String(localized: "non riesco a creare la GIF"))
        }
        progress(1)
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
