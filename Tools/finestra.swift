// Prova sui dispositivi: il numero della finestra principale di OrbitLR (per «screencapture -l»).
// Stampa «id larghezza altezza» della finestra più grande di OrbitLR, oppure niente.
import CoreGraphics
import Foundation
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (Int, Double, Double)? = nil
for w in list where (w[kCGWindowOwnerName as String] as? String) == "OrbitLR" {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Double],
          let wd = b["Width"], let ht = b["Height"], (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    if best == nil || wd * ht > best!.1 * best!.2 { best = (id, wd, ht) }
}
if let b = best { print("\(b.0) \(Int(b.1)) \(Int(b.2))") }
