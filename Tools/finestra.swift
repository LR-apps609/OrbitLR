// Prova sui dispositivi: il numero della finestra principale di OrbitLR (per «screencapture -l»).
// Stampa «id larghezza altezza» della finestra più grande di OrbitLR, oppure niente.
// 6.0.3 · «--tutte»: anche le finestre sopra le altre (la schedina di benvenuto è un pannello «floating»).
//         «--elenco»: tutte le finestre sullo schermo, di qualsiasi programma (per vedere l'avviso di Gatekeeper).
import CoreGraphics
import Foundation
let args = CommandLine.arguments
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
if args.contains("--elenco") {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let name = w[kCGWindowName as String] as? String ?? ""
        print("\(owner) · livello \(layer) · \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0)) · \(name)")
    }
    exit(0)
}
let anyLayer = args.contains("--tutte")
var best: (Int, Double, Double)? = nil
for w in list where (w[kCGWindowOwnerName as String] as? String) == "OrbitLR" {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Double],
          let wd = b["Width"], let ht = b["Height"], let layer = w[kCGWindowLayer as String] as? Int else { continue }
    // La barra dei menu (livello 25) non conta mai
    guard anyLayer ? (layer < 25 && wd > 100 && ht > 100) : layer == 0 else { continue }
    if best == nil || wd * ht > best!.1 * best!.2 { best = (id, wd, ht) }
}
if let b = best { print("\(b.0) \(Int(b.1)) \(Int(b.2))") }
