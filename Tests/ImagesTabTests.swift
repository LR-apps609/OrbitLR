import XCTest

/// 2.8 · Scheda Immagini: solo foto, niente doppioni, si lavora su tutte o su quelle scelte.
final class ImagesTabTests: XCTestCase {
    func testAddFiltersAndDedupes() throws {
        let a = try Fixtures.photo(name: "tab-a.jpg", width: 300, height: 200)
        let b = try Fixtures.photo(name: "tab-b.jpg", width: 300, height: 200)
        let txt = Fixtures.dir.appendingPathComponent("nota.txt")
        try "ciao".write(to: txt, atomically: true, encoding: .utf8)
        let m = ImagesTabModel()
        m.add([a, b, txt])
        XCTAssertEqual(m.files, [a, b])
        XCTAssertNotNil(m.notice, "il file che non è un'immagine viene segnalato")
        m.add([a])
        XCTAssertEqual(m.files.count, 2, "niente doppioni")
        XCTAssertNil(m.notice)
    }

    func testTargetsFollowSelection() throws {
        let a = try Fixtures.photo(name: "sel-a.jpg", width: 300, height: 200)
        let b = try Fixtures.photo(name: "sel-b.jpg", width: 300, height: 200)
        let m = ImagesTabModel()
        m.add([a, b])
        XCTAssertEqual(m.targets, [a, b], "nessuna scelta: tutte")
        m.toggle(b, extend: false)
        XCTAssertEqual(m.targets, [b])
        m.toggle(a, extend: true)
        XCTAssertEqual(Set(m.targets), [a, b])
        m.toggle(b, extend: true)
        XCTAssertEqual(m.targets, [a])
        m.remove(a)
        XCTAssertEqual(m.targets, [b], "tolta l'unica scelta: si torna a tutte")
        XCTAssertTrue(m.formats.allSatisfy { $0.id.hasPrefix("to:") })
        XCTAssertFalse(m.formats.isEmpty)
        XCTAssertFalse(m.tools.isEmpty)
        m.clear()
        XCTAssertTrue(m.files.isEmpty)
    }
}
