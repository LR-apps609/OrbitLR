import XCTest
import ImageIO

/// 3.6 · Foto più leggere: sotto il peso scelto con la qualità più alta possibile, oppure uguali ma più leggere.
final class SmartImageTests: XCTestCase {
    private func size(_ u: URL) -> (Int, Int) {
        let s = CGImageSourceCreateWithURL(u as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
    }

    func testSottoUnPesoPerIModuli() throws {
        let f = try Fixtures.photo(name: "modulo.jpg", width: 3000, height: 2000)
        XCTAssertGreaterThan(Job.size(of: f), 200_000, "la foto di prova deve pesare più di 200 KB")
        let out = try SmartImage.compress(f, targetBytes: 200_000, dir: Fixtures.dir)
        XCTAssertLessThanOrEqual(Job.size(of: out), 200_000, "sotto i 200 KB")
        XCTAssertEqual(out.pathExtension, "jpg")
        let (w, h) = size(out)
        XCTAssertEqual(Double(w) / Double(h), 1.5, accuracy: 0.01, "le proporzioni restano")
    }

    func testPrimaLaQualitaPoiLaMisura() throws {
        let f = try Fixtures.photo(name: "qualita-foto.jpg", width: 2000, height: 1500)
        let source = CGImageSourceCreateWithURL(f as CFURL, nil)!
        // Un peso ampio: misura piena, qualità alta
        let big = try XCTUnwrap(SmartImage.fit(source, longSide: 2000, target: 2_000_000))
        XCTAssertEqual(big.longSide, 2000)
        // Un peso piccolo: la qualità non scende mai sotto il minimo, si rimpicciolisce invece
        let small = try XCTUnwrap(SmartImage.fit(source, longSide: 2000, target: 40_000))
        XCTAssertGreaterThanOrEqual(small.quality, SmartImage.minQuality)
        XCTAssertLessThan(small.longSide, 2000)
        XCTAssertLessThanOrEqual(small.data.count, 40_000)
    }

    func testStessaQualitaMenoPeso() throws {
        let f = try Fixtures.photo(name: "uguale.jpg", width: 2400, height: 1600)
        do {
            let out = try SmartImage.compress(f, targetBytes: nil, dir: Fixtures.dir)
            XCTAssertLessThan(Job.size(of: out), Job.size(of: f))
            let (w, h) = size(out)
            XCTAssertEqual(w, 2400); XCTAssertEqual(h, 1600)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("già compressa"), error.localizedDescription)
        }
    }

    func testPesoImpossibileLoDice() throws {
        let f = try Fixtures.photo(name: "impossibile.jpg", width: 1200, height: 800)
        XCTAssertThrowsError(try SmartImage.compress(f, targetBytes: 300, dir: Fixtures.dir)) {
            XCTAssertTrue($0.localizedDescription.contains("peso un po’ maggiore"), $0.localizedDescription)
        }
    }

    func testNelCatalogo() {
        XCTAssertTrue(Catalog.actions(for: .img, exts: ["jpg"], mergeable: 1).contains { $0.id == "icompress" })
        XCTAssertEqual(ParamChoices.defaultValue(for: .icompress), "best")
        XCTAssertEqual(ParamChoices.defaultValue(for: .vcompress), "best")
    }
}
