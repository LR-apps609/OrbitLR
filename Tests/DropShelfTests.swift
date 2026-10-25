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
        let f = DropShelf.frame(for: screen, size: NSSize(width: 150, height: 172))
        XCTAssertEqual(f.maxX, 1440 - 18, accuracy: 0.5, "al bordo destro, staccato di poco")
        XCTAssertEqual(f.midY, screen.midY, accuracy: 0.5, "a metà altezza")
        XCTAssertTrue(screen.contains(f))
        // Secondo schermo a sinistra (coordinate negative)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(left.contains(DropShelf.frame(for: left, size: NSSize(width: 150, height: 172))))
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
