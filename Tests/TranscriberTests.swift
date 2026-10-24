import XCTest

/// 3.8 · Trascrivi senza Whisper: testo a paragrafi e sottotitoli .srt corretti.
final class TranscriberTests: XCTestCase {
    private let words: [AutoSubtitles.Word] = [
        .init(text: "Ciao", start: 0.0, end: 0.4), .init(text: "a", start: 0.45, end: 0.5),
        .init(text: "tutti.", start: 0.55, end: 1.0),
        .init(text: "Dopo", start: 3.2, end: 3.5), .init(text: "la", start: 3.55, end: 3.6), .init(text: "pausa.", start: 3.65, end: 4.1),
    ]

    func testParagrafiDivisiDallePause() {
        XCTAssertEqual(Transcriber.paragraphs(words), "Ciao a tutti.\n\nDopo la pausa.\n")
    }

    func testSottotitoliSRT() {
        let s = Transcriber.srt(AutoSubtitles.lines(words))
        XCTAssertTrue(s.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\nCiao a tutti.\n"), s)
        XCTAssertTrue(s.contains("2\n00:00:03,200 --> "), s)
        XCTAssertTrue(s.contains("Dopo la pausa."), s)
    }

    func testFormatiLettiDaMacOS() {
        XCTAssertTrue(Transcriber.supports(["m4a", "mp4"]))
        XCTAssertFalse(Transcriber.supports(["mkv"]), "gli altri restano al motore classico")
        XCTAssertFalse(Transcriber.supports([]))
    }
}
