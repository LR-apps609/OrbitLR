import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  3.6 · Foto più leggere, qualità prima di tutto.
//  • «Stessa qualità, meno peso»: si ricomprime solo quanto basta perché a occhio resti identica.
//  • «Sotto X KB» (moduli, documenti, visti): si cerca la qualità più alta che ci sta,
//    e la misura scende solo se nemmeno una buona qualità basterebbe.
//  Le foto si raddrizzano; per i pesi fissi (che si caricano su siti e moduli) via i dati personali.
// ════════════════════════════════════════════════════════════════════

enum SmartImage {
    /// La qualità sotto cui non si scende prima di rimpicciolire (sotto si vedono i quadretti).
    static let minQuality = 0.6

    struct Result: Equatable { let data: Data; let quality: Double; let longSide: Int }

    /// Comprime `src` e scrive in `dir`. `targetBytes` nil = stessa qualità, meno peso.
    static func compress(_ src: URL, targetBytes: Int?, dir: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw NativeError("non riesco a leggere l’immagine")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let long = max(w, h)
        guard long > 0 else { throw NativeError("dimensioni dell’immagine non valide") }
        let base = src.deletingPathExtension().lastPathComponent
        let e = Catalog.norm(src.pathExtension)
        let original = Job.size(of: src)

        if let target = targetBytes {
            if original > 0, original <= Int64(target), e == "jpg" {
                throw NativeError("«\(src.lastPathComponent)» pesa già meno di \(kb(target)): non serve comprimerla")
            }
            guard let r = try fit(source, longSide: long, target: target) else {
                throw NativeError("non riesco a farla stare in \(kb(target)) senza rovinarla: scegli un peso un po’ maggiore")
            }
            let out = Destination.unique(dir, base: "\(base) (\(kb(target)))", ext: "jpg")
            try r.data.write(to: out)
            return out
        }

        // Un'immagine con parti trasparenti (logo, icona) diventando JPEG le perderebbe: meglio dirlo
        if (props[kCGImagePropertyHasAlpha] as? Bool) == true, e == "png" || e == "tiff" || e == "webp" {
            throw NativeError("«\(src.lastPathComponent)» ha parti trasparenti: per non perderle resta com'è. Per alleggerirla usa «Ridimensiona» o un peso preciso")
        }
        // Stessa qualità: JPEG resta JPEG, HEIC resta HEIC; il resto diventa JPEG di alta qualità
        let format: UTType = e == "heic" ? .heic : .jpeg
        let q = e == "heic" ? 0.72 : 0.82
        guard let img = image(source, longSide: long),
              let data = encode(img, as: format, quality: q, metadata: cleanMetadata(props, keepPersonal: true)) else {
            throw NativeError("non riesco a comprimere l’immagine")
        }
        if original > 0, Int64(data.count) >= original * 9 / 10 {
            throw NativeError("«\(src.lastPathComponent)» è già compressa al meglio: ricomprimerla la peggiorerebbe senza farla pesare meno")
        }
        let out = Destination.unique(dir, base: "\(base) (più leggera)", ext: format == .heic ? "heic" : "jpg")
        try data.write(to: out)
        return out
    }

    /// La qualità più alta e la misura più grande che stanno sotto `target`.
    static func fit(_ source: CGImageSource, longSide: Int, target: Int) throws -> Result? {
        var side = Double(longSide)
        var best: Result? = nil
        while side >= 160 {
            guard let img = image(source, longSide: Int(side)) else { return nil }
            // Ricerca della qualità: 7 passi bastano per arrivare a meno di 1% dal massimo
            var lo = 0.3, hi = 0.95
            var found: Result? = nil
            if let d = encode(img, as: .jpeg, quality: hi, metadata: [:]), d.count <= target {
                found = Result(data: d, quality: hi, longSide: Int(side))
            } else {
                for _ in 0..<7 {
                    let mid = (lo + hi) / 2
                    if let d = encode(img, as: .jpeg, quality: mid, metadata: [:]), d.count <= target {
                        found = Result(data: d, quality: mid, longSide: Int(side)); lo = mid
                    } else { hi = mid }
                }
            }
            if let f = found {
                if f.quality >= minQuality { return f }            // buona qualità alla misura più grande possibile
                if best == nil { best = f }                        // ci sta, ma solo con qualità bassa: si prova più piccola
            }
            side *= 0.85
        }
        return best
    }

    // MARK: Strumenti

    /// L'immagine raddrizzata, al lato lungo scelto (mai ingrandita), con un buon ricampionamento.
    static func image(_ source: CGImageSource, longSide: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, longSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        // Il JPEG non ha trasparenza: lo sfondo diventa bianco (come vuole qualunque modulo)
        if img.alphaInfo == .none || img.alphaInfo == .noneSkipLast || img.alphaInfo == .noneSkipFirst { return img }
        return NativeEngine.flatten(img) ?? img
    }

    static func encode(_ img: CGImage, as type: UTType, quality: Double, metadata: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var opts = metadata
        opts[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(d, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return nil }
        return data as Data
    }

    /// I dati della foto: orientamento già applicato; i dati personali solo se richiesto.
    static func cleanMetadata(_ props: [CFString: Any], keepPersonal: Bool) -> [CFString: Any] {
        guard keepPersonal else { return [:] }
        var m = props
        m[kCGImagePropertyOrientation] = 1
        if var tiff = m[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            m[kCGImagePropertyTIFFDictionary] = tiff
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { m.removeValue(forKey: k) }
        return m
    }

    // MARK: 3.8 · Rimuovi i metadati, senza perdita

    /// Copia della foto senza posizione, data, modello, autore e altri dati personali.
    /// L'immagine non viene ricompressa (JPEG e HEIC restano identici punto per punto); l'orientamento resta.
    static func strip(_ src: URL, dir: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw NativeError("non riesco a leggere l’immagine")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let base = src.deletingPathExtension().lastPathComponent
        let out = Destination.unique(dir, base: "\(base) (senza metadati)", ext: src.pathExtension.isEmpty ? "jpg" : src.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw NativeError("macOS non sa scrivere questo formato")
        }
        // Solo l'orientamento sopravvive: tutto il resto (EXIF, GPS, IPTC, XMP) se ne va
        let meta = CGImageMetadataCreateMutable()
        if let o = props[kCGImagePropertyOrientation] as? Int {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFNumber)
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var err: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(dest, source, opts as CFDictionary, &err) {
            // Formati che non si copiano senza ricomprimere: si riscrive l'immagine, senza dati
            try? FileManager.default.removeItem(at: out)
            guard let d2 = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil),
                  let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NativeError("non riesco a togliere i metadati") }
            var p: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
            if let o = props[kCGImagePropertyOrientation] { p[kCGImagePropertyOrientation] = o }
            CGImageDestinationAddImage(d2, img, p as CFDictionary)
            guard CGImageDestinationFinalize(d2) else { throw NativeError("non riesco a togliere i metadati") }
        }
        return out
    }

    // MARK: 3.8 · WebP e ICO senza ImageMagick (foto sempre dritte)

    /// macOS raddrizza la foto; poi la scrive lui se sa farlo, altrimenti l'ffmpeg incluso in OrbitLR.
    static func convertRare(_ src: URL, to ext: String, dir: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw NativeError("non riesco a leggere l’immagine") }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let long = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let side = ext == "ico" ? min(256, max(16, long)) : max(16, long)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { throw NativeError("non riesco a leggere l’immagine") }
        let out = Destination.unique(dir, base: src.deletingPathExtension().lastPathComponent, ext: ext)
        let type = ext == "ico" ? "com.microsoft.ico" : "org.webmproject.webp"
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if writable.contains(type), let d = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(d), Job.size(of: out) > 0 { return out }
            try? FileManager.default.removeItem(at: out)
        }
        guard let ff = Paths.tool("ffmpeg") else { throw NativeError("per questo formato serve ffmpeg") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { throw NativeError("non riesco a preparare l’immagine") }
        CGImageDestinationAddImage(d, img, nil)
        guard CGImageDestinationFinalize(d) else { throw NativeError("non riesco a preparare l’immagine") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", tmp.path]
        if ext == "webp" { args += ["-c:v", "libwebp", "-quality", "85", "-compression_level", "5"] }
        else { args += ["-vf", "scale=256:256:force_original_aspect_ratio=decrease,pad=256:256:(ow-iw)/2:(oh-ih)/2:color=0x00000000,format=rgba"] }
        p.arguments = args + [out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, Job.size(of: out) > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError("non riesco a creare il file \(ext.uppercased())")
        }
        return out
    }

    /// «200 KB», «1 MB».
    static func kb(_ bytes: Int) -> String {
        bytes >= 1_000_000 && bytes % 1_000_000 == 0 ? "\(bytes / 1_000_000) MB" : "\(bytes / 1000) KB"
    }
}
