import Foundation

enum Kind: String, CaseIterable, Codable {
    case doc, sheet, slide, text, img, audio, video, pdf, sub

    var name: String {
        switch self {
        case .doc: return "documenti"
        case .sheet: return "fogli di calcolo"
        case .slide: return "presentazioni"
        case .text: return "file di testo"
        case .img: return "immagini"
        case .audio: return "file audio"
        case .video: return "video"
        case .pdf: return "PDF"
        case .sub: return "sottotitoli"
        }
    }

    /// Etichetta breve con la maiuscola, per i riquadri colorati.
    var label: String {
        switch self {
        case .doc: return "Documenti"
        case .sheet: return "Fogli"
        case .slide: return "Presentazioni"
        case .text: return "Testo e web"
        case .img: return "Immagini"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .sub: return "Sottotitoli"
        }
    }
}

enum ParamKind { case resize, pdfcompress, vcompress, cut, gifcut, extract, vresize, speed, rotate, reorder, password, unlock, rename,
                     removebg, straighten, upscale, aienhance, stack, social, ringtone, hidemark, icompress }

struct Action: Identifiable, Hashable {
    let id: String          // lo stesso identificativo dello script, es. "to:pdf" o "resize"
    let short: String       // testo breve nello spicchio
    let title: String       // titolo al centro del menu
    let hint: String        // spiegazione breve
    let symbol: String      // simbolo di sistema (SF Symbols)
    var param: ParamKind? = nil

    static let more = Action(id: "__more", short: "Altro", title: "Altri formati", hint: "Apre un secondo anello", symbol: "ellipsis")
}

enum Catalog {
    static let rawExts: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef"]

    static func norm(_ e: String) -> String {
        switch e.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm", "xhtml": return "html"
        case "markdown", "mdown": return "md"
        case "aif": return "aiff"
        case "j2k", "jpf", "jpx": return "jp2"
        default: return e.lowercased()
        }
    }

    static func kind(of url: URL) -> Kind? {
        let e = norm(url.pathExtension)
        switch e {
        case "docx", "doc", "odt", "rtf", "txt", "pages", "wps", "wpd": return .doc
        case "xlsx", "xls", "ods", "csv", "numbers": return .sheet
        case "pptx", "ppt", "odp", "key": return .slide
        case "md", "html", "epub": return .text
        case "jpg", "png", "heic", "tiff", "webp", "gif", "bmp", "svg", "ico": return .img
        case "avif", "psd", "jxl", "jp2", "tga", "exr": return .img                       // 2.9.6
        case "mp3", "wav", "m4a", "flac", "aac", "ogg", "opus", "aiff", "wma": return .audio
        case "caf", "amr", "m4b", "ac3", "aifc": return .audio                            // 2.9.6
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv", "flv", "mpg", "mpeg", "3gp", "mts", "m2ts": return .video
        case "ts", "vob", "mxf", "ogv", "dv", "f4v", "asf": return .video                // 2.9.6
        case "pdf": return .pdf
        case "srt": return .sub
        default: return rawExts.contains(e) ? .img : nil
        }
    }

    // MARK: - Conversioni di formato

    private static let convHint: [String: String] = [
        "pdf": "Da leggere e stampare ovunque", "docx": "DOCX · si modifica in Word e Pages", "odt": "Per LibreOffice",
        "rtf": "Testo con formattazione semplice", "txt": "Solo testo, senza formattazione", "html": "Pagina web",
        "md": "MD · testo con titoli e liste", "epub": "Libro elettronico",
        "xlsx": "XLSX · per Excel e Numbers", "ods": "Per LibreOffice Calc", "csv": "Tabella semplice, per ogni programma",
        "pptx": "PPTX · per PowerPoint e Keynote", "odp": "Per LibreOffice Impress",
        "jpg": "Leggero, per condividere", "png": "Senza perdita di qualità", "heic": "Il formato di iPhone, molto leggero",
        "webp": "Leggero, per il web", "tiff": "Alta qualità, per la stampa", "ico": "Icona per programmi e siti",
        "mp3": "Audio compatibile ovunque", "m4a": "Audio di qualità, per Apple", "wav": "Audio senza compressione",
        "flac": "Audio perfetto, più leggero del WAV", "ogg": "Audio leggero, per il web",
        "mp4": "Video compatibile ovunque", "mov": "Video per QuickTime e iMovie", "mkv": "Video con più audio e sottotitoli",
        "webm": "Video per il web", "gif": "Animazione senza audio",
    ]

    private static let convSymbol: [String: String] = [
        "pdf": "doc.richtext", "docx": "doc.text", "odt": "doc.text", "rtf": "doc.text", "txt": "doc.plaintext",
        "html": "globe", "md": "doc.plaintext", "epub": "book", "xlsx": "tablecells", "ods": "tablecells",
        "csv": "tablecells", "pptx": "rectangle.on.rectangle", "odp": "rectangle.on.rectangle",
        "jpg": "photo", "png": "photo", "heic": "photo", "webp": "photo", "tiff": "photo", "ico": "app",
        "mp3": "waveform", "m4a": "waveform", "wav": "waveform", "flac": "waveform", "ogg": "waveform",
        "mp4": "film", "mov": "film", "mkv": "film", "webm": "film", "gif": "photo.stack",
    ]

    static func conv(_ t: String, kind: Kind) -> Action {
        var title = "Converti in " + t.uppercased()
        var hint = convHint[t] ?? ""
        if kind == .pdf && (t == "png" || t == "jpg") { hint = "Un’immagine per ogni pagina" }
        if kind == .video && (t == "mp3" || t == "m4a") { title = "Estrai l’audio in " + t.uppercased(); hint = "Solo l’audio del video" }
        if kind == .video && t == "gif" { title = "GIF animata (tutto il video)" }
        // 3.0 · Word, Excel e PowerPoint con il loro nome; il formato resta scritto sotto
        let names = ["docx": "Word", "xlsx": "Excel", "pptx": "PowerPoint"]
        if let n = names[t] { title = "Converti in " + n }
        let short = t == "md" ? "Markdown" : (names[t] ?? t.uppercased())
        return Action(id: "to:" + t, short: short, title: title, hint: hint, symbol: convSymbol[t] ?? "arrow.right.circle")
    }

    // MARK: - Strumenti

    static let tools: [String: Action] = [
        "resize": Action(id: "resize", short: "Dimensione", title: "Ridimensiona", hint: "Foto più piccole e leggere", symbol: "arrow.up.left.and.arrow.down.right", param: .resize),
        "icompress": Action(id: "icompress", short: "Comprimi", title: "Comprimi", hint: "Più leggera senza perdere qualità, o sotto un peso preciso (moduli, documenti)", symbol: "arrow.down.right.and.arrow.up.left", param: .icompress),
        "strip": Action(id: "strip", short: "Metadati", title: "Rimuovi i metadati", hint: "Toglie posizione, modello del telefono e data dello scatto", symbol: "eye.slash"),
        "ocr": Action(id: "ocr", short: "Testo", title: "Copia il testo", hint: "Il testo scritto nella foto, pronto da incollare", symbol: "text.viewfinder"),
        "pdftext": Action(id: "pdftext", short: "Testo", title: "Copia il testo", hint: "Tutto il testo del PDF, anche dalle scansioni", symbol: "doc.text.magnifyingglass"),
        "split": Action(id: "split", short: "Dividi", title: "Dividi in pagine", hint: "Un PDF per ogni pagina", symbol: "rectangle.split.3x1"),
        "extract": Action(id: "extract", short: "Pagine", title: "Estrai alcune pagine", hint: "Scegli quali, es. 1–3, 5", symbol: "doc.on.doc", param: .extract),
        "pdfcompress": Action(id: "pdfcompress", short: "Comprimi", title: "Comprimi", hint: "Riduci il peso, per mandarlo via email", symbol: "arrow.down.right.and.arrow.up.left", param: .pdfcompress),
        "vcompress": Action(id: "vcompress", short: "Comprimi", title: "Comprimi", hint: "Più leggero senza perdere qualità, o per Discord, WhatsApp ed email", symbol: "arrow.down.right.and.arrow.up.left", param: .vcompress),
        "cut": Action(id: "cut", short: "Taglia", title: "Taglia", hint: "Tieni solo un pezzo", symbol: "scissors", param: .cut),
        "gifcut": Action(id: "gifcut", short: "GIF", title: "GIF da un pezzo", hint: "Un’animazione da un tratto del video", symbol: "photo.stack", param: .gifcut),
        "normalize": Action(id: "normalize", short: "Volume", title: "Volume uniforme", hint: "Né troppo basso né distorto", symbol: "speaker.wave.2"),
        "transcribe": Action(id: "transcribe", short: "Trascrivi", title: "Trascrivi", hint: "Le parole in testo e sottotitoli, senza internet", symbol: "captions.bubble"),
        "subextract": Action(id: "subextract", short: "Sottotitoli", title: "Estrai i sottotitoli", hint: "Un file SRT per ogni lingua", symbol: "text.bubble"),
        "subembed": Action(id: "subembed", short: "+ Sottotitoli", title: "Aggiungi i sottotitoli", hint: "Dal file SRT con lo stesso nome del video", symbol: "plus.bubble"),
        "merge": Action(id: "merge", short: "Unisci", title: "Unisci in un PDF", hint: "Tutti i PDF e le immagini selezionati", symbol: "square.stack.3d.up"),
        "rotate": Action(id: "rotate", short: "Ruota", title: "Ruota le pagine", hint: "Di 90° o 180°", symbol: "rotate.right", param: .rotate),
        "reorder": Action(id: "reorder", short: "Ordina", title: "Riordina le pagine", hint: "Nuovo ordine o pagine al contrario", symbol: "arrow.up.arrow.down", param: .reorder),
        "protect": Action(id: "protect", short: "Proteggi", title: "Proteggi con password", hint: "Serve la password per aprirlo", symbol: "lock.fill", param: .password),
        "unprotect": Action(id: "unprotect", short: "Sblocca", title: "Rimuovi la password", hint: "Una copia che si apre senza password", symbol: "lock.open.fill", param: .unlock),
        "vresize": Action(id: "vresize", short: "Risoluz.", title: "Cambia la grandezza", hint: "Full HD, HD o più piccolo, per pesare meno", symbol: "aspectratio", param: .vresize),
        "speed": Action(id: "speed", short: "Velocità", title: "Cambia la velocità", hint: "Da metà al doppio", symbol: "speedometer", param: .speed),
        "silence": Action(id: "silence", short: "Silenzi", title: "Rimuovi i silenzi", hint: "Toglie le pause lunghe", symbol: "waveform.badge.minus"),
        "rename": Action(id: "rename", short: "Rinomina", title: "Rinomina tutti", hint: "Per esempio Vacanze 001, Vacanze 002…", symbol: "character.cursor.ibeam", param: .rename),
        // 2.5 · PDF e immagini
        "searchable": Action(id: "searchable", short: "Ricercabile", title: "Rendi ricercabile", hint: "Un PDF in cui cercare e copiare il testo, anche dalle scansioni", symbol: "doc.text.magnifyingglass"),
        "pdfedit": Action(id: "pdfedit", short: "Firma", title: "Compila e firma", hint: "Moduli, firma, data e testo", symbol: "signature"),
        "redact": Action(id: "redact", short: "Oscura", title: "Oscura", hint: "Nasconde per davvero nomi, numeri e testo", symbol: "rectangle.inset.filled"),
        "hidemark": Action(id: "hidemark", short: "Filigrana", title: "Nascondi una scritta", hint: "Sfoca o copri un logo, una data o una filigrana", symbol: "eye.slash.circle", param: .hidemark),
        "removebg": Action(id: "removebg", short: "Sfondo", title: "Rimuovi lo sfondo", hint: "Resta solo il soggetto, su sfondo trasparente", symbol: "person.and.background.dotted", param: .removebg),
        "straighten": Action(id: "straighten", short: "Raddrizza", title: "Raddrizza il foglio", hint: "Da una foto storta a una scansione pulita", symbol: "doc.viewfinder", param: .straighten),
        "upscale": Action(id: "upscale", short: "Ingrandisci", title: "Ingrandisci", hint: "Due o quattro volte più grande, con i contorni nitidi", symbol: "plus.magnifyingglass", param: .upscale),
        "stack": Action(id: "stack", short: "Unisci scatti", title: "Unisci più scatti", hint: "Più foto della stessa scena diventano una sola, più nitida", symbol: "square.stack.3d.down.right", param: .stack),
        // 2.6 · video e audio
        "social": Action(id: "social", short: "Social", title: "Formato social", hint: "Verticale, quadrato o 4:5 per Reels, TikTok e post", symbol: "rectangle.portrait.on.rectangle.portrait", param: .social),
        "vmerge": Action(id: "vmerge", short: "Unisci", title: "Unisci i video", hint: "Uno dopo l’altro, in un solo video", symbol: "film.stack"),
        "music": Action(id: "music", short: "Musica", title: "Aggiungi musica", hint: "Sotto l’audio o al suo posto", symbol: "music.note"),
        "ringtone": Action(id: "ringtone", short: "Suoneria", title: "Suoneria iPhone", hint: "Fino a 30 secondi, pronta per iPhone", symbol: "bell.and.waves.left.and.right", param: .ringtone),
        "whatsapp": Action(id: "whatsapp", short: "WhatsApp", title: "Vocale leggero", hint: "Per WhatsApp e messaggi, voce chiara", symbol: "message"),
        "amerge": Action(id: "amerge", short: "Unisci", title: "Unisci gli audio", hint: "Uno dopo l’altro, in un solo file", symbol: "square.stack.3d.up"),
        "vproject": Action(id: "vproject", short: "Montaggio", title: "Esporta il montaggio", hint: "Il progetto della scheda Video", symbol: "film.stack"),
        "tts": Action(id: "tts", short: "Leggi", title: "Testo in voce", hint: "Un file audio letto da una voce naturale", symbol: "text.bubble"),
        "aienhance": Action(id: "aienhance", short: "Migliora", title: "Migliora con l’IA", hint: "Più nitida e pulita, senza inventare dettagli", symbol: "sparkles", param: .aienhance),
    ]

    /// Un’azione dal suo identificativo (per i preset).
    static func action(id: String, kind: Kind) -> Action? {
        if id.hasPrefix("to:") { return conv(String(id.dropFirst(3)), kind: kind) }
        return tools[id]
    }

    /// Il formato che conviene di più per quel file, evidenziato nel menu (es. HEIC → JPG).
    static func suggested(for kind: Kind, exts: Set<String>) -> String? {
        guard exts.count == 1, let e = exts.first else { return nil }
        if rawExts.contains(e) { return "to:jpg" }
        switch e {
        case "heic", "webp", "bmp", "tiff", "avif", "psd", "jxl", "jp2", "tga": return "to:jpg"
        case "exr": return "to:png"
        case "svg": return "to:png"
        case "mov", "mkv", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "m4v", "mts", "m2ts",
             "ts", "vob", "mxf", "ogv", "dv", "f4v", "asf": return "to:mp4"
        case "wav", "aiff", "flac", "wma", "ogg", "opus", "aac", "caf", "amr", "m4b", "ac3", "aifc": return "to:mp3"
        case "docx", "doc", "odt", "rtf", "pages", "wps", "wpd", "xlsx", "xls", "ods", "numbers", "pptx", "ppt", "odp", "key", "md", "html", "epub":
            return "to:pdf"
        default: return nil
        }
    }

    // MARK: - 3.0 · Gruppi degli strumenti nelle schede

    static func toolGroupOrder(kind: Kind) -> [String] {
        switch kind {
        case .img: return [mineGroup, "Modifica", "Migliora", "Altro"]
        case .video: return [mineGroup, "Taglia e unisci", "Peso e grandezza", "Audio e sottotitoli", "Altro"]
        default: return [mineGroup, "Organizza", "Proteggi", "Altro"]
        }
    }

    static let mineGroup = "Le tue scorciatoie"

    static func toolGroup(_ id: String, kind: Kind) -> String {
        if id.hasPrefix("preset:") || id.hasPrefix("recipe:") { return mineGroup }     // 3.2 · in cima, le proprie
        switch kind {
        case .img:
            switch id {
            case "icompress", "resize", "removebg", "hidemark", "straighten": return "Modifica"
            case "aienhance", "upscale", "stack": return "Migliora"
            default: return "Altro"
            }
        case .video:
            switch id {
            case "cut", "gifcut", "vmerge", "speed": return "Taglia e unisci"
            case "vcompress", "vresize", "social": return "Peso e grandezza"
            case "normalize", "transcribe", "subextract", "subembed": return "Audio e sottotitoli"
            default: return "Altro"
            }
        default:
            switch id {
            case "pdfcompress", "pdfedit", "split", "extract", "merge", "rotate", "reorder": return "Organizza"
            case "redact", "protect", "unprotect": return "Proteggi"
            default: return "Altro"
            }
        }
    }

    // MARK: - 3.0 · Il menu a torta: solo conversioni

    /// Le conversioni sono quelle che cambiano il formato (più «Unisci in un PDF» e «Copia il testo» del PDF).
    static func isConversion(_ id: String) -> Bool {
        id.hasPrefix("to:") || id == "merge" || id == "pdftext"
    }

    /// Lo spicchio che porta il file nella sua scheda, dove ci sono tutte le modifiche.
    static func openAction(for kind: Kind) -> Action? {
        switch kind {
        case .img: return Action(id: "__open:images", short: "Modifica", title: "Modifica in Immagini",
                                 hint: "Ridimensiona, togli lo sfondo, migliora e altro", symbol: "slider.horizontal.3")
        case .pdf, .doc, .sheet, .slide, .text:
            return Action(id: "__open:files", short: "Modifica", title: "Modifica in File",
                          hint: "Comprimi, dividi, firma, proteggi e altro", symbol: "slider.horizontal.3")
        case .audio: return Action(id: "__open:audio", short: "Modifica", title: "Modifica in Audio",
                                   hint: "Taglia, suoneria, volume, velocità e altro", symbol: "slider.horizontal.3")
        case .video: return Action(id: "__open:videotools", short: "Modifica", title: "Modifica in Video",
                                   hint: "Comprimi, taglia, GIF, formato social e altro", symbol: "slider.horizontal.3")
        case .sub: return nil
        }
    }

    /// Dove porta uno spicchio «Modifica in…».
    static func openTarget(_ id: String) -> DrawerTarget? {
        switch id {
        case "__open:images": return .images
        case "__open:files": return .files
        case "__open:audio": return .audio
        case "__open:videotools": return .videoTools
        default: return nil
        }
    }

    /// Il menu a torta (finestra e Finder): le conversioni, poi «Modifica in…» sempre nel primo anello.
    static func pieActions(for kind: Kind, exts: Set<String>, mergeable: Int, count: Int = 99) -> [Action] {
        var out = actions(for: kind, exts: exts, mergeable: mergeable, count: count).filter { isConversion($0.id) }
        if let open = openAction(for: kind) {
            out.insert(open, at: out.count + 1 <= 8 ? out.count : 6)
        }
        return out
    }

    /// Azioni per un tipo di file, dalla più usata alla meno usata.
    /// Le prime 7 occupano gli spicchi fissi; le altre finiscono in «Altro».
    static func actions(for kind: Kind, exts: Set<String>, mergeable: Int, count: Int = 99) -> [Action] {
        let order: [String]
        switch kind {
        case .pdf:   order = ["to:docx", "to:png", "to:jpg", "pdftext", "split", "extract", "pdfcompress",
                              "pdfedit", "redact", "searchable",
                              "merge", "rotate", "reorder", "protect", "unprotect", "rename"]
        case .img:   order = ["to:jpg", "to:png", "to:heic", "icompress", "resize", "strip", "ocr", "to:pdf",
                              "aienhance", "stack", "removebg", "hidemark", "straighten", "upscale", "searchable",
                              "to:webp", "to:tiff", "to:ico", "merge", "rename"]
        case .doc:   order = ["to:pdf", "to:docx", "to:odt", "to:txt", "to:md", "to:html", "to:rtf", "tts", "rename"]
        case .sheet: order = ["to:pdf", "to:xlsx", "to:csv", "to:ods", "to:html", "rename"]
        case .slide: order = ["to:pdf", "to:pptx", "to:odp", "rename"]
        case .text:  order = ["to:pdf", "to:docx", "to:html", "to:md", "to:odt", "to:epub", "tts", "rename"]
        case .audio: order = ["to:mp3", "to:m4a", "to:wav", "cut", "normalize", "transcribe", "silence",
                              "ringtone", "whatsapp", "amerge",
                              "speed", "to:flac", "to:ogg", "rename"]
        // 3.7 · Prima le cose di tutti i giorni (dalle ricerche: comprimere per le app, tagliare, cambiare grandezza)
        case .video: order = ["vcompress", "cut", "vresize", "social", "gifcut", "to:mp4", "to:mp3",
                              "vmerge", "speed", "transcribe", "normalize", "hidemark",
                              "to:mov", "to:mkv", "to:webm", "to:gif", "to:m4a",
                              "subextract", "subembed", "strip", "rename"]
        case .sub:   order = []
        }
        let hasSvg = exts.contains("svg")
        let hasRaw = !exts.isDisjoint(with: rawExts)
        var out: [Action] = []
        for id in order {
            if id.hasPrefix("to:") {
                let t = String(id.dropFirst(3))
                if exts.count == 1 && exts.first == t { continue }   // niente «converti in sé stesso»
                out.append(conv(t, kind: kind))
            } else {
                if id == "merge" && mergeable < 2 { continue }
                if (id == "vmerge" || id == "amerge") && count < 2 { continue }   // servono almeno 2 file
                // Video e audio della 2.6 usano i motori di macOS: solo i formati che sa leggere
                if Media.ids.contains(id) && id != "tts" && !exts.isEmpty && !exts.isSubset(of: MediaTabModel.readable) { continue }
                if id == "tts" && !exts.isEmpty && exts.isDisjoint(with: ["txt", "md", "rtf", "docx", "doc", "odt", "html", "pages"]) { continue }
                if id == "stack" && kind == .img && mergeable < 2 { continue }      // servono almeno 2 foto
                // 2.9.4 · Filigrana dei video: solo i formati che macOS sa leggere
                if id == "hidemark" && kind == .video && !exts.isEmpty && !exts.isSubset(of: MediaTabModel.readable) { continue }
                if hasSvg && ["resize", "strip", "ocr", "removebg", "hidemark", "straighten", "upscale", "aienhance", "searchable"].contains(id) { continue }
                if hasRaw && id == "strip" { continue }
                if let a = tools[id] { out.append(a) }
            }
        }
        return PieCustom.apply(out, kind: kind)       // l’ordine scelto in «Personalizza il menu»
    }
}
