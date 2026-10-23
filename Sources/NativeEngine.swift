import Foundation
import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct NativeError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Dove salvare i file creati: rispetta le Opzioni (stessa cartella, «Convertiti», cartella fissa).
enum Destination {
    static func dir(for src: URL) -> URL {
        let p = ScriptPrefs.load()
        let here = src.deletingLastPathComponent()
        switch p["dest"] {
        case "sub":
            return here.appendingPathComponent("Convertiti")
        case "fixed":
            if let d = p["destpath"], FileManager.default.fileExists(atPath: d) { return URL(fileURLWithPath: d) }
            return here
        default:
            return here
        }
    }

    /// «nome.ext», poi «nome (1).ext», «nome (2).ext»…
    static func unique(_ dir: URL, base: String, ext: String) -> URL {
        var u = dir.appendingPathComponent(base + "." + ext)
        var i = 1
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            i += 1
        }
        return u
    }
}

/// Conversioni fatte direttamente da macOS (ImageIO, AVFoundation, PDFKit):
/// nessun programma da installare, più veloci, e i metadati restano.
/// Tutto il resto passa al motore classico.
enum NativeEngine {
    /// 2.9.6 · anche AVIF, Photoshop, JPEG XL, JPEG 2000, TGA ed EXR: li legge macOS (ImageIO)
    static let imageIn: Set<String> = Set(["jpg", "png", "heic", "tiff", "gif", "bmp", "webp",
                                           "avif", "psd", "jxl", "jp2", "tga", "exr"]).union(Catalog.rawExts)
    static let imageOut: Set<String> = ["jpg", "png", "heic", "tiff", "pdf"]
    static let videoIn: Set<String> = ["mp4", "mov", "m4v"]
    static let audioIn: Set<String> = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff", "aac", "caf", "m4b", "aifc"]

    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "disableNative") }

    static func supports(_ job: Job) -> Bool {
        // Gli strumenti della 2.5 esistono solo nei motori di macOS: valgono sempre
        if Tools.ids.contains(job.action.id) { return true }
        if Media.ids.contains(job.action.id) { return true }        // 2.6: video e audio, solo con macOS
        guard enabled else { return false }
        if QuickMedia.handles(job) { return true }                   // 2.6.3: taglia, comprimi, GIF, volume
        let files = job.mainFiles
        guard !files.isEmpty else { return false }
        let exts = files.map { Catalog.norm($0.pathExtension) }
        let id = job.action.id
        if id.hasPrefix("to:") {
            let t = String(id.dropFirst(3))
            if imageOut.contains(t) { return exts.allSatisfy { imageIn.contains($0) } }
            if t == "mp4" || t == "mov" { return exts.allSatisfy { videoIn.contains($0) } }
            if t == "m4a" { return exts.allSatisfy { audioIn.contains($0) } }
            return false
        }
        if id == "resize" { return exts.allSatisfy { imageIn.contains($0) && $0 != "gif" } }
        if id == "vresize" && job.param == "hevc" { return exts.allSatisfy { videoIn.contains($0) } }
        return false
    }

    /// Elabora un file e restituisce il file creato.
    static func run(job: Job, file: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let id = job.action.id
        let base = file.deletingPathExtension().lastPathComponent
        let e = Catalog.norm(file.pathExtension)
        let dir = job.destOverride ?? Destination.dir(for: file)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if QuickMedia.ids.contains(id) {
            return try await Task.detached(priority: .userInitiated) {
                try await QuickMedia.run(job: job, file: file, dir: dir, progress: progress)
            }.value
        }
        if Media.ids.contains(id) {
            return try await Task.detached(priority: .userInitiated) {
                try await Media.run(job: job, file: file, dir: dir, progress: progress)
            }.value
        }
        if Tools.ids.contains(id) {
            // Vision e Core Image lavorano in sottofondo, per non bloccare la finestra
            return try await Task.detached(priority: .userInitiated) {
                try await Tools.run(job: job, file: file, dir: dir, progress: progress)
            }.value
        }

        if id == "resize" {
            let p = job.param
            var ext = (imageOut.contains(e) && e != "pdf") ? e : "png"
            if Catalog.rawExts.contains(e) || p == "web" { ext = "jpg" }
            let suffix = p == "half" ? "50%" : (p == "web" ? "web" : "\(p)px")
            let out = Destination.unique(dir, base: "\(base) (\(suffix))", ext: ext)
            try convertImage(file, to: ext, resize: p, out: out)
            progress(1)
            return out
        }

        if id == "vresize" {
            let out = Destination.unique(dir, base: "\(base) (HEVC)", ext: "mp4")
            try await exportAV(file, preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, out: out, job: job, progress: progress)
            return out
        }

        let t = String(id.dropFirst(3))
        let out = Destination.unique(dir, base: base, ext: t)
        if imageOut.contains(t) {
            try convertImage(file, to: t, resize: nil, out: out)
            progress(1)
            return out
        }
        if t == "m4a" {
            try await exportAV(file, preset: AVAssetExportPresetAppleM4A, type: .m4a, out: out, job: job, progress: progress)
            return out
        }
        // MP4 / MOV: se i codec lo permettono cambia solo il contenitore (istantaneo, nessuna perdita)
        let type: AVFileType = t == "mov" ? .mov : .mp4
        let asset = AVURLAsset(url: file)
        let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                   with: asset, outputFileType: type)
        try await exportAV(file, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality,
                           type: type, out: out, job: job, progress: progress)
        return out
    }

    // MARK: - Immagini (ImageIO): EXIF, posizione e profilo colore restano

    static func convertImage(_ src: URL, to t: String, resize: String?, out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw NativeError("non riesco a leggere l’immagine")
        }
        var meta = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        if t == "pdf" {
            guard let img = NSImage(contentsOf: src), let page = PDFPage(image: img) else { throw NativeError("non riesco a creare il PDF") }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: out) else { throw NativeError("non riesco a scrivere il PDF") }
            return
        }

        let ut: UTType
        switch t {
        case "jpg": ut = .jpeg
        case "png": ut = .png
        case "heic": ut = .heic
        default: ut = .tiff
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, ut.identifier as CFString, 1, nil) else {
            throw NativeError("macOS non sa scrivere questo formato")
        }
        var opts: [CFString: Any] = [:]
        if t == "jpg" { opts[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        if t == "heic" { opts[kCGImageDestinationLossyCompressionQuality] = 0.85 }

        let w = meta[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = meta[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longSide = max(w, h)
        let hasAlpha = meta[kCGImagePropertyHasAlpha] as? Bool ?? false

        if let r = resize {
            // Ridimensiona raddrizzando la foto; mai ingrandire
            var target: Int
            switch r {
            case "half": target = max(1, longSide / 2)
            case "web": target = 1600
            default: target = Int(r) ?? 1920
            }
            if longSide > 0 { target = min(target, longSide) }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ]
            guard var img = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                throw NativeError("non riesco a ridimensionare l’immagine")
            }
            if t == "jpg" && hasAlpha, let flat = flatten(img) { img = flat }
            if r == "web" {
                meta = [:]                                   // per il web: niente dati personali
            } else {
                meta[kCGImagePropertyOrientation] = 1        // ormai è già dritta
                if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    meta[kCGImagePropertyTIFFDictionary] = tiff
                }
                meta.removeValue(forKey: kCGImagePropertyPixelWidth)
                meta.removeValue(forKey: kCGImagePropertyPixelHeight)
            }
            if r == "web" { opts[kCGImageDestinationLossyCompressionQuality] = 0.8 }
            let all = meta.merging(opts) { _, new in new }
            CGImageDestinationAddImage(dest, img, all as CFDictionary)
        } else if t == "jpg" && hasAlpha {
            // Le trasparenze in JPG diventerebbero nere: sfondo bianco
            guard let img = CGImageSourceCreateImageAtIndex(source, 0, nil), let flat = flatten(img) else {
                throw NativeError("non riesco a leggere l’immagine")
            }
            CGImageDestinationAddImage(dest, flat, meta.merging(opts) { _, new in new } as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, source, 0, opts as CFDictionary)   // copia tutti i metadati
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw NativeError("non riesco a scrivere l’immagine")
        }
    }

    private static func flatten(_ img: CGImage) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: - Audio e video (AVFoundation): usa il chip del Mac e conserva i metadati

    final class DoneFlag { var value = false }

    /// Titolo, artista, album, data, copertina e posizione, riscritti con le chiavi del formato di arrivo.
    static func translatedMetadata(_ asset: AVURLAsset, to type: AVFileType) async -> [AVMetadataItem] {
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let audio = type == .m4a
        var out: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let v = value else { return }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = v
            if let dt = dataType { m.dataType = dt }
            out.append(m)
        }
        for item in common {
            guard let key = item.commonKey, let v = try? await item.load(.value) else { continue }
            switch key {
            case .commonKeyTitle: add(audio ? .iTunesMetadataSongName : .quickTimeMetadataTitle, v)
            case .commonKeyArtist: add(audio ? .iTunesMetadataArtist : .quickTimeMetadataArtist, v)
            case .commonKeyAlbumName: add(audio ? .iTunesMetadataAlbum : .quickTimeMetadataAlbum, v)
            case .commonKeyCreationDate: add(audio ? .iTunesMetadataReleaseDate : .quickTimeMetadataCreationDate, v)
            case .commonKeyCreator: add(audio ? .iTunesMetadataComposer : .quickTimeMetadataAuthor, v)
            case .commonKeyArtwork:
                if let d = v as? Data ?? (v as? NSData).map({ $0 as Data }) {
                    let isPNG = d.starts(with: [0x89, 0x50, 0x4E, 0x47])
                    let dt = (isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
                    add(audio ? .iTunesMetadataCoverArt : .quickTimeMetadataArtwork, d as NSData, dataType: dt)
                }
            case .commonKeyLocation:
                if !audio { add(.quickTimeMetadataLocationISO6709, v) }
            default:
                break
            }
        }
        return out
    }

    static func exportAV(_ src: URL, preset: String, type: AVFileType, out: URL, job: Job,
                         progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NativeError("macOS non riesce a leggere questo file")
        }
        s.outputURL = out
        s.outputFileType = type
        s.shouldOptimizeForNetworkUse = true
        // I tag vanno «tradotti» nel formato di arrivo: un tag MP3 (ID3) non si scrive così com'è in un M4A
        let translated = await translatedMetadata(asset, to: type)
        if type == .m4a {
            if !translated.isEmpty { s.metadata = translated }
        } else if let md = try? await asset.load(.metadata) {
            let all = md + translated
            if !all.isEmpty { s.metadata = all }
        }
        job.exportSession = s

        let done = DoneFlag()
        Task {
            while !done.value {
                progress(Double(s.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        done.value = true
        job.exportSession = nil

        switch s.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: out)
            throw NativeError("annullato")
        default:
            try? FileManager.default.removeItem(at: out)
            throw NativeError(s.error?.localizedDescription ?? "conversione non riuscita")
        }
    }
}

/// Dopo ogni operazione controlla che i file creati siano davvero validi e del formato giusto.
enum Verifier {
    static func problem(_ url: URL) async -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "il file creato non esiste" }
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if items.isEmpty { return "la cartella creata è vuota" }
            for i in items.prefix(3) { if let p = await problem(i) { return p } }
            return nil
        }
        if Job.size(of: url) == 0 { return "il file creato è vuoto" }
        let e = Catalog.norm(url.pathExtension)
        switch e {
        case "jpg", "png", "heic", "tiff", "gif", "bmp", "webp", "ico":
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(s) > 0 else {
                return "l’immagine creata non si apre"
            }
            if ["jpg", "png", "heic", "tiff"].contains(e), let t = CGImageSourceGetType(s) as String?,
               let have = UTType(t), let want = UTType(filenameExtension: e), !have.conforms(to: want) {
                return "il file non è davvero un \(e.uppercased())"
            }
        case "pdf":
            guard let d = PDFDocument(url: url) else { return "il PDF creato non si apre" }
            if !d.isLocked && d.pageCount == 0 { return "il PDF creato non ha pagine" }
        case "m4r":
            // Suoneria iPhone: un normale MPEG-4 audio con un'altra estensione
            guard let h = try? FileHandle(forReadingFrom: url) else { return "la suoneria creata non si apre" }
            let d = (try? h.read(upToCount: 12)) ?? Data()
            try? h.close()
            guard d.count == 12, String(data: d.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else { return "la suoneria creata è danneggiata" }
        case "mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff":
            let asset = AVURLAsset(url: url)
            let tracks = (try? await asset.load(.tracks)) ?? []
            if tracks.isEmpty { return "il file creato non contiene audio né video" }
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds <= 0 { return "il file creato ha durata zero" }
        case "mkv", "webm":
            if !startsWith(url, [0x1A, 0x45, 0xDF, 0xA3]) { return "il file non è davvero un \(e.uppercased())" }
        case "ogg", "opus":
            if !startsWith(url, Array("OggS".utf8)) { return "il file non è davvero un \(e.uppercased())" }
        case "flac":
            if !startsWith(url, Array("fLaC".utf8)) { return "il file non è davvero un FLAC" }
        case "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub":
            if !startsWith(url, [0x50, 0x4B]) { return "il documento creato è danneggiato" }
        case "html", "txt", "md", "csv", "srt", "rtf":
            guard let d = try? Data(contentsOf: url), !d.isEmpty,
                  String(data: d, encoding: .utf8) != nil || String(data: d, encoding: .isoLatin1) != nil else {
                return "il testo creato non si legge"
            }
        default:
            break
        }
        return nil
    }

    private static func startsWith(_ url: URL, _ bytes: [UInt8]) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: bytes.count)
        return [UInt8](d) == bytes
    }
}
