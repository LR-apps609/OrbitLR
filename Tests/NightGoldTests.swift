import XCTest
import AppKit
import SwiftUI

/// 6.0 «Notte e oro»: i colori della direzione B, con contrasto AA (4,5:1) per i testi.
final class NightGoldTests: XCTestCase {
    private func rgb(_ c: Color, dark: Bool) -> (Double, Double, Double) {
        let ns = NSColor(c)
        var out = (0.0, 0.0, 0.0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let s = ns.usingColorSpace(.sRGB)!
            out = (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        }
        return out
    }
    private func lum(_ c: (Double, Double, Double)) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
    }
    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = lum(rgb(a, dark: dark)), lb = lum(rgb(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testTextIsReadableInLightAndDark() {
        for dark in [false, true] {
            XCTAssertGreaterThan(contrast(Theme.ink, Theme.background, dark: dark), 4.5, "testo sulla carta")
            XCTAssertGreaterThan(contrast(Theme.ink2, Theme.background, dark: dark), 4.5, "testo secondario")
            XCTAssertGreaterThan(contrast(Theme.brass, Theme.background, dark: dark), 4.5, "etichette d’oro")
            XCTAssertGreaterThan(contrast(Theme.onAccent, Theme.accent, dark: dark), 4.5, "pulsante principale")
            XCTAssertGreaterThan(contrast(Theme.segOnText, Theme.segOn, dark: dark), 4.5, "interruttore")
            XCTAssertGreaterThan(contrast(Theme.sliceHotText, Theme.sliceHot, dark: dark), 4.5, "spicchio acceso")
            XCTAssertGreaterThan(contrast(Theme.danger, Theme.background, dark: dark), 4.5, "errori")
        }
    }

    func testPDFIsBlue() {
        let (r, _, b) = rgb(Theme.color(.pdf), dark: false)
        XCTAssertGreaterThan(b, r, "il PDF è blu, come sul sito")
    }
}
