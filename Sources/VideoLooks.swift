import Foundation
import CoreImage
import AppKit

// ════════════════════════════════════════════════════════════════════
//  2.9 · Filtri e regolazioni del video.
//  Un «look» = un filtro pronto (con la sua forza) + sei regolazioni.
//  Si applica allo stesso modo nell'anteprima e nell'esportazione
//  (VideoProjectBuilder disegna ogni fotogramma con Core Image).
// ════════════════════════════════════════════════════════════════════

struct VPLook: Codable, Equatable, Sendable {
    /// Id del filtro pronto («none» = nessuno).
    var preset = "none"
    /// Forza del filtro, 0…1.
    var amount = 1.0
    /// Regolazioni, tutte da −1 a 1 (0 = com'è).
    var brightness = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    /// Da 0 a 1.
    var sharpness = 0.0
    var vignette = 0.0

    var isIdentity: Bool {
        (preset == "none" || amount < 0.001) && abs(brightness) < 0.001 && abs(contrast) < 0.001 && abs(saturation) < 0.001
            && abs(warmth) < 0.001 && sharpness < 0.001 && vignette < 0.001
    }
}

struct VPLookPreset: Identifiable, Equatable {
    let id: String
    let name: String
}

enum VideoLooks {
    static let presets: [VPLookPreset] = [
        VPLookPreset(id: "none", name: "Nessuno"),
        VPLookPreset(id: "vivid", name: "Vivido"),
        VPLookPreset(id: "warm", name: "Caldo"),
        VPLookPreset(id: "cool", name: "Freddo"),
        VPLookPreset(id: "mono", name: "Bianco e nero"),
        VPLookPreset(id: "sepia", name: "Seppia"),
        VPLookPreset(id: "vintage", name: "Vintage"),
        VPLookPreset(id: "film", name: "Pellicola"),
        VPLookPreset(id: "night", name: "Notte"),
        VPLookPreset(id: "dream", name: "Sogno"),
        VPLookPreset(id: "drama", name: "Drammatico"),
        VPLookPreset(id: "pastel", name: "Pastello"),
        VPLookPreset(id: "radio", name: "Radio"),
    ]

    static func name(of id: String) -> String { presets.first { $0.id == id }?.name ?? "Nessuno" }

    /// Applica il look a un fotogramma. Il risultato ha sempre la stessa misura dell'originale.
    static func apply(_ look: VPLook?, to image: CIImage) -> CIImage {
        guard let look, !look.isIdentity else { return image }
        let extent = image.extent
        var img = image
        if look.preset != "none", look.amount > 0.001 {
            let styled = preset(look.preset, img).cropped(to: extent)
            img = look.amount >= 0.999 ? styled
                : styled.applyingFilter("CIDissolveTransition", ["inputTargetImage": img, "inputTime": 1 - look.amount]).cropped(to: extent)
        }
        img = adjust(img, look, extent: extent)
        return img.cropped(to: extent)
    }

    // MARK: Filtri pronti

    private static func preset(_ id: String, _ i: CIImage) -> CIImage {
        switch id {
        case "vivid":
            return controls(i, saturation: 1.35, contrast: 1.08).applyingFilter("CIVibrance", ["inputAmount": 0.4])
        case "warm":
            return tint(i, r: 1.10, g: 1.02, b: 0.86)
        case "cool":
            return tint(i, r: 0.88, g: 1.0, b: 1.12)
        case "mono":
            return controls(i, saturation: 0, contrast: 1.12)
        case "sepia":
            return i.applyingFilter("CISepiaTone", ["inputIntensity": 0.85])
        case "vintage":
            let faded = lift(controls(i.applyingFilter("CISepiaTone", ["inputIntensity": 0.35]), saturation: 0.8, contrast: 0.92), 0.06)
            return vignette(faded, 0.6, extent: i.extent)
        case "film":
            return lift(controls(tint(i, r: 1.03, g: 1.0, b: 0.95), saturation: 0.88, contrast: 1.12), 0.03)
        case "night":
            return tint(controls(i, brightness: -0.06, saturation: 0.75, contrast: 1.15), r: 0.9, g: 0.97, b: 1.12)
        case "dream":
            return controls(i.applyingFilter("CIBloom", ["inputRadius": 12, "inputIntensity": 0.6]), brightness: 0.03, saturation: 1.05)
        case "drama":
            return vignette(controls(i, saturation: 0.85, contrast: 1.3), 0.8, extent: i.extent)
        case "pastel":
            return controls(i, brightness: 0.06, saturation: 0.6, contrast: 0.9)
        case "radio":
            // Lo stile di OrbitLR: caldo, un velo color salvia, bordi scuri
            let warm = tint(i.applyingFilter("CISepiaTone", ["inputIntensity": 0.25]), r: 1.04, g: 1.03, b: 0.9)
            return vignette(controls(warm, saturation: 0.9, contrast: 1.05), 0.55, extent: i.extent)
        default:
            return i
        }
    }

    // MARK: Regolazioni

    private static func adjust(_ i: CIImage, _ l: VPLook, extent: CGRect) -> CIImage {
        var img = i
        if abs(l.brightness) > 0.001 || abs(l.contrast) > 0.001 || abs(l.saturation) > 0.001 {
            img = controls(img, brightness: l.brightness * 0.3, saturation: 1 + l.saturation, contrast: 1 + l.contrast * 0.5)
        }
        if abs(l.warmth) > 0.001 {
            let w = l.warmth
            img = tint(img, r: 1 + 0.12 * w, g: 1 + 0.02 * w, b: 1 - 0.14 * w)
        }
        if l.sharpness > 0.001 {
            img = img.applyingFilter("CISharpenLuminance", ["inputSharpness": l.sharpness * 0.9]).cropped(to: extent)
        }
        if l.vignette > 0.001 {
            img = vignette(img, l.vignette, extent: extent)
        }
        return img
    }

    private static func controls(_ i: CIImage, brightness: Double = 0, saturation: Double = 1, contrast: Double = 1) -> CIImage {
        i.applyingFilter("CIColorControls", ["inputBrightness": brightness, "inputSaturation": saturation, "inputContrast": contrast])
    }

    /// Moltiplica i canali: r > 1 e b < 1 scalda, il contrario raffredda.
    private static func tint(_ i: CIImage, r: Double, g: Double, b: Double) -> CIImage {
        i.applyingFilter("CIColorMatrix", [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        ])
    }

    /// Alza i neri (effetto «sbiadito» delle foto vecchie).
    private static func lift(_ i: CIImage, _ amount: Double) -> CIImage {
        i.applyingFilter("CIColorMatrix", [
            "inputRVector": CIVector(x: 1 - amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 - amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 - amount, w: 0),
            "inputBiasVector": CIVector(x: amount, y: amount, z: amount, w: 0),
        ])
    }

    private static func vignette(_ i: CIImage, _ strength: Double, extent: CGRect) -> CIImage {
        let r = Double(max(extent.width, extent.height)) * 0.62
        return i.applyingFilter("CIVignetteEffect", [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius": r,
            "inputIntensity": min(1, strength),
            "inputFalloff": 0.6,
        ]).cropped(to: extent)
    }

    // MARK: Miniature dei filtri

    /// Una miniatura con il filtro applicato (per i pulsanti dei filtri).
    static func thumbnail(_ image: NSImage, look: VPLook, side: CGFloat = 96) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let k = side / max(ci.extent.width, ci.extent.height)
        if k < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let out = apply(look, to: ci)
        guard let rendered = Media.ci.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
