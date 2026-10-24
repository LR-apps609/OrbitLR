import Foundation
import AppKit
import CoreML
import CoreImage

// ════════════════════════════════════════════════════════════════════
//  2.9.7 · «Rimuovi (IA)»: LaMa (Apache-2.0, Samsung AI Center) ricostruisce
//  la zona coperta dal logo con quello che c'è intorno. Tutto sul Mac.
//  Il modello (circa 200 MB) si scarica la prima volta dalle «Release» di OrbitLR
//  (versione «modelli-1», non è un aggiornamento dell'app) e resta nella cartella di supporto.
// ════════════════════════════════════════════════════════════════════

final class ModelStore: ObservableObject, @unchecked Sendable {
    static let shared = ModelStore()
    /// Impronta SHA-256 del modello LaMa 512 pubblicato (release «modelli-1»).
    static let pinnedSHA256 = "aafdf2aff5e7b3e5b986662e1ef063190197481122da5d8f02ea1d28edb77027"

    static let side = 512
    static let name = "LaMa-512"
    static let base = URL(string: "https://github.com/LR-apps609/OrbitLR/releases/download/modelli-1/")!
    static var folder: URL { Paths.support.appendingPathComponent("Modelli", isDirectory: true) }
    static var compiled: URL { folder.appendingPathComponent(name + ".mlmodelc", isDirectory: true) }

    /// 0…1 durante lo scaricamento, nil se non si sta scaricando.
    @Published private(set) var progress: Double? = nil
    @Published private(set) var error: String? = nil
    var isReady: Bool { FileManager.default.fileExists(atPath: Self.compiled.path) }

    private var model: MLModel?
    private let lock = NSLock()

    private func cachedModel() -> MLModel? { lock.withLock { model } }
    private func store(_ m: MLModel) { lock.withLock { model = m } }

    /// Il modello pronto: lo scarica e lo prepara se serve.
    func lama() async throws -> MLModel {
        if let m = cachedModel() { return m }
        if !isReady { try await download() }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: Self.compiled, configuration: cfg)
        store(m)
        return m
    }

    private func setProgress(_ v: Double?) { DispatchQueue.main.async { self.progress = v } }

    private func download() async throws {
        setProgress(0)
        DispatchQueue.main.async { self.error = nil }
        defer { setProgress(nil) }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        do {
            // 3.5.2 · L'impronta giusta è scritta DENTRO l'app: un file cambiato sul server non passa
            let expected = Self.pinnedSHA256
            let zipURL = Self.base.appendingPathComponent(Self.name + ".mlpackage.zip")
            let (tmp, resp) = try await URLSession.shared.download(from: zipURL, delegate: ProgressDelegate { [weak self] p in self?.setProgress(p) })
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NativeError("il modello di IA non è ancora disponibile") }
            guard Self.sha256(of: tmp) == expected else { throw NativeError("il modello scaricato è rovinato, riprova") }
            let work = Self.folder.appendingPathComponent("scarico-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work); try? fm.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", tmp.path, work.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let pkg = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "mlpackage" }) else {
                throw NativeError("non riesco ad aprire il modello scaricato")
            }
            let built = try await MLModel.compileModel(at: pkg)
            try? fm.removeItem(at: Self.compiled)
            try fm.moveItem(at: built, to: Self.compiled)
        } catch {
            let msg = (error as? NativeError)?.localizedDescription ?? "non riesco a scaricare il modello di IA (serve internet la prima volta)"
            DispatchQueue.main.async { self.error = msg }
            throw NativeError(msg)
        }
    }

    static func sha256(of url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let onProgress: (Double) -> Void
        var obs: NSKeyValueObservation?
        init(_ f: @escaping (Double) -> Void) { onProgress = f }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            obs = task.progress.observe(\.fractionCompleted) { [weak self] pr, _ in self?.onProgress(pr.fractionCompleted) }
        }
    }
}

/// Ricostruisce le zone di un'immagine con LaMa, una zona alla volta, lavorando solo sul riquadro intorno.
final class Inpainter: @unchecked Sendable {
    let model: MLModel
    private let ctx = Media.ci
    private let lock = NSLock()
    /// Video: il risultato del fotogramma prima, per ammorbidire il tremolio (uno per zona).
    private var previous: [Int: CIImage] = [:]
    private var lastTime = -1.0
    var smoothing = 0.0

    init(model: MLModel) { self.model = model }

    /// Il riquadro su cui lavora il modello: un quadrato intorno alla zona, con abbastanza contesto.
    static func window(for r: CGRect, in ext: CGRect) -> CGRect {
        let side = min(max(max(r.width, r.height) * 2.6, 96), max(ext.width, ext.height))
        return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side).integral
    }

    /// Un numero a 16 bit in Float (Float16 non esiste sui Mac Intel).
    static func half(_ h: UInt16) -> Float {
        let sign: UInt32 = UInt32(h & 0x8000) << 16
        var exp = Int((h >> 10) & 0x1F)
        var mant = UInt32(h & 0x3FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            while mant & 0x400 == 0 { mant <<= 1; exp -= 1 }
            exp += 1; mant &= 0x3FF
        } else if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        }
        return Float(bitPattern: sign | UInt32(exp + 112) << 23 | (mant << 13))
    }

    func apply(_ spec: HideMark.Spec, to img: CIImage, time: Double? = nil) throws -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let t = time { if t < lastTime { previous = [:] }; lastTime = t }
        let ext = img.extent
        var out = img
        for (i, r) in spec.rects.enumerated() {
            let px = HideMark.pixelRect(r, in: ext)
            guard px.width >= 2, px.height >= 2 else { continue }
            var filled = try fill(out, zone: px, ext: ext)
            if smoothing > 0, let prev = previous[i] {
                filled = prev.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": filled, "inputTime": 1 - smoothing])
                    .cropped(to: filled.extent)
            }
            if time != nil { previous[i] = filled }
            out = filled.composited(over: out).cropped(to: ext)
        }
        return out
    }

    /// La zona ricostruita (solo la zona allargata di poco, con i bordi sfumati), pronta da sovrapporre.
    private func fill(_ img: CIImage, zone: CGRect, ext: CGRect) throws -> CIImage {
        let S = CGFloat(ModelStore.side)
        let win = Self.window(for: zone, in: ext)
        let k = S / win.width
        // Il riquadro a 512×512: fuori dall'immagine si ripetono i bordi
        let crop = img.clampedToExtent().cropped(to: win)
            .transformed(by: CGAffineTransform(translationX: -win.minX, y: -win.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
            .cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        let grow: CGFloat = 4
        let maskRect = CGRect(x: (zone.minX - win.minX) * k - grow, y: (zone.minY - win.minY) * k - grow,
                              width: zone.width * k + grow * 2, height: zone.height * k + grow * 2)
        let side = ModelStore.side
        var rgba = [Float](repeating: 0, count: side * side * 4)
        ctx.render(crop, toBitmap: &rgba, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: S, height: S),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let image = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let mask = try MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let ip = image.dataPointer.bindMemory(to: Float.self, capacity: 3 * side * side)
        let mp = mask.dataPointer.bindMemory(to: Float.self, capacity: side * side)
        let plane = side * side
        for y in 0..<side {
            // La bitmap è dall'alto in basso; Core Image ha l'origine in basso
            let cy = CGFloat(side - 1 - y) + 0.5
            for x in 0..<side {
                let s = (y * side + x) * 4, d = y * side + x
                let inside = maskRect.contains(CGPoint(x: CGFloat(x) + 0.5, y: cy))
                mp[d] = inside ? 1 : 0
                // Dentro la zona il modello non deve vedere il logo
                ip[d] = inside ? 0 : min(1, max(0, rgba[s]))
                ip[plane + d] = inside ? 0 : min(1, max(0, rgba[s + 1]))
                ip[2 * plane + d] = inside ? 0 : min(1, max(0, rgba[s + 2]))
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": image, "mask": mask])
        guard let res = try model.prediction(from: input).featureValue(for: "output")?.multiArrayValue else {
            throw NativeError("il modello di IA non ha risposto")
        }
        // L'uscita può avere passi diversi da quelli «compatti» e numeri a 16 o 32 bit: si legge con i suoi passi
        guard res.shape.count == 4, res.shape[1].intValue == 3, res.shape[2].intValue == side, res.shape[3].intValue == side else {
            throw NativeError("il modello di IA ha risposto in un formato inatteso")
        }
        let st = res.strides.map { $0.intValue }
        var bytes = [UInt8](repeating: 255, count: plane * 4)
        func put(_ read: (Int) -> Float) {
            for y in 0..<side {
                for x in 0..<side {
                    let o = y * st[2] + x * st[3], d = (y * side + x) * 4
                    for ch in 0..<3 { bytes[d + ch] = UInt8(min(255, max(0, read(o + ch * st[1]) * 255 + 0.5))) }
                }
            }
        }
        switch res.dataType {
        case .float32:
            let rp = res.dataPointer.bindMemory(to: Float.self, capacity: res.count)
            put { rp[$0] }
        case .float16:
            let rp = res.dataPointer.bindMemory(to: UInt16.self, capacity: res.count)
            put { Self.half(rp[$0]) }
        case .double:
            let rp = res.dataPointer.bindMemory(to: Double.self, capacity: res.count)
            put { Float(rp[$0]) }
        default:
            put { res[$0].floatValue }
        }
        let restored = CIImage(bitmapData: Data(bytes), bytesPerRow: side * 4, size: CGSize(width: S, height: S),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Torna alla misura vera, al suo posto, e si tiene solo la zona (bordi morbidi di qualche pixel)
        let back = restored.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)
            .concatenating(CGAffineTransform(translationX: win.minX, y: win.minY)))
        let soft = max(1.5, 3 / k)
        let keep = zone.insetBy(dx: -soft * 1.5, dy: -soft * 1.5).intersection(ext)
        let maskImg = CIImage(color: .white).cropped(to: keep)
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": soft])
            .cropped(to: keep.insetBy(dx: -soft * 2, dy: -soft * 2))
        let clear = CIImage(color: .clear).cropped(to: ext)
        return back.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": clear, "inputMaskImage": maskImg.composited(over: CIImage(color: .black).cropped(to: ext))])
            .cropped(to: keep.insetBy(dx: -soft * 2, dy: -soft * 2).intersection(ext))
    }
}
