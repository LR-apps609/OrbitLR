import Foundation
import AppKit
import AVFoundation
import Vision
import simd
import CoreImage
import CoreImage.CIFilterBuiltins

// ════════════════════════════════════════════════════════════════════
//  «Unisci più scatti»: più foto della stessa scena (o i fotogrammi di un video breve)
//  vengono allineate e combinate in una sola immagine. Il rumore si riduce e,
//  ingrandendo 2×, i dettagli vengono dai fotogrammi veri: niente di inventato.
//  È lo stesso principio che usano gli smartphone quando scattano.
// ════════════════════════════════════════════════════════════════════

enum Stacker {
    static let maxFrames = 12
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// param: «1» stessa dimensione (meno rumore), «2» 2× (più dettagli)
    static func run(files: [URL], param: String, dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let scale: CGFloat = param == "1" ? 1 : 2
        let first = files[0]
        let isVideo = Catalog.kind(of: first) == .video

        // 1. I fotogrammi
        var frames: [CIImage] = []
        if isVideo {
            frames = try await videoFrames(first, count: 8)
        } else {
            for f in files.prefix(maxFrames) where Catalog.kind(of: f) == .img {
                frames.append(try Tools.orientedImage(f))
            }
        }
        guard frames.count >= 2 else { throw NativeError("Servono almeno 2 foto della stessa scena") }
        frames = frames.map { $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY)) }
        progress(0.1)

        // 2. Il riferimento è il fotogramma centrale; gli altri vengono allineati su di lui
        let refIndex = frames.count / 2
        let ref = frames[refIndex]
        let extent = ref.extent
        var aligned: [CIImage] = [ref]
        for (i, f) in frames.enumerated() where i != refIndex {
            if let a = align(f, to: ref) { aligned.append(a) }
            progress(0.1 + 0.5 * Double(i + 1) / Double(frames.count))
        }
        guard aligned.count >= 2 else { throw NativeError("Le foto sono troppo diverse per essere allineate") }

        // 3. Ingrandimento (se richiesto) e media: il rumore si annulla, i dettagli veri si sommano
        func up(_ img: CIImage) -> CIImage {
            guard scale > 1 else { return img }
            let s = CIFilter.lanczosScaleTransform()
            s.inputImage = img.clampedToExtent().cropped(to: extent)
            s.scale = Float(scale)
            s.aspectRatio = 1
            return s.outputImage ?? img
        }
        var acc = up(aligned[0])
        for (k, img) in aligned.dropFirst().enumerated() {
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = acc
            mix.targetImage = up(img)
            mix.time = Float(1.0 / Double(k + 2))          // media progressiva: ogni scatto pesa uguale
            acc = mix.outputImage ?? acc
        }
        let outRect = CGRect(x: 0, y: 0, width: extent.width * scale, height: extent.height * scale)

        // 4. Un filo di nitidezza: la media ammorbidisce un poco i contorni
        let sharp = CIFilter.unsharpMask()
        sharp.inputImage = acc
        sharp.radius = Float(1.2 * scale)
        sharp.intensity = 0.5
        let result = (sharp.outputImage ?? acc).cropped(to: outRect)
        progress(0.9)

        let base = first.deletingPathExtension().lastPathComponent
        let e = Catalog.norm(first.pathExtension)
        let ext = ["jpg", "png", "heic", "tiff"].contains(e) ? e : "jpg"
        let label = "\(aligned.count) scatti" + (scale > 1 ? " 2×" : "")
        let out = Destination.unique(dir, base: "\(base) (\(label))", ext: ext)
        guard let cg = ci.createCGImage(result, from: outRect) else { throw NativeError("Non riesco a creare l’immagine") }
        try Tools.write(cg, to: out, quality: 0.93)
        progress(1)
        return out
    }

    /// Allinea un fotogramma al riferimento: prima con la prospettiva (mano che si muove un po'),
    /// poi, se il risultato non è credibile, con il solo spostamento.
    private static func align(_ img: CIImage, to ref: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: ref, options: [:])
        let w = ref.extent.width, h = ref.extent.height

        let homo = VNHomographicImageRegistrationRequest(targetedCIImage: img, options: [:])
        if (try? handler.perform([homo])) != nil, let obs = homo.results?.first {
            let m = obs.warpTransform
            func map(_ p: CGPoint) -> CGPoint {
                let v = m * SIMD3<Float>(Float(p.x), Float(p.y), 1)
                return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
            }
            let tl = map(CGPoint(x: 0, y: h)), tr = map(CGPoint(x: w, y: h))
            let bl = map(CGPoint(x: 0, y: 0)), br = map(CGPoint(x: w, y: 0))
            // Credibile se gli angoli si spostano poco (meno del 15% della foto)
            let limit = max(w, h) * 0.15
            let moved = [hypot(tl.x - 0, tl.y - h), hypot(tr.x - w, tr.y - h), hypot(bl.x, bl.y), hypot(br.x - w, br.y)].max() ?? .infinity
            if moved.isFinite && moved < limit {
                let p = CIFilter.perspectiveTransform()
                p.inputImage = img
                p.topLeft = tl
                p.topRight = tr
                p.bottomLeft = bl
                p.bottomRight = br
                if let out = p.outputImage { return out.cropped(to: ref.extent) }
            }
        }

        let shift = VNTranslationalImageRegistrationRequest(targetedCIImage: img, options: [:])
        if (try? handler.perform([shift])) != nil, let obs = shift.results?.first {
            let t = obs.alignmentTransform
            guard abs(t.tx) < w * 0.15, abs(t.ty) < h * 0.15 else { return nil }
            return img.transformed(by: t).cropped(to: ref.extent)
        }
        return nil
    }

    /// Fotogrammi vicini tra loro, dal centro del video (al massimo 2 secondi): stessa scena, piccole differenze.
    private static func videoFrames(_ url: URL, count: Int) async throws -> [CIImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NativeError("Non riesco a leggere il video") }
        let span = min(2.0, duration * 0.8)
        let start = max(0, duration / 2 - span / 2)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var out: [CIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: start + span * Double(i) / Double(max(count - 1, 1)), preferredTimescale: 600)
            if let frame = try? await gen.image(at: t) { out.append(CIImage(cgImage: frame.image)) }
        }
        return out
    }
}
