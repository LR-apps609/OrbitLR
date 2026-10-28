import Foundation
import AppKit
import PDFKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Metal
import MetalKit
import MetalFX
import ImageIO
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  Strumenti della 2.5, tutti sul Mac con le tecnologie di Apple:
//  • Rendi ricercabile (PDF e foto di documenti) — Vision (OCR) + PDF con testo invisibile
//  • Rimuovi lo sfondo — Vision
//  • Raddrizza il documento — Vision + Core Image
//  • Ingrandisci 2×/4× — MetalFX (con Core Image se MetalFX non c'è)
// ════════════════════════════════════════════════════════════════════

enum Tools {
    static let ids: Set<String> = ["searchable", "removebg", "straighten", "upscale", "aienhance", "stack", "hidemark", "vector"]

    /// Esegue uno strumento su un file e restituisce il file creato.
    static func run(job: Job, file: URL, dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let kind = Catalog.kind(of: file)
        switch job.action.id {
        case "searchable":
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("ricercabile")))", ext: "pdf")
            if kind == .pdf {
                try makeSearchablePDF(file, out: out, progress: progress)
            } else {
                try makeSearchableFromImage(file, out: out)
                progress(1)
            }
            return out
        case "hidemark":
            // 2.9.4 · Nascondi filigrana, su una foto o un video
            guard let spec = HideMark.parse(job.param) else { throw NativeError(String(localized: "nessuna zona da coprire")) }
            // 2.9.7 · Rimozione con l'IA: il modello si scarica la prima volta
            var inpainter: Inpainter? = nil
            if spec.style == "ai" {
                if !ModelStore.shared.isReady { await MainActor.run { job.status = String(localized: "Scarico il modello di IA (solo la prima volta)…") } }
                inpainter = Inpainter(model: try await ModelStore.shared.lama())
                await MainActor.run { job.status = String(localized: "Ricostruisco la zona con l’IA…") }
            }
            if kind == .video {
                let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("senza logo")))", ext: "mp4")
                try await HideMark.video(file, spec: spec, out: out, job: job, inpainter: inpainter, progress: progress)
                return out
            }
            let e = Catalog.norm(file.pathExtension)
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("senza logo")))", ext: ["jpg", "png", "heic", "tiff"].contains(e) ? e : "png")
            try HideMark.image(file, spec: spec, out: out, inpainter: inpainter)
            progress(1)
            return out
        case "removebg":
            let mode = job.param.isEmpty ? "transparent" : job.param
            let ext = mode == "white" ? "jpg" : "png"
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("senza sfondo")))", ext: ext)
            try removeBackground(file, mode: mode, out: out)
            progress(1)
            return out
        case "straighten":
            let mode = job.param.isEmpty ? "color-jpg" : job.param
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("raddrizzato")))", ext: mode.hasSuffix("pdf") ? "pdf" : "jpg")
            try straighten(file, bw: mode.hasPrefix("bw"), out: out)
            progress(1)
            return out
        case "upscale":
            let factor = Int(job.param) ?? 2
            let e = Catalog.norm(file.pathExtension)
            let ext = ["jpg", "png", "heic", "tiff"].contains(e) ? e : "png"
            let out = Destination.unique(dir, base: "\(base) (\(factor)×)", ext: ext)
            try upscale(file, factor: factor, out: out)
            progress(1)
            return out
        case "aienhance":
            let p = job.param.isEmpty ? "b0-2" : job.param
            let e = Catalog.norm(file.pathExtension)
            let ext = ["jpg", "png", "heic", "tiff"].contains(e) ? e : "png"
            let parsed = AIEnhance.parse(p)
            let label = parsed.factor == 1 ? FileTag.t("migliorata") : "\(FileTag.t("IA")) \(parsed.factor)×"
            let out = Destination.unique(dir, base: "\(base) (\(label))", ext: ext)
            try AIEnhance.run(file, param: p, out: out, progress: progress)
            return out
        case "vector":
            // 4.3 · Vettoriale (SVG), con lo stesso motore di Windows
            // 4.6 · «Pacchetto logo»: uno ZIP con SVG, PDF, EPS, PNG, la versione a un colore e le icone
            if job.param == "pack" {
                let root = "\(base) (\(FileTag.t("pacchetto logo")))"
                let out = Destination.unique(dir, base: root, ext: "zip")
                try Vector.run(file, param: "pack", out: out, name: base, root: out.deletingPathExtension().lastPathComponent, progress: progress)
                return out
            }
            let out = Destination.unique(dir, base: "\(base) (\(FileTag.t("vettoriale")))", ext: "svg")
            try Vector.run(file, param: job.param.isEmpty ? "auto" : job.param, out: out, progress: progress)
            return out
        default:
            throw NativeError(String(localized: "Strumento sconosciuto"))
        }
    }

    // MARK: - Immagini: lettura e scrittura

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// L'immagine già girata nel verso giusto (le foto dell'iPhone hanno l'orientamento nei metadati).
    static func orientedImage(_ url: URL) throws -> CIImage {
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw NativeError(String(localized: "Non riesco ad aprire l’immagine"))
        }
        return img
    }

    static func cgImage(_ img: CIImage) throws -> CGImage {
        guard let cg = ci.createCGImage(img, from: img.extent) else { throw NativeError(String(localized: "Non riesco a elaborare l’immagine")) }
        return cg
    }

    static func write(_ cg: CGImage, to out: URL, quality: Double = 0.9) throws {
        let e = Catalog.norm(out.pathExtension)
        let type: UTType
        switch e {
        case "jpg": type = .jpeg
        case "heic": type = .heic
        case "tiff": type = .tiff
        default: type = .png
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw NativeError(String(localized: "Non riesco a creare il file"))
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NativeError(String(localized: "Non riesco a salvare l’immagine")) }
    }

    /// Una pagina PDF con un'immagine (per documenti raddrizzati e foto rese ricercabili). 200 punti per pollice.
    private static func pageSize(for cg: CGImage, dpi: CGFloat = 200) -> CGSize {
        CGSize(width: CGFloat(cg.width) * 72 / dpi, height: CGFloat(cg.height) * 72 / dpi)
    }

    // MARK: - Rendi ricercabile (punto 10)

    struct Line {
        let text: String
        let box: CGRect       // in proporzione (0…1), origine in basso a sinistra, come dà Vision
    }

    /// Riconosce il testo in un'immagine (italiano e inglese).
    static func recognize(_ cg: CGImage) throws -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["it-IT", "en-US"]
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return Line(text: c.string, box: o.boundingBox)
        }
    }

    /// Scrive il testo riconosciuto in modo invisibile sopra l'immagine: si vede la scansione, ma si può cercare e copiare.
    static func drawInvisibleText(_ lines: [Line], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for l in lines {
            let w: CGFloat = l.box.width * size.width
            let h: CGFloat = l.box.height * size.height
            guard w > 2, h > 2, !l.text.isEmpty else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, h * 0.85, nil)
            let attr = NSAttributedString(string: l.text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let sx: CGFloat = natural > 0 ? w / natural : 1
            ctx.textMatrix = CGAffineTransform(scaleX: sx, y: 1)
            ctx.textPosition = CGPoint(x: l.box.minX * size.width, y: l.box.minY * size.height + h * 0.18)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// Dimensioni della pagina come si vede (con la rotazione applicata).
    static func visibleSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// La pagina disegnata come immagine (con annotazioni e campi compilati), a `dpi` punti per pollice.
    static func render(_ page: PDFPage, dpi: CGFloat = 300, extra: ((CGContext) -> Void)? = nil) -> CGImage? {
        let size = visibleSize(page)
        let scale = dpi / 72
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        if let extra {
            ctx.saveGState()
            page.transform(ctx, for: .cropBox)
            extra(ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Una pagina «ha già del testo» se contiene almeno qualche parola selezionabile.
    static func hasText(_ page: PDFPage) -> Bool {
        let t = (page.string ?? "").filter { !$0.isWhitespace }
        return t.count > 20
    }

    static func makeSearchablePDF(_ src: URL, out: URL, progress: @escaping (Double) -> Void) throws {
        guard let doc = PDFDocument(url: src) else { throw NativeError(String(localized: "Non riesco ad aprire il PDF")) }
        guard !doc.isLocked else { throw NativeError(String(localized: "Il PDF è protetto da password")) }
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw NativeError(String(localized: "Non riesco a creare il PDF")) }
        var recognized = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = visibleSize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            if hasText(page) {
                // Pagina con testo vero: resta com'è (vettoriale)
                page.draw(with: .cropBox, to: ctx)
            } else if let img = render(page, dpi: 300) {
                ctx.draw(img, in: box)
                drawInvisibleText(try recognize(img), in: ctx, size: size)
                recognized += 1
            }
            ctx.endPage()
            progress(Double(i + 1) / Double(max(doc.pageCount, 1)))
        }
        ctx.closePDF()
        if recognized == 0 {
            try? FileManager.default.removeItem(at: out)
            throw NativeError(String(localized: "Il PDF ha già il testo ricercabile in tutte le pagine"))
        }
    }

    static func makeSearchableFromImage(_ src: URL, out: URL) throws {
        let cg = try cgImage(try orientedImage(src))
        let size = pageSize(for: cg)
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw NativeError(String(localized: "Non riesco a creare il PDF")) }
        ctx.beginPage(mediaBox: &box)
        ctx.draw(cg, in: box)
        drawInvisibleText(try recognize(cg), in: ctx, size: size)
        ctx.endPage()
        ctx.closePDF()
    }

    // MARK: - Rimuovi lo sfondo (punto 11)

    static func removeBackground(_ src: URL, mode: String, out: URL) throws {
        let input = try orientedImage(src)
        let cg = try cgImage(input)
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
            throw NativeError(String(localized: "Non trovo un soggetto da ritagliare in questa foto"))
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                 croppedToInstancesExtent: mode == "crop")
        var result = CIImage(cvPixelBuffer: buffer)
        if mode == "white" {
            let white = CIImage(color: .white).cropped(to: result.extent)
            result = result.composited(over: white)
        }
        try write(try cgImage(result), to: out)
    }

    // MARK: - Raddrizza il documento (punto 11)

    static func straighten(_ src: URL, bw: Bool, out: URL) throws {
        let input = try orientedImage(src)
        let cg = try cgImage(input)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)

        // 1. Trova il foglio (prima con il riconoscimento dei documenti, poi con quello dei rettangoli)
        var quad: VNRectangleObservation? = nil
        let doc = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([doc])
        quad = doc.results?.first
        if quad == nil {
            let rect = VNDetectRectanglesRequest()
            rect.minimumConfidence = 0.6
            rect.minimumSize = 0.2
            rect.maximumObservations = 1
            try? handler.perform([rect])
            quad = rect.results?.first
        }
        guard let q = quad else { throw NativeError(String(localized: "Non trovo il foglio nella foto. Prova con uno sfondo più scuro del foglio.")) }

        // 2. Prospettiva corretta
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
        let fix = CIFilter.perspectiveCorrection()
        fix.inputImage = input
        fix.topLeft = pt(q.topLeft)
        fix.topRight = pt(q.topRight)
        fix.bottomLeft = pt(q.bottomLeft)
        fix.bottomRight = pt(q.bottomRight)
        guard var img = fix.outputImage else { throw NativeError(String(localized: "Non riesco a raddrizzare il foglio")) }

        // 3. Pulizia, come una scansione
        if bw {
            let mono = CIFilter.colorControls()
            mono.inputImage = img
            mono.saturation = 0
            mono.contrast = 1.35
            mono.brightness = 0.04
            img = mono.outputImage ?? img
        }
        let enhance = CIFilter.documentEnhancer()
        enhance.inputImage = img
        enhance.amount = 1
        img = enhance.outputImage ?? img
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let result = try cgImage(img)

        if Catalog.norm(out.pathExtension) == "pdf" {
            var box = CGRect(origin: .zero, size: pageSize(for: result))
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw NativeError(String(localized: "Non riesco a creare il PDF")) }
            ctx.beginPage(mediaBox: &box)
            ctx.draw(result, in: box)
            ctx.endPage()
            ctx.closePDF()
        } else {
            try write(result, to: out, quality: 0.88)
        }
    }

    // MARK: - Ingrandisci (punto 11)

    static func upscale(_ src: URL, factor: Int, out: URL) throws {
        var cg = try cgImage(try orientedImage(src))
        let steps = factor >= 4 ? 2 : 1          // 4× = due passaggi da 2×
        for _ in 0..<steps {
            if let up = metalUpscale(cg) {
                cg = up
            } else {
                cg = try coreImageUpscale(cg)
            }
        }
        try write(cg, to: out, quality: 0.92)
    }

    /// Ingrandimento 2× con MetalFX (lo stesso che Apple usa nei giochi): contorni nitidi, nessun alone.
    static func metalUpscale(_ cg: CGImage) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        let w = cg.width, h = cg.height, ow = w * 2, oh = h * 2
        guard ow <= 16384, oh <= 16384 else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        guard let input = try? loader.newTexture(cgImage: cg, options: options) else { return nil }
        let format = input.pixelFormat
        guard format == .bgra8Unorm || format == .rgba8Unorm else { return nil }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = w
        desc.inputHeight = h
        desc.outputWidth = ow
        desc.outputHeight = oh
        desc.colorTextureFormat = format
        desc.outputTextureFormat = format
        desc.colorProcessingMode = .perceptual
        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: ow, height: oh, mipmapped: false)
        outDesc.usage = scaler.outputTextureUsage
        outDesc.storageMode = .private
        let readDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: ow, height: oh, mipmapped: false)
        readDesc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let output = device.makeTexture(descriptor: outDesc), let readable = device.makeTexture(descriptor: readDesc),
              let buffer = queue.makeCommandBuffer() else { return nil }

        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = w
        scaler.inputContentHeight = h
        scaler.encode(commandBuffer: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, to: readable)
        if readDesc.storageMode == .managed { blit.synchronize(resource: readable) }
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }

        let rowBytes = ow * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * oh)
        readable.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0)
        let info: UInt32 = format == .bgra8Unorm
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Se MetalFX non è disponibile: ingrandimento di alta qualità (Lanczos) con un po' di nitidezza.
    static func coreImageUpscale(_ cg: CGImage) throws -> CGImage {
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = CIImage(cgImage: cg)
        scale.scale = 2
        scale.aspectRatio = 1
        let sharp = CIFilter.unsharpMask()
        sharp.inputImage = scale.outputImage
        sharp.radius = 1.6
        sharp.intensity = 0.45
        guard let img = sharp.outputImage else { throw NativeError(String(localized: "Non riesco a ingrandire l’immagine")) }
        return try cgImage(img.cropped(to: CGRect(x: 0, y: 0, width: cg.width * 2, height: cg.height * 2)))
    }
}
