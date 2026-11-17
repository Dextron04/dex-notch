import XCTest

final class AccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func verdict(_ token: Bool, _ a: ServerAnswer, _ last: Date? = nil) -> GateVerdict { Gate.decide(hasToken: token, answer: a, lastConfirmed: last, now: now) }

    func testNoKeyMeansSignUp() {
        XCTAssertEqual(verdict(false, .confirmed(email: "a@b.co")), .needsAccount)
        XCTAssertEqual(verdict(false, .unreachable, now), .needsAccount)           // a recent confirmation does not help without the key
    }
    func testServerConfirmationOpensTheApp() { XCTAssertEqual(verdict(true, .confirmed(email: "a@b.co")), .open) }
    func testRemovedMacOrDeletedAccountGoesBackToSignUp() {
        XCTAssertEqual(verdict(true, .rejected, now), .needsAccount)               // no grace for an answer of "no"
    }
    func testOfflineKeepsRunningForAWeekThenLocks() {
        XCTAssertEqual(verdict(true, .unreachable, now.addingTimeInterval(-6 * 86_400)), .open)
        XCTAssertEqual(verdict(true, .unreachable, now.addingTimeInterval(-8 * 86_400)), .locked)
        XCTAssertEqual(verdict(true, .unreachable, nil), .locked)                  // never confirmed on this Mac
    }
    func testClockSetBackDoesNotExtendTheGrace() {
        XCTAssertEqual(verdict(true, .unreachable, now.addingTimeInterval(86_400)), .locked)   // "confirmed" tomorrow
    }

    private func d(_ s: String) -> Data { Data(s.utf8) }
    func testStartMustPointAtTheSameHostOverHTTPS() {
        let ok = #"{"code":"ABCD-2345","secret":"s","url":"https://vault.example.com/link?code=ABCD2345","expires_in":600}"#
        XCTAssertEqual(HostedAPI.parseStart(d(ok), host: "vault.example.com")?.code, "ABCD-2345")
        for bad in [ok.replacingOccurrences(of: "vault.example.com/link", with: "evil.example.net/link"),      // the browser is never sent elsewhere
                    ok.replacingOccurrences(of: "https://", with: "http://"),
                    ok.replacingOccurrences(of: "/link?", with: "/steal?"),
                    ok.replacingOccurrences(of: "ABCD-2345", with: "abcd-23"),
                    #"{"code":"ABCD-2345","secret":"","url":"https://vault.example.com/link"}"#, "nope"] {
            XCTAssertNil(HostedAPI.parseStart(d(bad), host: "vault.example.com"), bad)
        }
        XCTAssertNil(HostedAPI.parseStart(d(ok), host: "vault.example.com/path"))
    }
    func testPollStates() {
        XCTAssertEqual(HostedAPI.parsePoll(d(#"{"status":"pending"}"#)), .pending)
        XCTAssertEqual(HostedAPI.parsePoll(d(#"{"status":"expired"}"#)), .expired)
        let tok = "dvt_" + String(repeating: "A", count: 43)
        XCTAssertEqual(HostedAPI.parsePoll(d(#"{"status":"approved","token":"\#(tok)","email":"a@b.co"}"#)), .approved(token: tok, email: "a@b.co"))
        XCTAssertNil(HostedAPI.parsePoll(d(#"{"status":"approved","token":"not-a-token","email":"a@b.co"}"#)))      // a bad token is never stored
        XCTAssertNil(HostedAPI.parsePoll(d(#"{"status":"approved","token":"\#(tok)"}"#)))
        XCTAssertNil(HostedAPI.parsePoll(d(#"{"status":"???"}"#)))
    }
    func testMeAnswers() {
        XCTAssertEqual(HostedAPI.parseMe(status: 200, d(#"{"email":"a@b.co","status":"pending","entitled":false}"#)), .confirmed(email: "a@b.co"))   // a free account is confirmed
        XCTAssertEqual(HostedAPI.parseMe(status: 401, d("{}")), .rejected)
        for st in [429, 500, 502, 503] { XCTAssertEqual(HostedAPI.parseMe(status: st, d("{}")), .unreachable, "\(st)") }   // a server problem says nothing about the account
        XCTAssertEqual(HostedAPI.parseMe(status: 200, d("<html>")), .unreachable)                                         // e.g. a captive portal
    }
    func testBaseIsHTTPSOnly() {
        XCTAssertEqual(HostedAPI.base("vault.example.com")?.absoluteString, "https://vault.example.com")
        XCTAssertNil(HostedAPI.base("vault.example.com/x")); XCTAssertNil(HostedAPI.base("user@host"))
    }
}
