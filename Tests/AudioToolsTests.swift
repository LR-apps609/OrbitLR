import XCTest
import AVFoundation
@testable import OrbitLR

/// Strumenti della scheda Audio e unioni: suoneria, vocale per WhatsApp, unisci, testo in voce, unisci video.
final class AudioToolsTests: XCTestCase {

    func testRingtoneLengthFadesAndFormat() async throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 12), name: "canzone.wav")
        let out = Fixtures.url("suoneria.m4r")
        let job = try Fixtures.job("ringtone", kind: .audio, files: [src], param: "2|7|1|1")
        try await Media.renderAudio([(src, 2, 7)], out: out, bitrate: 192_000, channels: 2, fadeIn: 0.6, fadeOut: 1.5,
                                    normalize: true, maxSeconds: 40, job: job) { _ in }
        let problem = await Verifier.problem(out)
        XCTAssertNil(problem)
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 5, accuracy: 0.15)
        XCTAssertEqual(r.audioChannels, 2)
    }

    func testRingtoneNeverLongerThan40Seconds() async throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 50, freq: 220), name: "lunga.wav")
        let out = Fixtures.url("suoneria-lunga.m4r")
        let job = try Fixtures.job("ringtone", kind: .audio, files: [src])
        try await Media.renderAudio([(src, nil, nil)], out: out, bitrate: 192_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                    normalize: false, maxSeconds: 40, job: job) { _ in }
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 40, accuracy: 0.2)
    }

    func testWhatsAppVoiceIsMonoAndSmall() async throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 20, freq: 300, level: 0.05), name: "vocale.wav")
        let out = Fixtures.url("vocale.m4a")
        let job = try Fixtures.job("whatsapp", kind: .audio, files: [src])
        try await Media.renderAudio([(src, nil, nil)], out: out, bitrate: 64_000, channels: 1, fadeIn: 0, fadeOut: 0,
                                    normalize: true, maxSeconds: nil, job: job) { _ in }
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.audioChannels, 1)
        XCTAssertEqual(r.duration, 20, accuracy: 0.2)
        XCTAssertLessThan(Job.size(of: out), Job.size(of: src) / 5, "molto più leggero dell'originale")
    }

    func testMergeAudioOneAfterTheOther() async throws {
        let a = try Fixtures.wav(Fixtures.tone(seconds: 3), name: "p1.wav")
        let b = try Fixtures.wav(Fixtures.tone(seconds: 4, freq: 550), name: "p2.wav")
        let job = try Fixtures.job("amerge", kind: .audio, files: [a, b])
        let out = try await Media.runMulti(job: job, files: [a, b], dir: Fixtures.dir) { _ in }
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 7, accuracy: 0.2)
    }

    func testMergeVideosLandscapeAndPortrait() async throws {
        let a = try await Fixtures.video(name: "m1.mp4", width: 640, height: 360, seconds: 2)
        let b = try await Fixtures.video(name: "m2.mov", width: 640, height: 360, seconds: 2, portrait: true)
        let job = try Fixtures.job("vmerge", kind: .video, files: [a, b])
        let out = try await Media.runMulti(job: job, files: [a, b], dir: Fixtures.dir) { _ in }
        let problem = await Verifier.problem(out)
        XCTAssertNil(problem)
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 4, accuracy: 0.2)
        XCTAssertEqual(r.displaySize.width, 640, "misura del primo video")
    }

    func testTextToSpeechWritesAudio() async throws {
        let src = Fixtures.url("testo.txt")
        try "Ciao, questa è una prova di lettura ad alta voce.".write(to: src, atomically: true, encoding: .utf8)
        let job = try Fixtures.job("tts", kind: .text, files: [src])
        let out = try await Media.run(job: job, file: src, dir: Fixtures.dir) { _ in }
        let problem = await Verifier.problem(out)
        XCTAssertNil(problem)
        let r = try await Fixtures.probe(out)
        XCTAssertGreaterThan(r.duration, 1, "la voce ha letto il testo")
        XCTAssertEqual(out.pathExtension, "m4a")
    }

    func testReadTextFromFiles() throws {
        let md = Fixtures.url("nota.md")
        try "# Titolo\n\nUn *testo* di prova.".write(to: md, atomically: true, encoding: .utf8)
        let t = try Media.readText(md)
        XCTAssertFalse(t.contains("#"))
        XCTAssertFalse(t.contains("*"))
        XCTAssertTrue(t.contains("testo di prova"))
        let empty = Fixtures.url("vuoto.txt")
        try "   ".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Media.readText(empty))
    }
}
