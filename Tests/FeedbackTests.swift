import XCTest

/// 4.0 · «Suggerisci un'idea» e la domanda una volta sola.
final class FeedbackTests: XCTestCase {
    func testSiChiedeUnaVoltaSola() {
        XCTAssertFalse(Feedback.shouldAsk(successes: 3, asked: false), "troppo presto")
        XCTAssertTrue(Feedback.shouldAsk(successes: Feedback.threshold, asked: false))
        XCTAssertFalse(Feedback.shouldAsk(successes: 500, asked: true), "mai una seconda volta")
    }

    func testEmailGiaPronta() throws {
        let u = try XCTUnwrap(Feedback.mail(face: "love", text: "Vorrei il tema blu + più suoni"))
        XCTAssertEqual(u.scheme, "mailto")
        let s = u.absoluteString
        XCTAssertTrue(s.hasPrefix("mailto:" + BugReport.recipient))
        let c = try XCTUnwrap(URLComponents(url: u, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(c.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("Vorrei il tema blu + più suoni"), body)
        XCTAssertTrue(body.contains("😍"))
        XCTAssertTrue(body.contains("OrbitLR"))
        XCTAssertFalse(body.contains("/Users/"), "niente percorsi")
        let subject = try XCTUnwrap(c.queryItems?.first { $0.name == "subject" }?.value)
        XCTAssertTrue(subject.contains("Idea"))
        // Senza faccina: va bene lo stesso
        XCTAssertNotNil(Feedback.mail(face: nil, text: "Ciao"))
    }
}
