import XCTest
import AppKit

/// 3.9.1 · Il ripiano: compare solo con dei file, al bordo destro, ed è acceso di base.
@MainActor
final class DropShelfTests: XCTestCase {
    func testSoloConDeiFile() {
        let pb = NSPasteboard(name: NSPasteboard.Name("orbitlr-prova-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("solo testo", forType: .string)
        XCTAssertFalse(DropShelf.hasFiles(pb), "trascinare del testo non fa comparire il ripiano")
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/prova.mp4") as NSURL])
        XCTAssertTrue(DropShelf.hasFiles(pb))
        pb.releaseGlobally()
    }

    func testPosizione() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = DropShelf.panelSize
        let r = DropShelf.frame(for: screen, size: size)
        XCTAssertEqual(r.maxX, screen.maxX - 12, accuracy: 0.5, "a destra, staccato dal bordo")
        XCTAssertEqual(r.midY, screen.midY, accuracy: 0.5, "a metà altezza: lontano dal bordo in alto e dagli angoli")
        XCTAssertLessThan(r.maxY, screen.maxY - 200)
        XCTAssertGreaterThan(r.minY, screen.minY + 200)
        let l = DropShelf.frame(for: screen, size: size, left: true)
        XCTAssertEqual(l.minX, screen.minX + 12, accuracy: 0.5, "a sinistra se scelto")
        // Secondo schermo a sinistra (coordinate negative)
        let other = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(other.contains(DropShelf.frame(for: other, size: size)))
        XCTAssertTrue(other.contains(DropShelf.frame(for: other, size: size, left: true)))
    }

    func testNuvolettaSempreNelloSchermo() {
        let vis = NSRect(x: 0, y: 0, width: 1440, height: 875)
        for p in [NSPoint(x: 720, y: 450), NSPoint(x: 5, y: 5), NSPoint(x: 1435, y: 870), NSPoint(x: 700, y: 100)] {
            for stack in [0.0, 1, 2] {
                let o = ResultBubble.origin(near: p, in: vis, stack: CGFloat(stack))
                let r = NSRect(origin: o, size: ResultBubble.size)
                XCTAssertTrue(vis.contains(r), "\(p) pila \(stack): \(r)")
            }
        }
        // Di base sotto la torta
        let o = ResultBubble.origin(near: NSPoint(x: 720, y: 600), in: vis, stack: 0)
        XCTAssertLessThan(o.y, 600)
    }

    func testAccesoDiBase() {
        let saved = UserDefaults.standard.object(forKey: DropShelf.key)
        UserDefaults.standard.removeObject(forKey: DropShelf.key)
        XCTAssertTrue(DropShelf.enabled)
        UserDefaults.standard.set(false, forKey: DropShelf.key)
        XCTAssertFalse(DropShelf.enabled)
        if let saved { UserDefaults.standard.set(saved, forKey: DropShelf.key) } else { UserDefaults.standard.removeObject(forKey: DropShelf.key) }
    }
}
