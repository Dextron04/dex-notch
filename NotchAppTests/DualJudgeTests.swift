import XCTest

final class DualJudgeTests: XCTestCase {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
    enum Kind { case answer, judge, draft, review }
    static func kind(_ p: String) -> Kind {
        if p.contains("You are judging two answers") { return .judge }
        if p.contains("You are writing the final answer") { return .draft }
        if p.contains("You are reviewing a draft") { return .review }
        return .answer
    }
    /// Script: (backend, kind) -> reply, or nil to throw.
    static func fake(_ script: @escaping @Sendable (Backend, Kind) -> String?, seen: Seen? = nil) -> DualAsk {
        { b, p, isInternal, onText in
            let k = kind(p)
            seen?.add(b, k, p, isInternal)
            guard let r = script(b, k) else { throw Boom() }
            onText(r)
            return r
        }
    }
    final class Seen: @unchecked Sendable {
        private let l = NSLock(); private var items: [(Backend, Kind, String)] = []; private var flags: [(Kind, Bool)] = []
        func add(_ b: Backend, _ k: Kind, _ p: String, _ i: Bool) { l.lock(); items.append((b, k, p)); flags.append((k, i)); l.unlock() }
        func internals(_ k: Kind) -> [Bool] { l.lock(); defer { l.unlock() }; return flags.filter { $0.0 == k }.map(\.1) }
        func prompts(_ k: Kind) -> [String] { l.lock(); defer { l.unlock() }; return items.filter { $0.1 == k }.map { $0.2 } }
    }
    final class Stages: @unchecked Sendable {
        private let l = NSLock(); private(set) var v: [DualStage] = []; private(set) var drafts: [String] = []
        func add(_ s: DualStage) { l.lock(); v.append(s); l.unlock() }
        func draft(_ s: String) { l.lock(); drafts.append(s); l.unlock() }
    }
    func go(_ ask: @escaping DualAsk, _ st: Stages = Stages()) async throws -> (answer: String, verdict: String, winner: Backend) {
        try await DualJudge.run(question: "Q", history: "", ask: ask, onStage: { st.add($0) }, onDraft: { st.draft($0) })
    }
    static let agree: @Sendable (Backend, Kind) -> String? = { b, k in
        switch k {
        case .answer: return b == .claude ? "claude answer" : "codex answer"
        case .judge: return "BETTER: A\nA HAS: clarity\nB HAS: an example"
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
        XCTAssertEqual(DualJudge.writer([.codex: c]), .codex)
        XCTAssertEqual(DualJudge.verdictLine(votes: [.codex: c], writer: .codex, revised: false), "One judge preferred Codex's answer; Claude's points folded in. Reviewed by Claude.")
        XCTAssertEqual(DualJudge.verdictLine(votes: [:], writer: .claude, revised: true), "No verdict; Claude merged both. Revised by Codex.")
    }
    func testParseReviewApprovedAndRevised() {
        XCTAssertNil(DualJudge.parseReview("APPROVED"))
        XCTAssertNil(DualJudge.parseReview("  approved \n"))
        XCTAssertEqual(DualJudge.parseReview("REVISED:\nBetter text"), "Better text")
        XCTAssertNil(DualJudge.parseReview("looks fine"))
        XCTAssertEqual(DualJudge.parseReview("**REVISED:**\nA"), "A")
        XCTAssertEqual(DualJudge.parseReview("## REVISED:\nB"), "B")
        XCTAssertEqual(DualJudge.parseReview("Sure.\nREVISED:\nC"), "C")
    }
    func testHappyPathRunsFourStagesInOrder() async throws {
        let st = Stages()
        let r = try await go(Self.fake(Self.agree), st)
        XCTAssertEqual(st.v, [.answering, .judging, .drafting(by: .claude), .reviewing(by: .codex)])
        XCTAssertEqual(r.answer, "the draft")
        XCTAssertEqual(r.verdict, "Both preferred Claude's answer; Codex's points folded in. Reviewed by Codex.")
        XCTAssertEqual(r.winner, .claude)
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
        let r = try await go(Self.fake { b, k in k == .judge ? "BETTER: \(b == .claude ? "B" : "A")\nA HAS: x\nB HAS: y" : Self.agree(b, k) })
        XCTAssertEqual(r.verdict, "Split vote; Claude merged both. Reviewed by Codex.")
    }
    func testAnswerFailureFallsBackToOther() async throws {
        let st = Stages()
        let r = try await go(Self.fake { b, k in b == .codex && k == .answer ? nil : Self.agree(b, k) }, st)
        XCTAssertEqual(r.answer, "claude answer")
        XCTAssertEqual(r.verdict, "Codex couldn't answer (boom) — showing Claude's.")
        XCTAssertEqual(r.winner, .claude)
        XCTAssertEqual(st.v, [.answering])
    }
    func testBothFailThrows() async {
        do { _ = try await go(Self.fake { _, _ in nil }); XCTFail() } catch { XCTAssertTrue(error is Boom) }
    }
    func testUnparseableVerdictIsNoVote() async throws {
        let r = try await go(Self.fake { b, k in k == .judge ? "shrug" : Self.agree(b, k) })
        XCTAssertEqual(r.verdict, "No verdict; Claude merged both. Reviewed by Codex.")
        XCTAssertEqual(r.answer, "the draft")
    }
    func testParseReviewKeepsBodyVerbatim() {
        let body = "**bold** and a * b\n# Heading\n```c\n#include <stdio.h>\n```"
        XCTAssertEqual(DualJudge.parseReview("REVISED:\n" + body + "\n"), body)
        XCTAssertEqual(DualJudge.parseReview("**REVISED:**\n" + body), body)
    }
    func testSplitDraftPromptSaysSplit() {
        let c = Judgement(better: .claude, claudeStrengths: "", codexStrengths: "")
        let x = Judgement(better: .codex, claudeStrengths: "", codexStrengths: "")
        XCTAssertTrue(DualJudge.draftPrompt(question: "Q", claude: "a", codex: "b", judgements: [.claude: c, .codex: x]).contains("The judges split; start from the Claude answer."))
    }
    func testDraftFailureKeepsBetterAnswer() async throws {
        let st = Stages()
        let r = try await go(Self.fake { b, k in k == .draft ? nil : Self.agree(b, k) }, st)
        XCTAssertEqual(r.answer, "claude answer")
        XCTAssertEqual(r.verdict, "Claude couldn't merge — showing Claude's answer.")
        XCTAssertEqual(r.winner, .claude)
        XCTAssertEqual(st.v, [.answering, .judging, .drafting(by: .claude)])
        XCTAssertEqual(st.drafts.last, "claude answer")
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
        for s in ["ANS-C", "ANS-X", "XS-MARK", "Both judges preferred the Claude answer; start from it.", "every strength"] { XCTAssertTrue(p.contains(s), s) }
        let r = DualJudge.reviewPrompt(question: "Q", claude: "ANS-C", codex: "ANS-X", draft: "DR")
        XCTAssertTrue(r.contains("nothing good from either original was dropped"))
    }
    func testHistoryTextIncludedInAnswerPrompt() {
        let h = DualJudge.historyText([("user", "hi"), ("assistant", "hello")])
        XCTAssertTrue(h.contains("hi") && h.contains("hello"))
        XCTAssertTrue(DualJudge.answerPrompt(question: "Q2", history: h).contains("hello"))
        XCTAssertEqual(DualJudge.historyText([]), "")
    }

    func testHistoryReachesAllStagesAndInternalFlags() async throws {
        let seen = Seen()
        _ = try await DualJudge.run(question: "Q", history: "User: HIST-MARK", ask: Self.fake(Self.agree, seen: seen), onStage: { _ in }, onDraft: { _ in })
        for k in [Kind.answer, .judge, .draft, .review] {
            XCTAssertEqual(seen.prompts(k).count, k == .draft || k == .review ? 1 : 2)
            XCTAssertTrue(seen.prompts(k).allSatisfy { $0.contains("Conversation so far:") && $0.contains("HIST-MARK") }, "\(k)")
            XCTAssertTrue(seen.internals(k).allSatisfy { $0 == (k != .answer) }, "\(k)")
        }
        XCTAssertFalse(DualJudge.judgePrompt(question: "Q", claude: "a", codex: "b").contains("Conversation so far"))
    }
    func testJudgePromptIsBlind() {
        let p = DualJudge.judgePrompt(question: "Q", claude: "a", codex: "b")
        XCTAssertTrue(p.contains("ANSWER A") && p.contains("ANSWER B") && p.contains("BETTER: A"))
        XCTAssertFalse(p.lowercased().contains("claude") || p.lowercased().contains("codex"))
        XCTAssertEqual(DualJudge.parseJudgement("BETTER: B\nA HAS: x\nB HAS: y").better, .codex)
        XCTAssertEqual(DualJudge.parseJudgement("BETTER: B\nA HAS: x\nB HAS: y").claudeStrengths, "x")
    }
    func testEmptyAnswerCountsAsFailure() async throws {
        let r = try await go(Self.fake { b, k in b == .claude && k == .answer ? "  \n" : Self.agree(b, k) })
        XCTAssertEqual(r.answer, "codex answer")
        XCTAssertEqual(r.winner, .codex)
        XCTAssertEqual(r.verdict, "Claude couldn't answer (it returned no text) — showing Codex's.")
    }
    func testFailureNoteNamesTheReasonButNeverMoreThanAShortFirstLine() {
        struct E: Error, LocalizedError { var errorDescription: String? { "claude exited with code 1. Is it logged in?\nsecret second line" } }
        XCTAssertEqual(DualJudge.failureNote(.claude, E(), "showing Codex's."), "Claude couldn't answer (claude exited with code 1. Is it logged in?) — showing Codex's.")
        XCTAssertEqual(DualJudge.reason(CancellationError()), "it was cancelled")
        XCTAssertLessThanOrEqual(DualJudge.reason(Long()).count, 91)
        struct Long: Error, LocalizedError { var errorDescription: String? { String(repeating: "x", count: 500) } }
        struct Blank: Error, LocalizedError { var errorDescription: String? { "" } }
        XCTAssertEqual(DualJudge.failureNote(.codex, Blank(), "showing Claude's."), "Codex couldn't answer — showing Claude's.")
    }
    func testEmptyDraftFallsBack() async throws {
        let r = try await go(Self.fake { b, k in k == .draft ? " " : Self.agree(b, k) })
        XCTAssertEqual(r.answer, "claude answer")
        XCTAssertEqual(r.verdict, "Claude couldn't merge — showing Claude's answer.")
    }
    func testEmptyJudgeReplyIsNoVote() async throws {
        let r = try await go(Self.fake { b, k in k == .judge ? "\n " : Self.agree(b, k) })
        XCTAssertEqual(r.verdict, "No verdict; Claude merged both. Reviewed by Codex.")
    }
    func testStrengthsKeptWithoutVerdictLine() async throws {
        let seen = Seen()
        let r = try await go(Self.fake({ b, k in k == .judge ? "A HAS: A-MARK\nB HAS: B-MARK" : Self.agree(b, k) }, seen: seen))
        XCTAssertTrue(seen.prompts(.draft)[0].contains("B-MARK"))
        XCTAssertTrue(r.verdict.hasPrefix("No verdict"))
    }
    func testDraftShownEvenWithoutStreaming() async throws {
        let st = Stages()
        let ask: DualAsk = { b, p, _, _ in Self.agree(b, Self.kind(p))! } // never calls onText
        _ = try await go(ask, st)
        XCTAssertEqual(st.drafts.first, "the draft")
    }
}

/// Both runs two CLIs at once: one run's output must end when that run ends, not when the other one writes or exits.
final class RunnerLinesTests: XCTestCase {
    func testLinesSplitAndFlushTheTail() async {
        let p = Pipe()
        p.fileHandleForWriting.write(Data("one\ntwo\nthr".utf8)); p.fileHandleForWriting.write(Data("ee".utf8)); try? p.fileHandleForWriting.close()
        var got: [String] = []
        for await l in AgentRunner.lines(of: p.fileHandleForReading) { got.append(l) }
        XCTAssertEqual(got, ["one", "two", "three"])
    }
    func testOneStreamEndsWhileAnotherIsStillWaiting() async {
        let a = Pipe(), b = Pipe()      // b never gets data or EOF during the test: a pending read, like Codex thinking
        let held = Task { for await _ in AgentRunner.lines(of: b.fileHandleForReading) {} }
        try? await Task.sleep(for: .milliseconds(100))
        a.fileHandleForWriting.write(Data("x\n".utf8)); try? a.fileHandleForWriting.close()
        let done = expectation(description: "a ended")
        Task { for await _ in AgentRunner.lines(of: a.fileHandleForReading) {}; done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        held.cancel(); try? b.fileHandleForWriting.close()
    }
}
