// M01 · Legge un'immagine (o un PDF) con ImageIO e stampa una riga JSON:
// tipo, fotogrammi, misure salvate, orientamento, misure "come si vede", alfa, profondità,
// colori, GPS e dati personali, e il colore dei 4 angoli come si vede (orientamento applicato).
// Uso: ispeziona file…            → una riga JSON per file
//      ispeziona --heic in out    → copia in HEIC con tutti i metadati (per preparare i file di prova)
import Foundation
import CoreGraphics
import ImageIO

func jsonLine(_ d: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--heic" {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImageFromSource(d, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    exit(CGImageDestinationFinalize(d) ? 0 : 1)
}

func corners(_ img: CGImage) -> [[Int]] {
    let w = img.width, h = img.height
    guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
    // punti al 10% dai bordi; righe dall'alto (il contesto ha l'origine in basso: la memoria parte dall'alto)
    let xs = [w / 10, w - 1 - w / 10], ys = [h / 10, h - 1 - h / 10]
    var out: [[Int]] = []
    for y in ys { for x in xs {
        let o = (y * w + x) * 4
        let a = Int(p[o + 3])
        // da premoltiplicato a normale
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int(v) * 255 / a) }
        out.append([un(p[o]), un(p[o + 1]), un(p[o + 2]), a])
    } }
    return out   // alto-sinistra, alto-destra, basso-sinistra, basso-destra
}

for path in args {
    var r: [String: Any] = ["path": path]
    let url = URL(fileURLWithPath: path)
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    r["exists"] = attrs != nil
    r["size"] = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    if let perm = attrs?[.posixPermissions] as? NSNumber { r["perm"] = String(perm.intValue, radix: 8) }
    guard attrs != nil else { print(jsonLine(r)); continue }
    if path.lowercased().hasSuffix(".pdf"), let doc = CGPDFDocument(url as CFURL) {
        r["type"] = "com.adobe.pdf"
        r["pages"] = doc.numberOfPages
        if let pg = doc.page(at: 1) {
            let b = pg.getBoxRect(.mediaBox)
            r["page_w"] = Int(b.width.rounded()); r["page_h"] = Int(b.height.rounded())
            r["page_rot"] = Int(pg.rotationAngle)
        }
        print(jsonLine(r)); continue
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
        r["error"] = "non leggibile"; print(jsonLine(r)); continue
    }
    r["type"] = type as String
    r["frames"] = CGImageSourceGetCount(src)
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let o = props[kCGImagePropertyOrientation] as? Int ?? 1
    r["w"] = w; r["h"] = h; r["orient"] = o
    let swap = o >= 5 && o <= 8
    r["dw"] = swap ? h : w; r["dh"] = swap ? w : h
    r["has_alpha"] = props[kCGImagePropertyHasAlpha] as? Bool ?? false
    r["depth"] = props[kCGImagePropertyDepth] as? Int ?? 0
    r["model"] = props[kCGImagePropertyColorModel] as? String ?? ""
    r["profile"] = props[kCGImagePropertyProfileName] as? String ?? ""
    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    r["gps"] = gps?[kCGImagePropertyGPSLatitude] != nil
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    r["make"] = tiff?[kCGImagePropertyTIFFMake] as? String ?? ""
    r["camera"] = tiff?[kCGImagePropertyTIFFModel] as? String ?? ""
    r["date"] = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
    r["artist"] = tiff?[kCGImagePropertyTIFFArtist] as? String ?? ""
    // Come si vede: miniatura con l'orientamento applicato
    let long = max(w, h)
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: max(1, min(long, 600))]
    if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
        r["corners"] = corners(t)
        r["thumb_w"] = t.width; r["thumb_h"] = t.height
    }
    print(jsonLine(r))
}
