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

/// 2.8.2 · Scheda File: solo documenti; con tipi diversi si sceglie su quali lavorare.
final class FilesTabTests: XCTestCase {
    private func makePDF(_ name: String) throws -> URL {
        let u = Fixtures.dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = try XCTUnwrap(CGContext(u as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        return u
    }

    func testFilesTabAcceptsDocumentsAndSplitsKinds() throws {
        let pdf = try makePDF("scheda-file.pdf")
        let txt = Fixtures.dir.appendingPathComponent("scheda-file.txt")
        try "testo".write(to: txt, atomically: true, encoding: .utf8)
        let jpg = try Fixtures.photo(name: "scheda-file.jpg", width: 100, height: 100)
        let m = KindTabModel(accepts: [.pdf, .doc, .sheet, .slide, .text])
        m.add([pdf, txt, jpg])
        XCTAssertEqual(m.files, [pdf, txt], "la foto va nella scheda Immagini")
        XCTAssertNotNil(m.notice)
        XCTAssertNil(m.kind, "tipi diversi")
        XCTAssertEqual(m.kindCount, 2)
        XCTAssertTrue(m.actions.isEmpty, "con tipi diversi si chiede prima su quali lavorare")
        m.selectOnly(.pdf)
        XCTAssertEqual(m.kind, .pdf)
        XCTAssertEqual(m.targets, [pdf])
        XCTAssertFalse(m.actions.isEmpty)
    }
}
