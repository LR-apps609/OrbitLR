import XCTest
import PDFKit
import AppKit

/// 5.1 «Al sicuro» · Editor PDF: modifiche riconosciute, ⌘Z e ⇧⌘Z, firma sostituita con ripristino.
final class PDFEditorSafetyTests: XCTestCase {
    private var savedFolder: URL!

    override func setUp() {
        super.setUp()
        savedFolder = SignatureStore.folder
        // Mai toccare la firma vera: una cartella tutta per il test
        SignatureStore.folder = Fixtures.url("firma-\(UUID().uuidString)")
    }

    override func tearDown() {
        SignatureStore.folder = savedFolder
        super.tearDown()
    }

    /// Un PDF di una pagina A4 bianca, in memoria.
    private func blankDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func model(_ doc: PDFDocument) -> PDFEditorModel {
        let m = PDFEditorModel(source: Fixtures.url("prova.pdf"), document: doc, tool: .select)
        m.undo.groupsByEvent = false        // senza run loop: i gruppi li apre e chiude il modello
        return m
    }

    private func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 40, height: 20), flipped: false) { r in
            color.setFill()
            r.fill()
            return true
        }
    }

    func testAppenaApertoNonCiSonoModifiche() throws {
        let m = model(try blankDocument())
        XCTAssertFalse(m.hasChanges, "senza modifiche si chiude subito")
        XCTAssertFalse(m.undo.canUndo)
    }

    func testTestoAggiuntoSiAnnullaESiRipete() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let m = model(doc)
        m.placeText("Ciao", on: page, at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(m.hasChanges)
        XCTAssertEqual(page.annotations.count, 1)
        m.undo.undo()
        XCTAssertFalse(m.hasChanges, "annullato tutto: niente da salvare")
        XCTAssertEqual(page.annotations.count, 0)
        XCTAssertTrue(m.undo.canRedo)
        m.undo.redo()
        XCTAssertTrue(m.hasChanges)
        XCTAssertEqual(page.annotations.count, 1)
    }

    func testUnTrascinamentoEUnSoloAnnulla() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let m = model(doc)
        m.placeText("Ciao", on: page, at: CGPoint(x: 100, y: 100))
        let a = try XCTUnwrap(m.selected)
        let start = a.bounds
        // Come durante il trascinamento: tante posizioni, un solo «commit» al rilascio
        for dx in stride(from: CGFloat(5), through: 50, by: 5) { a.bounds = start.offsetBy(dx: dx, dy: dx) }
        m.commitBounds(a, from: start)
        XCTAssertNotEqual(a.bounds, start)
        m.undo.undo()
        XCTAssertEqual(a.bounds, start, "un ⌘Z riporta al punto di partenza")
        XCTAssertEqual(page.annotations.count, 1, "il testo c'è ancora")
        m.undo.redo()
        XCTAssertEqual(a.bounds, start.offsetBy(dx: 50, dy: 50))
    }

    func testEliminaSiRiprendeConAnnulla() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let m = model(doc)
        m.placeText("Ciao", on: page, at: CGPoint(x: 100, y: 100))
        let a = try XCTUnwrap(m.selected)
        m.remove(a)
        XCTAssertEqual(page.annotations.count, 0)
        XCTAssertFalse(m.hasChanges)
        m.undo.undo()
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(m.isMine(a), "torna un elemento che si può spostare ed eliminare")
        XCTAssertTrue(m.hasChanges)
    }

    func testOscuramentoTrascinatoEntraNellAnnulla() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let m = model(doc)
        let a = m.beginDraftRedaction(on: page, at: CGPoint(x: 50, y: 50))
        a.bounds = CGRect(x: 50, y: 50, width: 120, height: 30)
        m.finishDraftRedaction(a)
        XCTAssertEqual(m.redactions.count, 1)
        XCTAssertTrue(m.hasChanges)
        m.undo.undo()
        XCTAssertEqual(m.redactions.count, 0)
        XCTAssertEqual(page.annotations.count, 0)
        m.undo.redo()
        XCTAssertEqual(m.redactions.count, 1)
    }

    func testUnClicSenzaTrascinareNonLasciaNiente() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let m = model(doc)
        let a = m.beginDraftRedaction(on: page, at: CGPoint(x: 50, y: 50))
        m.finishDraftRedaction(a)
        XCTAssertEqual(page.annotations.count, 0)
        XCTAssertFalse(m.hasChanges)
        XCTAssertFalse(m.undo.canUndo, "niente da annullare")
    }

    func testRidimensionaDallAngolo() {
        let r = CGRect(x: 10, y: 100, width: 100, height: 50)
        let free = PDFEditorModel.resized(r, to: CGPoint(x: 210, y: 60), keepRatio: false)
        XCTAssertEqual(free, CGRect(x: 10, y: 60, width: 200, height: 90), "l'angolo in alto a sinistra resta fermo")
        let ratio = PDFEditorModel.resized(r, to: CGPoint(x: 210, y: 0), keepRatio: true)
        XCTAssertEqual(ratio.width, 200)
        XCTAssertEqual(ratio.height, 100, accuracy: 0.001, "la firma non si deforma")
        XCTAssertEqual(ratio.maxY, r.maxY, accuracy: 0.001)
        let tiny = PDFEditorModel.resized(r, to: CGPoint(x: 0, y: 500), keepRatio: false)
        XCTAssertEqual(tiny.width, 8)
        XCTAssertEqual(tiny.height, 8)
    }

    func testCampoDelModuloCompilatoContaComeModifica() throws {
        let doc = try blankDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 22), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "nome"
        page.addAnnotation(field)
        let m = model(doc)
        XCTAssertFalse(m.hasChanges)
        field.widgetStringValue = "Mario Rossi"
        XCTAssertTrue(m.hasChanges, "un campo compilato non si perde senza domanda")
    }

    func testFirmaSostituitaSiRipristina() throws {
        let m = model(try blankDocument())
        XCTAssertTrue(m.useSignature(image(.blue)), "la prima firma non chiede niente")
        let first = try XCTUnwrap(SignatureStore.data())
        XCTAssertFalse(m.undo.canUndo, "la prima firma non entra nell'annulla")

        m.confirmReplaceSignature = { false }
        XCTAssertFalse(m.useSignature(image(.red)), "«Annulla»: resta nel riquadro")
        XCTAssertEqual(SignatureStore.data(), first, "la firma salvata non cambia")

        m.confirmReplaceSignature = { true }
        XCTAssertTrue(m.useSignature(image(.red)))
        XCTAssertNotEqual(SignatureStore.data(), first)
        XCTAssertEqual(try? Data(contentsOf: SignatureStore.previousURL), first, "la vecchia resta in firma-precedente.png")
        m.undo.undo()
        XCTAssertEqual(SignatureStore.data(), first, "⌘Z rimette la firma di prima")
    }

    func testStessoFileScrittoInModoDiverso() {
        let a = URL(fileURLWithPath: "/tmp/cartella/doc.pdf")
        let b = URL(fileURLWithPath: "/tmp/cartella/altra/../doc.pdf")
        XCTAssertTrue(PDFEditorController.sameFile(a, b))
        XCTAssertFalse(PDFEditorController.sameFile(a, URL(fileURLWithPath: "/tmp/cartella/altro.pdf")))
    }

    func testNessunaFinestraApertaNienteDaSalvare() {
        XCTAssertFalse(PDFEditorController.hasUnsavedChanges)
    }
}
