import Foundation

enum DualStage: Equatable { case answering, judging, drafting(by: Backend), reviewing(by: Backend) }
struct Judgement: Equatable { var better: Backend?; var claudeStrengths: String; var codexStrengths: String }
/// ask(backend, prompt, internal, onText) -> full text; onText streams pieces. `internal` = judge/draft/review run (locked, never recorded).
typealias DualAsk = @Sendable (Backend, String, Bool, @escaping @Sendable (String) -> Void) async throws -> String

/// Claude and Codex both answer, judge each other, one drafts a hybrid, the other reviews it. UI-free; the CLI call is injected.
enum DualJudge {
    private static let style = "Be brief and direct: plain sentences, no headings, no preamble. Use short lists only when asked. Put any code in fenced blocks with a language tag."

    static func historyText(_ turns: [(role: String, text: String)]) -> String {
        turns.map { "\($0.role == "user" ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
    }
    private static func hist(_ history: String) -> String { history.isEmpty ? "" : "Conversation so far:\n\(history)\n\n" }
    static func answerPrompt(question: String, history: String) -> String {
        let h = hist(history)
        return "You answer inside a tiny overlay beside the Mac's notch. \(style)\n\n\(h)Question: \(question)"
    }
    static func judgePrompt(question: String, claude: String, codex: String, history: String = "") -> String {
        """
        You are judging two answers to the same question. Pick the better one, then list what each answer has that the other lacks (facts, steps, caveats, examples).
        Reply in exactly this format:
        BETTER: A   (or B)
        A HAS: what answer A has that answer B lacks
        B HAS: what answer B has that answer A lacks

        \(hist(history))Question: \(question)

        ANSWER A:
        \(claude)

        ANSWER B:
        \(codex)
        """
    }
    static func draftPrompt(question: String, claude: String, codex: String, judgements: [Backend: Judgement], history: String = "") -> String {
        let w = writer(judgements), o: Backend = w == .claude ? .codex : .claude
        let n = judgements.values.filter { $0.better != nil }.count
        let pick = n == 2 && judgements[.claude]?.better == judgements[.codex]?.better ? "Both judges preferred the \(w.displayName) answer; start from it."
            : n == 1 ? "One judge preferred the \(w.displayName) answer; start from it."
            : n == 2 ? "The judges split; start from the \(w.displayName) answer."
            : "No verdict; start from the \(w.displayName) answer."
        let fold = [Backend.claude, .codex].compactMap { judgements[$0] }.map { o == .claude ? $0.claudeStrengths : $0.codexStrengths }.filter { !$0.isEmpty }.joined(separator: "\n")
        return """
        You are writing the final answer from two candidate answers. \(pick) Fold in every strength the judges listed for the \(o.displayName) answer, so the result keeps the best of both. \
        Output only the final answer. You answer inside a tiny overlay beside the Mac's notch. \(style)

        \(hist(history))Question: \(question)

        CLAUDE ANSWER:
        \(claude)

        CODEX ANSWER:
        \(codex)

        Strengths of the \(o.displayName) answer to fold in:
        \(fold.isEmpty ? "(none listed)" : fold)
        """
    }
    static func reviewPrompt(question: String, claude: String, codex: String, draft: String, history: String = "") -> String {
        """
        You are reviewing a draft that merges two answers. Check that it is correct, answers the question, and that nothing good from either original was dropped. \
        Reply with exactly APPROVED if it is fine. Otherwise reply with REVISED: on the first line, then the full corrected answer (same style: \(style)).

        \(hist(history))Question: \(question)

        CLAUDE ANSWER:
        \(claude)

        CODEX ANSWER:
        \(codex)

        DRAFT:
        \(draft)
        """
    }

    static func parseJudgement(_ reply: String) -> Judgement {
        let t = reply.replacingOccurrences(of: "*", with: "")
        var better: Backend?
        if let m = t.range(of: #"better:\s*(claude|codex|a|b)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let v = t[m].lowercased()
            better = v.hasSuffix("claude") || v.hasSuffix("a") ? .claude : .codex
        }
        let cm = t.range(of: #"(claude|\ba) has:"#, options: [.regularExpression, .caseInsensitive]), xm = t.range(of: #"(codex|\bb) has:"#, options: [.regularExpression, .caseInsensitive])
        func section(_ a: Range<String.Index>?, _ b: Range<String.Index>?) -> String {
            guard let a else { return "" }
            let end = b.flatMap { $0.lowerBound > a.upperBound ? $0.lowerBound : nil } ?? t.endIndex
            return t[a.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Judgement(better: better, claudeStrengths: section(cm, xm), codexStrengths: section(xm, cm))
    }
    static func writer(_ votes: [Backend: Judgement]) -> Backend {
        let v = Set(votes.values.compactMap(\.better))
        return v.count == 1 ? v.first! : .claude // agree or a single vote decides; split or none -> Claude
    }
    static func parseReview(_ reply: String) -> String? {
        guard let m = reply.range(of: #"(?mi)^[ \t#*_]*revised:[ \t*_]*"#, options: .regularExpression) else { return nil }
        let body = reply[m.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
    static func verdictLine(votes: [Backend: Judgement], writer: Backend, revised: Bool) -> String {
        let other: Backend = writer == .claude ? .codex : .claude
        let n = votes.values.filter { $0.better != nil }.count
        let head = n == 2 && votes[.claude]?.better == votes[.codex]?.better ? "Both preferred \(writer.displayName)'s answer; \(other.displayName)'s points folded in."
            : n == 1 ? "One judge preferred \(writer.displayName)'s answer; \(other.displayName)'s points folded in."
            : n == 2 ? "Split vote; \(writer.displayName) merged both." : "No verdict; \(writer.displayName) merged both."
        return head + (revised ? " Revised by \(other.displayName)." : " Reviewed by \(other.displayName).")
    }

    static func run(question: String, history: String, ask: DualAsk,
                    onStage: @escaping @Sendable (DualStage) async -> Void,
                    onDraft: @escaping @Sendable (String) async -> Void) async throws -> (answer: String, verdict: String, winner: Backend) {
        await onStage(.answering)
        let p = answerPrompt(question: question, history: history)
        async let c = attempt(ask, .claude, p, false), x = attempt(ask, .codex, p, false)
        var (rc, rx) = await (c, x)
        if case let .success(t) = rc, blank(t) { rc = .failure(Empty()) }
        if case let .success(t) = rx, blank(t) { rx = .failure(Empty()) }
        try Task.checkCancellation()
        let claude: String, codex: String
        switch (rc, rx) {
        case let (.success(a), .success(b)): claude = a; codex = b
        case let (.success(a), .failure): return (a, "Codex couldn't answer — showing Claude's.", .claude)
        case let (.failure, .success(b)): return (b, "Claude couldn't answer — showing Codex's.", .codex)
        case let (.failure(e), .failure): throw e
        }

        await onStage(.judging)
        let jp = judgePrompt(question: question, claude: claude, codex: codex, history: history)
        async let jc = attempt(ask, .claude, jp, true), jx = attempt(ask, .codex, jp, true)
        let (rjc, rjx) = await (jc, jx)
        try Task.checkCancellation()
        var votes: [Backend: Judgement] = [:], strengths: [Backend: Judgement] = [:] // strengths: replies with no BETTER line still feed the draft
        if case let .success(t) = rjc { let j = parseJudgement(t); if j.better != nil { votes[.claude] = j } else { strengths[.claude] = j } }
        if case let .success(t) = rjx { let j = parseJudgement(t); if j.better != nil { votes[.codex] = j } else { strengths[.codex] = j } }

        let w = writer(votes), other: Backend = w == .claude ? .codex : .claude
        await onStage(.drafting(by: w))
        let dp = draftPrompt(question: question, claude: claude, codex: codex, judgements: votes.merging(strengths) { a, _ in a }, history: history)
        let (stream, cont) = AsyncStream<String>.makeStream()
        let pump = Task { for await s in stream { await onDraft(s) } }
        let acc = Accumulator()
        let draft: String
        do { draft = try await ask(w, dp, true) { cont.yield(acc.append($0)) }; if blank(draft) { throw Empty() } } catch {
            cont.finish(); await pump.value
            try Task.checkCancellation()
            let own = w == .claude ? claude : codex
            await onDraft(own) // replaces any partial text
            return (own, "\(w.displayName) couldn't merge — showing \(w.displayName)'s answer.", w)
        }
        cont.finish(); await pump.value
        try Task.checkCancellation()
        await onDraft(draft) // locked runs may deliver only the final text

        await onStage(.reviewing(by: other))
        var final = draft, revised = false
        if let r = try? await ask(other, reviewPrompt(question: question, claude: claude, codex: codex, draft: draft, history: history), true, { _ in }) {
            try Task.checkCancellation()
            if let fix = parseReview(r) { final = fix; revised = true; await onDraft(fix) }
        }
        try Task.checkCancellation()
        return (final, verdictLine(votes: votes, writer: w, revised: revised), w)
    }

    private struct Empty: Error {}
    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func attempt(_ ask: DualAsk, _ b: Backend, _ p: String, _ isInternal: Bool) async -> Result<String, Error> {
        do { return .success(try await ask(b, p, isInternal) { _ in }) } catch { return .failure(error) }
    }
    private final class Accumulator: @unchecked Sendable {
        private let l = NSLock(); private var s = ""
        func append(_ piece: String) -> String { l.lock(); defer { l.unlock() }; s += piece; return s }
    }
}
