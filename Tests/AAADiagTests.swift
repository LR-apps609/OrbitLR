import XCTest
import AVFoundation

final class AAADiagTests: XCTestCase, AVVideoCompositionValidationHandling {
    var reasons: [String] = []
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { reasons.append("key \(key)"); return true }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool { reasons.append("empty \(timeRange.start.seconds)-\(timeRange.end.seconds)"); return true }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoCompositionInstruction: AVVideoCompositionInstructionProtocol) -> Bool { reasons.append("badrange \(videoCompositionInstruction.timeRange.start.seconds)-\(videoCompositionInstruction.timeRange.end.seconds)"); return true }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn videoCompositionInstruction: AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool { reasons.append("trackid"); return true }

    func testDiag() async throws {
        let a = try await Fixtures.video(name: "dg.mp4", width: 320, height: 180, seconds: 2)
        let info = try await VPMediaInfo.load(a)
        var p = VideoProject()
        p.clips = [VPClip(path: a.path, inPoint: 0, outPoint: info.videoDuration)]
        let b = try await VideoProjectBuilder.build(p, infos: [a.path: info], speech: [:], maxSide: 640, engine: .frames)
        var lines: [String] = []
        lines.append("dur \(b.composition.duration.seconds) total \(b.duration)")
        for t in b.composition.tracks { lines.append("track \(t.trackID) \(t.mediaType.rawValue) segs \(t.segments.count) \(t.timeRange.start.seconds)-\(t.timeRange.end.seconds)") }
        for i in b.videoComposition.instructions { lines.append("ins \(i.timeRange.start.value)/\(i.timeRange.start.timescale)-\(i.timeRange.end.value)/\(i.timeRange.end.timescale) req \(String(describing: i.requiredSourceTrackIDs))") }
        let ok = try await b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: b.composition.duration), validationDelegate: self)
        lines.append("valid \(ok) \(reasons)")
        func tryGen(_ vc: AVVideoComposition, _ name: String) async {
            let g = AVAssetImageGenerator(asset: b.composition); g.videoComposition = vc
            do { _ = try await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)); lines.append("\(name) OK") }
            catch { lines.append("\(name) ERR \(error)") }
        }
        await tryGen(b.videoComposition, "as-is")
        let m1 = b.videoComposition.mutableCopy() as! AVMutableVideoComposition
        m1.colorPrimaries = nil; m1.colorTransferFunction = nil; m1.colorYCbCrMatrix = nil
        await tryGen(m1, "nocolor")
        let m2 = b.videoComposition.mutableCopy() as! AVMutableVideoComposition
        m2.sourceTrackIDForFrameTiming = b.composition.tracks(withMediaType: .video).first!.trackID
        await tryGen(m2, "timing")
        let m3 = b.videoComposition.mutableCopy() as! AVMutableVideoComposition
        if let empty = b.composition.tracks(withMediaType: .video).first(where: { $0.segments.isEmpty }) {
            let c = b.composition.mutableCopy() as! AVMutableComposition
            c.removeTrack(c.track(withTrackID: empty.trackID)!)
            let g = AVAssetImageGenerator(asset: c); g.videoComposition = m3
            do { _ = try await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)); lines.append("noempty OK") } catch { lines.append("noempty ERR \(error)") }
        }
        XCTFail("DIAG\n" + lines.joined(separator: "\n"))
    }
}
