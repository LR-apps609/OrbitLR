import XCTest
import Network

/// 2.9.5 · Manda all'iPhone.
final class SendToPhoneTests: XCTestCase {
    func testShareCopyIsM4A() throws {
        let src = Fixtures.url("Prova (suoneria).m4r")
        try Data("audio finto".utf8).write(to: src)
        let copy = try SendToPhone.shareCopy(of: src)
        XCTAssertEqual(copy.lastPathComponent, "Prova.m4a")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: src))
    }

    func testQRAndPage() {
        XCTAssertNotNil(SendToPhone.qrImage("http://192.168.1.2:5000/abc/"))
        let page = PhoneShare.page(name: "<b>Brano</b>.m4a", link: "/abc/file.m4a")
        XCTAssertTrue(page.contains("href=\"/abc/file.m4a\""))
        XCTAssertTrue(page.contains("Usa come suoneria"))
        XCTAssertFalse(page.contains("<b>Brano"), "il nome del file non diventa codice nella pagina")
    }

    /// Un GET semplice, senza URLSession (niente regole di sicurezza delle app per l'HTTP locale).
    private func get(_ urlText: String) async throws -> (String, Data) {
        let u = try XCTUnwrap(URL(string: urlText))
        let c = NWConnection(host: NWEndpoint.Host(u.host!), port: NWEndpoint.Port(rawValue: UInt16(u.port!))!, using: .tcp)
        let q = DispatchQueue(label: "test.get")
        return try await withCheckedThrowingContinuation { cont in
            var buf = Data()
            var done = false
            func finish(_ r: Result<(String, Data), Error>) { if !done { done = true; c.cancel(); cont.resume(with: r) } }
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, complete, err in
                    if let d { buf.append(d) }
                    if complete || err != nil {
                        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { finish(.failure(err ?? URLError(.badServerResponse))); return }
                        finish(.success((String(decoding: buf[..<sep.lowerBound], as: UTF8.self), Data(buf[sep.upperBound...]))))
                    } else { read() }
                }
            }
            c.stateUpdateHandler = { st in
                if case .ready = st {
                    // URL.path toglie la barra finale: si usa il percorso così com'è scritto
                    let path = URLComponents(string: urlText)?.percentEncodedPath ?? u.path
                    c.send(content: Data("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8),
                           completion: .contentProcessed { _ in read() })
                }
                if case .failed(let e) = st { finish(.failure(e)) }
            }
            c.start(queue: q)
        }
    }

    func testLocalServerServesPageAndFile() async throws {
        guard SendToPhone.localAddress() != nil else { throw XCTSkip("nessuna rete su questo Mac") }
        let src = Fixtures.url("Server (suoneria).m4r")
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        try bytes.write(to: src)
        let share = PhoneShare()
        await MainActor.run { share.start(src) }
        var base: String? = nil
        for _ in 0..<50 {
            base = await MainActor.run { share.url }
            if base != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let b = try XCTUnwrap(base, "il server non è partito")
        let (head1, page) = try await get(b)
        XCTAssertTrue(head1.contains("200"), head1)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Scarica la suoneria"))
        let (head2, file) = try await get(b + "file.m4a")
        XCTAssertTrue(head2.contains("audio/mp4"), head2)
        XCTAssertTrue(head2.contains("attachment"), head2)
        XCTAssertEqual(file, bytes, "arriva il file intero")
        // Senza il codice giusto non si scarica niente
        let wrong = b.replacingOccurrences(of: b.split(separator: "/").last.map(String.init) ?? "", with: "sbagliato")
        let (head3, _) = try await get(wrong + "file.m4a")
        XCTAssertTrue(head3.contains("404"), head3)
        await MainActor.run { share.stop() }
    }
}
