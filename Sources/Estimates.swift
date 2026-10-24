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
    /// TIFF escluso: pesa così tanto che convertirlo solo per stimarlo costa più della stima.
    static let imageFormats: Set<String> = ["jpg", "png", "heic"]
    /// 2.7.1 · Stime già fatte (file + data di modifica + formato): riaprire la torta non riconverte niente.
    nonisolated(unsafe) private static var cache: [String: Int64] = [:]
    private static let lock = NSLock()
    /// Foto più grandi di così: si stima su una sola, non su tre.
    static let bigPixels = 20_000_000
    /// Bit al secondo dell'audio che OrbitLR scrive per ogni formato.
    /// M4A resta fuori: il preset di Apple è a qualità variabile e il peso cambia troppo da file a file.
    static let audioBitrate: [String: Double] = ["mp3": 190_000, "wav": 1_411_200, "flac": 800_000,
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
            let big = files.prefix(4).contains { pixels($0) > bigPixels }
            let sample = Array(files.prefix(big ? 1 : (files.count <= 4 ? 4 : 3)))
            let sampleBytes = sample.reduce(Int64(0)) { $0 + Job.size(of: $1) }
            let totalBytes = files.reduce(Int64(0)) { $0 + Job.size(of: $1) }
            for id in targets {
                if Task.isCancelled { return out }
                let t = String(id.dropFirst(3))
                var sum: Int64 = 0
                var ok = true
                for f in sample {
                    if Task.isCancelled { return out }
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
                if kind == .video && key != "mp3" { continue }     // da un video: solo l'audio estratto
                out[id] = Int64(bps * seconds / 8)
            }
        default:
            break
        }
        return out
    }

    /// Converte davvero l'immagine in una cartella temporanea e ne misura il peso.
    static func imageBytes(_ src: URL, to t: String) -> Int64? {
        let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(src.path)|\(date)|\(t)"
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        guard let b = convertAndMeasure(src, to: t) else { return nil }
        lock.lock(); if cache.count > 500 { cache.removeAll() }; cache[key] = b; lock.unlock()
        return b
    }

    static func pixels(_ url: URL) -> Int {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return 0 }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    private static func convertAndMeasure(_ src: URL, to t: String) -> Int64? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitlr-stima-\(UUID().uuidString).\(t)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? NativeEngine.convertImage(src, to: t, resize: nil, out: tmp)) != nil else { return nil }
        let b = Job.size(of: tmp)
        return b > 0 ? b : nil
    }

    /// 2.7.5 · Formato social: lato corto 1080, stessa qualità del montaggio.
    static func socialBytes(seconds: Double, aspect: String, fps: Double = 30) -> Int64 {
        let parts = aspect.split(separator: "x").compactMap { Double($0) }
        let (aw, ah) = parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : (9, 16)
        let short = 1080.0
        let w = aw <= ah ? short : short * aw / ah
        let h = aw <= ah ? short * ah / aw : short
        let bits = max(2_000_000, min(50_000_000, w * h * fps * 0.13)) + 160_000
        return Int64(bits * seconds / 8)
    }

    /// 2.7.5 · Comprimi a X MB: il risultato starà sotto il peso scelto (o resta com'è se è già più leggero).
    static func compressText(current: Int64, targetMB: Int?, files: Int) -> String {
        let now = Fmt.bytes(current)
        guard let mb = targetMB, mb > 0 else { return "Ora pesa \(now)" }
        let target = Int64(mb) * 1_000_000 * Int64(max(1, files))
        if current > 0 && current <= target { return "Pesa già \(now): è sotto il limite scelto" }
        return "Ora \(now) → al massimo \(Fmt.bytes(target))"
            + (files > 1 ? " in tutto" : "")
    }

    /// «≈ 1,2 MB»
    static func label(_ bytes: Int64) -> String {
        "≈ " + Fmt.bytes(bytes)
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
            guard !Task.isCancelled, !e.isEmpty, let model = self else { return }
            await MainActor.run { model.estimates = e }
        }
    }
}
