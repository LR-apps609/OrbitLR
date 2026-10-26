import Foundation
import AppKit

struct ComponentInfo: Identifiable {
    let id: String
    let name: String
    let tool: String
    let brew: String          // nome per Homebrew; «--cask …» per le app
    let purpose: String
    let unlocks: String
    var installed: Bool { Paths.tool(tool) != nil }
}

/// Installa i programmi mancanti con Homebrew, dentro l'app, mostrando cosa sta succedendo.
final class Installer: ObservableObject, @unchecked Sendable {
    static let shared = Installer()

    @Published var running: String? = nil        // id del componente in installazione (o "all")
    @Published var lines: [String] = []
    @Published var lastResult: String? = nil
    @Published var refresh = 0
    private var process: Process?

    /// 3.8 · ffmpeg viaggia dentro l'app; compressione PDF, metadati e trascrizione usano macOS.
    /// Restano facoltativi solo i programmi per i formati più rari.
    let components: [ComponentInfo] = [
        ComponentInfo(id: "ffmpeg", name: String(localized: "ffmpeg (incluso)"), tool: "ffmpeg", brew: "ffmpeg", purpose: String(localized: "Audio e video"),
                      unlocks: String(localized: "MP3, FLAC, OGG, MKV, WEBM, WebP, ICO, velocità, sottotitoli: già dentro OrbitLR")),
        ComponentInfo(id: "soffice", name: String(localized: "LibreOffice (facoltativo)"), tool: "soffice", brew: "--cask libreoffice", purpose: String(localized: "Documenti, fogli, presentazioni"),
                      unlocks: "Word, Excel, PowerPoint, Pages, Numbers, Keynote ↔ PDF"),
        ComponentInfo(id: "pandoc", name: String(localized: "pandoc (facoltativo)"), tool: "pandoc", brew: "pandoc", purpose: String(localized: "Testo e web"),
                      unlocks: "Markdown, HTML, EPUB"),
        ComponentInfo(id: "magick", name: String(localized: "ImageMagick (facoltativo)"), tool: "magick", brew: "imagemagick", purpose: String(localized: "Immagini rare"),
                      unlocks: String(localized: "SVG e formati di immagine poco comuni")),
    ]

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// Programmi che OrbitLR non chiede più (ci pensa macOS), ma che il motore classico usa ancora se ci sono.
    let legacy: [ComponentInfo] = [
        ComponentInfo(id: "gs", name: "Ghostscript", tool: "gs", brew: "ghostscript", purpose: "PDF", unlocks: String(localized: "Compressione dei PDF (motore classico)")),
        ComponentInfo(id: "exiftool", name: "ExifTool", tool: "exiftool", brew: "exiftool", purpose: String(localized: "Privacy"), unlocks: String(localized: "Metadati (motore classico)")),
        ComponentInfo(id: "whisper", name: "Whisper", tool: "whisper-cli", brew: "whisper-cpp", purpose: String(localized: "Trascrizione"), unlocks: String(localized: "Trascrizione (motore classico)")),
    ]
    var all: [ComponentInfo] { components + legacy }
    var missing: [ComponentInfo] { components.filter { !$0.installed } }

    func install(_ list: [ComponentInfo], id: String) {
        guard running == nil, let brew = brewPath, !list.isEmpty else { return }
        running = id
        lastResult = nil
        lines = [String(localized: "Avvio dell’installazione…")]

        let formulas = list.filter { !$0.brew.hasPrefix("--cask") }.map { $0.brew }
        let casks = list.filter { $0.brew.hasPrefix("--cask") }.map { $0.brew.replacingOccurrences(of: "--cask ", with: "") }
        var script = ""
        if !formulas.isEmpty { script += "\"\(brew)\" install \(formulas.joined(separator: " ")); " }
        if !casks.isEmpty { script += "\"\(brew)\" install --cask \(casks.joined(separator: " ")); " }
        script += "true"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { continue }
                DispatchQueue.main.async {
                    self?.lines.append(line)
                    if (self?.lines.count ?? 0) > 400 { self?.lines.removeFirst(100) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                self.process = nil
                let still = list.filter { !$0.installed }
                let names = still.map { $0.name }.joined(separator: ", ")
                self.lastResult = still.isEmpty ? String(localized: "Installazione completata ✓")
                    : String(localized: "Non installati: \(names). Dettagli qui sotto.")
                xattrClear()
                self.refresh += 1
            }
        }
        process = p
        do { try p.run() } catch {
            running = nil
            lastResult = String(localized: "Non riesco ad avviare Homebrew")
        }
    }

    func cancel() { process?.terminate() }

    /// Homebrew stesso va installato nel Terminale, perché chiede la password del Mac.
    func installHomebrewInTerminal() {
        let cmd = "/bin/bash -c \\\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\""
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
    }
}

/// LibreOffice appena installato: toglie il blocco di sicurezza, così parte senza chiedere.
private func xattrClear() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    p.arguments = ["-dr", "com.apple.quarantine", "/Applications/LibreOffice.app"]
    try? p.run()
}
