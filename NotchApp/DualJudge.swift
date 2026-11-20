import Foundation

enum DualStage: Equatable { case answering, judging, drafting(by: Backend), reviewing(by: Backend) }
struct Judgement: Equatable { var better: Backend?; var claudeStrengths: String; var codexStrengths: String }
/// ask(backend, prompt, onText) -> full text; onText streams pieces.
typealias DualAsk = @Sendable (Backend, String, @escaping @Sendable (String) -> Void) async throws -> String

/// Claude and Codex both answer, judge each other, one drafts a hybrid, the other reviews it. UI-free; the CLI call is injected.
enum DualJudge {
    private static let style = "Be brief and direct: plain sentences, no headings, no preamble. Use short lists only when asked. Put any code in fenced blocks with a language tag."

    static func historyText(_ turns: [(role: String, text: String)]) -> String {
        turns.map { "\($0.role == "user" ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
    }
    static func answerPrompt(question: String, history: String) -> String {
        let h = history.isEmpty ? "" : "Conversation so far:\n\(history)\n\n"
        return "You answer inside a tiny overlay beside the Mac's notch. \(style)\n\n\(h)Question: \(question)"
    }
    static func judgePrompt(question: String, claude: String, codex: String) -> String {
        """
        You are judging two answers to the same question. Pick the better one, then list what each answer has that the other lacks (facts, steps, caveats, examples).
        Reply in exactly this format:
        BETTER: claude   (or codex)
        CLAUDE HAS: what the Claude answer has that the Codex answer lacks
        CODEX HAS: what the Codex answer has that the Claude answer lacks

        Question: \(question)

        CLAUDE ANSWER:
        \(claude)

        CODEX ANSWER:
        \(codex)
        """
    }
    static func draftPrompt(question: String, claude: String, codex: String, judgements: [Backend: Judgement]) -> String {
        let js = [Backend.claude, .codex].compactMap { judgements[$0] }
        func list(_ f: (Judgement) -> String) -> String {
            let l = js.map(f).filter { !$0.isEmpty }.joined(separator: "\n"); return l.isEmpty ? "(none listed)" : l
        }
        return """
        You are writing the final answer from two candidate answers. Start from the better answer and fold in every strength the judges listed for the other answer, so the result keeps the best of both. \
        Output only the final answer. You answer inside a tiny overlay beside the Mac's notch. \(style)

        Question: \(question)

        CLAUDE ANSWER:
        \(claude)

        CODEX ANSWER:
        \(codex)

        Judges' notes, what the Claude answer has that the Codex one lacks:
        \(list { $0.claudeStrengths })

        Judges' notes, what the Codex answer has that the Claude one lacks:
        \(list { $0.codexStrengths })
        """
    }
    static func reviewPrompt(question: String, claude: String, codex: String, draft: String) -> String {
        """
        You are reviewing a draft that merges two answers. Check that it is correct, answers the question, and that nothing good from either original was dropped. \
        Reply with exactly APPROVED if it is fine. Otherwise reply with REVISED: on the first line, then the full corrected answer (same style: \(style)).

        Question: \(question)

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
        if let m = t.range(of: #"better:\s*(claude|codex)"#, options: [.regularExpression, .caseInsensitive]) {
            better = t[m].lowercased().hasSuffix("claude") ? .claude : .codex
        }
        let cm = t.range(of: "claude has:", options: .caseInsensitive), xm = t.range(of: "codex has:", options: .caseInsensitive)
        func section(_ a: Range<String.Index>?, _ b: Range<String.Index>?) -> String {
            guard let a else { return "" }
            let end = b.flatMap { $0.lowerBound > a.upperBound ? $0.lowerBound : nil } ?? t.endIndex
            return t[a.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Judgement(better: better, claudeStrengths: section(cm, xm), codexStrengths: section(xm, cm))
    }
    static func writer(_ votes: [Backend: Judgement]) -> Backend {
        if let a = votes[.claude]?.better, a == votes[.codex]?.better { return a }
        return .claude
    }
    static func parseReview(_ reply: String) -> String? {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: "revised:", options: [.caseInsensitive, .anchored]) != nil else { return nil }
        let body = t.dropFirst("revised:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
    static func verdictLine(votes: [Backend: Judgement], writer: Backend, revised: Bool) -> String {
        let other: Backend = writer == .claude ? .codex : .claude
        let agreed = votes[.claude]?.better != nil && votes[.claude]?.better == votes[.codex]?.better
        let head = agreed ? "Both preferred \(writer.displayName)'s answer; \(other.displayName)'s points folded in."
                          : "Split vote; \(writer.displayName) merged both."
        return head + (revised ? " Revised by \(other.displayName)." : " Reviewed by \(other.displayName).")
    }

    static func run(question: String, history: String, ask: DualAsk,
                    onStage: @escaping @Sendable (DualStage) async -> Void,
                    onDraft: @escaping @Sendable (String) async -> Void) async throws -> (answer: String, verdict: String) {
        await onStage(.answering)
        let p = answerPrompt(question: question, history: history)
        async let c = attempt(ask, .claude, p), x = attempt(ask, .codex, p)
        let (rc, rx) = await (c, x)
        try Task.checkCancellation()
        let claude: String, codex: String
        switch (rc, rx) {
        case let (.success(a), .success(b)): claude = a; codex = b
        case let (.success(a), .failure): return (a, "Codex couldn't answer — showing Claude's.")
        case let (.failure, .success(b)): return (b, "Claude couldn't answer — showing Codex's.")
        case let (.failure(e), .failure): throw e
        }

        await onStage(.judging)
        let jp = judgePrompt(question: question, claude: claude, codex: codex)
        async let jc = attempt(ask, .claude, jp), jx = attempt(ask, .codex, jp)
        let (rjc, rjx) = await (jc, jx)
        try Task.checkCancellation()
        var votes: [Backend: Judgement] = [:]
        if case let .success(t) = rjc { let j = parseJudgement(t); if j.better != nil { votes[.claude] = j } }
        if case let .success(t) = rjx { let j = parseJudgement(t); if j.better != nil { votes[.codex] = j } }

        let w = writer(votes), other: Backend = w == .claude ? .codex : .claude
        await onStage(.drafting(by: w))
        let dp = draftPrompt(question: question, claude: claude, codex: codex, judgements: votes)
        let (stream, cont) = AsyncStream<String>.makeStream()
        let pump = Task { for await s in stream { await onDraft(s) } }
        let acc = Accumulator()
        let draft: String
        do { draft = try await ask(w, dp) { cont.yield(acc.append($0)) } } catch { cont.finish(); await pump.value; throw error }
        cont.finish(); await pump.value
        try Task.checkCancellation()

        await onStage(.reviewing(by: other))
        var final = draft, revised = false
        if let r = try? await ask(other, reviewPrompt(question: question, claude: claude, codex: codex, draft: draft), { _ in }) {
            try Task.checkCancellation()
            if let fix = parseReview(r) { final = fix; revised = true; await onDraft(fix) }
        }
        try Task.checkCancellation()
        return (final, verdictLine(votes: votes, writer: w, revised: revised))
    }

    private static func attempt(_ ask: DualAsk, _ b: Backend, _ p: String) async -> Result<String, Error> {
        do { return .success(try await ask(b, p) { _ in }) } catch { return .failure(error) }
    }
    private final class Accumulator: @unchecked Sendable {
        private let l = NSLock(); private var s = ""
        func append(_ piece: String) -> String { l.lock(); defer { l.unlock() }; s += piece; return s }
    }
}
