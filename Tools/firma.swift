// 3.5.2 · Firma e controllo degli aggiornamenti di OrbitLR (Ed25519, CryptoKit).
//
//   swift Tools/firma.swift manifesto <versione> <build> <app.zip> <NOVITA.txt> <manifest.json>
//   swift Tools/firma.swift firma     <manifest.json> <manifest.sig>        (chiave in ORBITLR_SIGNING_KEY)
//   swift Tools/firma.swift controlla <cartella Firmato> <chiave pubblica base64>…
//
// La chiave privata non viene mai stampata né scritta su disco.
import Foundation
import CryptoKit

func die(_ s: String) -> Never { FileHandle.standardError.write(Data(("ERRORE: " + s + "\n").utf8)); exit(1) }
func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

let a = CommandLine.arguments
guard a.count >= 2 else { die("uso: manifesto | firma | controlla") }

switch a[1] {
case "manifesto":
    guard a.count == 7 else { die("manifesto <versione> <build> <app.zip> <NOVITA.txt> <manifest.json>") }
    guard let app = FileManager.default.contents(atPath: a[4]) else { die("non trovo \(a[4])") }
    let news = (try? String(contentsOfFile: a[5], encoding: .utf8)) ?? ""
    let m: [String: String] = ["version": a[2], "build": a[3], "sha256": sha(app), "news": news]
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    try! enc.encode(m).write(to: URL(fileURLWithPath: a[6]))
    print("Manifesto: \(a[2]) (\(a[3])) · app \(sha(app).prefix(16))…")

case "firma":
    guard a.count == 4 else { die("firma <manifest.json> <manifest.sig>") }
    let raw = (ProcessInfo.processInfo.environment["ORBITLR_SIGNING_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { die("manca il segreto ORBITLR_SIGNING_KEY su GitHub (Settings → Secrets → Actions)") }
    guard let kd = Data(base64Encoded: raw), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: kd) else {
        die("ORBITLR_SIGNING_KEY non è una chiave valida")
    }
    guard let m = FileManager.default.contents(atPath: a[2]) else { die("non trovo \(a[2])") }
    let sig = try! key.signature(for: m)
    try! sig.write(to: URL(fileURLWithPath: a[3]))
    print("Firmato con la chiave pubblica \(key.publicKey.rawRepresentation.base64EncodedString())")

case "controlla":
    guard a.count >= 4 else { die("controlla <cartella Firmato> <chiave pubblica>…") }
    let dir = URL(fileURLWithPath: a[2])
    guard let m = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
          let s = try? Data(contentsOf: dir.appendingPathComponent("manifest.sig")),
          let app = try? Data(contentsOf: dir.appendingPathComponent("app.zip")) else { die("pacchetto firmato incompleto") }
    let keys = a.dropFirst(3).compactMap { Data(base64Encoded: $0) }.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    guard keys.contains(where: { $0.isValidSignature(s, for: m) }) else { die("la firma non corrisponde alle chiavi dell'app") }
    guard let j = try? JSONSerialization.jsonObject(with: m) as? [String: String], j["sha256"] == sha(app) else {
        die("l'impronta dell'app non corrisponde al manifesto")
    }
    print("Firma valida · OrbitLR \(j["version"] ?? "?") (\(j["build"] ?? "?"))")

default:
    die("comando sconosciuto \(a[1])")
}
