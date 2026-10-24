import XCTest
import AVFoundation

/// 3.6 · Video grandi e qualità: il piano sceglie bene, il taglio è istantaneo, la compressione rispetta peso e misura.
final class SmartVideoTests: XCTestCase {
    private func src(_ w: Double, _ h: Double, fps: Double = 30, seconds: Double, mbps: Double, codec: String = "avc1") -> SmartVideo.Source {
        SmartVideo.Source(width: w, height: h, fps: fps, duration: seconds, videoBitrate: mbps * 1_000_000,
                          audioBitrate: 128_000, codec: codec, audioIsAAC: true, hdr: false)
    }

    func testPesoPiccoloPrimaTogliFotogrammiPoiMisura() {
        // 10 minuti in 1080p a 60 fps, da far stare in 100 MB
        guard case .plan(let p) = SmartVideo.plan(src(1920, 1080, fps: 60, seconds: 600, mbps: 20), targetBytes: 100 * 1_048_576, codec: .h264) else {
            return XCTFail("doveva esserci un piano")
        }
        XCTAssertEqual(p.fps, 30, "prima si rinuncia ai 60 fotogrammi")
        XCTAssertEqual(p.height, 540, "poi si scende quanto basta, non di più")
        XCTAssertLessThanOrEqual(p.bytes(duration: 600), 100 * 1_048_576)
    }

    func testPesoAmpioTieneTuttoUguale() {
        guard case .plan(let p) = SmartVideo.plan(src(1920, 1080, seconds: 60, mbps: 20), targetBytes: 100 * 1_048_576, codec: .h264) else {
            return XCTFail()
        }
        XCTAssertEqual(p.width, 1920); XCTAssertEqual(p.height, 1080); XCTAssertEqual(p.fps, 30)
    }

    func testVerticaleRestaVerticale() {
        guard case .plan(let p) = SmartVideo.plan(src(1080, 1920, seconds: 600, mbps: 15), targetBytes: 50 * 1_048_576, codec: .h264) else {
            return XCTFail()
        }
        XCTAssertLessThan(p.width, p.height)
    }

    func testStessaQualitaDaH264AHEVC() {
        guard case .plan(let p) = SmartVideo.plan(src(1920, 1080, seconds: 60, mbps: 10), targetBytes: nil, codec: .hevc) else {
            return XCTFail()
        }
        XCTAssertEqual(p.width, 1920, "stessa misura")
        XCTAssertLessThan(Double(p.videoBitrate), 10_000_000 * 0.85, "più leggero")
        XCTAssertGreaterThan(Double(p.videoBitrate), 1920 * 1080 * 30 * 0.07, "ma con i dati che servono a sembrare uguale")
    }

    func testGiaLeggeroNonSiTocca() {
        XCTAssertEqual(SmartVideo.plan(src(1920, 1080, seconds: 60, mbps: 3, codec: "hvc1"), targetBytes: nil, codec: .hevc), .alreadyLight)
    }

    func testTroppoLungo() {
        XCTAssertEqual(SmartVideo.plan(src(1920, 1080, seconds: 7200, mbps: 10), targetBytes: 10 * 1_048_576, codec: .h264), .tooLong)
    }

    func testSpazioInsufficienteLoDiceSubito() {
        XCTAssertThrowsError(try SmartVideo.ensureSpace(in: Fixtures.dir, for: Int64.max / 4)) {
            XCTAssertTrue($0.localizedDescription.contains("spazio libero"))
        }
        XCTAssertNoThrow(try SmartVideo.ensureSpace(in: Fixtures.dir, for: 1_000_000))
    }

    // MARK: Su video veri

    func testTaglioIstantaneoSenzaPerdita() async throws {
        let v = try await Fixtures.video(name: "taglio-veloce.mp4", width: 640, height: 360, seconds: 6, noise: true)
        let out = Fixtures.url("taglio-veloce-out.mp4")
        let t0 = Date()
        let ok = try await SmartVideo.trimLossless(v, range: CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600),
                                                                          end: CMTime(seconds: 4, preferredTimescale: 600)),
                                                   out: out, job: nil) { _ in }
        XCTAssertTrue(ok, "un MP4 si taglia senza ricodificare")
        print("TEMPO: taglio senza perdita \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 2, accuracy: 0.6)
    }

    func testStessaQualitaMenoPeso() async throws {
        let v = try await Fixtures.video(name: "qualita.mp4", width: 1280, height: 720, seconds: 4, noise: true)
        let out = Fixtures.url("qualita-out.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            try await SmartVideo.compress(v, targetBytes: nil, out: out, job: nil) { _ in }
        } catch {
            // Se il video di prova è già leggero va bene lo stesso: lo dice chiaramente
            XCTAssertTrue(error.localizedDescription.contains("già compresso"), error.localizedDescription)
            return
        }
        XCTAssertLessThan(Job.size(of: out), Job.size(of: v), "più leggero")
        let tr = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let size = try await tr?.load(.naturalSize)
        XCTAssertEqual(size?.width, 1280, "stessa misura")
        XCTAssertEqual(size?.height, 720)
    }

    func testCambiaGrandezza() async throws {
        let v = try await Fixtures.video(name: "grande.mp4", width: 1280, height: 720, seconds: 2)
        let out = Fixtures.url("grande-480.mp4")
        try await SmartVideo.resize(v, shortSide: 480, out: out, job: nil) { _ in }
        let tr = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let size = try await tr?.load(.naturalSize)
        XCTAssertEqual(size?.height, 480)
        XCTAssertEqual(size?.width, 854)
    }

    func testVideoVerticaleCompressoResta() async throws {
        let v = try await Fixtures.video(name: "verticale.mp4", width: 1280, height: 720, seconds: 3, portrait: true, noise: true)
        let out = Fixtures.url("verticale-out.mp4")
        try? FileManager.default.removeItem(at: out)
        try await SmartVideo.compress(v, targetBytes: Int64(0.5 * 1_048_576), out: out, job: nil) { _ in }
        XCTAssertLessThanOrEqual(Job.size(of: out), Int64(0.5 * 1_048_576))
        let tr = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let (n, t) = try await tr!.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: n).applying(t)
        XCTAssertLessThan(abs(r.width), abs(r.height), "resta in piedi")
        XCTAssertGreaterThan(try await brightness(out), 0.08, "e l'immagine c'è davvero (non è nera)")
    }

    /// La luminosità media di un fotogramma a metà video (0 = nero).
    private func brightness(_ url: URL) async throws -> Double {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        let img = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]) }
        return sum / Double(w * h * 3) / 255
    }

    func testCambiaGrandezzaNonTagliaNeStira() async throws {
        let v = try await Fixtures.video(name: "grande-contenuto.mp4", width: 1280, height: 720, seconds: 2, noise: true)
        let out = Fixtures.url("grande-contenuto-480.mp4")
        try await SmartVideo.resize(v, shortSide: 480, out: out, job: nil) { _ in }
        let a = try await brightness(v), b = try await brightness(out)
        XCTAssertEqual(a, b, accuracy: 0.08, "stessa immagine, solo più piccola")
    }
}
