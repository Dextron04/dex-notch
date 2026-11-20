# Dual Judgement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Both" dial choice where Claude and Codex answer, judge each other, and produce one hybrid answer, with live stage status.

**Architecture:** `Backend.both` joins the dial. A new UI-free `DualJudge` enum holds prompts, verdict parsing and the async 4-stage orchestration, with the CLI call injected as a closure so it is unit-tested with fakes. `Assistant` wires it to `AgentRunner.run`, exposes `dualStage`, and the notch shows a stage track, a combined mark and a verdict line.

**Tech Stack:** Swift 6, SwiftUI, XCTest, xcodegen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-11-20-dual-judgement-design.md`

## Global Constraints
- Branch `feature/dual-judgement`. Commits: no Claude co-author trailer, no "Generated with" line.
- New source files must be added to `project.yml` (UI-free ones also to the `NotchAppTests` sources list), then run `xcodegen generate`.
- Tests: `xcodebuild test -scheme NotchApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- Dual is always read-only: every dual `Route` has `work: false`, `folder: nil`, `locked: false`.
- No draft file on disk; the draft is a `String` in memory.
- `.both` is offered only when `cliFound` contains both `.claude` and `.codex`. Add-on triage (`Addons.swift` order) never uses `.both`.
- UI copy uses `displayName` ("Claude", "Codex").

## Review Focus
- One CLI fails in Answering → the other's answer is shown alone with note "Codex couldn't answer — showing Claude's." (Task 2 test `testAnswerFailureFallsBackToOther`).
- Both CLIs fail in Answering → error thrown, no empty turn left (Task 2 `testBothFailThrows`).
- Judge reply with no `BETTER:` line or garbage → counts as no vote; tie → Claude writes (Task 2 `testUnparseableVerdictIsNoVote`).
- Reviewer fails or times out → draft kept as final (Task 2 `testReviewFailureKeepsDraft`).
- ⌘N / cancel mid-dual → orchestration stops, `dualStage` back to nil (Task 3 step: `finish()` clears it; Task 2 `testCancellationPropagates`).

---

### Task 1: `Backend.both` plumbing

**Files:**
- Modify: `NotchApp/AgentStream.swift` (enum `Backend`, `order`, `route`, `consumePrefix`, `defaultBackend`)
- Modify: `NotchApp/Assistant.swift` (`choices`, `setBackend`, `toggleWork`, `cycleFolder`)
- Modify: `NotchApp/Addons.swift:81` (drop `.both` when parsing order)
- Modify: `NotchApp/ModelMark.swift` (temporary `.both` case: claude + codex marks overlapped; Task 4 polishes)
- Test: `NotchAppTests/AgentStreamTests.swift`

**Interfaces:**
- Produces: `Backend.both` (rawValue `"both"`, `displayName` `"Both"`); `AgentStream.order == [.gemma, .claude, .codex, .both]`; `AgentStream.dialChoices(cliFound: Set<Backend>, hasGemma: Bool) -> [Backend]`.

- [ ] **Step 1: Failing tests**
```swift
func testBothPrefixIsReadOnly() { XCTAssertEqual(AgentStream.route("@both+ hi"), Route(backend: .both, work: false, prompt: "hi")) }
func testBothOnlyWithBothCLIs() {
    XCTAssertEqual(AgentStream.dialChoices(cliFound: [.claude, .codex], hasGemma: false), [.claude, .codex, .both])
    XCTAssertEqual(AgentStream.dialChoices(cliFound: [.claude], hasGemma: true), [.gemma, .claude])
}
func testDefaultNeverPicksBothUnlessPreferred() {
    XCTAssertEqual(AgentStream.defaultBackend(choices: [.claude, .codex, .both], preferred: nil), .claude)
    XCTAssertEqual(AgentStream.defaultBackend(choices: [.claude, .codex, .both], preferred: .both), .both)
}
func testConsumeBothPrefixNeverWork() { XCTAssertEqual(AgentStream.consumePrefix("@both+ x")?.work, false) }
```
Plus in `AddonsTests`: an order containing `"both"` parses without it.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** `route`/`consumePrefix`: `work` false for `.gemma` and `.both`. `Assistant.choices` returns `AgentStream.dialChoices(cliFound:hasGemma:)`. `setBackend`, `toggleWork`, `cycleFolder` treat `.both` like `.gemma` for `work` (always false, folder untouched). Fix every exhaustive `switch` on `Backend` the compiler flags.
- [ ] **Step 4: Run all tests, expect PASS.**
- [ ] **Step 5: Commit** `feat(dual): Backend.both on the dial, read-only`.

### Task 2: `DualJudge` logic + orchestration (UI-free)

**Files:**
- Create: `NotchApp/DualJudge.swift` (add to app sources and `NotchAppTests` sources in `project.yml`)
- Test: `NotchAppTests/DualJudgeTests.swift`

**Interfaces:**
- Consumes: `Backend`.
- Produces:
```swift
enum DualStage: Equatable { case answering, judging, drafting(by: Backend), reviewing(by: Backend) }
struct Judgement: Equatable { var better: Backend?; var claudeStrengths: String; var codexStrengths: String }
typealias DualAsk = @Sendable (Backend, String, @escaping @Sendable (String) -> Void) async throws -> String
// ask(backend, prompt, onText) -> full text; onText streams pieces.
enum DualJudge {
    static func historyText(_ turns: [(role: String, text: String)]) -> String
    static func answerPrompt(question: String, history: String) -> String
    static func judgePrompt(question: String, claude: String, codex: String) -> String
    static func draftPrompt(question: String, claude: String, codex: String, judgements: [Backend: Judgement]) -> String
    static func reviewPrompt(question: String, claude: String, codex: String, draft: String) -> String
    static func parseJudgement(_ reply: String) -> Judgement
    static func writer(_ votes: [Backend: Judgement]) -> Backend      // both agree → that one; else .claude
    static func parseReview(_ reply: String) -> String?               // nil = APPROVED; else the corrected text
    static func verdictLine(votes: [Backend: Judgement], writer: Backend, revised: Bool) -> String
    static func run(question: String, history: String, ask: DualAsk,
                    onStage: @escaping @Sendable (DualStage) async -> Void,
                    onDraft: @escaping @Sendable (String) async -> Void) async throws -> (answer: String, verdict: String)
}
```
Prompt contract (exact markers): judge reply first line `BETTER: claude` or `BETTER: codex`, then `CLAUDE HAS:` section and `CODEX HAS:` section listing what each answer has that the other lacks. Review reply is exactly `APPROVED` or `REVISED:` followed by the full corrected answer. Draft prompt: start from the better answer and fold in every point listed for the other one; output only the final answer, brief, same style rules as `Assistant.system`. `parseJudgement` is case-insensitive and tolerates leading whitespace/markdown bold.
Verdict copy: agree → `"Both preferred Claude's answer; Codex's points folded in."`; split → `"Split vote; Claude merged both."`; append `" Reviewed by Codex."` or `" Revised by Codex."`. One answer only → `"Only Claude answered."`.

`run` flow: stage `.answering`; both answers concurrently (`async let`), streaming nothing. One fails → return the other with verdict `"Codex couldn't answer — showing Claude's."` (names per side); both fail → rethrow the first error. Stage `.judging`; both judge concurrently; a failed judge = no vote. Stage `.drafting(by: writer)`; stream draft through `onDraft` (cumulative text). Stage `.reviewing(by: other)`; review failure keeps the draft; `REVISED:` → `onDraft(revised)` and use it. `Task.checkCancellation()` between stages.

- [ ] **Step 1: Failing tests** with a fake `ask` that returns scripted replies per (backend, stage-keyword in prompt):
  `testParseJudgementVariants` (`"BETTER: Codex"`, `"**better: claude**"`, garbage → `nil`), `testWriterAgreementAndTie`, `testParseReviewApprovedAndRevised`, `testHappyPathRunsFourStagesInOrder` (records stages: `[.answering, .judging, .drafting(by: .claude), .reviewing(by: .codex)]`, returns draft), `testRevisionReplacesDraft`, `testAnswerFailureFallsBackToOther`, `testBothFailThrows`, `testUnparseableVerdictIsNoVote`, `testReviewFailureKeepsDraft`, `testCancellationPropagates`, `testDraftPromptContainsBothAnswersAndStrengths`, `testHistoryTextIncludedInAnswerPrompt`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement `DualJudge.swift`.**
- [ ] **Step 4: Run all tests, expect PASS.**
- [ ] **Step 5: Commit** `feat(dual): judge/draft/review orchestration with tests`.

### Task 3: Wire into `Assistant`

**Files:**
- Modify: `NotchApp/Assistant.swift` (`Turn`, `send`, `finish`, `reset`, persistence mapping)
- Modify: `NotchApp/ConversationStore.swift` (`SavedTurn.verdict: String?`, optional so old files decode)
- Test: `NotchAppTests/ConversationStoreTests.swift`

**Interfaces:**
- Consumes: `DualJudge.run`, `DualStage`, `AgentRunner.run(_:session:)`.
- Produces: `Assistant.dualStage: DualStage?` (observable), `Turn.verdict: String?`.

- [ ] **Step 1: Failing test** `testOldSavedTurnWithoutVerdictDecodes` and round-trip with verdict.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** In `send`, `b == .both` branch: `history = DualJudge.historyText(turns.dropLast(2))`, `ask` = run `AgentRunner.run(Route(backend:, work:false, prompt:), session: nil)` collecting `.text`/`.final` (as `runAgent` does), throwing on `.error`, mapping `AgentRunner.Missing` to the existing message. `onStage` sets `dualStage`, `waiting = true` for answering/judging, `toolNote = nil`. `onDraft` sets `waiting=false; streaming=true` and replaces last turn text. On return, set final text and `turns[last].verdict`. `finish()` and `reset()` set `dualStage = nil`. `.both` never writes `sessions`.
- [ ] **Step 4: Build + all tests PASS.**
- [ ] **Step 5: Commit** `feat(dual): run Both from the notch`.

### Task 4: UI and motion

Invoke `frontend-design` and `motion-design` skills first. Match the existing look: `Ink` palette, `EmberSweep`, SF system font sizes 11–13, dark notch surface. Nothing loud; motion short and springy; respect `accessibilityReduceMotion` (fall back to opacity fades).

**Files:**
- Modify: `NotchApp/ModelMark.swift` (`.both`: Claude and Codex marks overlapping, offset ~30%; when active they drift apart slightly)
- Create: `NotchApp/DualStageView.swift` (app target only)
- Modify: `NotchApp/NotchView.swift:117-130` (`statusText`), transcript area for the stage track and verdict line

**Interfaces:**
- Consumes: `Assistant.dualStage`, `Turn.verdict`, `ModelMark`.

- [ ] **Step 1:** `statusText` while `backend == .both && busy`: `both · answering`, `both · judging`, `both · drafting (Claude)`, `both · reviewing (Codex)`.
- [ ] **Step 2:** `DualStageView(stage:)`: four labelled pips Answering · Judging · Drafting · Reviewing above the answer while dual runs; done pips filled ember, current one pulses; during answering both marks pulse alternately, during judging they face each other (slight rotation/offset swap), drafting/reviewing highlights the acting model's mark with a glow; matched-geometry slide between pips.
- [ ] **Step 3:** Verdict line under a finished dual answer: small `Ink.dim` text with the winner's mark, fades + slides up in.
- [ ] **Step 4:** Build, run all tests, launch app (`run` skill) and screenshot each stage with a fake run if possible (`NOTCH_CLIS` override exists for demos).
- [ ] **Step 5: Commit** `feat(dual): stage track, Both mark, verdict line`.

### Task 5: Docs + final verification
- [ ] README model-dial section and `CHANGELOG.md` "Unreleased": one entry for Dual judgement (`@both`, Tab to "Both").
- [ ] Full test suite + Release build pass; whole-branch review; commit `docs(dual): README and changelog`.
