import XCTest
import AVFoundation
import CoreImage

/// 2.9.3 · Transizioni tra le clip.
final class VideoTransitionsTests: XCTestCase {
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

    /// Due clip: A scura, B chiara (con le regolazioni), così si vede chi c'è sullo schermo.
    private func project(_ kind: String?, duration: Double = 0.8, trimmed: Bool) async throws -> (VideoProject, [String: VPMediaInfo]) {
        let a = try await Fixtures.video(name: "tr-a.mp4", width: 320, height: 180, seconds: 2)
        let b = try await Fixtures.video(name: "tr-b.mp4", width: 320, height: 180, seconds: 2)
        let ia = try await VPMediaInfo.load(a), ib = try await VPMediaInfo.load(b)
        var dark = VPLook(); dark.brightness = -1
        var light = VPLook(); light.brightness = 1
        var ca = VPClip(path: a.path, inPoint: 0, outPoint: trimmed ? 1.5 : ia.videoDuration)
        ca.look = dark
        var cb = VPClip(path: b.path, inPoint: trimmed ? 0.5 : 0, outPoint: ib.videoDuration)
        cb.look = light
        if let kind { cb.transition = VPTransition(kind: kind, duration: duration) }
        var p = VideoProject()
        p.clips = [ca, cb]
        return (p, [a.path: ia, b.path: ib])
    }

    private let top = CGRect(x: 0, y: 0, width: 1, height: 0.2)          // lo sfondo, lontano dal quadrato che si muove

    func testDurationClamp() {
        let t = VPTransition(kind: "fade", duration: 1.5)
        XCTAssertEqual(VideoProjectBuilder.transitionDuration(t, before: 10, after: 10), 1.5, accuracy: 0.001)
        XCTAssertEqual(VideoProjectBuilder.transitionDuration(t, before: 1, after: 10), 0.4, accuracy: 0.001, "mai più del 40% della clip")
        XCTAssertEqual(VideoProjectBuilder.transitionDuration(VPTransition(duration: 5), before: 10, after: 10), 2, accuracy: 0.001)
        XCTAssertEqual(VideoProjectBuilder.transitionDuration(nil, before: 10, after: 10), 0)
    }

    /// La durata del montaggio non cambia: la timeline resta giusta.
    func testDurationUnchanged() async throws {
        for trimmed in [false, true] {
            let (p0, infos) = try await project(nil, trimmed: trimmed)
            let (p1, _) = try await project("fade", trimmed: trimmed)
            let x = try await VideoProjectBuilder.build(p0, infos: infos, speech: [:], maxSide: 640, engine: .frames)
            let y = try await VideoProjectBuilder.build(p1, infos: infos, speech: [:], maxSide: 640, engine: .frames)
            XCTAssertEqual(x.duration, y.duration, accuracy: 0.001)
            XCTAssertEqual(y.composition.duration.seconds, y.duration, accuracy: 0.05, "nessun pezzo oltre la fine")
            let c = try await VideoProjectBuilder.build(p1, infos: infos, speech: [:], maxSide: 640, engine: .layers)
            XCTAssertEqual(c.duration, y.duration, accuracy: 0.001, "il motore classico ignora le transizioni ma dura uguale")
        }
    }

    /// Dissolvenza: a metà del passaggio la luce sta tra quella di A e quella di B; fuori dal passaggio, solo A o solo B.
    func testFadeBlendsBothPaths() async throws {
        for trimmed in [false, true] {                 // senza margini (fotogramma fermo) e con margini veri
            let (p, infos) = try await project("fade", trimmed: trimmed)
            let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
            let cut = p.clips[0].length
            let a0 = lum(try await frame(b, at: 0.3), top)
            let b0 = lum(try await frame(b, at: b.duration - 0.3), top)
            XCTAssertGreaterThan(b0, a0 + 0.25, "B è più chiara di A")
            let mid = lum(try await frame(b, at: cut), top)
            XCTAssertGreaterThan(mid, a0 + 0.08, "a metà si vede anche B (margini: \(trimmed))")
            XCTAssertLessThan(mid, b0 - 0.08, "a metà si vede ancora A (margini: \(trimmed))")
            let before = lum(try await frame(b, at: cut - 0.6), top)
            XCTAssertEqual(before, a0, accuracy: 0.08, "prima del passaggio solo A")
        }
    }

    func testFadeToBlack() async throws {
        let (p, infos) = try await project("black", trimmed: true)
        let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let f = try await frame(b, at: p.clips[0].length)
        XCTAssertLessThan(lum(f, CGRect(x: 0, y: 0, width: 1, height: 1)), 0.08, "a metà: nero")
    }

    func testFadeToWhite() async throws {
        let (p, infos) = try await project("white", trimmed: true)
        let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let f = try await frame(b, at: p.clips[0].length)
        XCTAssertGreaterThan(lum(f, CGRect(x: 0, y: 0, width: 1, height: 1)), 0.9, "a metà: bianco")
    }

    /// Scorrimento: a metà, A a sinistra e B a destra.
    func testSlideHalves() async throws {
        let (p, infos) = try await project("slide", trimmed: true)
        let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let f = try await frame(b, at: p.clips[0].length)
        let left = lum(f, CGRect(x: 0.02, y: 0, width: 0.3, height: 0.2)), right = lum(f, CGRect(x: 0.68, y: 0, width: 0.3, height: 0.2))
        XCTAssertGreaterThan(right, left + 0.2, "B entra da destra")
    }

    /// Nessuna transizione rompe l'immagine.
    func testAllKindsRender() async throws {
        for k in VPTransition.kinds.map(\.id) {
            let (p, infos) = try await project(k, trimmed: true)
            let b = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
            let cut = p.clips[0].length
            for t in [cut - 0.3, cut, cut + 0.3] {
                let f = try await frame(b, at: t)
                XCTAssertEqual(f.width, Int(b.renderSize.width), "\(k)")
            }
        }
    }

    /// L'esportazione usa lo stesso disegno: il file ha la durata giusta e il passaggio dentro.
    func testExportWithTransition() async throws {
        let (p0, _) = try await project("fade", trimmed: true)
        var p = p0
        p.resolution = 720
        let out = Fixtures.dir.appendingPathComponent("tr-out.mp4")
        let a = try XCTUnwrap(Catalog.action(id: "vproject", kind: .video))
        try await VideoProjectExport.run(project: p, speech: [:], out: out, job: Job(files: [p.clips[0].url], action: a, param: ""), progress: { _ in })
        let asset = AVURLAsset(url: out)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, p.duration, accuracy: 0.15)
        let g = AVAssetImageGenerator(asset: asset)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let a0 = lum(try await g.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image, top)
        let mid = lum(try await g.image(at: CMTime(seconds: p.clips[0].length, preferredTimescale: 600)).image, top)
        XCTAssertGreaterThan(mid, a0 + 0.08, "nel file esportato c'è il passaggio")
    }

    func testOldProjectsHaveNoTransitions() throws {
        let old = #"{"id":"6F1E2A57-6A4D-4F0B-9C3D-1A2B3C4D5E6F","path":"/a.mp4","inPoint":0,"outPoint":1}"#
        let c = try JSONDecoder().decode(VPClip.self, from: Data(old.utf8))
        XCTAssertNil(c.transition)
    }
}
