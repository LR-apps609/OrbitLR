import Foundation
import Speech
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  3.3 · Sottotitoli automatici nel montaggio.
//  macOS ascolta le clip (sul Mac, senza internet quando la lingua lo
//  permette), le parole diventano righe brevi e le righe diventano testi
//  «Sottotitolo» in basso, al momento giusto, anche con clip tagliate o
//  accelerate. Si modificano poi come tutti gli altri testi.
// ════════════════════════════════════════════════════════════════════

enum AutoSubtitles {
    struct Word: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    struct Line: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
        /// 4.0 · Quando inizia ogni parola della riga (secondi, sulla stessa scala di start/end)
        var wordStarts: [Double] = []
        /// 4.0 · Le parole della riga (servono per tenere solo quelle dentro una clip tagliata)
        var words: [String] = []
    }

    /// Una riga si chiude dopo 7 parole, 42 caratteri, 3,5 secondi, una pausa lunga o un punto.
    static let maxWords = 7, maxChars = 42, maxSeconds = 3.5, pause = 0.6

    /// Raggruppa le parole in righe da leggere comode.
    static func lines(_ words: [Word]) -> [Line] {
        var out: [Line] = []
        var cur: [Word] = []
        func flush() {
            guard let a = cur.first, let b = cur.last else { return }
            let text = cur.map(\.text).joined(separator: " ")
            // Ogni riga resta almeno 1 secondo, per dare il tempo di leggerla
            out.append(Line(text: text, start: a.start, end: max(b.end, a.start + 1), wordStarts: cur.map(\.start), words: cur.map(\.text)))
            cur = []
        }
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = cur.last, let first = cur.first {
                let chars = cur.map(\.text).joined(separator: " ").count + 1 + w.text.count
                if w.start - last.end > pause || cur.count >= maxWords || chars > maxChars || w.end - first.start > maxSeconds {
                    flush()
                }
            }
            cur.append(w)
            if let c = w.text.last, ".!?".contains(c) { flush() }
        }
        flush()
        // Righe che si accavallano (per il secondo minimo): la precedente finisce dove inizia la nuova
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i] = Line(text: out[i].text, start: out[i].start, end: max(out[i].start + 0.3, out[i + 1].start),
                          wordStarts: out[i].wordStarts, words: out[i].words)
        }
        return out
    }

    /// Dai secondi del file ai secondi del montaggio: solo il pezzo usato, con la velocità della clip.
    static func timeline(_ lines: [Line], clip: VPClip, clipStart: Double) -> [Line] {
        lines.compactMap { l in
            var text = l.text, starts = l.wordStarts, words = l.words
            var a = max(l.start, clip.inPoint)
            // Una riga a cavallo di due pezzi (dopo un taglio): in ogni pezzo solo le sue parole
            if !words.isEmpty, words.count == starts.count {
                let keep = starts.indices.filter { starts[$0] >= clip.inPoint - 0.05 && starts[$0] < clip.outPoint - 0.05 }
                guard !keep.isEmpty else { return nil }
                words = keep.map { words[$0] }; starts = keep.map { starts[$0] }
                text = words.joined(separator: " ")
                a = max(clip.inPoint, starts[0])
            }
            let b = min(l.end, clip.outPoint)
            guard b - a > 0.15 else { return nil }
            return Line(text: text, start: clipStart + (a - clip.inPoint) / clip.speed,
                        end: clipStart + (b - clip.inPoint) / clip.speed,
                        wordStarts: starts.map { clipStart + (max($0, clip.inPoint) - clip.inPoint) / clip.speed },
                        words: words)
        }
    }

    /// I testi «Sottotitolo» pronti per il progetto.
    static func texts(_ lines: [Line]) -> [VPText] {
        lines.map { l in
            var t = VPText()
            t.text = l.text
            t.style = "subtitle"
            t.start = l.start
            t.end = l.end
            t.y = 0.86
            // 4.0 · Come nei video dei social: la parola detta si accende
            t.anim = "word"
            let n = VPText.wordCount(l.text)
            if l.wordStarts.count == n { t.wordTimes = l.wordStarts.map { max(0, $0 - l.start) } }
            t.color = "white"
            return t
        }
    }

    enum Failure: Error { case notAllowed, unavailable, nothingHeard, notOnDevice }

    /// La lingua scelta in Opzioni → Avanzate (trascrizione); «automatica» = quella del Mac, se è tra quelle note.
    static func preferredLocale(setting: String = ScriptPrefs.load()["wlang"] ?? "auto", system: Locale = .current) -> Locale {
        let map = ["it": "it-IT", "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE"]
        if let id = map[setting] { return Locale(identifier: id) }
        if let code = system.language.languageCode?.identifier, let id = map[code] { return Locale(identifier: id) }
        return Locale(identifier: "it-IT")
    }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Le parole dette in un file, con i loro tempi (secondi del file).
    static func words(in url: URL, locale: Locale = Locale(identifier: "it-IT")) async throws -> [Word] {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw Failure.unavailable }
        // 3.5.2 · Solo sul Mac: se questa lingua non si può riconoscere senza internet, non si manda l'audio a nessuno
        guard rec.supportsOnDeviceRecognition else { throw Failure.notOnDevice }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    let ws = result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    c.resume(returning: ws)
                } else if let error {
                    done = true
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Ascolta tutte le clip con l'audio acceso e mette i sottotitoli nel progetto (un solo ⌘Z li toglie).
    @MainActor
    static func run(_ s: VideoProjectStore, undo: UndoManager?) async -> String {
        guard await authorize() else {
            return String(localized: "Per i sottotitoli serve il permesso «Riconoscimento vocale»: Impostazioni di Sistema → Privacy e sicurezza.")
        }
        let clips = s.project.clips, starts = s.project.starts
        var all: [Line] = []
        var cache: [String: [Word]] = [:]
        var offline = false
        for (c, start) in zip(clips, starts) where !c.isMuted {
            let ws: [Word]
            if let hit = cache[c.path] { ws = hit } else {
                do { ws = try await words(in: c.url, locale: preferredLocale()) }
                catch Failure.notOnDevice { offline = true; ws = [] }
                catch { ws = [] }
                cache[c.path] = ws
            }
            all += timeline(lines(ws), clip: c, clipStart: start)
        }
        if all.isEmpty && offline {
            // 3.5.2 · L'audio non lascia mai il Mac: se la lingua non è pronta, si spiega come averla
            return String(localized: "Il Mac non ha ancora la lingua per riconoscere la voce senza internet. Impostazioni di Sistema → Tastiera → Dettatura: attivala con la lingua giusta, attendi lo scaricamento e riprova.")
        }
        guard !all.isEmpty else { return String(localized: "Non ho sentito parole nelle clip (o l’audio è spento).") }
        let new = texts(all)
        s.change(undo, String(localized: "Sottotitoli automatici")) { p in
            // Al posto dei sottotitoli automatici di prima, se c'erano
            p.texts = (p.texts ?? []).filter { $0.style != "subtitle" || $0.y < 0.8 } + new
        }
        return new.count == 1 ? String(localized: "1 sottotitolo aggiunto: controllalo nella riga «Testi».") : String(localized: "\(new.count) sottotitoli aggiunti: controllali nella riga «Testi».")
    }
}
