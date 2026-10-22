import Foundation

/// Dove l'app tiene i suoi file. Sono gli stessi usati dall'Azione rapida, così le due cose restano allineate.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/LRConverter")
    static let log = home.appendingPathComponent("Library/Logs/LRConverter.log")
    static var installedScript: URL { support.appendingPathComponent("LRConverter.zsh") }
    static var bundledScript: URL? { Bundle.main.url(forResource: "LRConverter", withExtension: "zsh") }
    static var prefs: URL { support.appendingPathComponent("prefs") }
    static var history: URL { support.appendingPathComponent("history.json") }

    /// Il motore usato per le conversioni (lo script testato con --test).
    static var script: URL {
        FileManager.default.fileExists(atPath: installedScript.path) ? installedScript : (bundledScript ?? installedScript)
    }

    /// Copia nella cartella di supporto lo script incluso nell'app, se è diverso.
    /// Così anche l'Azione rapida usa sempre la versione più recente.
    static func installScript() {
        guard let src = bundledScript else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: installedScript), a == b { return }
        try? fm.removeItem(at: installedScript)
        try? fm.copyItem(at: src, to: installedScript)
    }

    /// Cerca un programma nei posti dove lo installano Homebrew e gli installer ufficiali.
    static func tool(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/Applications/LibreOffice.app/Contents/MacOS"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
