// M01 · Il minimo delle parti dell'app che servono al codice delle immagini (copiato, non cambiato).
import Foundation
import ImageIO

enum Catalog {
    static let rawExts: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef"]
    static func norm(_ e: String) -> String {
        switch e.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        default: return e.lowercased()
        }
    }
}
enum Job {
    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
enum AppLanguage { static var active = "it"; static var subfolder: String { "Convertiti" } }
enum ScriptPrefs { static func load() -> [String: String] { [:] } }
enum FileTag { static func t(_ it: String) -> String { it } }
enum Paths {
    static func tool(_ name: String) -> String? {
        for d in ["/Applications/OrbitLR.app/Contents/Resources/Motori", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
