import XCTest

/// 3.1 · Volto: il guadagno in parole, i suoni nuovi, un solo modo di muoversi.
final class VoltoTests: XCTestCase {
    func testGuadagnoInParole() {
        let g = Job.gain(before: 48_000_000, after: 9_000_000, done: true)
        XCTAssertTrue(g.hasPrefix("da "), g)
        XCTAssertTrue(g.hasSuffix("−81%"), g)
        XCTAssertFalse(Job.gain(before: 1_000_000, after: 2_000_000, done: true).contains("%"), "se pesa di più, niente percentuale")
        XCTAssertEqual(Job.gain(before: 0, after: 10, done: true), "")
        XCTAssertEqual(Job.gain(before: 10, after: 5, done: false), "", "solo a lavoro finito")
    }

    func testISuoniCiSonoTutti() {
        // I test non includono le risorse dell'app: si guarda la cartella del progetto
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds")
        for e in Sounds.Effect.allCases {
            let u = dir.appendingPathComponent(e.rawValue + ".wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), "manca il suono \(e.rawValue)")
            XCTAssertLessThan(Job.size(of: u), 200_000, "\(e.rawValue): un suono deve restare leggero")
        }
    }
}
