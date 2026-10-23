import XCTest
import AVFoundation
import ImageIO

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

    func testRingtoneNeverLongerThan30Seconds() async throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 50, freq: 220), name: "lunga.wav")
        let out = Fixtures.url("suoneria-lunga.m4r")
        let job = try Fixtures.job("ringtone", kind: .audio, files: [src])
        try await Media.renderAudio([(src, nil, nil)], out: out, bitrate: 192_000, channels: 2, fadeIn: 0, fadeOut: 0,
                                    normalize: false, maxSeconds: 30, job: job) { _ in }
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 30, accuracy: 0.2)
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

    // MARK: 2.6.3 · Taglia, GIF, Comprimi, Volume uniforme senza programmi esterni

    private func quick(_ id: String, kind: Kind, file: URL, param: String) async throws -> URL {
        let job = try Fixtures.job(id, kind: kind, files: [file], param: param)
        XCTAssertTrue(QuickMedia.handles(job), "\(id) deve funzionare con i motori di macOS")
        let out = try await QuickMedia.run(job: job, file: file, dir: Fixtures.dir) { _ in }
        let problem = await Verifier.problem(out)
        XCTAssertNil(problem, "\(id): il controllo finale non deve trovare problemi")
        return out
    }

    func testCutVideoNative() async throws {
        let v = try await Fixtures.video(name: "taglia.mp4", width: 640, height: 360, seconds: 6, audio: Fixtures.tone(seconds: 6))
        let out = try await quick("cut", kind: .video, file: v, param: "1.000|4.500")
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 3.5, accuracy: 0.2)
        XCTAssertTrue(r.hasAudio)
    }

    func testCutAudioKeepsWav() async throws {
        let a = try Fixtures.wav(Fixtures.tone(seconds: 8), name: "taglia.wav")
        let out = try await quick("cut", kind: .audio, file: a, param: "2.000|")
        XCTAssertEqual(out.pathExtension, "wav", "un WAV resta WAV")
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 6, accuracy: 0.15)
    }

    func testGifNative() async throws {
        let v = try await Fixtures.video(name: "gif.mp4", width: 640, height: 360, seconds: 4)
        let out = try await quick("gifcut", kind: .video, file: v, param: "0.500|2.500")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(src), 15, "circa 12 fotogrammi al secondo")
    }

    func testCompressToExactSize() async throws {
        let v = try await Fixtures.video(name: "pesante.mp4", width: 1280, height: 720, seconds: 4, noise: true)
        let before = Job.size(of: v)
        XCTAssertGreaterThan(before, 3 * 1_048_576, "il video di prova deve essere pesante")
        let out = try await quick("vcompress", kind: .video, file: v, param: "2")
        XCTAssertLessThanOrEqual(Job.size(of: out), 2 * 1_048_576, "sotto il peso scelto")
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.duration, 4, accuracy: 0.2)
    }

    func testCompressAlreadySmallSaysSo() async throws {
        let v = try await Fixtures.video(name: "leggero.mp4", width: 320, height: 180, seconds: 1)
        let job = try Fixtures.job("vcompress", kind: .video, files: [v], param: "25")
        do {
            _ = try await QuickMedia.run(job: job, file: v, dir: Fixtures.dir) { _ in }
            XCTFail("doveva dire che pesa già meno")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pesa già meno"))
        }
    }

    func testNormalizeRaisesQuietAudio() async throws {
        let quiet = try Fixtures.wav(Fixtures.tone(seconds: 4, level: 0.03), name: "basso.wav")
        let out = try await quick("normalize", kind: .audio, file: quiet, param: "")
        let before = try Fixtures.readMono(quiet), after = try Fixtures.readMono(out)
        func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
        XCTAssertGreaterThan(rms(after), rms(before) * 3, "il volume si alza")
        XCTAssertLessThanOrEqual(after.map { abs($0) }.max() ?? 0, 0.95, "senza distorcere")
    }

    func testOutputFolderNames() {
        XCTAssertEqual(JobStrip.folderName(Paths.home.appendingPathComponent("Desktop/a.mp4")), "Scrivania")
        XCTAssertEqual(JobStrip.folderName(URL(fileURLWithPath: "/tmp/Progetto/a.mp4")), "«Progetto»")
    }
}

