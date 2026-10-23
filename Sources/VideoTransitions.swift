import Foundation
import AVFoundation
import CoreImage

// ════════════════════════════════════════════════════════════════════
//  2.9.3 · Transizioni tra le clip.
//  Il montaggio ha due tracce video che si alternano: durante una
//  transizione le due clip si sovrappongono e VPCompositor le mescola
//  fotogramma per fotogramma (anteprima ed esportazione uguali).
// ════════════════════════════════════════════════════════════════════

/// Un tratto del montaggio: una clip da sola (`to == nil`) o il passaggio da `from` a `to`.
final class VPCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let from: VideoProjectBuilder.Placement
    let to: VideoProjectBuilder.Placement?
    let transition: VPTransition?
    let canvas: CGSize
    /// 2.9.8 · zone da sfocare su tutto il montaggio
    let hide: HideMark.Spec?

    init(range: (Double, Double), from: VideoProjectBuilder.Placement, to: VideoProjectBuilder.Placement?,
         transition: VPTransition?, canvas: CGSize, hide: HideMark.Spec? = nil) {
        let a = VideoProjectBuilder.cm(range.0), b = VideoProjectBuilder.cm(range.1)
        timeRange = CMTimeRange(start: a, end: b)
        self.from = from
        self.to = to
        self.transition = transition
        self.canvas = canvas
        self.hide = hide
        var ids = [NSNumber(value: from.trackID)]
        if let to { ids.append(NSNumber(value: to.trackID)) }
        requiredSourceTrackIDs = ids
        super.init()
    }
}

final class VPCompositor: NSObject, AVVideoCompositing {
    private static let bgra: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.bgra }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.bgra }
    private let queue = DispatchQueue(label: "orbitlr.compositor")
    /// I fotogrammi arrivano senza profilo e Core Image li legge come sRGB: si riscrive in sRGB, così i colori
    /// restano identici (con il profilo 709 l'immagine usciva più scura).
    private let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let ins = request.videoCompositionInstruction as? VPCompositionInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "OrbitLR", code: 1, userInfo: [NSLocalizedDescriptionKey: "fotogramma non disponibile"]))
                return
            }
            let t = request.compositionTime.seconds
            let start = ins.timeRange.start.seconds, len = max(0.0001, ins.timeRange.duration.seconds)
            let a = frame(request, ins.from, ins.canvas)
            var img = a
            if let to = ins.to {
                let b = frame(request, to, ins.canvas)
                let x = min(1, max(0, (t - start) / len))
                img = Self.blend(a, b, kind: ins.transition?.kind ?? "fade", progress: x * x * (3 - 2 * x), canvas: ins.canvas)
            }
            if let h = ins.hide, h.style != "ai" { img = HideMark.apply(h, to: img) }
            Media.ci.render(img, to: out, bounds: CGRect(origin: .zero, size: ins.canvas), colorSpace: space)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// Il fotogramma di una clip, girato, in tela, con filtro e sfondo nero.
    private func frame(_ r: AVAsynchronousVideoCompositionRequest, _ pl: VideoProjectBuilder.Placement, _ canvas: CGSize) -> CIImage {
        let bg = Self.color(0, canvas)
        guard let px = r.sourceFrame(byTrackID: pl.trackID) else { return bg }
        return VideoProjectBuilder.place(CIImage(cvPixelBuffer: px), pl, canvas: canvas, at: r.compositionTime.seconds)
            .composited(over: bg).cropped(to: bg.extent)
    }

    static func color(_ v: Double, _ canvas: CGSize) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ p: Double) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": b, "inputTime": min(1, max(0, p))])
    }

    /// Mescola la clip che finisce (a) con quella che comincia (b); p va da 0 a 1.
    static func blend(_ a: CIImage, _ b: CIImage, kind: String, progress p: Double, canvas: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let out: CIImage
        switch kind {
        case "black", "white":
            let mid = color(kind == "black" ? 0 : 1, canvas)
            out = p < 0.5 ? dissolve(a, mid, p * 2) : dissolve(mid, b, p * 2 - 1)
        case "slide":
            let w = canvas.width
            out = b.transformed(by: CGAffineTransform(translationX: w * (1 - p), y: 0))
                .composited(over: a.transformed(by: CGAffineTransform(translationX: -w * p, y: 0)))
                .composited(over: color(0, canvas))
        case "zoom":
            func zoom(_ i: CIImage, _ s: Double) -> CIImage {
                i.transformed(by: CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))).cropped(to: rect)
            }
            out = dissolve(zoom(a, 1 + 0.3 * p), zoom(b, 1.3 - 0.3 * p), p)
        case "blur":
            let r = 24 * sin(Double.pi * p)
            func blur(_ i: CIImage) -> CIImage {
                r < 0.3 ? i : i.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": r]).cropped(to: rect)
            }
            out = dissolve(blur(a), blur(b), p)
        default:
            out = dissolve(a, b, p)
        }
        return out.cropped(to: rect)
    }
}
