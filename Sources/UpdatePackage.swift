import Foundation
import CryptoKit

// ════════════════════════════════════════════════════════════════════
//  3.5.2 · Aggiornamenti firmati.
//  Ogni pacchetto .orbitlr contiene, nella cartella «Firmato»:
//    • app.zip        l'app pronta
//    • manifest.json  versione, numero di build, impronta SHA-256 di app.zip, novità
//    • manifest.sig   la firma Ed25519 di manifest.json
//  La chiave privata vive solo nei segreti di GitHub (e una di riserva offline):
//  OrbitLR installa un aggiornamento solo se la firma torna con una delle chiavi qui sotto,
//  se l'impronta dell'app torna, e se la versione è più nuova di quella installata.
// ════════════════════════════════════════════════════════════════════

enum UpdatePackage {
    /// Le chiavi pubbliche di cui OrbitLR si fida: la principale (GitHub) e quella di riserva (offline).
    static let trustedKeys: [String] = [
        "xOzQ8TT6IqdlLtj8FQnyLAelvSBtXehmmkPAArIsVis=",
        "Nr/1zqg8DjVw1zAVnbZbHPHNya+soZ83wNB9zLhCung=",
    ]

    struct Manifest: Codable, Equatable {
        let version: String
        let build: String
        let sha256: String
        var news: String = ""
    }

    enum Failure: Error, Equatable {
        case notSigned, badSignature, badManifest, tampered, notNewer(String), wrongApp

        /// Il messaggio per l'utente: semplice e senza gergo.
        var message: String {
            switch self {
            case .notSigned:
                return String(localized: "Questo aggiornamento non è firmato da OrbitLR. Per sicurezza non lo installo: scaricalo solo dalla pagina ufficiale.")
            case .badSignature:
                return String(localized: "La firma di questo aggiornamento non è quella di OrbitLR. Per sicurezza non lo installo.")
            case .badManifest:
                return String(localized: "Questo file non è un aggiornamento di OrbitLR valido.")
            case .tampered:
                return String(localized: "Questo aggiornamento è stato modificato dopo la firma. Per sicurezza non lo installo.")
            case .notNewer(let v):
                return String(localized: "Questo aggiornamento (\(v)) non è più nuovo della versione che hai: non serve installarlo.")
            case .wrongApp:
                return String(localized: "L'app dentro l'aggiornamento non corrisponde a quella firmata. Per sicurezza non la installo.")
            }
        }
    }

    /// Verifica firma e impronta. Restituisce il manifesto se tutto torna.
    static func verify(manifest data: Data, signature: Data, payload: Data,
                       current: (version: String, build: String),
                       keys: [String] = trustedKeys) throws -> Manifest {
        let pubs = keys.compactMap { Data(base64Encoded: $0) }.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard !pubs.isEmpty else { throw Failure.badSignature }
        guard pubs.contains(where: { $0.isValidSignature(signature, for: data) }) else { throw Failure.badSignature }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data), !m.version.isEmpty else { throw Failure.badManifest }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == m.sha256.lowercased() else { throw Failure.tampered }
        guard isNewer(m, than: current) else { throw Failure.notNewer(m.version) }
        return m
    }

    /// Più nuova: versione maggiore, oppure stessa versione con numero di build maggiore (ripubblicazione).
    static func isNewer(_ m: Manifest, than current: (version: String, build: String)) -> Bool {
        if News.newer(m.version, than: current.version) { return true }
        if m.version == current.version, let a = Int(m.build), let b = Int(current.build), a > b { return true }
        return false
    }

    /// L'identità dell'app: un aggiornamento deve contenere proprio OrbitLR.
    static let bundleID = "it.ledion.OrbitLR"

    struct Prepared { let manifest: Manifest; let app: URL; let work: URL }

    /// Tutto il controllo di un pacchetto, senza finestre (si prova nei test):
    /// estrazione in una cartella privata, firma, impronta, versione, poi l'app estratta dai byte già verificati.
    /// In caso di problema la cartella di lavoro viene cancellata.
    static func prepare(_ file: URL, current: (version: String, build: String), expectedVersion: String? = nil,
                        keys: [String] = trustedKeys, bundleID: String = bundleID) throws -> Prepared {
        let dir = try privateWorkFolder()
        do {
            let outer = dir.appendingPathComponent("pacchetto", isDirectory: true)
            guard ditto(["-x", "-k", file.path, outer.path]), !hasEscapingLinks(outer) else { throw Failure.badManifest }
            guard let signed = findSigned(outer),
                  let manifestData = try? Data(contentsOf: signed.appendingPathComponent("manifest.json")),
                  let sig = try? Data(contentsOf: signed.appendingPathComponent("manifest.sig")),
                  let payload = try? Data(contentsOf: signed.appendingPathComponent("app.zip")) else {   // in memoria: nessuno può cambiarli dopo il controllo
                throw Failure.notSigned
            }
            let m = try verify(manifest: manifestData, signature: sig, payload: payload, current: current, keys: keys)
            if let expectedVersion, expectedVersion != m.version { throw Failure.wrongApp }
            // L'app si estrae dai byte già verificati, mai dal file che potrebbe cambiare nel frattempo
            let zip = dir.appendingPathComponent("app-verificata.zip")
            let appDir = dir.appendingPathComponent("app", isDirectory: true)
            try payload.write(to: zip, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: outer)                  // il pacchetto esterno non serve più
            guard ditto(["-x", "-k", zip.path, appDir.path]), !hasEscapingLinks(appDir) else { throw Failure.badManifest }
            let app = appDir.appendingPathComponent("OrbitLR.app")
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleShortVersionString"] as? String == m.version,
                  info?["CFBundleVersion"] as? String == m.build,
                  info?["CFBundleIdentifier"] as? String == bundleID else { throw Failure.wrongApp }
            return Prepared(manifest: m, app: app, work: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// La cartella «Firmato» dentro il pacchetto (al primo o al secondo livello).
    static func findSigned(_ dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("Firmato")
        if fm.fileExists(atPath: direct.appendingPathComponent("manifest.json").path) { return direct }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for s in subs {
            let f = s.appendingPathComponent("Firmato")
            if fm.fileExists(atPath: f.appendingPathComponent("manifest.json").path) { return f }
        }
        return nil
    }

    private static func ditto(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Una cartella di lavoro nuova, visibile solo a chi usa il Mac (permessi 700), con nome imprevedibile.
    static func privateWorkFolder() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OrbitLR-aggiornamento-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Vero se dentro `root` c'è un collegamento che porta fuori da `root` (o un nome con «..»).
    static func hasEscapingLinks(_ root: URL) -> Bool {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return true }
        for case let u as URL in e {
            if u.lastPathComponent == ".." { return true }
            let isLink = (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard isLink else { continue }
            // Dove porta il collegamento, calcolato sul testo (vale anche se la destinazione non esiste)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: u.path) else { return true }
            let abs = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                                          : u.deletingLastPathComponent().appendingPathComponent(dest)
            let target = abs.standardizedFileURL.path
            if !(target == rootPath || target.hasPrefix(rootPath + "/")) { return true }
        }
        return false
    }
}
