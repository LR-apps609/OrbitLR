import XCTest
import AVFoundation

/// 2.7.4 · Audio della singola clip: spento tutto o da un punto in poi.
final class ClipAudioTests: XCTestCase {
    private func audioSeconds(_ built: VPBuilt) -> Double {
        guard let t = built.composition.tracks(withMediaType: .audio).first else { return 0 }
        return t.segments.filter { !$0.isEmpty }.reduce(0) { $0 + $1.timeMapping.target.duration.seconds }
    }

    func testMutedClipHasNoAudioInMontage() async throws {
        let v = try await Fixtures.video(name: "audio-clip.mp4", width: 320, height: 180, seconds: 3,
                                         audio: Fixtures.tone(seconds: 3, freq: 440))
        let i = try await VPMediaInfo.load(v)
        XCTAssertTrue(i.hasAudio)
        var p = VideoProject()
        p.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 2), VPClip(path: v.path, inPoint: 0, outPoint: 2)]
        let all = try await VideoProjectBuilder.build(p, infos: [v.path: i], speech: [:], maxSide: 640)
        XCTAssertEqual(audioSeconds(all), 4, accuracy: 0.1)
        p.clips[1].muted = true
        let half = try await VideoProjectBuilder.build(p, infos: [v.path: i], speech: [:], maxSide: 640)
        XCTAssertEqual(audioSeconds(half), 2, accuracy: 0.1, "la seconda clip è muta")
        XCTAssertEqual(half.duration, 4, accuracy: 0.1, "il video resta lungo uguale")
    }

    func testMutedClipIgnoredForDucking() {
        var p = VideoProject()
        p.clips = [VPClip(path: "/a.mp4", inPoint: 0, outPoint: 5), VPClip(path: "/b.mp4", inPoint: 0, outPoint: 5)]
        let speech: [String: [ClosedRange<Double>]] = ["/a.mp4": [1...2], "/b.mp4": [1...2]]
        XCTAssertEqual(VideoProjectBuilder.speechOnTimeline(p, speech: speech).count, 2)
        p.clips[0].muted = true
        XCTAssertEqual(VideoProjectBuilder.speechOnTimeline(p, speech: speech).map { $0.lowerBound }, [6])
    }

    @MainActor
    func testMuteFromHereSplitsAndUndoes() async throws {
        let v = try await Fixtures.video(name: "audio-da-qui.mp4", width: 320, height: 180, seconds: 4)
        let i = try await VPMediaInfo.load(v)
        let s = VideoProjectStore(folder: Fixtures.dir.appendingPathComponent("p-\(UUID().uuidString)"))
        let um = UndoManager()
        um.groupsByEvent = false
        s.newProject(um)
        um.beginUndoGrouping()
        s.change(um, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: i.videoDuration)] }
        um.endUndoGrouping()
        s.seek(1.5)
        um.beginUndoGrouping(); s.muteFromHere(um); um.endUndoGrouping()
        XCTAssertEqual(s.project.clips.count, 2)
        XCTAssertFalse(s.project.clips[0].isMuted)
        XCTAssertTrue(s.project.clips[1].isMuted)
        XCTAssertEqual(s.project.duration, i.videoDuration, accuracy: 0.01)
        um.undo()
        XCTAssertEqual(s.project.clips.count, 1)
        s.selected = s.project.clips[0].id
        um.beginUndoGrouping(); s.toggleClipAudio(um); um.endUndoGrouping()
        XCTAssertTrue(s.project.clips[0].isMuted)
        um.beginUndoGrouping(); s.toggleClipAudio(um); um.endUndoGrouping()
        XCTAssertNil(s.project.clips[0].muted, "riacceso: torna come prima")
        s.closeProject(um)
    }
}
