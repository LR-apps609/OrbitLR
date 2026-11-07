// M05 · Elenca le finestre a schermo di OrbitLR (id, livello, misura, titolo).
import CoreGraphics
import Foundation
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("OrbitLR") || owner.contains("CoreServicesUIAgent") || owner.contains("UserNotificationCenter") || owner.contains("Gatekeeper") else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let name = w[kCGWindowName as String] as? String ?? ""
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    print("\(id)\t\(owner)\tpid=\(pid)\tlayer=\(layer)\t\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\t\(name)")
}
