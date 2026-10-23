import XCTest
import AVFoundation
import CoreImage

/// 2.9.9 · Testi animati.
final class VideoTextsTests: XCTestCase {
    private func lum(_ cg: CGImage, _ r: CGRect) -> Double {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let rect = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
        let avg = CIImage(cgImage: cg).applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        Media.ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 765
    }

    private func frame(_ b: VPBuilt, at t: Double) async throws -> CGImage {
        let g = AVAssetImageGenerator(asset: b.composition)
        g.videoComposition = b.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    func testTimingAndAnimations() throws {
        let canvas = CGSize(width: 1280, height: 720)
        var t = VPText(); t.text = "Ciao a tutti"; t.start = 1; t.end = 3
        XCTAssertNil(TextRender.image(t, canvas: canvas, at: 0.5), "prima dell'inizio non c'è")
        XCTAssertNil(TextRender.image(t, canvas: canvas, at: 3.2), "dopo la fine non c'è")
        XCTAssertNotNil(TextRender.image(t, canvas: canvas, at: 2))
        for a in VPText.anims.map(\.id) {
            t.anim = a
            for time in [1.05, 1.3, 2.0, 2.9] { XCTAssertNotNil(TextRender.image(t, canvas: canvas, at: time), "\(a) a \(time) s") }
        }
        // Macchina da scrivere: all'inizio si vede solo un pezzo del testo
        t.anim = "type"
        let early = try XCTUnwrap(TextRender.image(t, canvas: canvas, at: 1.1)).extent.width
        let full = try XCTUnwrap(TextRender.image(t, canvas: canvas, at: 2.5)).extent.width
        XCTAssertLessThan(early, full * 0.7)
        // Testo lunghissimo: va a capo e resta dentro la tela
        t.text = String(repeating: "parola ", count: 60)
        let big = try XCTUnwrap(TextRender.image(t, canvas: canvas, at: 2.5)).extent
        XCTAssertLessThanOrEqual(big.width, canvas.width)
        XCTAssertGreaterThanOrEqual(big.minX, -0.5)
    }

    /// Un titolo bianco al centro si vede nel video (e solo mentre deve).
    func testTitleAppearsInVideoAndExport() async throws {
        let v = try await Fixtures.video(name: "testi.mp4", width: 320, height: 180, seconds: 3)
        let info = try await VPMediaInfo.load(v)
        var p = VideoProject()
        p.clips = [VPClip(path: v.path, inPoint: 0, outPoint: info.videoDuration)]
        var t = VPText(); t.text = "TITOLO"; t.style = "big"; t.start = 1; t.end = 2.5; t.x = 0.5; t.y = 0.3
        p.texts = [t]
        let b = try await VideoProjectBuilder.build(p, infos: [v.path: info], speech: [:], maxSide: 640, engine: .frames)
        let zone = CGRect(x: 0.3, y: 0.22, width: 0.4, height: 0.16)
        let before = lum(try await frame(b, at: 0.5), zone)
        let during = lum(try await frame(b, at: 1.8), zone)
        let after = lum(try await frame(b, at: 2.8), zone)
        XCTAssertGreaterThan(during, before + 0.12, "il titolo bianco si vede")
        XCTAssertEqual(after, before, accuracy: 0.06, "e poi sparisce")

        p.resolution = 720
        let out = Fixtures.dir.appendingPathComponent("testi-out.mp4")
        let action = try XCTUnwrap(Catalog.action(id: "vproject", kind: .video))
        try await VideoProjectExport.run(project: p, speech: [:], out: out, job: Job(files: [v], action: action, param: ""), progress: { _ in })
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        let f = try await g.image(at: CMTime(seconds: 1.8, preferredTimescale: 600)).image
        XCTAssertGreaterThan(lum(f, zone), before + 0.12, "anche nel file esportato")
    }

    func testOldProjectsHaveNoTexts() throws {
        let old = #"{"clips":[],"originalVolume":1,"originalMuted":false,"aspect":"orig","follow":true,"resolution":1080,"fps":30}"#
        let p = try JSONDecoder().decode(VideoProject.self, from: Data(old.utf8))
        XCTAssertNil(p.texts)
    }
}
