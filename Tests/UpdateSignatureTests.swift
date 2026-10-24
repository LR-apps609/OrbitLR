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

/// 3.5.2 · Prova completa del nuovo aggiornatore: un pacchetto vero (zip, cartella «Firmato», app) passa dal
/// controllo come farà sul Mac; uno manomesso no. Così la prima volta che servirà, funzionerà.
final class UpdatePackageEndToEndTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    /// Costruisce «OrbitLR 9.0.orbitlr» come la CI: OrbitLR/Firmato/{app.zip, manifest.json, manifest.sig}.
    private func package(version: String = "9.0", build: String = "900", bundleID: String = "it.ledion.OrbitLR",
                         tamper: Bool = false) throws -> URL {
        let fm = FileManager.default
        let root = Fixtures.dir.appendingPathComponent("pacchetto-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("app/OrbitLR.app/Contents", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleIdentifier": bundleID]
        info.write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        try Data("binario".utf8).write(to: app.appendingPathComponent("MacOS/OrbitLR"))
        let signed = root.appendingPathComponent("OrbitLR/Firmato", isDirectory: true)
        try fm.createDirectory(at: signed, withIntermediateDirectories: true)
        let zip = signed.appendingPathComponent("app.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.appendingPathComponent("app/OrbitLR.app").path, zip.path])
        let payload = try Data(contentsOf: zip)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let m = try JSONEncoder().encode(UpdatePackage.Manifest(version: version, build: build, sha256: sha, news: "Novità della \(version) :\n• prova"))
        try m.write(to: signed.appendingPathComponent("manifest.json"))
        try key.signature(for: m).write(to: signed.appendingPathComponent("manifest.sig"))
        if tamper { try Data("app cambiata".utf8).write(to: zip) }
        let out = Fixtures.dir.appendingPathComponent("OrbitLR \(version)-\(UUID().uuidString).orbitlr")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.appendingPathComponent("OrbitLR").path, out.path])
        return out
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "prova", code: Int(p.terminationStatus)) }
    }

    func testPacchettoGiustoPassa() throws {
        let f = try package()
        let r = try UpdatePackage.prepare(f, current: ("3.5.2", "62"), expectedVersion: "9.0",
                                          keys: [key.publicKey.rawRepresentation.base64EncodedString()])
        XCTAssertEqual(r.manifest.version, "9.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.app.appendingPathComponent("Contents/Info.plist").path))
        try? FileManager.default.removeItem(at: r.work)
    }

    func testPacchettoManomessoNo() throws {
        let f = try package(tamper: true)
        XCTAssertThrowsError(try UpdatePackage.prepare(f, current: ("3.5.2", "62"),
                                                       keys: [key.publicKey.rawRepresentation.base64EncodedString()])) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .tampered)
        }
    }

    func testFirmaDiAltriNo() throws {
        let f = try package()
        // Le chiavi vere dell'app: un pacchetto firmato da un'altra chiave non passa
        XCTAssertThrowsError(try UpdatePackage.prepare(f, current: ("3.5.2", "62"))) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .badSignature)
        }
    }

    func testAltraAppNo() throws {
        let f = try package(bundleID: "com.altra.app")
        XCTAssertThrowsError(try UpdatePackage.prepare(f, current: ("3.5.2", "62"),
                                                       keys: [key.publicKey.rawRepresentation.base64EncodedString()])) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .wrongApp)
        }
    }

    func testVersioneAnnunciataDiversaNo() throws {
        let f = try package()
        XCTAssertThrowsError(try UpdatePackage.prepare(f, current: ("3.5.2", "62"), expectedVersion: "9.1",
                                                       keys: [key.publicKey.rawRepresentation.base64EncodedString()]))
    }

    func testPacchettoVecchioSenzaFirmaNo() throws {
        let root = Fixtures.dir.appendingPathComponent("vecchio-\(UUID().uuidString)/OrbitLR", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Prebuilt"), withIntermediateDirectories: true)
        try "name: OrbitLR".write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        let out = Fixtures.dir.appendingPathComponent("vecchio-\(UUID().uuidString).orbitlr")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, out.path])
        XCTAssertThrowsError(try UpdatePackage.prepare(out, current: ("3.5.2", "62"))) {
            XCTAssertEqual($0 as? UpdatePackage.Failure, .notSigned)
        }
    }
}
