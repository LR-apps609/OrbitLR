import Foundation
import PDFKit

// ════════════════════════════════════════════════════════════════════
//  3.8 · Comprimi PDF con il motore di macOS (prima serviva Ghostscript, da installare,
//  con una licenza che non permette di venderlo dentro un'app).
//  Le immagini dentro il PDF diventano JPEG; con «Media» e «Forte» anche alla risoluzione giusta
//  per lo schermo. Testo, link e moduli restano come sono.
// ════════════════════════════════════════════════════════════════════

enum SmartPDF {
    static func compress(_ src: URL, level: String, dir: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw NativeError("PDF danneggiato o non valido") }
        if doc.isLocked { throw NativeError("il PDF è protetto da password: toglila prima con «Togli la password»") }
        var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level != "light" { opts[.optimizeImagesForScreenOption] = true }
        let base = src.deletingPathExtension().lastPathComponent
        let out = Destination.unique(dir, base: "\(base) (compresso)", ext: "pdf")
        guard doc.write(to: out, withOptions: opts) else { throw NativeError("non riesco a scrivere il PDF compresso") }
        let before = Job.size(of: src), after = Job.size(of: out)
        if before > 0, after >= before * 97 / 100 {
            try? FileManager.default.removeItem(at: out)
            throw NativeError("«\(src.lastPathComponent)» è già compresso al massimo")
        }
        return out
    }
}
