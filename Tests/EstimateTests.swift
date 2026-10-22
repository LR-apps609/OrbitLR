import XCTest

/// 2.7 · Il peso previsto sugli spicchi deve essere vicino a quello vero.
final class EstimateTests: XCTestCase {
    func testImageEstimateMatchesRealConversion() async throws {
        let src = try Fixtures.photo(name: "stima.png")
        let actions = ["to:jpg", "to:heic", "to:png"].compactMap { Catalog.action(id: $0, kind: .img) }
        let e = await SizeEstimate.estimates(actions: actions, files: [src], kind: .img)
        XCTAssertEqual(e.count, 3, "una stima per ogni formato: \(e)")
        let out = Fixtures.url("stima-vera.jpg")
        try NativeEngine.convertImage(src, to: "jpg", resize: nil, out: out)
        let real = Double(Job.size(of: out))
        let guess = Double(e["to:jpg"] ?? 0)
        XCTAssertEqual(guess / real, 1, accuracy: 0.05, "JPG: previsto \(guess), vero \(real)")
        XCTAssertLessThan(e["to:heic"] ?? .max, e["to:png"] ?? 0, "HEIC pesa meno del PNG")
    }

    func testManyImagesAreExtrapolated() async throws {
        let files = try (0..<6).map { try Fixtures.photo(name: "lotto-\($0).jpg", width: 800, height: 600) }
        let a = try XCTUnwrap(Catalog.action(id: "to:png", kind: .img))
        let e = await SizeEstimate.estimates(actions: [a], files: files, kind: .img)
        var real: Int64 = 0
        for (i, f) in files.enumerated() {
            let out = Fixtures.url("lotto-vero-\(i).png")
            try NativeEngine.convertImage(f, to: "png", resize: nil, out: out)
            real += Job.size(of: out)
        }
        XCTAssertEqual(Double(e["to:png"] ?? 0) / Double(real), 1, accuracy: 0.3)
    }

    func testAudioEstimateIsClose() async throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 20, freq: 330).enumerated().map { i, v in v + Float(i % 97) / 970 - 0.05 },
                                   name: "stima.wav")
        let a = try XCTUnwrap(Catalog.action(id: "to:wav", kind: .audio))
        let m4a = try XCTUnwrap(Catalog.action(id: "to:m4a", kind: .audio))
        let e = await SizeEstimate.estimates(actions: [a, m4a], files: [src], kind: .audio)
        XCTAssertNil(e["to:m4a"], "M4A è a qualità variabile: nessuna stima")
        let guess = try XCTUnwrap(e["to:wav"])
        let real = 1_411_200.0 * 20 / 8                               // WAV 16 bit stereo 44,1 kHz: peso esatto
        XCTAssertEqual(Double(guess) / real, 1, accuracy: 0.05, "WAV: previsto \(guess), vero \(real)")
    }

    func testNoEstimateWhenUnknown() async throws {
        let src = try Fixtures.photo(name: "nessuna.jpg", width: 400, height: 300)
        let a = try XCTUnwrap(Catalog.action(id: "removebg", kind: .img))
        let e = await SizeEstimate.estimates(actions: [a], files: [src], kind: .img)
        XCTAssertTrue(e.isEmpty, "niente numeri dove non si può sapere")
    }
}

/// 2.7 · Statistiche del mese nella Cronologia.
final class MonthStatsTests: XCTestCase {
    func testCountsOnlyThisMonthAndNotUndone() {
        let now = Date()
        let old = Calendar.current.date(byAdding: .month, value: -2, to: now)!
        var undone = HistoryEntry(date: now, title: "x", action: "In PNG", outputs: ["/a", "/b"], kind: "img", before: 900, after: 100)
        undone.undone = true
        let h = [
            HistoryEntry(date: now, title: "a", action: "In JPG", outputs: ["/1"], kind: "img", before: 5_000, after: 1_000),
            HistoryEntry(date: now, title: "b", action: "In JPG", outputs: ["/2", "/3"], kind: "img", before: 3_000, after: 1_000),
            HistoryEntry(date: now, title: "c", action: "Comprimi", outputs: ["/4"], kind: "pdf", before: 100, after: 400),
            HistoryEntry(date: old, title: "d", action: "Comprimi", outputs: ["/5"], kind: "pdf", before: 9_000, after: 1),
            undone,
        ]
        let s = MonthStats.of(h, now: now)
        XCTAssertEqual(s.files, 4)
        XCTAssertEqual(s.saved, 6_000, "solo i risparmi veri di questo mese")
        XCTAssertEqual(s.topAction, "In JPG")
    }
}
