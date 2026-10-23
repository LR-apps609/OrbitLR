import XCTest
import CoreImage
import AVFoundation
import CoreML

/// 2.9.7 · Rimuovi filigrana con l'IA (LaMa). Il modello si scarica come farebbe l'app;
/// se non è ancora tra i file scaricabili la prova si salta (e lo dice).
final class InpaintTests: XCTestCase {
    private func model() async throws -> MLModelHolder {
        do { return MLModelHolder(try await ModelStore.shared.lama()) }
        catch { throw XCTSkip("modello di IA non disponibile: \(error.localizedDescription)") }
    }

    private func mean(_ img: CIImage, _ r: CGRect) -> (Double, Double, Double) {
        let avg = img.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: r)])
        var px = [UInt8](repeating: 0, count: 4)
        Media.ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Un fondo liscio con un «logo» bianco: dopo l'IA, al posto del logo c'è il colore del fondo.
    func testRemovesLogoOnPlainBackground() async throws {
        let m = try await model()
        let W: CGFloat = 640, H: CGFloat = 400
        let bg = CIImage(color: CIColor(red: 0.2, green: 0.45, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let logoRect = CGRect(x: 480, y: 330, width: 120, height: 40)          // in alto a destra (Core Image: origine in basso)
        let withLogo = CIImage(color: .white).cropped(to: logoRect).composited(over: bg)
        let zone = CGRect(x: 470 / W, y: (H - 375) / H, width: 140 / W, height: 50 / H)   // un po' più grande del logo
        let spec = HideMark.Spec(style: "ai", strength: 0.6, rects: [zone])
        let out = try Inpainter(model: m.model).apply(spec, to: withLogo)
        XCTAssertEqual(out.extent, withLogo.extent, "la misura non cambia")
        let inside = mean(out, logoRect.insetBy(dx: 10, dy: 8))
        XCTAssertEqual(inside.0, 0.2, accuracy: 0.08, "rosso come il fondo")
        XCTAssertEqual(inside.1, 0.45, accuracy: 0.08, "verde come il fondo")
        XCTAssertEqual(inside.2, 0.6, accuracy: 0.08, "blu come il fondo")
        let far = mean(out, CGRect(x: 20, y: 20, width: 200, height: 150))
        XCTAssertEqual(far.1, 0.45, accuracy: 0.02, "lontano dalla zona non cambia niente")
    }

    /// Dal file: foto e video con «Rimuovi (IA)» passano dallo strumento vero.
    func testPhotoAndVideoThroughTool() async throws {
        _ = try await model()
        let photo = try Fixtures.photo(name: "ia-foto.png", width: 600, height: 400)
        let spec = HideMark.Spec(style: "ai", strength: 0.6, rects: [CGRect(x: 0.7, y: 0.85, width: 0.25, height: 0.1)])
        let dir = Fixtures.dir.appendingPathComponent("ia-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jp = try Fixtures.job("hidemark", kind: .img, files: [photo], param: HideMark.encode(spec))
        let outPhoto = try await Tools.run(job: jp, file: photo, dir: dir) { _ in }
        let cg = try Tools.cgImage(try Tools.orientedImage(outPhoto))
        XCTAssertEqual(cg.width, 600); XCTAssertEqual(cg.height, 400)

        let video = try await Fixtures.video(name: "ia-video.mp4", width: 320, height: 180, seconds: 0.6)
        let jv = try Fixtures.job("hidemark", kind: .video, files: [video], param: HideMark.encode(spec))
        let outVideo = try await Tools.run(job: jv, file: video, dir: dir) { _ in }
        let a = try await Fixtures.probe(video), b = try await Fixtures.probe(outVideo)
        XCTAssertEqual(b.duration, a.duration, accuracy: 0.15)
        XCTAssertEqual(b.displaySize, a.displaySize)
    }
}

/// Il modello come valore da passare in giro nei test.
struct MLModelHolder { let model: MLModel; init(_ m: MLModel) { model = m } }
