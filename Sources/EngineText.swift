import Foundation

// ════════════════════════════════════════════════════════════════════
//  4.2 · I messaggi del motore classico (LRConverter.zsh) sono scritti in italiano, con dentro nomi di file
//  e numeri: in inglese si riconoscono con un modello e si riscrivono. Il motore resta com'è.
// ════════════════════════════════════════════════════════════════════

enum EngineText {
    /// (modello italiano, testo inglese con $1, $2… al posto delle parti variabili)
    static let patterns: [(String, String)] = [
        (#"^«(.+)» era già compresso al massimo$"#, "“$1” was already compressed as much as possible"),
        (#"^«(.+)» pesa già meno di (\S+) MB$"#, "“$1” is already under $2 MB"),
        (#"^non riesco a leggere la durata del video$"#, "Couldn’t read the video’s duration"),
        (#"^il video è troppo lungo per stare in (\S+) MB: scegli un peso maggiore o taglialo prima$"#,
         "The video is too long to fit in $1 MB: choose a larger size or trim it first"),
        (#"^non riesco a farlo stare sotto (\S+) MB \(verrebbe (.+)\): scegli un peso maggiore o taglialo prima$"#,
         "Couldn’t get it under $1 MB (it would be $2): choose a larger size or trim it first"),
        (#"^per questo formato serve ImageMagick$"#, "This format needs ImageMagick"),
        (#"^il file non contiene audio$"#, "The file has no audio"),
        (#"^Whisper non è installato$"#, "Whisper isn’t installed"),
        (#"^manca il modello di trascrizione$"#, "The transcription model is missing"),
        (#"^il video non contiene sottotitoli$"#, "The video has no subtitles"),
        (#"^i sottotitoli di questo video sono immagini \(es\. Blu-ray\), non convertibili in testo$"#,
         "This video’s subtitles are images (e.g. Blu-ray) and can’t be turned into text"),
        (#"^non ho trovato un file \.srt con lo stesso nome del video \(selezionali insieme\)$"#,
         "Couldn’t find an .srt file with the same name as the video (select them together)"),
        (#"^download del modello non riuscito \(controlla la connessione\)$"#, "Model download failed (check your connection)"),
        (#"^«(.+)» è su iCloud e non sono riuscito a scaricarlo sul Mac: aprilo una volta dal Finder e riprova$"#,
         "“$1” is in iCloud and couldn’t be downloaded to this Mac: open it once in the Finder and try again"),
        (#"^Preparazione iniziale \(solo la prima volta, circa un minuto\)…$"#, "First-time setup (only once, about a minute)…"),
        (#"^Preparazione iniziale: solo la prima volta, circa un minuto…$"#, "First-time setup: only once, about a minute…"),
        (#"^Scarico il modello di trascrizione \(solo la prima volta\)…$"#, "Downloading the transcription model (first time only)…"),
        (#"^Scarico da iCloud «(.+)»…$"#, "Downloading “$1” from iCloud…"),
        (#"^Converto (\d+) documenti con LibreOffice…$"#, "Converting $1 documents with LibreOffice…"),
        (#"^(\d+/\d+) · Unisco (\d+) file in un PDF$"#, "$1 · Merging $2 files into a PDF"),
        (#"^Seleziona il video insieme al file \.srt$"#, "Select the video together with the .srt file"),
        (#"^Nessun file supportato selezionato$"#, "No supported files selected"),
        // Messaggi del motore video di macOS (SmartVideo), che il codice riconosce in italiano
        (#"^spazio libero insufficiente: servono circa (.+), ce ne sono (.+)\. Libera un po' di spazio e riprova$"#,
         "Not enough free space: about $1 needed, $2 available. Free up some space and try again"),
        (#"^il video è troppo lungo per stare in (.+): scegli un peso maggiore o taglialo prima$"#,
         "The video is too long to fit in $1: choose a larger size or trim it first"),
        (#"^«(.+)» è già compresso al meglio: ricomprimerlo lo peggiorerebbe senza farlo pesare meno$"#,
         "“$1” is already compressed as well as it can be: compressing it again would make it worse without making it lighter"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = patterns.compactMap { p in
        (try? NSRegularExpression(pattern: p.0)).map { ($0, p.1) }
    }

    /// Il testo nella lingua dell'app (in italiano resta com'è).
    static func localized(_ s: String) -> String {
        AppLanguage.active == "en" ? english(s) : s
    }

    static func english(_ s: String) -> String {
        let full = rewrite(s)
        if full != s { return full }
        // «nome.ext: messaggio» → si tiene il nome, si riscrive il messaggio
        if let r = s.range(of: ": ") {
            let name = String(s[..<r.lowerBound])
            if name.contains("."), name.count < 160 {
                let rest = String(s[r.upperBound...])
                let t = rewrite(rest)
                if t != rest { return name + ": " + t }
            }
        }
        return s
    }

    private static func rewrite(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = NSRange(t.startIndex..., in: t)
        for (re, tpl) in compiled {
            if let m = re.firstMatch(in: t, range: r) {
                return re.replacementString(for: m, in: t, offset: 0, template: tpl)
            }
        }
        return s
    }
}
