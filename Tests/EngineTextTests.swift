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
}
