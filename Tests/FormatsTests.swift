import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 2.9.6 · Formati nuovi: riconosciuti dall'app e dal motore classico, e quelli di macOS letti davvero.
final class FormatsTests: XCTestCase {
    private let newOnes: [(String, Kind)] = [
        ("avif", .img), ("psd", .img), ("jxl", .img), ("jp2", .img), ("tga", .img), ("exr", .img),
        ("caf", .audio), ("amr", .audio), ("m4b", .audio), ("ac3", .audio), ("aifc", .audio),
        ("ts", .video), ("vob", .video), ("mxf", .video), ("ogv", .video), ("dv", .video), ("f4v", .video), ("asf", .video),
        ("wps", .doc), ("wpd", .doc),
    ]

    func testKindsInAppAndScript() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/LRConverter.zsh"), encoding: .utf8)
        let kindOf = script.components(separatedBy: "kind_of() {")[1].components(separatedBy: "}")[0]
        for (e, k) in newOnes {
            XCTAssertEqual(Catalog.kind(of: URL(fileURLWithPath: "/x/prova.\(e)")), k, ".\(e) nell'app")
            let line = kindOf.split(separator: "\n").first { $0.contains("print") && $0.split(separator: ")")[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.contains(e) }
            XCTAssertNotNil(line, ".\(e) nel motore classico")
            if let line { XCTAssertTrue(line.contains("print \(k.rawValue)"), ".\(e): tipo giusto nel motore classico") }
            XCTAssertFalse(Catalog.actions(for: k, exts: [e], mergeable: 1).isEmpty, ".\(e): ci sono azioni")
        }
        XCTAssertEqual(Catalog.kind(of: URL(fileURLWithPath: "/x/a.J2K")), .img)
    }

    /// Le immagini nuove: macOS le legge davvero; quelle che sa anche scrivere si convertono in JPG.
    func testImagesReadAndConvert() throws {
        let readable = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let src = try Fixtures.photo(name: "formati.png", width: 320, height: 240)
        let img = try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var converted: [String] = []
        for e in ["psd", "jp2", "tga", "exr", "avif", "jxl"] {
            let uti = try XCTUnwrap(UTType(filenameExtension: e)?.identifier, ".\(e): tipo sconosciuto a macOS")
            XCTAssertTrue(readable.contains(uti), ".\(e): macOS deve saperlo leggere (\(uti))")
            guard writable.contains(uti) else { continue }          // non tutti si possono creare per la prova
            let f = Fixtures.url("formati.\(e)")
            try? FileManager.default.removeItem(at: f)
            let d = try XCTUnwrap(CGImageDestinationCreateWithURL(f as CFURL, uti as CFString, 1, nil))
            CGImageDestinationAddImage(d, img, nil)
            XCTAssertTrue(CGImageDestinationFinalize(d))
            let out = Fixtures.url("formati-\(e).jpg")
            try? FileManager.default.removeItem(at: out)
            try NativeEngine.convertImage(f, to: "jpg", resize: nil, out: out)
            let back = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(back.width, 320, ".\(e) → JPG"); XCTAssertEqual(back.height, 240)
            converted.append(e)
        }
        XCTAssertTrue(converted.contains("psd") || converted.contains("tga") || converted.contains("jp2"),
                      "almeno uno dei formati nuovi provato davvero (\(converted))")
    }

    /// Gli audio nuovi che macOS legge: si aprono e diventano una suoneria.
    func testAudioCafAifcM4B() async throws {
        let pcm = Fixtures.tone(seconds: 3, freq: 330)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.count))!
        buf.frameLength = buf.frameCapacity
        for i in 0..<pcm.count { buf.floatChannelData![0][i] = pcm[i] }
        let cases: [(String, [String: Any])] = [
            ("caf", [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]),
            ("aifc", [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]),
            ("m4a", [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]),
        ]
        for (e, settings) in cases {
            var f = Fixtures.url("formati-audio.\(e)")
            try? FileManager.default.removeItem(at: f)
            do {
                let file = try AVAudioFile(forWriting: f, settings: settings)
                try file.write(from: buf)
            }
            if e == "m4a" {                                   // un audiolibro è un M4A con un altro nome
                let b = Fixtures.url("formati-audio.m4b")
                try? FileManager.default.removeItem(at: b)
                try FileManager.default.moveItem(at: f, to: b)
                f = b
            }
            let ext = Catalog.norm(f.pathExtension)
            XCTAssertTrue(MediaTabModel.readable.contains(ext), ".\(ext) tra i formati letti da macOS")
            let info = try await VPMediaInfo.load(f)
            XCTAssertTrue(info.hasAudio, ".\(ext): ha l'audio")
            XCTAssertEqual(info.duration, 3, accuracy: 0.2, ".\(ext): durata")
            let out = Fixtures.url("formati-\(ext).m4r")
            let job = try Fixtures.job("ringtone", kind: .audio, files: [f])
            try await Media.renderAudio([(f, nil, nil)], out: out, bitrate: 128_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                        normalize: false, maxSeconds: 30, job: job) { _ in }
            let r = try await Fixtures.probe(out)
            XCTAssertEqual(r.duration, 3, accuracy: 0.2, ".\(ext) → suoneria")
        }
    }
}
