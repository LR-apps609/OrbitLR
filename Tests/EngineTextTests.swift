import XCTest

final class EngineTextTests: XCTestCase {
    func testModelliValidi() {
        for p in EngineText.patterns {
            XCTAssertNotNil(try? NSRegularExpression(pattern: p.0), "modello non valido: \(p.0)")
        }
    }

    func testRiscritturaInglese() {
        XCTAssertEqual(EngineText.english("«gita.mov» era già compresso al massimo"), "“gita.mov” was already compressed as much as possible")
        XCTAssertEqual(EngineText.english("non riesco a farlo stare sotto 10 MB (verrebbe 12,3 MB): scegli un peso maggiore o taglialo prima"),
                       "Couldn’t get it under 10 MB (it would be 12,3 MB): choose a larger size or trim it first")
        XCTAssertEqual(EngineText.english("3/7 · Unisco 4 file in un PDF"), "3/7 · Merging 4 files into a PDF")
        XCTAssertEqual(EngineText.english("qualcosa di sconosciuto"), "qualcosa di sconosciuto")
    }

    /// 6.0.3 · In zsh "$sp[v]" dentro una stringa è un pezzo della variabile, non «2[v]»: «Cambia la velocità»
    /// non funzionava su nessun video con l'audio. Nei filtri di ffmpeg le variabili vanno scritte ${sp}.
    func testFiltriSenzaIndiciZsh() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LRConverter.zsh"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"\$[a-z_][a-z0-9_]*\[[a-z]+\]"#)
        for line in script.split(separator: "\n") where line.contains("filter_complex") || line.contains("-af ") || line.contains("-vf ") {
            let s = String(line)
            XCTAssertNil(re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "variabile seguita da [etichetta] in un filtro: \(s)")
        }
    }

    /// 6.0.4 · ImageMagick non deve mai scrivere direttamente sul nome dell'utente («%d» diventerebbe un numero):
    /// le uscite verso "$out" passano da mgk, che usa un nome fisso e poi sposta il file.
    func testMagickNonScriveSulNomeDellUtente() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LRConverter.zsh"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"(^|[^a-z_])magick [^;|&]*"\$out""#)
        for line in script.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let s = String(line)
            XCTAssertNil(re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "magick scrive su $out: \(s)")
        }
    }
}
