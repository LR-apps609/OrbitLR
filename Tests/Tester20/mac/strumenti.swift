// Tester20 · Mac · piccoli strumenti per il banco di prova (non toccano l'app).
//   finestre [tutte]            → «id livello x y l a proprietario|titolo» delle finestre di OrbitLR
//   schermo                     → misura dello schermo principale
//   meta <file>                 → JSON con le proprietà ImageIO (GPS, EXIF, misura, tipo)
//   foto <uscita> <l> <a> [gps] → crea una foto (tipo dall'estensione: heic/jpg/png/tiff) con sfumature e, se chiesto, GPS
//   logo <uscita.png> <l>       → un logo semplice (cerchio + barra) su sfondo bianco, per SVG e rimozione sfondo
//   ax <pid> [uscita.json]      → controlli senza nome (AXUIElement); exit 3 se il processo non è autorizzato
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices
import PDFKit

let args = CommandLine.arguments
func die(_ s: String, _ code: Int32 = 1) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(code) }
guard args.count > 1 else { die("comando?") }

func windows(all: Bool) {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
        guard all || owner == "OrbitLR", let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        let name = (w[kCGWindowName as String] as? String) ?? ""
        print("\(id) \(layer) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0)) \(owner)|\(name)")
    }
}

func makeImage(_ w: Int, _ h: Int, logo: Bool) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if logo {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.1, alpha: 1))
        let s = Double(min(w, h))
        ctx.fillEllipse(in: CGRect(x: s * 0.2, y: s * 0.2, width: s * 0.6, height: s * 0.6))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: s * 0.1, y: s * 0.45, width: s * 0.8, height: s * 0.1))
    } else {
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1),
                                                    CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 3, y: h / 3, width: w / 3, height: h / 3))
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, to path: String, gps: Bool) {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    let type: UTType = ext == "heic" ? .heic : ext == "png" ? .png : (ext == "tif" || ext == "tiff") ? .tiff : .jpeg
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { die("destinazione") }
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"]
    props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:08:15 10:30:00",
                                             kCGImagePropertyExifUserComment: "Tester20"]
    if gps {
        props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 40.8518, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 14.2681, kCGImagePropertyGPSLongitudeRef: "E",
                                                kCGImagePropertyGPSAltitude: 17.0]
    }
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    guard CGImageDestinationFinalize(d) else { die("scrittura non riuscita: \(path)") }
}

func meta(_ path: String) {
    var out: [String: Any] = ["file": path]
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        out["errore"] = "non leggibile"; print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!); return
    }
    out["tipo"] = CGImageSourceGetType(src) as String? ?? ""
    out["immagini"] = CGImageSourceGetCount(src)
    if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        out["larghezza"] = p[kCGImagePropertyPixelWidth] ?? 0
        out["altezza"] = p[kCGImagePropertyPixelHeight] ?? 0
        out["alfa"] = p[kCGImagePropertyHasAlpha] ?? false
        out["orientamento"] = p[kCGImagePropertyOrientation] ?? 1
        out["gps"] = (p[kCGImagePropertyGPSDictionary] as? [CFString: Any]).map { !$0.isEmpty } ?? false
        out["gps_dati"] = (p[kCGImagePropertyGPSDictionary] as? [CFString: Any])?.keys.map { $0 as String } ?? []
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        out["modello"] = tiff?[kCGImagePropertyTIFFModel] as? String ?? ""
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        out["data_scatto"] = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
    }
    // pixel trasparenti agli angoli (per «Rimuovi lo sfondo»)
    if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let data = ctx.data {
            let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }
            out["alfa_angoli"] = [alpha(1, 1), alpha(w - 2, 1), alpha(1, h - 2), alpha(w - 2, h - 2)]
            out["alfa_centro"] = alpha(w / 2, h / 2)
        }
    }
    print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
}

func axAudit(pid: pid_t, out: String?) {
    let trusted = AXIsProcessTrusted()
    if !trusted { print("{\"autorizzato\":false}"); exit(3) }
    let app = AXUIElementCreateApplication(pid)
    var rows: [[String: Any]] = []
    var visited = 0
    func attr(_ e: AXUIElement, _ a: String) -> Any? {
        var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    func walk(_ e: AXUIElement, _ depth: Int, _ path: String) {
        visited += 1
        guard depth < 40, visited < 6000 else { return }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
        let help = attr(e, kAXHelpAttribute) as? String ?? ""
        let label = attr(e, "AXLabel") as? String ?? ""
        let ident = attr(e, "AXIdentifier") as? String ?? ""
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTextField",
                                     "AXMenuButton", "AXComboBox", "AXIncrementor", "AXDisclosureTriangle", "AXSegmentedControl"]
        if controls.contains(role) {
            var valueText = ""
            if let v = attr(e, kAXValueAttribute) { valueText = "\(v)" }
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = attr(e, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = attr(e, kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            rows.append(["ruolo": role, "titolo": title, "descrizione": desc, "aiuto": help, "etichetta": label,
                         "id": ident, "valore": String(valueText.prefix(60)), "percorso": path,
                         "x": Int(pos.x), "y": Int(pos.y), "l": Int(size.width), "a": Int(size.height),
                         "senza_nome": title.isEmpty && desc.isEmpty && label.isEmpty])
        }
        if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
            for (i, k) in kids.enumerated() { walk(k, depth + 1, path + "/" + (role.isEmpty ? "?" : role) + "[\(i)]") }
        }
    }
    if let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
        for (i, w) in wins.enumerated() { walk(w, 0, "W\(i)") }
    }
    if let mb = attr(app, kAXMenuBarAttribute) { _ = mb }
    let res: [String: Any] = ["autorizzato": true, "elementi_visitati": visited, "controlli": rows]
    let data = try! JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys])
    if let out { try! data.write(to: URL(fileURLWithPath: out)) } else { print(String(data: data, encoding: .utf8)!) }
}

switch args[1] {
case "finestre": windows(all: args.count > 2 && args[2] == "tutte")
case "schermo":
    if let s = NSScreen.main { print("\(Int(s.frame.width)) \(Int(s.frame.height)) \(s.backingScaleFactor) \(Int(s.visibleFrame.width)) \(Int(s.visibleFrame.height))") }
case "meta": meta(args[2])
case "foto": write(makeImage(Int(args[3])!, Int(args[4])!, logo: false), to: args[2], gps: args.count > 5 && args[5] == "gps")
case "logo": write(makeImage(Int(args[3])!, Int(args[3])!, logo: true), to: args[2], gps: false)
case "ax": axAudit(pid: pid_t(Int32(args[2])!), out: args.count > 3 ? args[3] : nil)
case "pagine":
    guard let d = PDFDocument(url: URL(fileURLWithPath: args[2])) else { print("-1"); exit(1) }
    print(d.isLocked ? -2 : d.pageCount)
case "premi":
    // premi <pid> <testo>: AXPress sul primo elemento con quel titolo/descrizione/valore; per le righe di un elenco: AXSelected
    let app = AXUIElementCreateApplication(pid_t(Int32(args[2])!))
    let want = args[3]
    func at(_ e: AXUIElement, _ a: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
    var n = 0
    func find(_ e: AXUIElement, _ parents: [AXUIElement]) -> Bool {
        n += 1; if n > 8000 { return false }
        let t = [at(e, kAXTitleAttribute), at(e, kAXDescriptionAttribute), at(e, kAXValueAttribute)].compactMap { $0 as? String }
        if t.contains(want) {
            if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { print("premuto \(at(e, kAXRoleAttribute) ?? "")"); return true }
            for p in ([e] + parents.reversed()) where (at(p, kAXRoleAttribute) as? String) == "AXRow" {
                if AXUIElementSetAttributeValue(p, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { print("riga selezionata"); return true }
            }
        }
        for k in (at(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if find(k, parents + [e]) { return true } }
        return false
    }
    var done = false
    for w in (at(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where !done { done = find(w, []) }
    if !done { print("non trovato"); exit(2) }
case "testi":
    // testi <pid>: tutti i titoli, valori e descrizioni visibili nelle finestre (per sapere cosa mostra l'app)
    let app = AXUIElementCreateApplication(pid_t(Int32(args[2])!))
    func at(_ e: AXUIElement, _ a: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
    var n = 0
    var seen = Set<String>()
    func walk(_ e: AXUIElement) {
        n += 1; if n > 8000 { return }
        for a in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let t = at(e, a) as? String, !t.isEmpty, seen.insert(t).inserted { print(t.replacingOccurrences(of: "\n", with: " ")) }
        }
        for k in (at(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(k) }
    }
    for w in (at(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { print("[finestra \(at(w, kAXTitleAttribute) as? String ?? "")]"); walk(w) }
case "fiducia": print(AXIsProcessTrusted() ? "si" : "no")
case "servizio":
    // Come il menu Servizi del Finder: i file sulla «lavagna» e il servizio chiamato per nome (niente Automazione)
    NSUpdateDynamicServices()
    let pb = NSPasteboard(name: NSPasteboard.Name("t20-servizio-\(getpid())"))
    pb.clearContents()
    let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) as NSURL }
    pb.writeObjects(Array(urls))
    let ok = NSPerformService(args[2], pb)
    print(ok ? "servizio eseguito" : "servizio NON eseguito")
    exit(ok ? 0 : 2)
default: die("comando sconosciuto")
}
