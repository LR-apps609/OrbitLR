import XCTest

/// 3.0 · Il menu a torta ha solo conversioni, più «Modifica» che porta il file nella sua scheda.
final class PieConversionsTests: XCTestCase {
    func testSoloConversioni() {
        for (k, e) in [(Kind.img, "jpg"), (.video, "mp4"), (.audio, "wav"), (.pdf, "pdf"), (.doc, "docx"), (.sheet, "xlsx"), (.slide, "pptx"), (.text, "md")] {
            let pie = Catalog.pieActions(for: k, exts: [e], mergeable: 1, count: 1)
            XCTAssertFalse(pie.isEmpty, "\(k)")
            for a in pie {
                XCTAssertTrue(Catalog.isConversion(a.id) || a.id.hasPrefix("__open:"), "\(k): \(a.id) non è una conversione")
            }
            let open = pie.firstIndex { $0.id.hasPrefix("__open:") }
            XCTAssertNotNil(open, "\(k): manca «Modifica»")
            XCTAssertLessThan(open ?? 99, 8, "\(k): «Modifica» deve stare nel primo anello")
            XCTAssertNotNil(Catalog.openTarget(pie[open!].id), "\(k): «Modifica» non porta da nessuna parte")
        }
    }

    func testGliStrumentiRestanoNelleSchede() {
        // Quello che esce dalla torta resta nelle schede (Immagini, File, Video)
        XCTAssertTrue(Catalog.actions(for: .img, exts: ["jpg"], mergeable: 1).contains { $0.id == "removebg" })
        XCTAssertFalse(Catalog.pieActions(for: .img, exts: ["jpg"], mergeable: 1).contains { $0.id == "removebg" })
        XCTAssertTrue(Catalog.actions(for: .video, exts: ["mp4"], mergeable: 1).contains { $0.id == "vcompress" })
        XCTAssertFalse(Catalog.pieActions(for: .video, exts: ["mp4"], mergeable: 1).contains { $0.id == "vcompress" })
    }

    func testWordExcelPowerPoint() {
        XCTAssertEqual(Catalog.conv("docx", kind: .pdf).short, "Word")
        XCTAssertEqual(Catalog.conv("xlsx", kind: .sheet).short, "Excel")
        XCTAssertEqual(Catalog.conv("pptx", kind: .slide).short, "PowerPoint")
        XCTAssertTrue(Catalog.conv("docx", kind: .pdf).hint.contains("DOCX"), "il formato resta scritto")
    }

    func testGruppiDegliStrumenti() {
        let m = KindTabModel(accepts: [.img])
        XCTAssertEqual(Catalog.toolGroup("removebg", kind: .img), "Modifica")
        XCTAssertEqual(Catalog.toolGroup("aienhance", kind: .img), "Migliora")
        XCTAssertEqual(Catalog.toolGroup("protect", kind: .pdf), "Proteggi")
        XCTAssertTrue(m.toolGroups.isEmpty, "senza file nessun gruppo")
    }
}
