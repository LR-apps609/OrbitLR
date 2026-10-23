import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CoreImage

// ════════════════════════════════════════════════════════════════════
//  2.9.4 · Nascondi filigrana (foto e video).
//  Si disegnano uno o più rettangoli sul logo; dentro si sfoca
//  (normale o a pixel). Le zone sono in proporzione (0…1) rispetto
//  all'immagine come la vedi, origine in alto a sinistra.
//  Parametro: «stile|forza|x,y,l,a;x,y,l,a…», es. «blur|0.6|0.8,0.9,0.15,0.06».
// ════════════════════════════════════════════════════════════════════

enum HideMark {
    struct Spec: Equatable {
        var style = "blur"          // «blur» sfocatura, «pixel» a quadretti
        var strength = 0.6          // 0…1
        var rects: [CGRect] = []
    }

    static func encode(_ s: Spec) -> String {
        let r = s.rects.map { r in [r.minX, r.minY, r.width, r.height].map { String(format: "%.4f", Double($0)) }.joined(separator: ",") }
        return "\(s.style)|\(String(format: "%.2f", s.strength))|\(r.joined(separator: ";"))"
    }

    static func parse(_ text: String) -> Spec? {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        var s = Spec()
        s.style = parts[0] == "pixel" ? "pixel" : "blur"
        s.strength = min(1, max(0, Double(parts[1]) ?? 0.6))
        s.rects = parts[2].split(separator: ";").compactMap { item in
            let v = item.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { return nil }
            let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return r.isNull || r.width < 0.002 || r.height < 0.002 ? nil : r
        }
        return s.rects.isEmpty ? nil : s
    }

    /// Una zona in proporzione → rettangolo in pixel di Core Image (origine in basso a sinistra).
    static func pixelRect(_ r: CGRect, in ext: CGRect) -> CGRect {
        CGRect(x: ext.minX + r.minX * ext.width, y: ext.minY + (1 - r.maxY) * ext.height,
               width: r.width * ext.width, height: r.height * ext.height).integral.intersection(ext)
    }

    /// Applica la sfocatura dentro le zone. La misura dell'immagine non cambia.
    static func apply(_ s: Spec, to img: CIImage) -> CIImage {
        let ext = img.extent
        var out = img
        let clamped = img.clampedToExtent()
        for r in s.rects {
            let px = pixelRect(r, in: ext)
            guard px.width >= 1, px.height >= 1 else { continue }
            let side = Double(min(px.width, px.height))
            let patch: CIImage
            if s.style == "pixel" {
                // Quadretti: almeno 4 px, fino a un terzo del lato corto della zona
                let scale = max(4, side * (0.08 + 0.25 * s.strength))
                patch = clamped.applyingFilter("CIPixellate", parameters: [
                    "inputScale": scale, "inputCenter": CIVector(x: px.minX, y: px.minY),
                ])
            } else {
                let radius = max(3, side * (0.06 + 0.3 * s.strength))
                patch = clamped.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
            }
            out = patch.cropped(to: px).composited(over: out)
        }
        return out.cropped(to: ext)
    }

    // MARK: Foto

    static func image(_ file: URL, spec: Spec, out: URL) throws {
        let img = try Tools.orientedImage(file)
        let cg = try Tools.cgImage(apply(spec, to: img))
        try Tools.write(cg, to: out, quality: 0.92)
    }

    // MARK: Video

    static func video(_ file: URL, spec: Spec, out: URL, job: Job, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw NativeError("questo file non ha video") }
        // Il fotogramma arriva già girato nel verso giusto: le zone valgono così come le hai disegnate
        let vc = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: apply(spec, to: request.sourceImage), context: Media.ci)
        }
        try await Media.export(asset, videoComposition: vc, audioMix: nil, out: out, job: job, progress: progress)
    }

    /// Il primo fotogramma utile (o quello all'istante t) per disegnare le zone.
    static func frame(of url: URL, at t: Double, maxSide: CGFloat = 1100) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxSide, height: maxSide)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        return try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }
}

// MARK: - Il riquadro per disegnare le zone

struct HideMarkEditor: View {
    let url: URL
    let onDone: (String?) -> Void

    @State private var spec = HideMark.Spec()
    @State private var source: CGImage? = nil
    @State private var shown: NSImage? = nil
    @State private var draft: CGRect? = nil
    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var selected: Int? = nil

    private var isVideo: Bool { Catalog.kind(of: url) == .video }
    private let box = CGSize(width: 620, height: 400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KindBadge(kind: Catalog.kind(of: url), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nascondi filigrana").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            canvas
            if isVideo && duration > 0.5 {
                HStack(spacing: 8) {
                    Image(systemName: "film").foregroundStyle(.secondary)
                    Slider(value: $time, in: 0...duration) { editing in if !editing { loadFrame() } }
                    Text(formatShort(time)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                .help("Scorri il video per controllare dove sta il logo nei vari momenti")
            }
            HStack(spacing: 14) {
                Picker("", selection: $spec.style) {
                    Text("Sfocatura").tag("blur")
                    Text("Pixel").tag("pixel")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Text("Forza").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: $spec.strength, in: 0...1).frame(width: 150)
                Spacer()
                if !spec.rects.isEmpty {
                    Button("Togli tutte le zone") { spec.rects = []; selected = nil }
                        .controlSize(.small)
                }
            }
            Text(spec.rects.isEmpty
                 ? "Trascina sull'immagine per coprire il logo o la scritta. Puoi disegnare più zone."
                 : "\(spec.rects.count) \(spec.rects.count == 1 ? "zona" : "zone") · trascina ancora per aggiungerne, ✕ per toglierne una")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Text("Usalo sui tuoi contenuti: la filigrana di foto e video altrui protegge il loro lavoro.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Button("Annulla") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(isVideo ? "Crea il video" : "Crea la foto") { onDone(HideMark.encode(spec)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(spec.rects.isEmpty)
            }
        }
        .padding(20)
        .frame(width: box.width + 40)
        .task {
            if isVideo {
                let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                duration = d.isFinite ? d : 0
                time = min(1, duration / 2)
            }
            loadFrame()
        }
        .onChange(of: spec) { _, _ in render() }
    }

    /// L'immagine con le zone, adattata al riquadro.
    private var canvas: some View {
        let size = fitted
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
            if let shown {
                Image(nsImage: shown).resizable().frame(width: size.width, height: size.height)
                ForEach(Array(spec.rects.enumerated()), id: \.offset) { i, r in
                    zone(r, size: size, index: i)
                }
                if let d = draft {
                    Rectangle().strokeBorder(Theme.brass, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: d.width * size.width, height: d.height * size.height)
                        .offset(x: d.minX * size.width, y: d.minY * size.height)
                }
            } else {
                ProgressView().frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in draft = norm(v.startLocation, v.location, size) }
            .onEnded { v in
                let r = norm(v.startLocation, v.location, size)
                draft = nil
                if r.width > 0.01 && r.height > 0.01 { spec.rects.append(r); selected = spec.rects.count - 1 }
            })
        .frame(maxWidth: .infinity)
    }

    private func zone(_ r: CGRect, size: CGSize, index i: Int) -> some View {
        Rectangle().strokeBorder(Theme.brass, lineWidth: 2)
            .frame(width: r.width * size.width, height: r.height * size.height)
            .overlay(alignment: .topTrailing) {
                Button { spec.rects.remove(at: i); selected = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14, weight: .bold))
                        .symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.black.opacity(0.7))
                }
                .buttonStyle(.plain).offset(x: 7, y: -7)
                .help("Togli questa zona")
            }
            .offset(x: r.minX * size.width, y: r.minY * size.height)
    }

    private var fitted: CGSize {
        guard let s = source else { return CGSize(width: box.width, height: box.height * 0.8) }
        let w = CGFloat(s.width), h = CGFloat(s.height)
        let k = min(box.width / max(w, 1), box.height / max(h, 1))
        return CGSize(width: w * k, height: h * k)
    }

    private func norm(_ a: CGPoint, _ b: CGPoint, _ size: CGSize) -> CGRect {
        let x0 = min(max(0, min(a.x, b.x)), size.width), x1 = min(max(0, max(a.x, b.x)), size.width)
        let y0 = min(max(0, min(a.y, b.y)), size.height), y1 = min(max(0, max(a.y, b.y)), size.height)
        return CGRect(x: x0 / size.width, y: y0 / size.height, width: (x1 - x0) / size.width, height: (y1 - y0) / size.height)
    }

    private func loadFrame() {
        Task {
            let cg: CGImage?
            if isVideo {
                cg = await HideMark.frame(of: url, at: time)
            } else {
                cg = await Task.detached { () -> CGImage? in
                    guard var img = try? Tools.orientedImage(url) else { return nil }
                    let k = 1100 / max(img.extent.width, img.extent.height)
                    if k < 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
                    return Media.ci.createCGImage(img, from: img.extent)
                }.value
            }
            await MainActor.run {
                source = cg
                render()
            }
        }
    }

    /// Anteprima dal vivo: l'effetto vero, sulle zone già disegnate.
    private func render() {
        guard let s = source else { shown = nil; return }
        let out = HideMark.apply(spec, to: CIImage(cgImage: s))
        if let cg = Media.ci.createCGImage(out, from: out.extent) {
            shown = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
