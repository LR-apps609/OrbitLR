import XCTest
import AVFoundation
import CoreImage

/// 2.9.8 · Effetti della clip.
final class VideoEffectsTests: XCTestCase {
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

    private func one(_ fx: VPEffects?, seconds: Double = 2, audio: Bool = false) async throws -> (VideoProject, [String: VPMediaInfo]) {
        let v = try await Fixtures.video(name: "fx.mp4", width: 320, height: 180, seconds: seconds,
                                         audio: audio ? Fixtures.tone(seconds: seconds, freq: 440) : nil)
        let info = try await VPMediaInfo.load(v)
        var c = VPClip(path: v.path, inPoint: 0, outPoint: info.videoDuration)
        c.fx = fx
        var p = VideoProject()
        p.clips = [c]
        return (p, [v.path: info])
    }

    /// I 5 quadrati in fila dicono dove sta il quadratino chiaro (si muove da sinistra a destra nel tempo).
    private func row(_ cg: CGImage) -> [Double] {
        (0..<5).map { lum(cg, CGRect(x: Double($0) * 0.2, y: 0.35, width: 0.2, height: 0.3)) }
    }

    func testSpeedChangesLengthAndTiming() async throws {
        var fast = VPEffects(); fast.speed = 2
        let (p2, infos) = try await one(fast)
        let (p1, _) = try await one(nil)
        XCTAssertEqual(p2.duration, p1.duration / 2, accuracy: 0.01, "a 2× dura la metà")
        XCTAssertEqual(p2.clip(at: 0.5)?.local ?? 0, 1.0, accuracy: 0.01, "a metà montaggio siamo a 1 s del file")
        for engine in [VideoProjectBuilder.Engine.frames, .layers] {
            let b2 = try await VideoProjectBuilder.build(p2, infos: infos, speech: [:], maxSide: 640, engine: engine)
            XCTAssertEqual(b2.duration, p2.duration, accuracy: 0.02)
            XCTAssertEqual(b2.composition.duration.seconds, p2.duration, accuracy: 0.05)
        }
        let b2 = try await VideoProjectBuilder.build(p2, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let b1 = try await VideoProjectBuilder.build(p1, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let a = row(try await frame(b2, at: 0.6)), b = row(try await frame(b1, at: 1.2))
        for i in 0..<5 { XCTAssertEqual(a[i], b[i], accuracy: 0.06, "a 2×, 0,6 s del montaggio = 1,2 s del file (riquadro \(i))") }
    }

    func testFlipMirrorsAndRotateTurnsCanvas() async throws {
        let (p0, infos) = try await one(nil)
        var flip = VPEffects(); flip.flipH = true
        var pf = p0; pf.clips[0].fx = flip
        let b0 = try await VideoProjectBuilder.build(p0, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let bf = try await VideoProjectBuilder.build(pf, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let a = row(try await frame(b0, at: 0.3)), b = row(try await frame(bf, at: 0.3))
        for i in 0..<5 { XCTAssertEqual(b[i], a[4 - i], accuracy: 0.06, "specchiato (riquadro \(i))") }
        var rot = VPEffects(); rot.rotate = 90
        var pr = p0; pr.clips[0].fx = rot
        let br = try await VideoProjectBuilder.build(pr, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        XCTAssertGreaterThan(br.renderSize.height, br.renderSize.width, "ruotata di 90°: la tela diventa verticale")
        let cl = try await VideoProjectBuilder.build(pr, infos: infos, speech: [:], maxSide: 640, engine: .layers)
        XCTAssertEqual(cl.renderSize, br.renderSize, "anche il motore classico la gira")
    }

    func testFadeInStartsBlackAndBlurZoomRender() async throws {
        var fx = VPEffects(); fx.fadeIn = 1; fx.fadeOut = 0.5; fx.blur = 0.5; fx.zoom = "in"
        let (p, infos) = try await one(fx)
        let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let start = lum(try await frame(b, at: 0.02), whole)
        let mid = lum(try await frame(b, at: 1.2), whole)
        let end = lum(try await frame(b, at: b.duration - 0.03), whole)
        XCTAssertLessThan(start, 0.05, "all'inizio è quasi nero")
        XCTAssertGreaterThan(mid, start + 0.15, "poi si vede")
        XCTAssertLessThan(end, mid * 0.3, "alla fine sparisce")
        let f = try await frame(b, at: 1.2)
        XCTAssertEqual(f.width, Int(b.renderSize.width))
    }

    func testSpeedAndTransitionsTogether() async throws {
        let a = try await Fixtures.video(name: "fx-a.mp4", width: 320, height: 180, seconds: 2)
        let bfile = try await Fixtures.video(name: "fx-b.mp4", width: 320, height: 180, seconds: 2)
        let ia = try await VPMediaInfo.load(a), ib = try await VPMediaInfo.load(bfile)
        var c1 = VPClip(path: a.path, inPoint: 0.2, outPoint: 1.6)
        var f1 = VPEffects(); f1.speed = 0.5; c1.fx = f1
        var c2 = VPClip(path: bfile.path, inPoint: 0.3, outPoint: 1.8)
        var f2 = VPEffects(); f2.speed = 3; c2.fx = f2
        c2.transition = VPTransition(kind: "fade", duration: 0.4)
        var p = VideoProject(); p.clips = [c1, c2]
        let built = try await VideoProjectBuilder.build(p, infos: [a.path: ia, bfile.path: ib], speech: [:], maxSide: 640, engine: .frames)
        XCTAssertEqual(built.duration, 1.4 / 0.5 + 1.5 / 3, accuracy: 0.02)
        XCTAssertEqual(built.composition.duration.seconds, built.duration, accuracy: 0.05)
        _ = try await frame(built, at: 2.8)                         // dentro il passaggio
    }

    /// Esportato a 2×: video e audio durano la metà, insieme.
    func testExportAtDoubleSpeed() async throws {
        var fast = VPEffects(); fast.speed = 2
        let (p0, _) = try await one(fast, seconds: 2, audio: true)
        var p = p0
        p.resolution = 720
        let out = Fixtures.dir.appendingPathComponent("fx-2x.mp4")
        let action = try XCTUnwrap(Catalog.action(id: "vproject", kind: .video))
        try await VideoProjectExport.run(project: p, speech: [:], out: out, job: Job(files: [p.clips[0].url], action: action, param: ""), progress: { _ in })
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 1, accuracy: 0.12)
        XCTAssertTrue(r.hasAudio)
    }

    func testSplitKeepsTransitionAndFadesOnTheRightPiece() {
        var c = VPClip(path: "/a.mp4", inPoint: 0, outPoint: 4)
        c.transition = VPTransition()
        var fx = VPEffects(); fx.fadeIn = 1; fx.fadeOut = 1; c.fx = fx
        var a = c, b = c
        VideoProjectStore.splitExtras(&a, &b)
        XCTAssertNotNil(a.transition); XCTAssertNil(b.transition)
        XCTAssertEqual(a.fx?.fadeIn, 1); XCTAssertEqual(a.fx?.fadeOut, 0)
        XCTAssertEqual(b.fx?.fadeIn, 0); XCTAssertEqual(b.fx?.fadeOut, 1)
    }
}
