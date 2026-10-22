import Foundation
import AppKit
import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

// ════════════════════════════════════════════════════════════════════
//  «Migliora con IA»: Real-ESRGAN (licenza BSD-3, Xintao Wang et al.), convertito per Core ML.
//  Tutto sul Mac, con il chip grafico e il Neural Engine. Due modelli:
//  • Fedele (RealESRNet): ripulisce e rende nitido senza aggiungere dettagli inventati
//  • Più nitido (RealESRGAN): più incisivo, ma può ricostruire texture che nella foto non c'erano
//  L'immagine viene elaborata a riquadri da 256 px (con un bordo di sovrapposizione), poi ricomposta.
// ════════════════════════════════════════════════════════════════════

enum AIEnhance {
    /// Riquadro d'ingresso del modello e bordo di sovrapposizione (evita le «cuciture» tra un riquadro e l'altro).
    static let tile = 256
    static let pad = 16
    static let scale = 4
    /// Limite del risultato: oltre i 100 megapixel il file diventerebbe enorme.
    static let maxOutputPixels = 100_000_000

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])
    private static var cache: [String: MLModel] = [:]
    private static let lock = NSLock()

    /// param: «f1», «f2», «f4» (fedele) o «n1», «n2», «n4» (più nitido): modello + quanto ingrandire.
    static func run(_ src: URL, param: String, out: URL, progress: @escaping (Double) -> Void) throws {
        let sharp = param.hasPrefix("n")
        let factor = max(1, min(4, Int(param.dropFirst()) ?? 2))
        let model = try loadModel(sharp ? "RealESRGAN" : "RealESRNet")

        var input = try Tools.orientedImage(src)
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let ow = input.extent.width, oh = input.extent.height
        guard ow >= 8, oh >= 8 else { throw NativeError("L’immagine è troppo piccola") }

        // Dimensione finale e dimensione su cui lavora il modello (che ingrandisce sempre di 4×).
        // «Stessa dimensione» su foto grandi: si lavora a metà e poi si torna alla misura originale,
        // così ci vuole un quarto del tempo e il risultato è comunque più pulito e nitido.
        let target = CGSize(width: ow * CGFloat(factor), height: oh * CGFloat(factor))
        var work = CGSize(width: ow, height: oh)
        if factor == 1 && ow * oh > 2_000_000 { work = CGSize(width: ow / 2, height: oh / 2) }
        let outPixels = work.width * work.height * CGFloat(scale * scale)
        if outPixels > CGFloat(maxOutputPixels) {
            let k = sqrt(CGFloat(maxOutputPixels) / outPixels)
            work = CGSize(width: work.width * k, height: work.height * k)
        }
        let ww = max(8, Int(work.width.rounded())), wh = max(8, Int(work.height.rounded()))
        var source = input
        if ww != Int(ow) || wh != Int(oh) {
            let s = CIFilter.lanczosScaleTransform()
            s.inputImage = input
            s.scale = Float(CGFloat(wh) / oh)
            s.aspectRatio = Float((CGFloat(ww) / ow) / (CGFloat(wh) / oh))
            source = (s.outputImage ?? input).cropped(to: CGRect(x: 0, y: 0, width: ww, height: wh))
        }

        // Elaborazione a riquadri
        let big = try upscale4(source, width: ww, height: wh, model: model, progress: progress)

        // Misura finale
        var result = CIImage(cgImage: big)
        let bw = CGFloat(big.width), bh = CGFloat(big.height)
        let tw = min(target.width, bw * 4), th = min(target.height, bh * 4)
        if abs(bw - tw) > 1 || abs(bh - th) > 1 {
            let s = CIFilter.lanczosScaleTransform()
            s.inputImage = result
            s.scale = Float(th / bh)
            s.aspectRatio = Float((tw / bw) / (th / bh))
            result = (s.outputImage ?? result).cropped(to: CGRect(x: 0, y: 0, width: tw.rounded(), height: th.rounded()))
        }
        try Tools.write(try Tools.cgImage(result), to: out, quality: 0.93)
        progress(1)
    }

    // MARK: Modello

    /// Il modello si compila la prima volta (qualche secondo) e poi resta pronto nella cartella di OrbitLR.
    static func loadModel(_ name: String) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let m = cache[name] { return m }
        let fm = FileManager.default
        let compiledDir = Paths.support.appendingPathComponent("Models", isDirectory: true)
        let compiled = compiledDir.appendingPathComponent("\(name).mlmodelc")
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let stamp = compiledDir.appendingPathComponent("\(name).version")
        let ready = fm.fileExists(atPath: compiled.path)
            && (try? String(contentsOf: stamp, encoding: .utf8)) == version
        if !ready {
            guard let pkg = Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models")
                    ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
                throw NativeError("Manca il modello di IA nell’app")
            }
            let tmp = try MLModel.compileModel(at: pkg)
            try fm.createDirectory(at: compiledDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: tmp, to: compiled)
            try? version.write(to: stamp, atomically: true, encoding: .utf8)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try MLModel(contentsOf: compiled, configuration: config)
        cache[name] = m
        return m
    }

    // MARK: Riquadri

    private static func upscale4(_ img: CIImage, width w: Int, height h: Int, model: MLModel,
                                 progress: @escaping (Double) -> Void) throws -> CGImage {
        let step = tile - pad * 2
        let ow = w * scale, oh = h * scale
        guard let out = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NativeError("L’immagine è troppo grande per la memoria disponibile")
        }
        // I bordi dell'immagine si «allungano»: i riquadri sui lati hanno sempre qualcosa da guardare
        let extended = img.clampedToExtent()
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "output"
        let cols = Int(ceil(Double(w) / Double(step))), rows = Int(ceil(Double(h) / Double(step)))
        let total = max(cols * rows, 1)
        var done = 0
        guard let buffer = makeBuffer(tile, tile) else { throw NativeError("Memoria insufficiente") }

        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = c * step, y0 = r * step
                let region = CGRect(x: x0 - pad, y: y0 - pad, width: tile, height: tile)
                let piece = extended.cropped(to: region)
                    .transformed(by: CGAffineTransform(translationX: CGFloat(pad - x0), y: CGFloat(pad - y0)))
                ci.render(piece, to: buffer, bounds: CGRect(x: 0, y: 0, width: tile, height: tile),
                          colorSpace: CGColorSpaceCreateDeviceRGB())
                let inFeatures = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
                let result = try model.prediction(from: inFeatures)
                guard let outBuffer = result.featureValue(for: outputName)?.imageBufferValue else {
                    throw NativeError("Il modello di IA non ha restituito un’immagine")
                }
                // Dal riquadro ingrandito si tiene solo il centro (senza il bordo di sovrapposizione)
                let keepW = min(step, w - x0), keepH = min(step, h - y0)
                let crop = CGRect(x: pad * scale, y: pad * scale, width: keepW * scale, height: keepH * scale)
                let piece4 = CIImage(cvPixelBuffer: outBuffer).cropped(to: crop)
                if let cg = ci.createCGImage(piece4, from: crop) {
                    out.draw(cg, in: CGRect(x: x0 * scale, y: y0 * scale, width: keepW * scale, height: keepH * scale))
                }
                done += 1
                progress(0.98 * Double(done) / Double(total))
            }
        }
        guard let image = out.makeImage() else { throw NativeError("Non riesco a ricomporre l’immagine") }
        return image
    }

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }
}
