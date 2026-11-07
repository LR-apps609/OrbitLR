// M01 · Fa le stesse chiamate di NativeEngine.run per le azioni sulle immagini.
// Uso: nativo AZIONE PARAMETRO FILE CARTELLA → «OUT<TAB>percorso», «FAIL<TAB>motivo» o «SKIP<TAB>motivo»
import Foundation

let imageIn: Set<String> = Set(["jpg", "png", "heic", "tiff", "gif", "bmp", "webp",
                                "avif", "psd", "jxl", "jp2", "tga", "exr"]).union(Catalog.rawExts)
let imageOut: Set<String> = ["jpg", "png", "heic", "tiff", "pdf"]
let a = CommandLine.arguments
let id = a[1], param = a[2], file = URL(fileURLWithPath: a[3]), dir = URL(fileURLWithPath: a[4])
let e = Catalog.norm(file.pathExtension)
let base = file.deletingPathExtension().lastPathComponent

// Le stesse regole di NativeEngine.supports (senza ImageMagick sul Mac)
func supported() -> Bool {
    if id.hasPrefix("to:") {
        let t = String(id.dropFirst(3))
        if imageOut.contains(t) { return imageIn.contains(e) }
        if t == "webp" || t == "ico" { return imageIn.contains(e) && e != "gif" }
        return false
    }
    if id == "resize" || id == "icompress" { return imageIn.contains(e) && e != "gif" }
    if id == "strip" { return ["jpg", "heic", "png", "tiff"].contains(e) }
    return false
}
guard supported() else { print("SKIP\tnon passa dal motore nativo"); exit(0) }
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: URL
    switch id {
    case "strip": out = try SmartImage.strip(file, dir: dir)
    case "icompress":
        let kb = Int(param.trimmingCharacters(in: .whitespaces))
        out = try SmartImage.compress(file, targetBytes: kb.map { $0 * 1000 }, dir: dir)
    case "resize":
        var ext = (imageOut.contains(e) && e != "pdf") ? e : "png"
        if Catalog.rawExts.contains(e) || param == "web" { ext = "jpg" }
        let suffix = param == "half" ? "50%" : (param == "web" ? "web" : "\(param)px")
        out = Destination.unique(dir, base: "\(base) (\(suffix))", ext: ext)
        try NativeEngine.convertImage(file, to: ext, resize: param, out: out)
    default:
        let t = String(id.dropFirst(3))
        if t == "webp" || t == "ico" { out = try SmartImage.convertRare(file, to: t, dir: dir) }
        else {
            out = Destination.unique(dir, base: base, ext: t)
            try NativeEngine.convertImage(file, to: t, resize: nil, out: out)
        }
    }
    print("OUT\t\(out.path)")
} catch {
    print("FAIL\t\(error.localizedDescription)")
    exit(1)
}
