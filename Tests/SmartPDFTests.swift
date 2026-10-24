import XCTest
import PDFKit
import AppKit

/// 3.8 · Comprimi PDF senza programmi da installare.
final class SmartPDFTests: XCTestCase {
    func testPDFConFotoPesaMeno() throws {
        let photo = try Fixtures.photo(name: "pagina.png", width: 3000, height: 2000)
        let img = try XCTUnwrap(NSImage(contentsOf: photo))
        let doc = PDFDocument()
        for i in 0..<3 { doc.insert(try XCTUnwrap(PDFPage(image: img)), at: i) }
        let src = Fixtures.url("con-foto.pdf")
        try? FileManager.default.removeItem(at: src)
        XCTAssertTrue(doc.write(to: src))
        let out = try SmartPDF.compress(src, level: "medium", dir: Fixtures.dir)
        XCTAssertLessThan(Job.size(of: out), Job.size(of: src), "pesa meno")
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 3, "tutte le pagine")
        print("TEMPO: PDF compresso da \(Job.size(of: src) / 1000) KB a \(Job.size(of: out) / 1000) KB")
    }
}
