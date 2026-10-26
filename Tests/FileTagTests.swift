import XCTest

/// 4.2.1 · Le parole nei nomi dei file creati: in italiano restano com'erano, in inglese c'è sempre una traduzione.
final class FileTagTests: XCTestCase {
    func testItalianoInvariato() {
        XCTAssertEqual(FileTag.t("taglio"), "taglio")
        XCTAssertEqual(FileTag.t("più leggera"), "più leggera")
    }

    func testOgniParolaHaLInglese() {
        for (it, en) in FileTag.english {
            XCTAssertFalse(en.isEmpty, it)
            XCTAssertFalse(en.contains("/") || en.contains(":"), "carattere non valido nel nome: \(en)")
        }
        XCTAssertEqual(FileTag.all("voce"), ["voce", "voice"])
    }
}
