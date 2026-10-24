import XCTest
import CryptoKit

/// 3.5.2 · Aggiornamenti firmati: si installa solo ciò che è firmato, integro e più nuovo.
final class UpdateSignatureTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var pub: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func manifest(_ version: String, build: String = "100", payload: Data) -> Data {
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let m = UpdatePackage.Manifest(version: version, build: build, sha256: sha, news: "Novità della \(version) :\n• prova")
        return try! JSONEncoder().encode(m)
    }

    func testFirmaGiustaPassa() throws {
        let payload = Data("app".utf8)
        let m = manifest("9.0", payload: payload)
        let sig = try key.signature(for: m)
        let got = try UpdatePackage.verify(manifest: m, signature: sig, payload: payload, current: ("3.5.2", "62"), keys: [pub])
        XCTAssertEqual(got.version, "9.0")
    }

    func testFirmaDiUnAltroNo() throws {
        let payload = Data("app".utf8)
        let m = manifest("9.0", payload: payload)
        let other = Curve25519.Signing.PrivateKey()
        let sig = try other.signature(for: m)
        XCTAssertThrowsError(try UpdatePackage.verify(manifest: m, signature: sig, payload: payload, current: ("3.5.2", "62"), keys: [pub])) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .badSignature)
        }
    }

    func testManifestoCambiatoDopoLaFirmaNo() throws {
        let payload = Data("app".utf8)
        let m = manifest("9.0", payload: payload)
        let sig = try key.signature(for: m)
        let changed = manifest("9.1", payload: payload)
        XCTAssertThrowsError(try UpdatePackage.verify(manifest: changed, signature: sig, payload: payload, current: ("3.5.2", "62"), keys: [pub]))
    }

    func testAppCambiataDopoLaFirmaNo() throws {
        let m = manifest("9.0", payload: Data("app".utf8))
        let sig = try key.signature(for: m)
        XCTAssertThrowsError(try UpdatePackage.verify(manifest: m, signature: sig, payload: Data("app maligna".utf8), current: ("3.5.2", "62"), keys: [pub])) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .tampered)
        }
    }

    func testVersioneVecchiaNo() throws {
        let payload = Data("app".utf8)
        for (v, b) in [("3.4.9", "200"), ("3.5.2", "62")] {
            let m = manifest(v, build: b, payload: payload)
            let sig = try key.signature(for: m)
            XCTAssertThrowsError(try UpdatePackage.verify(manifest: m, signature: sig, payload: payload, current: ("3.5.2", "62"), keys: [pub])) {
                XCTAssertEqual($0 as? UpdatePackage.Failure, .notNewer(v))
            }
        }
        // Stessa versione ripubblicata con un numero di build maggiore: sì
        let m = manifest("3.5.2", build: "63", payload: payload)
        XCTAssertNoThrow(try UpdatePackage.verify(manifest: m, signature: try key.signature(for: m), payload: payload, current: ("3.5.2", "62"), keys: [pub]))
    }

    func testLeChiaviDellAppSonoValide() {
        XCTAssertEqual(UpdatePackage.trustedKeys.count, 2)
        for k in UpdatePackage.trustedKeys {
            let d = Data(base64Encoded: k)
            XCTAssertEqual(d?.count, 32)
            XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: d!))
        }
    }

    func testCollegamentiCheEsconoDallaCartellaNo() throws {
        let fm = FileManager.default
        let root = try UpdatePackage.privateWorkFolder()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("A.app/Contents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("A.app/Interno").path, withDestinationPath: "Contents")
        XCTAssertFalse(UpdatePackage.hasEscapingLinks(root), "un collegamento interno va bene")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("A.app/Fuori").path, withDestinationPath: "../../../../etc")
        XCTAssertTrue(UpdatePackage.hasEscapingLinks(root), "uno che esce no")
        let perms = try fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700, "cartella privata")
    }
}
