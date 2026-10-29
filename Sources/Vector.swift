import Foundation
import CoreImage
import ImageIO

// ════════════════════════════════════════════════════════════════════
//  4.3 · «Vettoriale (SVG)»: lo stesso motore di OrbitLR per Windows (orbit-vector, scritto in Rust,
//  compilato su GitHub per Apple Silicon e Intel e messo in Resources/Motori).
//  Sulle immagini piccole i bordi si ricostruiscono prima con Real-ESRGAN (Core ML, già nell'app):
//  logo e testo vengono molto più precisi. Tutto sul Mac.
// ════════════════════════════════════════════════════════════════════

enum Vector {
    /// Lato lungo sotto il quale conviene ingrandire con l'IA prima di vettorializzare.
    static let aiBelow = 1000
    /// Con la precisione massima l'ingrandimento con l'IA vale la pena anche su immagini più grandi.
    static let aiBelowPrecise = 1600

    /// «auto», «logo», «logot» (logo senza sfondo), «bw» (firme e scansioni), «photo», «photomax».
    static func arguments(_ param: String) -> [String] {
        // 4.6 · «pack»: il pacchetto logo (il motore sceglie da solo precisione e sfondo trasparente)
        if param == "pack" { return ["--mode", "auto", "--pack"] + (AppLanguage.active == "en" ? ["--en"] : []) }
        // 4.4 · «+» in fondo: precisione massima (il ricalco lento, curva per curva sul bordo vero)
        if param.hasSuffix("+") { return arguments(String(param.dropLast())) + ["--precise"] }
        // 4.5 · «*» in fondo: Estrema (più ricalchi in parallelo, il migliore ottimizzato contro l'originale)
        if param.hasSuffix("*") { return arguments(String(param.dropLast())) + ["--extreme"] }
        switch param {
        case "logo": return ["--mode", "logo"]
        case "logot": return ["--mode", "logo", "--transparent"]
        case "bw": return ["--mode", "bw"]
        case "photo": return ["--mode", "photo"]
        case "photomax": return ["--mode", "photo", "--detail", "3"]
        default: return ["--mode", "auto"]
        }
    }

    /// 5.1 · `job`: Interrompi chiude davvero il motore (prima il lavoro arrivava fino in fondo).
    static func run(_ src: URL, param: String, out: URL, name: String? = nil, root: String? = nil, job: Job? = nil,
                    progress: @escaping (Double) -> Void) throws {
        guard let exe = Paths.motori?.appendingPathComponent("orbit-vector"),
              FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw NativeError(String(localized: "Manca il motore del vettoriale nell’app: reinstalla OrbitLR"))
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-vettoriale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // L'immagine già girata nel verso giusto, in PNG (il motore legge PNG; HEIC e RAW passano da qui)
        let input = tmp.appendingPathComponent("immagine.png")
        let img = try Tools.orientedImage(src)
        let cg = try Tools.cgImage(img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)))
        try Tools.write(cg, to: input)
        let side = max(cg.width, cg.height)

        var args = [input.path, out.path] + arguments(param)
        if let name { args += ["--name", name] }
        if let root { args += ["--root", root] }
        var base = 0.0
        if !param.hasPrefix("photo") && side > 96 && side <= (param.hasSuffix("+") || param.hasSuffix("*") || param == "pack" ? aiBelowPrecise : aiBelow) {
            let up = tmp.appendingPathComponent("ingrandita.png")
            do {
                // «Più nitido» 4×: i bordi tornano netti
                try AIEnhance.run(input, param: "b100-4", out: up, cancelled: { job?.cancelRequested ?? false },
                                  progress: { p in progress(p * 0.6) })
                args += ["--upscaled", up.path]
                base = 0.6
            } catch {
                if job?.cancelRequested == true { throw NativeError("annullato") }
                NSLog("Vettoriale: ingrandimento con l’IA non riuscito (\(error.localizedDescription)), vado avanti senza")
            }
        }

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        // «Estrema» usa tutti i core meno uno: a priorità bassa, il Mac resta reattivo
        p.qualityOfService = .utility
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        var lastError = ""
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("PROGRESS "), let v = Double(line.dropFirst(9)) {
                    progress(base + (1 - base) * v)
                } else if line.hasPrefix("ERROR ") {
                    lock.lock(); lastError = String(line.dropFirst(6)); lock.unlock()
                }
            }
        }
        if job?.cancelRequested == true { throw NativeError("annullato") }
        try p.run()
        job?.process = p                                   // 5.1 · così «Interrompi» lo chiude
        p.waitUntilExit()
        job?.process = nil
        err.fileHandleForReading.readabilityHandler = nil
        if job?.cancelRequested == true {
            try? FileManager.default.removeItem(at: out)
            throw NativeError("annullato")
        }
        lock.lock(); let msg = lastError; lock.unlock()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw NativeError(msg.isEmpty ? String(localized: "Il vettoriale non è riuscito") : msg.prefix(1).uppercased() + msg.dropFirst())
        }
        progress(1)
    }
}
