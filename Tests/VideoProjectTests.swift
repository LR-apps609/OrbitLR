import XCTest
import AVFoundation

/// Il montaggio della scheda Video: composizione, musica, voci, esportazione, annulla.
final class VideoProjectTests: XCTestCase {

    private func info(_ u: URL) async throws -> VPMediaInfo { try await VPMediaInfo.load(u) }

    private func clip(_ u: URL, _ i: VPMediaInfo, _ a: Double = 0, _ b: Double? = nil) -> VPClip {
        VPClip(path: u.path, inPoint: a, outPoint: b ?? i.videoDuration)
    }

    // MARK: Composizione

    func testClipsInSequenceWithTrim() async throws {
        let a = try await Fixtures.video(name: "a.mp4", width: 640, height: 360, seconds: 4)
        let b = try await Fixtures.video(name: "b.mp4", width: 640, height: 360, seconds: 3)
        let ia = try await info(a), ib = try await info(b)
        var p = VideoProject()
        p.clips = [clip(a, ia, 1, 3), clip(b, ib)]
        XCTAssertEqual(p.duration, 5, accuracy: 0.1)
        let built = try await VideoProjectBuilder.build(p, infos: [a.path: ia, b.path: ib], speech: [:], maxSide: 1280)
        XCTAssertEqual(built.duration, 5, accuracy: 0.15)
        XCTAssertEqual(built.renderSize.width, 640)
        XCTAssertEqual(built.renderSize.height, 360)
    }

    func testPortraitPhoneVideoKeepsOrientation() async throws {
        let v = try await Fixtures.video(name: "verticale.mov", width: 640, height: 360, seconds: 2, portrait: true)
        let i = try await info(v)
        XCTAssertLessThan(i.displaySize.width, i.displaySize.height, "un video girato deve risultare verticale")
        var p = VideoProject()
        p.clips = [clip(v, i)]
        let built = try await VideoProjectBuilder.build(p, infos: [v.path: i], speech: [:], maxSide: 1280)
        XCTAssertEqual(built.renderSize.width, 360)
        XCTAssertEqual(built.renderSize.height, 640)
    }

    func testClipAtAndStarts() {
        var p = VideoProject()
        p.clips = [VPClip(path: "/a", inPoint: 2, outPoint: 6), VPClip(path: "/b", inPoint: 0, outPoint: 3)]
        XCTAssertEqual(p.starts, [0, 4])
        XCTAssertEqual(p.clip(at: 1)?.index, 0)
        XCTAssertEqual(p.clip(at: 1)?.local ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(p.clip(at: 5)?.index, 1)
        XCTAssertEqual(p.clip(at: 5)?.local ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(p.clip(at: 99)?.index, 1, "oltre la fine: l'ultima clip")
    }

    // MARK: Musica

    func testMusicLoopsOrStops() async throws {
        let v = try await Fixtures.video(name: "lungo.mp4", width: 320, height: 180, seconds: 7)
        let song = try Fixtures.wav(Fixtures.tone(seconds: 2), name: "brano.wav")
        let iv = try await info(v), isong = try await info(song)
        var p = VideoProject()
        p.clips = [clip(v, iv)]
        p.music = VPMusic(path: song.path)
        p.music?.loop = true
        let infos = [v.path: iv, song.path: isong]

        var built = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640)
        var musicTrack = built.composition.tracks(withMediaType: .audio).last
        XCTAssertEqual(musicTrack?.timeRange.end.seconds ?? 0, 7, accuracy: 0.15, "con «Ripeti» la musica arriva alla fine")

        p.music?.loop = false
        built = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640)
        musicTrack = built.composition.tracks(withMediaType: .audio).last
        XCTAssertEqual(musicTrack?.timeRange.end.seconds ?? 0, 2, accuracy: 0.15, "senza «Ripeti» la musica finisce col brano")
        XCTAssertEqual(VideoProjectBuilder.musicEnd(p, songDuration: isong.duration) ?? 0, 2, accuracy: 0.1)

        // Parte dopo 3 secondi nel video
        p.music?.offset = 3
        built = try await VideoProjectBuilder.build(p, infos: infos, speech: [:], maxSide: 640)
        musicTrack = built.composition.tracks(withMediaType: .audio).last
        let firstReal = musicTrack?.segments.first { !$0.isEmpty }
        XCTAssertEqual(firstReal?.timeMapping.target.start.seconds ?? -1, 3, accuracy: 0.05)
    }

    func testFadesAndDuckingEnvelope() throws {
        let comp = AVMutableComposition()
        let track = try XCTUnwrap(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        var m = VPMusic(path: "/x")
        m.volume = 0.8
        m.fadeIn = 1
        m.fadeOut = 2
        let p = VideoProjectBuilder.musicEnvelope(track: track, music: m, start: 0, end: 10, duck: [4...6])
        func vol(_ t: Double) -> Float {
            var a: Float = 0, b: Float = 0
            var r = CMTimeRange()
            guard p.getVolumeRamp(for: CMTime(seconds: t, preferredTimescale: 600), startVolume: &a, endVolume: &b, timeRange: &r) else { return -1 }
            let k = Float((t - r.start.seconds) / max(0.0001, r.duration.seconds))
            return a + (b - a) * k
        }
        XCTAssertLessThan(vol(0.05), 0.1, "all'inizio la dissolvenza parte da zero")
        XCTAssertEqual(vol(2), 0.8, accuracy: 0.02, "volume pieno scelto")
        XCTAssertEqual(vol(5), 0.2, accuracy: 0.03, "mentre si parla la musica scende a un quarto")
        XCTAssertEqual(vol(7.5), 0.8, accuracy: 0.05, "dopo la voce torna su")
        XCTAssertLessThan(vol(9.95), 0.05, "alla fine si spegne")
    }

    func testSpeechDetectionFindsTheVoice() async throws {
        let voice = try Fixtures.speech("Hello, this is a short test of the speech detector. We are talking for a few seconds now.")
        XCTAssertGreaterThan(voice.count, 44_100, "la voce di prova dura almeno un secondo")
        let lead = 3.0
        let audio = Fixtures.silence(seconds: lead) + voice + Fixtures.silence(seconds: 3)
        let total = Double(audio.count) / 44_100
        let v = try await Fixtures.video(name: "parla.mp4", width: 320, height: 180, seconds: total, audio: audio)
        let ranges = await SpeechDetector.ranges(in: v)
        let speechEnd = lead + Double(voice.count) / 44_100
        XCTAssertFalse(ranges.isEmpty, "deve trovare la voce")
        XCTAssertTrue(ranges.contains { $0.overlaps(lead...speechEnd) }, "la voce trovata è dove parla: \(ranges)")
        XCTAssertFalse(ranges.contains { $0.upperBound < lead - 1.2 }, "niente voce nel silenzio iniziale: \(ranges)")

        let tone = try await Fixtures.video(name: "tono.mp4", width: 320, height: 180, seconds: 5, audio: Fixtures.tone(seconds: 5))
        let toneRanges = await SpeechDetector.ranges(in: tone)
        XCTAssertLessThan(toneRanges.count, 2, "un tono non è una voce: \(toneRanges)")
    }

    // MARK: Esportazione

    private func export(_ p: VideoProject, name: String, speech: [String: [ClosedRange<Double>]] = [:]) async throws -> Fixtures.Probe {
        let snap = try VideoProjectExport.writeSnapshot(p, speech: speech)
        let out = Fixtures.url(name)
        try? FileManager.default.removeItem(at: out)
        let job = try Fixtures.job("vproject", kind: .video, files: p.clips.map { $0.url }, param: snap.path)
        try await VideoProjectExport.run(snapshot: snap, out: out, job: job) { _ in }
        let problem = await Verifier.problem(out)
        XCTAssertNil(problem, "il controllo finale non deve trovare problemi")
        return try await Fixtures.probe(out)
    }

    func testExportOriginalWithMusic() async throws {
        let a = try await Fixtures.video(name: "e1.mp4", width: 640, height: 360, seconds: 3, audio: Fixtures.tone(seconds: 3, freq: 300))
        let b = try await Fixtures.video(name: "e2.mov", width: 640, height: 360, seconds: 2, portrait: true)
        let song = try Fixtures.wav(Fixtures.tone(seconds: 10, freq: 660), name: "musica.wav")
        let ia = try await info(a), ib = try await info(b)
        var p = VideoProject()
        p.clips = [clip(a, ia, 0.5, 3), clip(b, ib)]
        p.music = VPMusic(path: song.path)
        let r = try await export(p, name: "montaggio.mp4")
        XCTAssertEqual(r.duration, 4.5, accuracy: 0.25)
        XCTAssertEqual(r.displaySize.width, 640)
        XCTAssertEqual(r.displaySize.height, 360)
        XCTAssertTrue(r.hasAudio)
    }

    func testExportVerticalFollowingSubject() async throws {
        let v = try await Fixtures.video(name: "orizz.mp4", width: 1280, height: 720, seconds: 3)
        let i = try await info(v)
        var p = VideoProject()
        p.clips = [clip(v, i)]
        p.aspect = "9x16"
        p.follow = true
        let r = try await export(p, name: "verticale-out.mp4")
        XCTAssertEqual(Double(r.displaySize.width / r.displaySize.height), 9.0 / 16.0, accuracy: 0.02)
        XCTAssertEqual(r.displaySize.height, 720, "mai più grande dell'originale")
        XCTAssertFalse(r.hasAudio, "il video di prova non ha audio")
    }

    func testExportResolutionAndFrameRate() async throws {
        let v = try await Fixtures.video(name: "fullhd.mp4", width: 1920, height: 1080, seconds: 2)
        let i = try await info(v)
        var p = VideoProject()
        p.clips = [clip(v, i)]
        p.resolution = 720
        p.fps = 60
        let r = try await export(p, name: "720p60.mp4")
        XCTAssertEqual(r.displaySize.width, 1280)
        XCTAssertEqual(r.displaySize.height, 720)
        XCTAssertGreaterThan(r.fps, 50, "60 fotogrammi al secondo")

        p.resolution = 2160
        p.fps = 30
        let r2 = try await export(p, name: "4k-richiesto.mp4")
        XCTAssertEqual(r2.displaySize.height, 1080, "4K su un video Full HD resta Full HD")
    }

    func testSocialFromPieMenu() async throws {
        let v = try await Fixtures.video(name: "torta-social.mp4", width: 1280, height: 720, seconds: 2)
        let job = try Fixtures.job("social", kind: .video, files: [v], param: "1x1|0")
        let out = try await Media.run(job: job, file: v, dir: Fixtures.dir) { _ in }
        let r = try await Fixtures.probe(out)
        XCTAssertEqual(r.displaySize.width, 720)
        XCTAssertEqual(r.displaySize.height, 720)
        XCTAssertEqual(r.duration, 2, accuracy: 0.2)
    }

    func testOutputSizeMath() {
        var p = VideoProject()
        p.aspect = "1x1"
        p.resolution = 1080
        var s = VideoProjectExport.outputSize(canvas: CGSize(width: 1920, height: 1080), project: p)
        XCTAssertEqual(s.out, CGSize(width: 1080, height: 1080))
        p.aspect = "4x5"
        s = VideoProjectExport.outputSize(canvas: CGSize(width: 1080, height: 1920), project: p)
        XCTAssertEqual(Double(s.out.width / s.out.height), 0.8, accuracy: 0.01)
        XCTAssertEqual(Int(s.out.width) % 2, 0, "misure pari (richieste dal codificatore)")
        XCTAssertEqual(Int(s.out.height) % 2, 0)
    }

    // MARK: Salvataggio e annulla

    func testProjectSavesAndLoads() throws {
        var p = VideoProject()
        p.clips = [VPClip(path: "/tmp/x.mp4", inPoint: 1, outPoint: 2)]
        p.music = VPMusic(path: "/tmp/m.mp3", offset: 2, inPoint: 30, loop: true, volume: 0.5, fadeIn: 0, fadeOut: 3, duck: false)
        p.aspect = "9x16"
        p.resolution = 720
        let d = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: d), p)
    }

    @MainActor
    func testUndoRedoSplitAndTrim() async throws {
        let a = try await Fixtures.video(name: "u1.mp4", width: 320, height: 180, seconds: 4)
        let ia = try await info(a)
        let s = VideoProjectStore()
        let um = UndoManager()
        um.groupsByEvent = false
        func step(_ f: () -> Void) { um.beginUndoGrouping(); f(); um.endUndoGrouping() }

        step { s.newProject(um) }
        step { s.change(um, "Aggiungi") { $0.clips = [VPClip(path: a.path, inPoint: 0, outPoint: ia.videoDuration)] } }
        s.seek(1.5)
        step { s.split(um) }
        XCTAssertEqual(s.project.clips.count, 2)
        XCTAssertEqual(s.project.clips[0].length, 1.5, accuracy: 0.01)
        XCTAssertEqual(s.project.duration, ia.videoDuration, accuracy: 0.01, "dividere non cambia la durata")

        s.seek(3)
        step { s.trimEndHere(um) }
        XCTAssertEqual(s.project.duration, 3, accuracy: 0.01)

        um.undo()
        XCTAssertEqual(s.project.duration, ia.videoDuration, accuracy: 0.01, "⌘Z annulla il taglio")
        um.undo()
        XCTAssertEqual(s.project.clips.count, 1, "⌘Z annulla la divisione")
        um.redo()
        XCTAssertEqual(s.project.clips.count, 2, "⇧⌘Z la rifà")

        step { s.deleteClip(um) }
        XCTAssertEqual(s.project.clips.count, 1)
        um.undo()
        XCTAssertEqual(s.project.clips.count, 2)
        step { s.newProject(um) }
    }
}
