import Foundation
import AVFoundation
import ImageIO

// ════════════════════════════════════════════════════════════════════
//  2.7 · Peso previsto su ogni spicchio, prima di scegliere.
//  Solo dove la stima è affidabile:
//  • immagini → si converte davvero (in sottofondo, su una copia temporanea) e si misura
//  • audio → dalla durata e dalla qualità che usa OrbitLR
//  Dove non si può sapere, non si scrive niente: meglio nessun numero che un numero sbagliato.
// ════════════════════════════════════════════════════════════════════

enum SizeEstimate {
    static let imageFormats: Set<String> = ["jpg", "png", "heic", "tiff"]
    /// Bit al secondo dell'audio che OrbitLR scrive per ogni formato.
    static let audioBitrate: [String: Double] = ["mp3": 190_000, "m4a": 256_000, "wav": 1_411_200, "flac": 800_000,
                                                 "ogg": 160_000, "whatsapp": 64_000]

    /// Stime per le azioni di un menu: id dell'azione → byte previsti (somma di tutti i file).
    static func estimates(actions: [Action], files: [URL], kind: Kind) async -> [String: Int64] {
        let ids = actions.map { $0.id }
        var out: [String: Int64] = [:]
        switch kind {
        case .img:
            let targets = ids.filter { $0.hasPrefix("to:") && imageFormats.contains(String($0.dropFirst(3))) }
            guard !targets.isEmpty else { return [:] }
            // Fino a 4 file si convertono tutti; con di più, si provano i primi 3 e si proporziona sul peso totale
            let sample = Array(files.prefix(files.count <= 4 ? 4 : 3))
            let sampleBytes = sample.reduce(Int64(0)) { $0 + Job.size(of: $1) }
            let totalBytes = files.reduce(Int64(0)) { $0 + Job.size(of: $1) }
            for id in targets {
                if Task.isCancelled { return out }
                let t = String(id.dropFirst(3))
                var sum: Int64 = 0
                var ok = true
                for f in sample {
                    guard NativeEngine.imageIn.contains(Catalog.norm(f.pathExtension)), let b = imageBytes(f, to: t) else { ok = false; break }
                    sum += b
                }
                guard ok, sum > 0 else { continue }
                out[id] = sample.count == files.count || sampleBytes == 0 ? sum : Int64(Double(sum) * Double(totalBytes) / Double(sampleBytes))
            }
        case .audio, .video:
            var seconds = 0.0
            for f in files.prefix(50) {
                let d = (try? await AVURLAsset(url: f).load(.duration).seconds) ?? 0
                if d.isFinite { seconds += max(0, d) }
            }
            guard seconds > 0 else { return [:] }
            for id in ids {
                let key = id.hasPrefix("to:") ? String(id.dropFirst(3)) : id
                guard let bps = audioBitrate[key] else { continue }
                if kind == .video && key != "mp3" && key != "m4a" { continue }     // da un video: solo l'audio estratto
                out[id] = Int64(bps * seconds / 8)
            }
        default:
            break
        }
        return out
    }

    /// Converte davvero l'immagine in una cartella temporanea e ne misura il peso.
    static func imageBytes(_ src: URL, to t: String) -> Int64? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-stima-\(UUID().uuidString).\(t)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? NativeEngine.convertImage(src, to: t, resize: nil, out: tmp)) != nil else { return nil }
        let b = Job.size(of: tmp)
        return b > 0 ? b : nil
    }

    /// «≈ 1,2 MB»
    static func label(_ bytes: Int64) -> String {
        "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension PieModel {
    /// Calcola in sottofondo i pesi previsti e li mostra sugli spicchi appena pronti.
    func loadEstimates(files: [URL], kind: Kind) {
        estimateTask?.cancel()
        estimates = [:]
        let actions = all
        let total = files.reduce(Int64(0)) { $0 + Job.size(of: $1) }
        currentBytes = total
        estimateTask = Task.detached(priority: .utility) { [weak self] in
            let e = await SizeEstimate.estimates(actions: actions, files: files, kind: kind)
            guard !Task.isCancelled, !e.isEmpty else { return }
            await MainActor.run { self?.estimates = e }
        }
    }
}
