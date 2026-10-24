import XCTest

/// 3.5.2 · Numeri all'italiana: virgola per i decimali, anche su un Mac in inglese.
final class ItalianNumbersTests: XCTestCase {
    func testTempiConLaVirgola() {
        XCTAssertEqual(formatTime(30.5), "0:30,5")
        XCTAssertEqual(formatTime(3725.3), "1:02:05,3")
        XCTAssertEqual(parseTime(formatTime(30.5)), 30.5, "si rilegge quello che si scrive")
        XCTAssertEqual(Fmt.secs(1.5), "1,5 s")
    }

    func testPesiConLaVirgola() {
        let t = Fmt.bytes(2_800_000)
        XCTAssertFalse(t.contains("."), t)
        XCTAssertTrue(t.contains(","), t)
    }
}
