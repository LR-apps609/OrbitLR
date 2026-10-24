import XCTest
import CoreImage

/// 3.9 · Pronto per i social: stili della parola detta, impostazioni in un clic, progetto verticale.
final class SocialReadyTests: XCTestCase {
    /// Quanti pixel «accesi» (ottone o chiari) e quanti scuri ci sono nel disegno del testo.
    private func counts(_ cg: CGImage) -> (lit: Int, dark: Int, opaque: Int) {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lit = 0, dark = 0, opaque = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 200 {
            opaque += 1
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if r > 200 && g > 150 && b < 140 { lit += 1 }
            if r < 60 && g < 60 && b < 60 { dark += 1 }
        }
        return (lit, dark, opaque)
    }

    func testStiliDellaParolaDetta() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let text = "Ciao a tutti quanti"
        var images: [String: CGImage] = [:]
        for st in VPText.wordStyles.map(\.id) {
            images[st] = try XCTUnwrap(TextRender.bitmap(text, style: "subtitle", color: "white", canvas: canvas, highlight: 2, wordStyle: st), st)
        }
        let plain = try XCTUnwrap(TextRender.bitmap(text, style: "subtitle", color: "white", canvas: canvas))
        let color = counts(images["color"]!), box = counts(images["box"]!), under = counts(images["under"]!)
        XCTAssertGreaterThan(color.lit, 50, "la parola detta è colorata")
        XCTAssertEqual(counts(plain).lit, 0, "senza parola detta niente colore")
        XCTAssertGreaterThan(box.lit, color.lit * 2, "evidenziata: il riquadro colorato è molto più grande delle lettere")
        XCTAssertGreaterThan(under.lit, color.lit, "sottolineata: lettere colorate più la riga")
        XCTAssertGreaterThan(images["big"]!.height, plain.height, "più grande: la riga diventa più alta")
        // Stesso testo e stessa parola, stili diversi: disegni diversi (niente scambi nella memoria)
        XCTAssertNotEqual(counts(images["color"]!).opaque, counts(images["box"]!).opaque)
        // Un testo senza «Parola per parola» non cambia con lo stile
        var t = VPText(); t.text = text; t.start = 0; t.end = 3; t.wordStyle = "box"
        XCTAssertNotNil(TextRender.image(t, canvas: canvas, at: 1))
    }

    func testProgettiVecchiSiAprono() throws {
        // Un testo salvato dalla 3.8 (senza «wordStyle») si legge e resta «colorata»
        var t = VPText(); t.text = "Prova"; t.anim = "word"
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        json.removeValue(forKey: "wordStyle")
        let back = try JSONDecoder().decode(VPText.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.wordStyle)
        XCTAssertEqual(back.text, "Prova")
    }

    func testProntoPer() {
        var p = VideoProject()
        let tiktok = SocialPreset.all.first { $0.id == "tiktok" }!
        tiktok.apply(&p)
        XCTAssertEqual(p.aspect, "9x16")
        XCTAssertEqual(p.resolution, 1080)
        XCTAssertTrue(tiktok.matches(p))
        let wa = SocialPreset.all.first { $0.id == "whatsapp" }!
        XCTAssertFalse(wa.matches(p))
        p.aspect = "orig"
        wa.apply(&p)
        XCTAssertEqual(p.resolution, 720)
        XCTAssertEqual(p.aspect, "orig", "WhatsApp tiene la forma del video")
        XCTAssertTrue(wa.matches(p))
        XCTAssertEqual(Set(SocialPreset.all.map(\.id)).count, SocialPreset.all.count)
    }
}
