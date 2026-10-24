import XCTest

/// 2.8.1 · Controlla aggiornamenti.
final class UpdateCheckTests: XCTestCase {
    func testParseGitHubRelease() throws {
        let json = """
        {"tag_name":"v2.8.1","html_url":"https://github.com/LR-apps609/OrbitLR/releases/tag/v2.8.1",
         "assets":[{"name":"note.txt","browser_download_url":"https://github.com/LR-apps609/OrbitLR/releases/download/v2.8.1/note.txt"},
                   {"name":"OrbitLR.2.8.1.orbitlr","browser_download_url":"https://github.com/LR-apps609/OrbitLR/releases/download/v2.8.1/OrbitLR.2.8.1.orbitlr"}]}
        """
        let r = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "2.8.1")
        XCTAssertEqual(r.asset.absoluteString, "https://github.com/LR-apps609/OrbitLR/releases/download/v2.8.1/OrbitLR.2.8.1.orbitlr")
        // 3.5.2 · Da altri siti, o non in modo sicuro: si ignora
        for bad in ["https://x/OrbitLR.orbitlr", "http://github.com/LR-apps609/OrbitLR/releases/download/v9/OrbitLR.orbitlr",
                    "https://github.com/altro/OrbitLR/releases/download/v9/OrbitLR.orbitlr"] {
            let j = #"{"tag_name":"v9","assets":[{"name":"OrbitLR.orbitlr","browser_download_url":"\#(bad)"}]}"#
            XCTAssertNil(UpdateCheck.parse(Data(j.utf8)), bad)
        }
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

/// 2.8.3 · Aiuto: ricerca e contenuti.
final class HelpTests: XCTestCase {
    func testSearchIgnoresCaseAndAccents() {
        XCTAssertTrue(FAQ.search("VERTICALE").contains { $0.id == "vformat" })
        XCTAssertTrue(FAQ.search("piu pdf").contains { $0.id == "fmerge" }, "«più» si trova anche senza accento")
        XCTAssertEqual(FAQ.search("").count, FAQ.all.count)
        XCTAssertTrue(FAQ.search("zzzz nessuna").isEmpty)
    }

    func testEveryAnswerHasAKnownSectionAndUniqueId() {
        XCTAssertEqual(Set(FAQ.all.map { $0.id }).count, FAQ.all.count)
        XCTAssertTrue(FAQ.all.allSatisfy { FAQ.sections.contains($0.section) })
        XCTAssertTrue(FAQ.all.allSatisfy { !$0.answer.isEmpty && $0.question.count < 90 })
    }
}
