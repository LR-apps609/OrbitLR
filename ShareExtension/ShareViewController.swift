import Cocoa
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  Estensione «Condividi» (punto 13)
//  Da Foto, Mail, Safari, Anteprima o dal Finder: Condividi → OrbitLR.
//  L'estensione raccoglie i file, apre OrbitLR e le passa i file: il menu a torta compare subito.
//  I file che non hanno un percorso proprio (es. foto da Foto) vengono copiati in Download/OrbitLR,
//  così anche i risultati finiscono lì.
// ════════════════════════════════════════════════════════════════════

final class ShareViewController: NSViewController {
    private let lock = NSLock()
    private var paths: [String] = []

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 96))
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.frame = NSRect(x: 20, y: 24, width: 48, height: 48)
        let title = NSTextField(labelWithString: "Apro OrbitLR…")
        title.font = .boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 80, y: 50, width: 200, height: 20)
        let sub = NSTextField(labelWithString: "Il menu a torta compare tra un istante.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 80, y: 30, width: 210, height: 16)
        v.addSubview(icon)
        v.addSubview(title)
        v.addSubview(sub)
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collect()
    }

    private func collect() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let tmp = Self.inbox
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let group = DispatchGroup()

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    var url = item as? URL
                    if url == nil, let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    if let u = url, let path = Self.pass(u, into: tmp) { self?.add(path) }
                    group.leave()
                }
            } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                // Foto, PDF o video passati come dati: si copiano (il file temporaneo sparisce subito dopo)
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                    if let u = url, let path = Self.copy(u, into: tmp, name: p.suggestedName) { self?.add(path) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if !self.paths.isEmpty {
                var c = URLComponents()
                c.scheme = "orbitlr"
                c.host = "open"
                c.queryItems = self.paths.map { URLQueryItem(name: "f", value: $0) }
                if let link = c.url { NSWorkspace.shared.open(link) }
            }
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    /// Download, nella cartella vera dell'utente (l'estensione ha il permesso per Download). Nessuna sottocartella nuova.
    private static var inbox: URL {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent("Downloads")
    }

    private func add(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    /// Un file vero dell'utente (Scrivania, Documenti…) passa così com'è: il risultato finirà accanto all'originale.
    /// Un file temporaneo di un'altra app viene copiato, perché potrebbe sparire.
    private static func pass(_ u: URL, into tmp: URL) -> String? {
        let p = u.path
        let temporary = p.contains("/Library/") || p.hasPrefix("/private/") || p.hasPrefix("/var/") || p.hasPrefix("/tmp/")
        if !temporary { return p }
        return copy(u, into: tmp, name: nil)
    }

    private static func copy(_ u: URL, into tmp: URL, name: String?) -> String? {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        var fileName = u.lastPathComponent
        // 3.5.2 · Il nome proposto da un'altra app: solo il nome, mai un percorso
        let name = name.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-") }
            .map { $0.hasPrefix(".") ? "File" + $0 : $0 }
        if let name, !name.isEmpty {
            fileName = (name as NSString).pathExtension.isEmpty && !u.pathExtension.isEmpty ? name + "." + u.pathExtension : name
        }
        var dest = tmp.appendingPathComponent(fileName)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = tmp.appendingPathComponent("\((fileName as NSString).deletingPathExtension) (\(i)).\(u.pathExtension)")
            i += 1
        }
        do { try FileManager.default.copyItem(at: u, to: dest) } catch { return nil }
        return dest.path
    }
}
