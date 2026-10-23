import XCTest

/// 2.8.1 · Controlla aggiornamenti.
final class UpdateCheckTests: XCTestCase {
    func testParseGitHubRelease() throws {
        let json = """
        {"tag_name":"v2.8.1","html_url":"https://github.com/LR-apps609/OrbitLR/releases/tag/v2.8.1",
         "assets":[{"name":"note.txt","browser_download_url":"https://x/note.txt"},
                   {"name":"OrbitLR.2.8.1.orbitlr","browser_download_url":"https://x/OrbitLR.2.8.1.orbitlr"}]}
        """
        let r = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "2.8.1")
        XCTAssertEqual(r.asset.absoluteString, "https://x/OrbitLR.2.8.1.orbitlr")
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v3","assets":[]}"#.utf8)), "senza file .orbitlr non c'è niente da installare")
        XCTAssertNil(UpdateCheck.parse(Data("non json".utf8)))
    }

    func testAutoCheckOncePerDay() {
        let d = UserDefaults(suiteName: "orbitlr-test-\(UUID().uuidString)")!
        let now = Date()
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, defaults: d), "mai controllato")
        d.set(now.timeIntervalSince1970 - 3600, forKey: UpdateCheck.lastKey)
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, defaults: d), "un'ora fa: no")
        d.set(now.timeIntervalSince1970 - 21 * 3600, forKey: UpdateCheck.lastKey)
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, defaults: d))
        d.set(false, forKey: UpdateCheck.autoKey)
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, defaults: d), "spento: mai")
    }

    func testInstallAlertShowsOnlyNewItems() {
        let news = "Novità della 2.8.1:\n• Uno\n\nNovità della 2.8:\n• Due\n\nNovità della 2.7.7:\n• Tre\n"
        XCTAssertEqual(News.items(since: "2.7.7", in: news, maxVersions: 5), ["Uno", "Due"])
    }
}
