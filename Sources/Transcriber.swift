import Foundation
import Speech
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  3.8 · «Trascrivi» con il riconoscimento vocale di macOS, sul Mac (senza internet).
//  Prima serviva Whisper, da installare. Funziona con audio e video di qualsiasi durata:
//  macOS legge il file da sé, senza tenerlo in memoria.
//  Escono il testo (a paragrafi, divisi dalle pause) e i sottotitoli .srt.
// ════════════════════════════════════════════════════════════════════

enum Transcriber {
    /// Formati che macOS legge da solo.
    static let inputs: Set<String> = ["mp3", "m4a", "wav", "aiff", "aac", "caf", "m4b", "mp4", "mov", "m4v"]

    static func supports(_ exts: [String]) -> Bool { !exts.isEmpty && exts.allSatisfy { inputs.contains($0) } }

    /// Trascrive `file` in `dir`: il testo va in `extra` (per primo), il file .srt viene restituito.
    static func run(_ file: URL, dir: URL, job: Job?, progress: @escaping (Double) -> Void,
                    extra: @escaping (URL) -> Void) async throws -> URL {
        guard await AutoSubtitles.authorize() else {
            throw NativeError(String(localized: "serve il permesso «Riconoscimento vocale»: Impostazioni di Sistema → Privacy e sicurezza"))
        }
        let words = try await recognize(file, locale: AutoSubtitles.preferredLocale(), job: job, progress: progress)
        guard !words.isEmpty else { throw NativeError(String(localized: "non ho sentito parole in «\(file.lastPathComponent)»")) }
        let base = file.deletingPathExtension().lastPathComponent
        let txt = Destination.unique(dir, base: "\(base) (\(FileTag.t("trascrizione")))", ext: "txt")
        try paragraphs(words).write(to: txt, atomically: true, encoding: .utf8)
        let srtURL = Destination.unique(dir, base: "\(base) (\(FileTag.t("trascrizione")))", ext: "srt")
        try srt(AutoSubtitles.lines(words)).write(to: srtURL, atomically: true, encoding: .utf8)
        // Il testo arriva per primo tra i file creati (è quello che si apre), poi i sottotitoli
        extra(txt)
        progress(1)
        return srtURL
    }

    // MARK: Riconoscimento

    static func recognize(_ file: URL, locale: Locale, job: Job?, progress: @escaping (Double) -> Void) async throws -> [AutoSubtitles.Word] {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw NativeError(String(localized: "il riconoscimento vocale non è disponibile per questa lingua"))
        }
        // Solo sul Mac: l'audio non va mai su internet
        guard rec.supportsOnDeviceRecognition else {
            throw NativeError(String(localized: "il Mac non ha ancora la lingua per riconoscere la voce senza internet. Impostazioni di Sistema → Tastiera → Dettatura: attivala con la lingua giusta, attendi lo scaricamento e riprova"))
        }
        let asset = AVURLAsset.precise(file)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw NativeError(String(localized: "il file non contiene audio")) }
        let duration = max(1, try await asset.load(.duration).seconds)

        // macOS legge il file da sé (niente audio tenuto in memoria, anche per ore di registrazione)
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true

        /// Raccoglie TUTTI i tratti riconosciuti (un audio lungo ne dà più d'uno) e sa quando è finita.
        final class Collector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var words: [AutoSubtitles.Word] = []
            private var finished = false
            private var failure: Error?
            func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
                let ws = result.bestTranscription.segments.map {
                    AutoSubtitles.Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                }
                lock.lock(); words += ws; lock.unlock()
            }
            func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully ok: Bool) {
                lock.lock(); finished = true; if !ok { failure = task.error }; lock.unlock()
            }
            var state: (done: Bool, words: [AutoSubtitles.Word], error: Error?) {
                lock.lock(); defer { lock.unlock() }
                return (finished, words.sorted { $0.start < $1.start }, failure)
            }
        }
        let collector = Collector()
        let task = rec.recognitionTask(with: req, delegate: collector)
        // Attesa che segue il lavoro: si può annullare, e il tempo massimo cresce con la durata del file
        let start = Date()
        let limit = max(600, duration * 2)
        while !collector.state.done {
            if job?.cancelRequested == true { task.cancel(); throw NativeError("annullato") }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > limit { task.cancel(); throw NativeError(String(localized: "il riconoscimento non ha risposto in tempo")) }
            progress(min(0.9, elapsed / max(5, duration / 8)))         // stima: circa 8 volte più veloce del tempo reale
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let st = collector.state
        if st.words.isEmpty, let e = st.error { throw NativeError(e.localizedDescription) }
        return st.words
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
