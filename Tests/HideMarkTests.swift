import XCTest
import AVFoundation
import CoreImage

/// 2.9.4 · Nascondi filigrana.
final class HideMarkTests: XCTestCase {
    /// Quanto «dettaglio» c'è in una zona (frazioni, origine in alto a sinistra): differenza media con una copia appena sfocata.
    private func detail(_ cg: CGImage, _ r: CGRect) -> Double {
        let img = CIImage(cgImage: cg)
        let soft = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2]).cropped(to: img.extent)
        let diff = img.applyingFilter("CIDifferenceBlendMode", parameters: ["inputBackgroundImage": soft])
        let rect = HideMark.pixelRect(r, in: img.extent)
        let avg = diff.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        Media.ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 765
    }

    private func load(_ u: URL) throws -> CGImage {
        try Tools.cgImage(try Tools.orientedImage(u))
    }

    func testParamRoundTrip() throws {
        var s = HideMark.Spec()
        s.style = "pixel"; s.strength = 0.8
        s.rects = [CGRect(x: 0.8, y: 0.9, width: 0.15, height: 0.06), CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.1)]
        let back = try XCTUnwrap(HideMark.parse(HideMark.encode(s)))
        XCTAssertEqual(back.style, "pixel")
        XCTAssertEqual(back.strength, 0.8, accuracy: 0.001)
        XCTAssertEqual(back.rects.count, 2)
        XCTAssertEqual(back.rects[0].minX, 0.8, accuracy: 0.0001)
        XCTAssertEqual(back.rects[1].height, 0.1, accuracy: 0.0001)
        XCTAssertNil(HideMark.parse("blur|0.5|"), "senza zone non si parte")
        XCTAssertNil(HideMark.parse("qualcosa"))
        // Una zona che esce dall'immagine si taglia ai bordi
        let cut = try XCTUnwrap(HideMark.parse("blur|0.5|0.9,0.9,0.5,0.5"))
        XCTAssertEqual(cut.rects[0].maxX, 1, accuracy: 0.0001)
    }

    /// Dentro la zona il dettaglio sparisce, fuori resta identico; la misura non cambia.
    func testPhotoBlurAndPixelOnlyInside() throws {
        let src = try Fixtures.photo(name: "filigrana.png", width: 800, height: 600)
        let zone = CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.2)
        let outside = CGRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3)
        let original = try load(src)
        for style in ["blur", "pixel"] {
            let out = Fixtures.url("filigrana-\(style).png")
            try? FileManager.default.removeItem(at: out)
            try HideMark.image(src, spec: HideMark.Spec(style: style, strength: 0.6, rects: [zone]), out: out)
            let res = try load(out)
            XCTAssertEqual(res.width, original.width, "\(style): stessa larghezza")
            XCTAssertEqual(res.height, original.height, "\(style): stessa altezza")
            XCTAssertLessThan(detail(res, zone.insetBy(dx: 0.02, dy: 0.02)), detail(original, zone) * 0.5, "\(style): dentro, niente dettaglio")
            XCTAssertEqual(detail(res, outside), detail(original, outside), accuracy: 0.004, "\(style): fuori, tutto com'era")
        }
    }

    /// Il video esce con la stessa durata e la zona sfocata in ogni momento.
    func testVideoBlur() async throws {
        let src = try await Fixtures.video(name: "filigrana.mp4", width: 320, height: 180, seconds: 2, noise: true)
        let out = Fixtures.url("filigrana-out.mp4")
        try? FileManager.default.removeItem(at: out)
        let zone = CGRect(x: 0.0, y: 0.0, width: 0.4, height: 0.4)
        let spec = HideMark.Spec(style: "blur", strength: 0.7, rects: [zone])
        let job = try Fixtures.job("hidemark", kind: .video, files: [src], param: HideMark.encode(spec))
        try await HideMark.video(src, spec: spec, out: out, job: job) { _ in }
        let a = try await Fixtures.probe(src), b = try await Fixtures.probe(out)
        XCTAssertEqual(b.duration, a.duration, accuracy: 0.15)
        XCTAssertEqual(b.displaySize, a.displaySize)
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        g.appliesPreferredTrackTransform = true
        let f = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let inside = detail(f, CGRect(x: 0.03, y: 0.03, width: 0.3, height: 0.3))
        let outside = detail(f, CGRect(x: 0.6, y: 0.6, width: 0.35, height: 0.35))
        XCTAssertLessThan(inside, outside * 0.5, "la zona in alto a sinistra è sfocata, il resto no")
    }

    /// Video girato (come quelli dell'iPhone): la zona sta dove l'hai disegnata, non ruotata.
    func testVideoPortraitZoneStaysWhereDrawn() async throws {
        let src = try await Fixtures.video(name: "filigrana-vert.mp4", width: 320, height: 180, seconds: 1.5, portrait: true, noise: true)
        let out = Fixtures.url("filigrana-vert-out.mp4")
        try? FileManager.default.removeItem(at: out)
        let spec = HideMark.Spec(style: "pixel", strength: 0.8, rects: [CGRect(x: 0, y: 0.75, width: 1, height: 0.25)])   // in basso
        let job = try Fixtures.job("hidemark", kind: .video, files: [src], param: HideMark.encode(spec))
        try await HideMark.video(src, spec: spec, out: out, job: job) { _ in }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        g.appliesPreferredTrackTransform = true
        let f = try await g.image(at: CMTime(seconds: 0.7, preferredTimescale: 600)).image
        XCTAssertGreaterThan(f.height, f.width, "resta verticale")
        let bottom = detail(f, CGRect(x: 0.05, y: 0.8, width: 0.9, height: 0.15))
        let top = detail(f, CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.2))
        XCTAssertLessThan(bottom, top * 0.5, "a quadretti in basso, nitido in alto")
    }

    func testActionIsOfferedForPhotosAndVideos() {
        XCTAssertTrue(Catalog.actions(for: .img, exts: ["jpg"], mergeable: 1).contains { $0.id == "hidemark" })
        XCTAssertTrue(Catalog.actions(for: .video, exts: ["mp4"], mergeable: 1).contains { $0.id == "hidemark" })
        XCTAssertFalse(Catalog.actions(for: .img, exts: ["svg"], mergeable: 1).contains { $0.id == "hidemark" })
    }
}
