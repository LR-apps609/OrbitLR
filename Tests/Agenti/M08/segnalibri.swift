// M08 · Scrive un progetto video di OrbitLR con clip e segnalibri veri (per la prova del disco scollegato).
// Uso: swift segnalibri.swift <uscita.json> <file...>
import Foundation
let a = CommandLine.arguments
var clips: [[String: Any]] = []
for p in a.dropFirst(2) {
    let u = URL(fileURLWithPath: p)
    let b = (try? u.bookmarkData())?.base64EncodedString()
    var c: [String: Any] = ["id": UUID().uuidString, "path": p, "inPoint": 0.0, "outPoint": 5.0]
    if let b { c["bookmark"] = b }
    clips.append(c)
}
let proj: [String: Any] = ["name": "M08 disco", "clips": clips, "originalVolume": 1.0, "originalMuted": false,
                           "aspect": "orig", "follow": true, "resolution": 1080, "fps": 30]
let d = try! JSONSerialization.data(withJSONObject: proj)
try! d.write(to: URL(fileURLWithPath: a[1]))
print("clip: \(clips.count), con segnalibro: \(clips.filter { $0["bookmark"] != nil }.count)")
