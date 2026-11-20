import XCTest
@testable import NotchApp

final class DualJudgeTests: XCTestCase {
    struct Boom: Error {}
    enum Kind { case answer, judge, draft, review }
    static func kind(_ p: String) -> Kind {
        if p.contains("You are judging two answers") { return .judge }
        if p.contains("You are writing the final answer") { return .draft }
        if p.contains("You are reviewing a draft") { return .review }
        return .answer
    }
    /// Script: (backend, kind) -> reply, or nil to throw.
    static func fake(_ script: @escaping @Sendable (Backend, Kind) -> String?, seen: Seen? = nil) -> DualAsk {
        { b, p, onText in
            let k = kind(p)
            seen?.add(b, k, p)
            guard let r = script(b, k) else { throw Boom() }
            onText(r)
            return r
        }
    }
    final class Seen: @unchecked Sendable {
        private let l = NSLock(); private var items: [(Backend, Kind, String)] = []
        func add(_ b: Backend, _ k: Kind, _ p: String) { l.lock(); items.append((b, k, p)); l.unlock() }
        func prompts(_ k: Kind) -> [String] { l.lock(); defer { l.unlock() }; return items.filter { $0.1 == k }.map { $0.2 } }
    }
    final class Stages: @unchecked Sendable {
        private let l = NSLock(); private(set) var v: [DualStage] = []; private(set) var drafts: [String] = []
        func add(_ s: DualStage) { l.lock(); v.append(s); l.unlock() }
        func draft(_ s: String) { l.lock(); drafts.append(s); l.unlock() }
    }
    func go(_ ask: @escaping DualAsk, _ st: Stages = Stages()) async throws -> (answer: String, verdict: String) {
        try await DualJudge.run(question: "Q", history: "", ask: ask, onStage: { st.add($0) }, onDraft: { st.draft($0) })
    }
    static let agree: @Sendable (Backend, Kind) -> String? = { b, k in
        switch k {
        case .answer: return b == .claude ? "claude answer" : "codex answer"
        case .judge: return "BETTER: claude\nCLAUDE HAS: clarity\nCODEX HAS: an example"
        case .draft: return "the draft"
        case .review: return "APPROVED"
        }
    }

    func testParseJudgementVariants() {
        XCTAssertEqual(DualJudge.parseJudgement("BETTER: Codex\nCLAUDE HAS: a\nCODEX HAS: b").better, .codex)
        let j = DualJudge.parseJudgement("  **better: claude**\n**CLAUDE HAS:** speed\n**CODEX HAS:** depth")
        XCTAssertEqual(j.better, .claude)
        XCTAssertEqual(j.claudeStrengths, "speed")
        XCTAssertEqual(j.codexStrengths, "depth")
        XCTAssertNil(DualJudge.parseJudgement("no idea").better)
    }
    func testWriterAgreementAndTie() {
        let c = Judgement(better: .codex, claudeStrengths: "", codexStrengths: "")
        let l = Judgement(better: .claude, claudeStrengths: "", codexStrengths: "")
        XCTAssertEqual(DualJudge.writer([.claude: c, .codex: c]), .codex)
        XCTAssertEqual(DualJudge.writer([.claude: c, .codex: l]), .claude)
        XCTAssertEqual(DualJudge.writer([:]), .claude)
    }
    func testParseReviewApprovedAndRevised() {
        XCTAssertNil(DualJudge.parseReview("APPROVED"))
        XCTAssertNil(DualJudge.parseReview("  approved \n"))
        XCTAssertEqual(DualJudge.parseReview("REVISED:\nBetter text"), "Better text")
        XCTAssertNil(DualJudge.parseReview("looks fine"))
    }
    func testHappyPathRunsFourStagesInOrder() async throws {
        let st = Stages()
        let r = try await go(Self.fake(Self.agree), st)
        XCTAssertEqual(st.v, [.answering, .judging, .drafting(by: .claude), .reviewing(by: .codex)])
        XCTAssertEqual(r.answer, "the draft")
        XCTAssertEqual(r.verdict, "Both preferred Claude's answer; Codex's points folded in. Reviewed by Codex.")
        XCTAssertEqual(st.drafts.last, "the draft")
    }
    func testRevisionReplacesDraft() async throws {
        let st = Stages()
        let r = try await go(Self.fake { b, k in k == .review ? "REVISED:\nfixed" : Self.agree(b, k) }, st)
        XCTAssertEqual(r.answer, "fixed")
        XCTAssertEqual(st.drafts.last, "fixed")
        XCTAssertTrue(r.verdict.hasSuffix(" Revised by Codex."))
    }
    func testSplitVoteVerdict() async throws {
        let r = try await go(Self.fake { b, k in k == .judge ? "BETTER: \(b == .claude ? "codex" : "claude")\nCLAUDE HAS: x\nCODEX HAS: y" : Self.agree(b, k) })
        XCTAssertEqual(r.verdict, "Split vote; Claude merged both. Reviewed by Codex.")
    }
    func testAnswerFailureFallsBackToOther() async throws {
        let st = Stages()
        let r = try await go(Self.fake { b, k in b == .codex && k == .answer ? nil : Self.agree(b, k) }, st)
        XCTAssertEqual(r.answer, "claude answer")
        XCTAssertEqual(r.verdict, "Codex couldn't answer — showing Claude's.")
        XCTAssertEqual(st.v, [.answering])
    }
    func testBothFailThrows() async {
        do { _ = try await go(Self.fake { _, _ in nil }); XCTFail() } catch { XCTAssertTrue(error is Boom) }
    }
    func testUnparseableVerdictIsNoVote() async throws {
        let r = try await go(Self.fake { b, k in k == .judge ? "shrug" : Self.agree(b, k) })
        XCTAssertEqual(r.verdict, "Split vote; Claude merged both. Reviewed by Codex.")
        XCTAssertEqual(r.answer, "the draft")
    }
    func testReviewFailureKeepsDraft() async throws {
        let r = try await go(Self.fake { b, k in k == .review ? nil : Self.agree(b, k) })
        XCTAssertEqual(r.answer, "the draft")
    }
    func testCancellationPropagates() async {
        do {
            _ = try await DualJudge.run(question: "Q", history: "", ask: Self.fake(Self.agree),
                onStage: { s in if s == .answering { withUnsafeCurrentTask { $0?.cancel() } } }, onDraft: { _ in })
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDraftPromptContainsBothAnswersAndStrengths() {
        let j = Judgement(better: .claude, claudeStrengths: "CS-MARK", codexStrengths: "XS-MARK")
        let p = DualJudge.draftPrompt(question: "Q", claude: "ANS-C", codex: "ANS-X", judgements: [.claude: j, .codex: j])
        for s in ["ANS-C", "ANS-X", "CS-MARK", "XS-MARK", "Start from the better answer", "every strength"] { XCTAssertTrue(p.contains(s), s) }
        let r = DualJudge.reviewPrompt(question: "Q", claude: "ANS-C", codex: "ANS-X", draft: "DR")
        XCTAssertTrue(r.contains("nothing good from either original was dropped"))
    }
    func testHistoryTextIncludedInAnswerPrompt() {
        let h = DualJudge.historyText([("user", "hi"), ("assistant", "hello")])
        XCTAssertTrue(h.contains("hi") && h.contains("hello"))
        XCTAssertTrue(DualJudge.answerPrompt(question: "Q2", history: h).contains("hello"))
        XCTAssertEqual(DualJudge.historyText([]), "")
    }
}
