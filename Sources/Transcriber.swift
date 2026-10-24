import Foundation
import Speech
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  3.8 · «Trascrivi» con il riconoscimento vocale di macOS, sul Mac (senza internet).
//  Prima serviva Whisper, da installare. Funziona con audio e video di qualsiasi durata:
//  l'audio scorre a pezzi verso il riconoscimento, mai tutto in memoria.
//  Escono il testo (a paragrafi, divisi dalle pause) e i sottotitoli .srt.
// ════════════════════════════════════════════════════════════════════

enum Transcriber {
    /// Formati che macOS legge da solo.
    static let inputs: Set<String> = ["mp3", "m4a", "wav", "aiff", "aac", "caf", "m4b", "mp4", "mov", "m4v"]

    static func supports(_ exts: [String]) -> Bool { !exts.isEmpty && exts.allSatisfy { inputs.contains($0) } }

    /// Trascrive `file` in `dir`: restituisce il testo; il file .srt va in `extra`.
    static func run(_ file: URL, dir: URL, job: Job?, progress: @escaping (Double) -> Void,
                    extra: @escaping (URL) -> Void) async throws -> URL {
        guard await AutoSubtitles.authorize() else {
            throw NativeError("serve il permesso «Riconoscimento vocale»: Impostazioni di Sistema → Privacy e sicurezza")
        }
        let words = try await recognize(file, locale: AutoSubtitles.preferredLocale(), job: job, progress: progress)
        guard !words.isEmpty else { throw NativeError("non ho sentito parole in «\(file.lastPathComponent)»") }
        let base = file.deletingPathExtension().lastPathComponent
        let txt = Destination.unique(dir, base: "\(base) (trascrizione)", ext: "txt")
        try paragraphs(words).write(to: txt, atomically: true, encoding: .utf8)
        let srtURL = Destination.unique(dir, base: "\(base) (trascrizione)", ext: "srt")
        try srt(AutoSubtitles.lines(words)).write(to: srtURL, atomically: true, encoding: .utf8)
        extra(srtURL)
        progress(1)
        return txt
    }

    // MARK: Riconoscimento

    static func recognize(_ file: URL, locale: Locale, job: Job?, progress: @escaping (Double) -> Void) async throws -> [AutoSubtitles.Word] {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw NativeError("il riconoscimento vocale non è disponibile per questa lingua")
        }
        // Solo sul Mac: l'audio non va mai su internet
        guard rec.supportsOnDeviceRecognition else {
            throw NativeError("il Mac non ha ancora la lingua per riconoscere la voce senza internet. Impostazioni di Sistema → Tastiera → Dettatura: attivala con la lingua giusta, attendi lo scaricamento e riprova")
        }
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw NativeError("il file non contiene audio") }
        let duration = max(0.1, try await asset.load(.duration).seconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true

        final class Box: @unchecked Sendable { var words: [AutoSubtitles.Word] = []; var done = false; var error: Error? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let task = rec.recognitionTask(with: req) { result, error in
            if let result {
                // Ogni risultato finale copre un tratto: le parole si aggiungono in ordine
                if result.isFinal {
                    box.words = result.bestTranscription.segments.map {
                        AutoSubtitles.Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                }
            }
            if let error { box.error = error }
            if result?.isFinal == true || error != nil, !box.done { box.done = true; finished.signal() }
        }

        // L'audio scorre a pezzi: 16 kHz, mono (quello che serve al riconoscimento)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw NativeError("non riesco a leggere l'audio") }
        reader.add(out)
        guard reader.startReading() else { throw NativeError(reader.error?.localizedDescription ?? "non riesco a leggere l'audio") }
        var lastStep = -1
        while let sb = out.copyNextSampleBuffer() {
            if job?.cancelRequested == true { reader.cancelReading(); task.cancel(); throw NativeError("annullato") }
            if let buf = pcm(sb, format: format) { req.append(buf) }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if t.isFinite {
                let step = Int(min(0.9, t / duration * 0.9) * 100)
                if step > lastStep { lastStep = step; progress(Double(step) / 100) }
            }
        }
        req.endAudio()
        // Il riconoscimento finisce poco dopo l'ultimo pezzo (al massimo qualche minuto per file lunghissimi)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: finished.wait(timeout: .now() + 600) == .success) }
        }
        if !ok { task.cancel(); throw NativeError("il riconoscimento non ha risposto in tempo") }
        if box.words.isEmpty, let e = box.error { throw NativeError(e.localizedDescription) }
        return box.words
    }

    private static func pcm(_ sb: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return nil }
        return buf
    }

    // MARK: Scrittura

    /// Il testo a paragrafi: una pausa lunga (oltre 1,5 secondi) apre un paragrafo nuovo.
    static func paragraphs(_ words: [AutoSubtitles.Word]) -> String {
        var out = "", prevEnd: Double? = nil
        for w in words {
            if let p = prevEnd {
                out += w.start - p > 1.5 ? "\n\n" : " "
            }
            out += w.text
            prevEnd = w.end
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Sottotitoli .srt (00:01:02,500 --> 00:01:05,000).
    static func srt(_ lines: [AutoSubtitles.Line]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return lines.enumerated().map { i, l in "\(i + 1)\n\(ts(l.start)) --> \(ts(l.end))\n\(l.text)\n" }.joined(separator: "\n")
    }
}
