import XCTest
import AppKit

/// 3.5.1 · Miniature: un file sparito non lascia una miniatura vecchia in memoria.
@MainActor
final class ThumbCacheTests: XCTestCase {
    func testFileSparitoNonLasciaMiniatura() async throws {
        let url = Fixtures.dir.appendingPathComponent("miniatura-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: Fixtures.dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)

        let first = await ThumbCache.shared.image(for: url, side: 88)
        if first != nil { XCTAssertNotNil(ThumbCache.shared.cached(for: url, side: 88), "pronta in memoria") }

        try FileManager.default.removeItem(at: url)
        let gone = await ThumbCache.shared.image(for: url, side: 88)
        XCTAssertNil(gone, "il file non c'è più")
        XCTAssertNil(ThumbCache.shared.cached(for: url, side: 88), "e nemmeno la miniatura vecchia")
    }
}
