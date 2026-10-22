import XCTest

/// I messaggi d'errore arrivano all'utente come frasi chiare, con la soluzione.
final class FriendlyErrorTests: XCTestCase {
    func testTechnicalMessagesBecomeClear() {
        let audio = FriendlyError.text("Ciao.txt: Impossibile completare l’operazione. (Errore com.apple.coreaudio.avfaudio 560226676).")
        XCTAssertTrue(audio.hasPrefix("Ciao.txt: "), "il nome del file resta")
        XCTAssertFalse(audio.contains("560226676"), "niente codici")
        XCTAssertTrue(audio.contains("M4A"), "dice cosa fare")

        XCTAssertTrue(FriendlyError.text("The operation couldn’t be completed. No space left on device").contains("Spazio su disco"))
        XCTAssertTrue(FriendlyError.text("video.mov: Operation not permitted").contains("non può scrivere"))
        XCTAssertTrue(FriendlyError.text("AVFoundationErrorDomain -11828 Cannot Open").contains("non riesce a leggere"))
    }

    func testClearMessagesStayAsTheyAre() {
        let ok = "il video è troppo lungo per stare in 8 MB: scegli un peso maggiore o taglialo prima"
        XCTAssertEqual(FriendlyError.text(ok), ok)
        XCTAssertEqual(FriendlyError.text("Manca ffmpeg — vedi Componenti"), "Manca ffmpeg — vedi Componenti")
    }

    func testJobTranslatesOnItsOwn() throws {
        let job = try Fixtures.job("to:mp4", kind: .video, files: [URL(fileURLWithPath: "/tmp/x.mov")])
        job.failures.append("x.mov: Impossibile completare l’operazione. (OSStatus errore -11800.)")
        XCTAssertFalse(job.failures[0].contains("-11800"))
        XCTAssertTrue(job.failures[0].hasPrefix("x.mov: "))
    }
}
