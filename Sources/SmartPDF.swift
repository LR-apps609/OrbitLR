import Foundation
import PDFKit
import Quartz

// ════════════════════════════════════════════════════════════════════
//  3.8 · Comprimi PDF con il motore di macOS (prima serviva Ghostscript, da installare,
//  con una licenza che non permette di venderlo dentro un'app).
//  Le immagini dentro il PDF vengono ricompresse in JPEG e riportate a una risoluzione sensata
//  (stampa, schermo, minima). Testo, link e moduli restano come sono.
//  È lo stesso meccanismo di «Riduci dimensioni file» di Anteprima, ma con valori scelti con cura:
//  quello di Anteprima rende i testi delle scansioni illeggibili.
// ════════════════════════════════════════════════════════════════════

enum SmartPDF {
    /// Qualità JPEG e risoluzione massima delle immagini per ogni livello.
    static func settings(_ level: String) -> (quality: Double, dpi: Int) {
        switch level {
        case "light": return (0.8, 220)          // qualità di stampa
        case "strong": return (0.5, 110)         // il più leggero possibile, ancora leggibile
        default: return (0.65, 150)              // schermo e email
        }
    }

    static func compress(_ src: URL, level: String, dir: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw NativeError(String(localized: "PDF danneggiato o non valido")) }
        if doc.isLocked { throw NativeError(String(localized: "il PDF è protetto da password: toglila prima con «Togli la password»")) }
        let base = src.deletingPathExtension().lastPathComponent
        let out = Destination.unique(dir, base: "\(base) (compresso)", ext: "pdf")
        let before = Job.size(of: src)

        // 1) Filtro con qualità e risoluzione scelte da noi
        if let filter = makeFilter(level) {
            _ = doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        }
        // 2) Se non è servito, le opzioni semplici di macOS
        if Job.size(of: out) == 0 || Job.size(of: out) >= before * 97 / 100 {
            var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if level != "light" { opts[.optimizeImagesForScreenOption] = true }
            let alt = dir.appendingPathComponent(".\(UUID().uuidString).pdf")
            if doc.write(to: alt, withOptions: opts), Job.size(of: alt) > 0,
               Job.size(of: out) == 0 || Job.size(of: alt) < Job.size(of: out) {
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: alt, to: out)
            } else {
                try? FileManager.default.removeItem(at: alt)
            }
        }
        let after = Job.size(of: out)
        guard after > 0 else { throw NativeError(String(localized: "non riesco a scrivere il PDF compresso")) }
        // Deve restare un PDF valido, con tutte le pagine
        guard PDFDocument(url: out)?.pageCount == doc.pageCount else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError(String(localized: "la compressione ha rovinato il PDF: lascio l'originale"))
        }
        if before > 0, after >= before * 97 / 100 {
            try? FileManager.default.removeItem(at: out)
            throw NativeError(String(localized: "«\(src.lastPathComponent)» è già compresso al massimo"))
        }
        return out
    }

    /// Il filtro di Quartz con le impostazioni del livello.
    static func makeFilter(_ level: String) -> QuartzFilter? {
        let (q, dpi) = settings(level)
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "OrbitLR \(level)",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": q,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleFactor": 0.0,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 0,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitLR-\(level)-\(UUID().uuidString).qfilter")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return QuartzFilter(url: url)
    }
}
