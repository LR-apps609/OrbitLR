import XCTest
import AVFoundation
import CoreImage

/// 2.9 · Motore a fotogrammi e filtri.
final class VideoLooksTests: XCTestCase {
    /// Colore medio di una zona (x, y, larghezza, altezza in frazioni, origine in alto a sinistra).
    private func average(_ cg: CGImage, _ r: CGRect) -> (Double, Double, Double) {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let rect = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
        let ci = CIImage(cgImage: cg)
        let avg = ci.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        Media.ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    private func frame(_ b: VPBuilt, at t: Double) async throws -> CGImage {
        let g = AVAssetImageGenerator(asset: b.composition)
        g.videoComposition = b.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    /// Il motore nuovo deve disegnare il fotogramma esattamente come il vecchio (posizione e rotazione).
    private func assertSameAsLayers(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let info = try await VPMediaInfo.load(url)
        var p = VideoProject()
        p.clips = [VPClip(path: url.path, inPoint: 0, outPoint: info.videoDuration)]
        let a = try await VideoProjectBuilder.build(p, infos: [url.path: info], speech: [:], maxSide: 640, engine: .layers)
        let b = try await VideoProjectBuilder.build(p, infos: [url.path: info], speech: [:], maxSide: 640, engine: .frames)
        XCTAssertEqual(a.renderSize, b.renderSize, file: file, line: line)
        for t in [0.3, 1.2] {
            let fa = try await frame(a, at: t), fb = try await frame(b, at: t)
            for zone in [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                         CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                         CGRect(x: 0.33, y: 0.33, width: 0.34, height: 0.34)] {
                let ca = average(fa, zone), cb = average(fb, zone)
                XCTAssertEqual(ca.0, cb.0, accuracy: 0.06, "rosso, zona \(zone), t \(t)", file: file, line: line)
                XCTAssertEqual(ca.1, cb.1, accuracy: 0.06, "verde, zona \(zone), t \(t)", file: file, line: line)
                XCTAssertEqual(ca.2, cb.2, accuracy: 0.06, "blu, zona \(zone), t \(t)", file: file, line: line)
            }
        }
    }

    func testFramesEngineMatchesLayersLandscape() async throws {
        try await assertSameAsLayers(try await Fixtures.video(name: "motore-orizz.mp4", width: 320, height: 180, seconds: 2))
    }

    func testFramesEngineMatchesLayersPortrait() async throws {
        try await assertSameAsLayers(try await Fixtures.video(name: "motore-vert.mp4", width: 320, height: 180, seconds: 2, portrait: true))
    }

    func testFramesEngineTwoClipsDifferentSizes() async throws {
        let a = try await Fixtures.video(name: "motore-a.mp4", width: 320, height: 180, seconds: 1.5)
        let b = try await Fixtures.video(name: "motore-b.mp4", width: 240, height: 240, seconds: 1.5)
        let ia = try await VPMediaInfo.load(a), ib = try await VPMediaInfo.load(b)
        var p = VideoProject()
        p.clips = [VPClip(path: a.path, inPoint: 0, outPoint: ia.videoDuration), VPClip(path: b.path, inPoint: 0, outPoint: ib.videoDuration)]
        let infos = [a.path: ia, b.path: ib]
        let x = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .layers)
        let y = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640, engine: .frames)
        let t = ia.videoDuration + 0.5                      // dentro la seconda clip (quadrata, con bande nere)
        let fx = try await frame(x, at: t), fy = try await frame(y, at: t)
        for zone in [CGRect(x: 0, y: 0, width: 0.15, height: 1), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)] {
            let cx = average(fx, zone), cy = average(fy, zone)
            XCTAssertEqual(cx.0 + cx.1 + cx.2, cy.0 + cy.1 + cy.2, accuracy: 0.12, "zona \(zone)")
        }
    }

    func testLookColours() {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        func rgb(_ l: VPLook) -> (Double, Double, Double) {
            let out = VideoLooks.apply(l, to: gray)
            XCTAssertEqual(out.extent, gray.extent, "la misura non cambia")
            let cg = Media.ci.createCGImage(out, from: out.extent)!
            return average(cg, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        }
        let base = rgb(VPLook())
        var mono = VPLook(); mono.preset = "mono"
        let m = rgb(mono)
        XCTAssertEqual(m.0, m.1, accuracy: 0.03); XCTAssertEqual(m.1, m.2, accuracy: 0.03)
        var warm = VPLook(); warm.preset = "warm"
        let w = rgb(warm)
        XCTAssertGreaterThan(w.0 - w.2, base.0 - base.2 + 0.03, "caldo: più rosso che blu")
        var cool = VPLook(); cool.preset = "cool"
        let c = rgb(cool)
        XCTAssertLessThan(c.0 - c.2, base.0 - base.2 - 0.03, "freddo: più blu")
        var none = VPLook(); none.preset = "mono"; none.amount = 0
        let n = rgb(none)
        XCTAssertEqual(n.0, base.0, accuracy: 0.02, "forza 0: com'era")
        var bright = VPLook(); bright.brightness = 1
        XCTAssertGreaterThan(rgb(bright).1, base.1 + 0.1)
        for p in VideoLooks.presets {                          // nessun filtro rompe l'immagine
            var l = VPLook(); l.preset = p.id
            let v = rgb(l)
            XCTAssertTrue(v.0 + v.1 + v.2 > 0.05, "\(p.name) non deve dare un'immagine nera")
        }
    }

    func testProjectLookAndClipOverride() throws {
        var p = VideoProject()
        var mono = VPLook(); mono.preset = "mono"
        p.look = mono
        var c = VPClip(path: "/a.mp4", inPoint: 0, outPoint: 1)
        XCTAssertEqual(p.effectiveLook(c)?.preset, "mono")
        var warm = VPLook(); warm.preset = "warm"
        c.look = warm
        XCTAssertEqual(p.effectiveLook(c)?.preset, "warm", "la clip vince sul progetto")
        let old = #"{"clips":[{"id":"6F1E2A57-6A4D-4F0B-9C3D-1A2B3C4D5E6F","path":"/a.mp4","inPoint":0,"outPoint":1}],"originalVolume":1,"originalMuted":false,"aspect":"orig","follow":true,"resolution":1080,"fps":30}"#
        let d = try JSONDecoder().decode(VideoProject.self, from: Data(old.utf8))
        XCTAssertNil(d.look, "i progetti di prima si aprono senza filtri")
    }

    func testExportWithMonoFilterIsGray() async throws {
        let v = try await Fixtures.video(name: "export-bn.mp4", width: 320, height: 180, seconds: 1.5)
        let info = try await VPMediaInfo.load(v)
        var p = VideoProject()
        p.clips = [VPClip(path: v.path, inPoint: 0, outPoint: info.videoDuration)]
        var mono = VPLook(); mono.preset = "mono"
        p.look = mono
        p.resolution = 720
        let out = Fixtures.dir.appendingPathComponent("export-bn-out.mp4")
        let a = try XCTUnwrap(Catalog.action(id: "vproject", kind: .video))
        try await VideoProjectExport.run(project: p, speech: [:], out: out, job: Job(files: [v], action: a, param: ""), progress: { _ in })
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        let cg = try await g.image(at: CMTime(seconds: 0.7, preferredTimescale: 600)).image
        let c = average(cg, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(c.0, c.1, accuracy: 0.04, "bianco e nero anche nel file esportato")
        XCTAssertEqual(c.1, c.2, accuracy: 0.04)
    }
}
