import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import OrbitLR

/// File di prova creati al momento: video con un quadrato che si muove, toni, silenzio e una voce vera (`say`).
enum Fixtures {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitLRTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    struct FixtureError: Error, CustomStringConvertible { let description: String }

    // MARK: Audio

    /// Campioni mono (Float) a `rate` Hz.
    static func tone(seconds: Double, freq: Double = 440, level: Float = 0.3, rate: Double = 44_100) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in level * Float(sin(2 * Double.pi * freq * Double(i) / rate)) }
    }

    static func silence(seconds: Double, rate: Double = 44_100) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Una voce sintetica di macOS (comando `say`), riportata a 44,1 kHz mono.
    static func speech(_ text: String) throws -> [Float] {
        let aiff = url("voce-\(UUID().uuidString).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", aiff.path, text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FixtureError(description: "say non ha funzionato") }
        return try readMono(aiff)
    }

    static func readMono(_ file: URL, rate: Double = 44_100) throws -> [Float] {
        let src = try AVAudioFile(forReading: file)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src.processingFormat, to: target),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length)) else {
            throw FixtureError(description: "conversione audio non disponibile")
        }
        try src.read(into: inBuf)
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * rate / src.processingFormat.sampleRate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { throw FixtureError(description: "memoria") }
        var given = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Scrive un WAV mono.
    @discardableResult
    static func wav(_ samples: [Float], name: String, rate: Double = 44_100) throws -> URL {
        let u = url(name)
        try? FileManager.default.removeItem(at: u)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw FixtureError(description: "formato audio")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData?[0] { samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) } }
        let file = try AVAudioFile(forWriting: u, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
        return u
    }

    // MARK: Video

    /// Video H.264 con un quadrato chiaro che attraversa l'immagine. `portrait`: girato come quelli dell'iPhone
    /// (fotogrammi orizzontali + rotazione di 90° nei metadati). `audio`: campioni mono da mettere come traccia audio.
    static func video(name: String, width: Int, height: Int, seconds: Double, fps: Int = 30,
                      portrait: Bool = false, audio: [Float]? = nil) async throws -> URL {
        let u = url(name)
        try? FileManager.default.removeItem(at: u)
        let writer = try AVAssetWriter(outputURL: u, fileType: name.hasSuffix(".mov") ? .mov : .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        vIn.expectsMediaDataInRealTime = false
        if portrait { vIn.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(vIn)
        var aIn: AVAssetWriterInput? = nil
        var asbd = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        if audio != nil, let fmt {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ], sourceFormatHint: fmt)
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }
        guard writer.startWriting() else { throw writer.error ?? FixtureError(description: "scrittura video") }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        let group = DispatchGroup()
        final class State: @unchecked Sendable { var frame = 0; var sample = 0; var vDone = false; var aDone = false }
        let st = State()
        group.enter()
        vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.video")) {
            while vIn.isReadyForMoreMediaData && !st.vDone {
                if st.frame >= frames { st.vDone = true; vIn.markAsFinished(); group.leave(); return }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
                guard let pb else { continue }
                drawFrame(pb, index: st.frame, of: frames, width: width, height: height)
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(st.frame), timescale: CMTimeScale(fps)))
                st.frame += 1
            }
        }
        if let aIn, let samples = audio, let fmt {
            group.enter()
            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.audio")) {
                let chunk = 4096
                while aIn.isReadyForMoreMediaData && !st.aDone {
                    if st.sample >= samples.count { st.aDone = true; aIn.markAsFinished(); group.leave(); return }
                    let end = min(samples.count, st.sample + chunk)
                    let piece = Array(samples[st.sample..<end])
                    if let sb = sampleBuffer(piece, at: st.sample, format: fmt) { aIn.append(sb) }
                    st.sample = end
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        guard writer.status == .completed else { throw writer.error ?? FixtureError(description: "video di prova non scritto") }
        return u
    }

    private static func drawFrame(_ pb: CVPixelBuffer, index: Int, of total: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let k = CGFloat(index) / CGFloat(max(1, total - 1))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.25 + 0.3 * k, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = CGFloat(min(width, height)) / 3
        ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: (CGFloat(width) - side) * k, y: (CGFloat(height) - side) / 2, width: side, height: side))
    }

    private static func sampleBuffer(_ samples: [Float], at position: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                             sampleCount: samples.count,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: 44_100),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    // MARK: Lettura dei risultati

    struct Probe {
        var duration: Double
        var displaySize: CGSize
        var fps: Double
        var hasAudio: Bool
        var audioChannels: Int
    }

    static func probe(_ u: URL) async throws -> Probe {
        let a = AVURLAsset(url: u)
        let d = try await a.load(.duration).seconds
        var size = CGSize.zero, fps = 0.0
        if let v = try await a.loadTracks(withMediaType: .video).first {
            let ns = try await v.load(.naturalSize)
            let t = try await v.load(.preferredTransform)
            let r = CGRect(origin: .zero, size: ns).applying(t)
            size = CGSize(width: abs(r.width), height: abs(r.height))
            fps = Double(try await v.load(.nominalFrameRate))
        }
        var channels = 0
        let audio = try await a.loadTracks(withMediaType: .audio).first
        if let audio, let desc = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
        }
        return Probe(duration: d, displaySize: size, fps: fps, hasAudio: audio != nil, audioChannels: channels)
    }

    static func job(_ id: String, kind: Kind, files: [URL], param: String = "") throws -> Job {
        guard let a = Catalog.action(id: id, kind: kind) else { throw FixtureError(description: "azione \(id) mancante") }
        return Job(files: files, action: a, param: param)
    }
}
