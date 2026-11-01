import XCTest

/// 5.1.1 · Downloader che non si blocca: i link di Drive & co. si rifiutano subito; il motore che tace viene notato.
final class SafeLinksTests: XCTestCase {
    func testCloudLinksAreRefusedUpFront() throws {
        for s in ["https://drive.google.com/file/d/abc/view?usp=sharing", "https://docs.google.com/uc?id=x",
                  "https://www.dropbox.com/s/x/video.mp4", "https://www.icloud.com/iclouddrive/x", "https://we.tl/t-abc".replacingOccurrences(of: "we.tl", with: "wetransfer.com")] {
            let u = try XCTUnwrap(MusicLink.link(from: s))
            XCTAssertNotNil(MusicLink.unsupportedReason(u), s)
        }
        for s in ["https://www.youtube.com/watch?v=x", "https://www.instagram.com/reel/x", "https://vimeo.com/1"] {
            let u = try XCTUnwrap(MusicLink.link(from: s))
            XCTAssertNil(MusicLink.unsupportedReason(u), s)
        }
    }

    func testSilenceIsNoticed() {
        let c = MusicLink.Collected()
        XCTAssertNil(c.lastOutput)
        c.touch()
        XCTAssertNotNil(c.lastOutput)
        XCTAssertLessThan(Date().timeIntervalSince(c.lastOutput!), 1)
    }

    func testStopEndsAProcessThatIgnoresItsPipes() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        MusicLink.stop(p)
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(p.isRunning, "«Interrompi» ferma davvero il motore")
    }
}
