import Foundation

// ════════════════════════════════════════════════════════════════════
//  2.6.4 · Messaggi d'errore umani: cosa è successo e cosa fare, mai codici di macOS.
//  Si applica da solo a ogni errore di un lavoro (Job.failures).
// ════════════════════════════════════════════════════════════════════

enum FriendlyError {
    /// Trasforma un messaggio tecnico in una frase con la soluzione. Un messaggio già chiaro resta com'è.
    static func text(_ raw: String) -> String {
        // «nome.ext: messaggio» → si tiene il nome del file, si traduce solo il messaggio
        if let r = raw.range(of: ": ") {
            let name = String(raw[..<r.lowerBound])
            if name.contains("."), name.count < 160 {
                let rest = String(raw[r.upperBound...])
                let t = translate(rest)
                if t != rest { return name + ": " + t }
            }
        }
        return translate(raw)
    }

    private static func translate(_ raw: String) -> String {
        let s = raw.lowercased()
        func has(_ any: String...) -> Bool { any.contains { s.contains($0) } }

        if has("no space left", "spazio su disco esaurito", "out of space", "nsfilewriteoutofspaceerror", "error 640", "errore 640") {
            return "Spazio su disco esaurito: libera un po’ di spazio e riprova."
        }
        if has("operation not permitted", "non hai il permesso", "permission", "error 513", "errore 513", "not permitted") {
            return "OrbitLR non può scrivere in quella cartella: spostala altrove o scegli un’altra cartella nelle Opzioni."
        }
        if has("no such file", "doesn’t exist", "doesn't exist", "non esiste", "error 260", "errore 260", "error 4)", "errore 4)") {
            return "Il file non c’è più: forse è stato spostato, rinominato o è su un disco scollegato."
        }
        if has("com.apple.coreaudio", "avfaudio") {
            return "Il suono di questo file non si può elaborare così: prova a convertirlo prima in M4A."
        }
        if has("-11838", "operation stopped", "operazione interrotta") {
            return "macOS ha interrotto il lavoro: riprova (se il Mac era in stop o sotto sforzo, ora dovrebbe andare)."
        }
        // Solo i messaggi di macOS (in inglese o con il codice): quelli del motore classico sono già in italiano chiaro
        if has("-11800", "-11828", "-11829", "-11833", "cannot decode", "impossibile decodificare", "media format",
               "cannot open", "not supported") {
            return "macOS non riesce a leggere questo file: può essere danneggiato o in un formato insolito."
        }
        if has("-11847", "-11819", "media services were reset", "servizi multimediali") {
            return "Il motore video di macOS si è riavviato durante il lavoro: riprova."
        }
        if has("the operation couldn’t be completed", "the operation couldn't be completed", "impossibile completare l’operazione",
               "impossibile completare l'operazione") {
            return "Qualcosa non è andato con questo file. Riprova; se succede ancora, usa «Segnala bug» e lo sistemiamo."
        }
        return raw
    }
}
