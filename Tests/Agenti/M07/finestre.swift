// M07 · Elenco delle finestre di OrbitLR: «id livello x y larghezza altezza titolo», una per riga.
// Con «schermo» stampa la misura dello schermo principale (punti) e il fattore Retina.
import CoreGraphics
import AppKit
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "schermo" {
    if let s = NSScreen.main { print("\(Int(s.frame.width)) \(Int(s.frame.height)) \(s.backingScaleFactor) visibile \(Int(s.visibleFrame.width))x\(Int(s.visibleFrame.height))") }
    exit(0)
}
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let wanted = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "tutte" ? true : owner == "OrbitLR"
    guard wanted, let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let name = (w[kCGWindowName as String] as? String) ?? ""
    print("\(id) \(layer) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0)) \(owner)|\(name)")
}
