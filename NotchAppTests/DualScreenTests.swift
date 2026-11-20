import XCTest

/// Screen help together with the Both backend: who gets the screenshot and the look tool, and where the marks come from.
final class DualScreenTests: XCTestCase {
    let launch = ScreenTool.Launch(exe: "/x/NotchApp", socket: "/tmp/s", token: "T")
    var screen: DualScreen { DualScreen(image: "/scratch/screen.png", size: CGSize(width: 2000, height: 1000), look: launch) }

    func testAnswerRunsGetShotAndToolOnEachModelsTerms() {
        let c = DualJudge.route(.claude, prompt: "Q", isInternal: false, screen: screen)
        let x = DualJudge.route(.codex, prompt: "Q", isInternal: false, screen: screen)
        XCTAssertFalse(c.locked); XCTAssertFalse(x.locked)
        XCTAssertEqual(c.look, launch); XCTAssertEqual(x.look, launch)           // same token: the 3-per-question cap is shared
        XCTAssertEqual(x.image, "/scratch/screen.png")                           // Codex: -i
        XCTAssertTrue(c.prompt.contains("/scratch/screen.png") && c.prompt.contains("Read it first"))   // Claude: reads the file
        XCTAssertTrue(x.prompt.contains("attached as an image"))
        XCTAssertTrue(AgentStream.codexArgs(prompt: x.prompt, session: nil, work: false, image: x.image, look: x.look).contains("-i"))
    }
    func testInternalStagesNeverGetShotOrTool() {
        for b in [Backend.claude, .codex] {
            let r = DualJudge.route(b, prompt: "judge", isInternal: true, screen: screen)
            XCTAssertTrue(r.locked); XCTAssertNil(r.look); XCTAssertNil(r.image); XCTAssertEqual(r.prompt, "judge")
        }
    }
    func testLookOnlyAddsHintAndNoScreenMeansPlainRoute() {
        let r = DualJudge.route(.claude, prompt: "Q", isInternal: false, screen: DualScreen(look: launch))
        XCTAssertTrue(r.prompt.hasSuffix(ScreenTool.hint)); XCTAssertNil(r.image); XCTAssertEqual(r.look, launch)
        XCTAssertEqual(DualJudge.route(.codex, prompt: "Q", isInternal: false, screen: nil), Route(backend: .codex, work: false, prompt: "Q"))
    }
    func testBothIsOfferedTheLookToolButGemmaIsNot() {
        XCTAssertTrue(ScreenTool.offered(.both, setting: true)); XCTAssertFalse(ScreenTool.offered(.both, setting: false))
        XCTAssertFalse(ScreenTool.offered(.gemma, setting: true))
    }
    func testMarksComeFromTheFinalRevisedAnswerOnly() async throws {
        let m1 = #"<mark x="1" y="1" w="5" h="5">draft spot</mark>"#, m2 = #"<mark x="100" y="50" w="20" h="10">final spot</mark>"#
        let ask: DualAsk = { b, p, _, _ in
            if p.contains("You are judging") { return "BETTER: A\nA HAS: x\nB HAS: y" }
            if p.contains("You are writing the final") { XCTAssertTrue(p.contains("<mark")); return "Draft \(m1)" }
            if p.contains("You are reviewing") { return "REVISED:\nFinal \(m2)" }
            return "\(b.rawValue) says \(m1)"        // both answers carry marks; neither should reach the overlay on its own
        }
        let out = try await DualJudge.run(question: "Q", history: "", marks: true, ask: ask, onStage: { _ in }, onDraft: { _ in })
        let p = ScreenMarks.parse(out.answer, imageSize: CGSize(width: 2000, height: 1000), badges: true)
        XCTAssertEqual(p.marks.map(\.label), ["final spot"])           // one overlay, from the revised answer
        XCTAssertEqual(p.clean, "Final ①")                              // badge 1 matches overlay box 1
    }
    func testMarksNoteOnlyWhenScreenIsInvolved() async throws {
        final class Box: @unchecked Sendable { var p: [String] = [] }
        for flag in [true, false] {
            let box = Box()
            let ask: DualAsk = { _, p, i, _ in
                if i { box.p.append(p) }
                if p.contains("You are judging") { return "BETTER: A" }
                if p.contains("You are reviewing") { return "APPROVED" }
                return "a"
            }
            _ = try await DualJudge.run(question: "Q", history: "", marks: flag, ask: ask, onStage: { _ in }, onDraft: { _ in })
            XCTAssertEqual(box.p.filter { $0.contains("point at spots") }.count, flag ? 2 : 0)   // draft + review, never the blind judges
        }
    }
}
