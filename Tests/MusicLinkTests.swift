import XCTest

/// 4.1 · Musica da un link e ritornello per la suoneria.
final class MusicLinkTests: XCTestCase {
    func testSoloLinkVeri() {
        XCTAssertNotNil(MusicLink.link(from: "  https://example.com/canzone?id=3\n"))
        XCTAssertNotNil(MusicLink.link(from: "http://musica.it/brano"))
        XCTAssertNil(MusicLink.link(from: "file:///etc/passwd"), "mai file del Mac")
        XCTAssertNil(MusicLink.link(from: "ciao come stai"))
        XCTAssertNil(MusicLink.link(from: "https://localhost/x"))
        XCTAssertNil(MusicLink.link(from: "-o /tmp/x"), "niente opzioni travestite da link")
    }

    func testImprontaDallElenco() {
        let sums = """
        2b5251788b36fcbc476568b4eea8cb239f0a775759456f2ff9344a437c52f000  yt-dlp_macos.zip
        7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40  yt-dlp_macos
        """
        XCTAssertEqual(MusicLink.expectedHash(in: sums, for: "yt-dlp_macos"), "7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40")
        XCTAssertNil(MusicLink.expectedHash(in: sums, for: "yt-dlp_linux"))
    }

    func testAvanzamentoEErrori() {
        XCTAssertEqual(MusicLink.percent(in: "[download]  42.3% of    3.21MiB at  1.2MiB/s ETA 00:01") ?? -1, 0.423, accuracy: 0.0001)
        XCTAssertNil(MusicLink.percent(in: "[info] qualcosa"))
        XCTAssertTrue(MusicLink.friendly("ERROR: Unsupported URL: https://x.it").contains("non so prendere"))
        XCTAssertTrue(MusicLink.friendly("ERROR: Private video. Sign in").contains("privato"))
        XCTAssertTrue(MusicLink.friendly("HTTP Error 403: Forbidden").contains("rifiutato"))
        XCTAssertTrue(MusicLink.friendly("ERROR: [Netflix] This video is DRM protected").contains("DRM"), "Netflix e simili: un messaggio chiaro")
    }

    func testRitornello() {
        // 3 minuti: strofa bassa, ritornello forte da 70 a 100 s, finale forte (che va ignorato)
        let duration = 180.0, perSec = 4.0
        let n = Int(duration * perSec)
        var peaks = [Float](repeating: 0.3, count: n)
        for i in Int(70 * perSec)..<Int(100 * perSec) { peaks[i] = 0.9 }
        for i in Int(170 * perSec)..<n { peaks[i] = 1.0 }
        let s = TrimModel.loudestWindow(peaks: peaks, duration: duration, length: 30)
        XCTAssertEqual(s, 69.5, accuracy: 1.0, "il riquadro va sul ritornello, non sul finale")
        XCTAssertEqual(TrimModel.loudestWindow(peaks: [0.5, 0.5], duration: 10, length: 30), 0, "canzone più corta della suoneria")
    }

    func testFormatiVideo() {
        let v = MusicLink.formatArgs(.video).joined(separator: " ")
        XCTAssertTrue(v.contains("avc1") && v.contains("height<=1080"), "di base MP4 H.264 fino a 1080p")
        XCTAssertTrue(v.contains("--merge-output-format mp4"))
        XCTAssertFalse(v.contains("-x"), "il video non diventa solo audio")
        let b = MusicLink.formatArgs(.videoBest).joined(separator: " ")
        XCTAssertFalse(b.contains("1080"), "massima qualità: nessun limite")
        XCTAssertTrue(MusicLink.formatArgs(.audio).contains("-x"))
    }
}
