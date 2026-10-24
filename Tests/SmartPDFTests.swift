import XCTest
import PDFKit
import AppKit

/// 3.8 · Comprimi PDF senza programmi da installare.
final class SmartPDFTests: XCTestCase {
    /// Un PDF come quelli veri: pagine A4 con una foto ad alta risoluzione (come una scansione o un volantino).
    private func heavyPDF() throws -> URL {
        let photo = try Fixtures.photo(name: "pagina.png", width: 3000, height: 2000)
        let src = Fixtures.url("con-foto.pdf")
        try? FileManager.default.removeItem(at: src)
        guard let img = NSImage(contentsOf: photo)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "prova", code: 1)
        }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(src as CFURL, mediaBox: &box, nil) else { throw NSError(domain: "prova", code: 2) }
        for _ in 0..<3 {
            ctx.beginPDFPage(nil)
            ctx.draw(img, in: CGRect(x: 40, y: 300, width: 515, height: 343))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return src
    }

    func testPDFConFotoPesaMeno() throws {
        let src = try heavyPDF()
        let out = try SmartPDF.compress(src, level: "medium", dir: Fixtures.dir)
        XCTAssertLessThan(Job.size(of: out), Job.size(of: src), "pesa meno")
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 3, "tutte le pagine")
        print("TEMPO: PDF compresso da \(Job.size(of: src) / 1000) KB a \(Job.size(of: out) / 1000) KB")
    }

    func testLivelliDiversi() throws {
        let src = try heavyPDF()
        let light = try SmartPDF.compress(src, level: "light", dir: Fixtures.dir)
        let strong = try SmartPDF.compress(src, level: "strong", dir: Fixtures.dir)
        XCTAssertLessThanOrEqual(Job.size(of: strong), Job.size(of: light), "«Forte» pesa meno di «Leggera»")
    }
}
