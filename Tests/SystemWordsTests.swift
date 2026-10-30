import XCTest

/// 5.2 · «Sistema»: una parola per cosa, i nomi delle sezioni sempre da `title`, aree di clic di 24 pt.
final class SystemWordsTests: XCTestCase {
    private func catalog() throws -> [String: Any] {
        let url = Bundle(for: SystemWordsTests.self).url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Localizable.xcstrings non trovato") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    /// Le parole doppie del rapporto non ci sono più.
    func testNoDoubleWords() throws {
        let s = try catalog()
        for old in ["Togli i silenzi", "Inizio qui", "Parte qui", "Fine qui", "Finisce qui", "Mostra nella cartella",
                    "Compila e firma", "Sblocca", "Inserisci la password", "Segnala un bug", "Spegni l’audio della clip",
                    "Riaccendi l’audio della clip", "Muta questa clip", "Muti tutti", "Rimuovi la musica", "Rimuovi il testo",
                    "Intera", "Aggiungi file…", "Apri un altro…", "Spegni da qui"] {
            XCTAssertNil(s[old], "«\(old)» è una parola doppia: usa quella di Design/DESIGN.md")
        }
    }

    /// Le parole nuove hanno l'inglese.
    func testNewWordsAreTranslated() throws {
        let s = try catalog()
        for k in ["Rimuovi i silenzi", "Inizia qui", "Finisci qui", "Mostra nel Finder", "Editor PDF", "Rimuovi la password…",
                  "Segnala un problema", "Togli la musica", "Togli il testo", "Muta la clip", "Riattiva l’audio",
                  "Muta tutti i video", "Muta da qui", "Dissolvenza della musica", "Dissolvenza della clip",
                  "Elimina il risultato", "revert.confirm", "Coppia precedente", "Coppia successiva"] {
            let e = (s[k] as? [String: Any])?["localizations"] as? [String: Any]
            XCTAssertNotNil(e?["en"], "manca l’inglese per «\(k)»")
        }
    }

    func testSectionNamesComeFromTitle() {
        XCTAssertEqual(SidebarItem.workspace.title, String(localized: "Converti"))
        XCTAssertEqual(SidebarItem.files.title, String(localized: "PDF e documenti"))
        XCTAssertTrue(Help.sections.contains("Converti"))
        XCTAssertFalse(Help.sections.contains("Conversione"))
        XCTAssertEqual(BugReport.categories.first, "Converti")
    }

    func testFiveRadii() {
        XCTAssertEqual([Radius.xs, Radius.s, Radius.m, Radius.l, Radius.xl], [5, 7, 9, 12, 14])
    }
}
