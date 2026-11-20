import XCTest

final class ScreenMarksTests: XCTestCase {
    let size = CGSize(width: 1000, height: 500)

    func testParsesAnyAttributeOrderAndFloats() {
        let p = ScreenMarks.parse(#"Click <mark h=20.5 w="30" y='10' x="5.25">Wi-Fi</mark> here."#, imageSize: size)
        XCTAssertEqual(p.marks, [.init(rect: CGRect(x: 5.25, y: 10, width: 30, height: 20.5), label: "Wi-Fi")])
        XCTAssertEqual(p.clean, "Click here.")
    }
    func testMalformedTagsAreStrippedWithoutMarks() {
        let p = ScreenMarks.parse(#"a <mark x="1" y="2">no size</mark> b <mark x="1" y="2" w="0" h="5">zero</mark> c </mark> d"#, imageSize: size)
        XCTAssertTrue(p.marks.isEmpty)
        XCTAssertEqual(p.clean, "a b c d")
    }
    func testCapsAtSixButStripsAll() {
        let t = (0..<9).map { #"<mark x="\#($0)" y="0" w="5" h="5">n</mark>"# }.joined(separator: " ")
        let p = ScreenMarks.parse(t, imageSize: size)
        XCTAssertEqual(p.marks.count, 6)
        XCTAssertEqual(p.clean, "")
    }
    func testClampsToImageBoundsAndDropsOutsideOnes() {
        let p = ScreenMarks.parse(#"<mark x="950" y="480" w="100" h="100">a</mark><mark x="2000" y="0" w="5" h="5">b</mark>"#, imageSize: size)
        XCTAssertEqual(p.marks.map(\.rect), [CGRect(x: 950, y: 480, width: 50, height: 20)])
    }
    func testPartialTagAtEndOfStreamIsHidden() {
        for tail in ["<", "<m", "<mark", #"<mark x="1" y="2"#, #"<mark x="1" y="2" w="3" h="4">lab"#, "<MARK x"] {
            XCTAssertEqual(ScreenMarks.parse("See this " + tail, imageSize: size).clean, "See this", tail)
        }
        XCTAssertEqual(ScreenMarks.parse("1 < 2 and x <y", imageSize: size).clean, "1 < 2 and x <y")   // ordinary angle brackets stay
    }
    func testToScreenMapsScaleOriginAndFlip() {
        // 1000x500 px image of a 500x250 pt display at (0,0)
        XCTAssertEqual(ScreenMarks.toScreen(CGRect(x: 100, y: 50, width: 200, height: 100), imageSize: size, screenFrame: CGRect(x: 0, y: 0, width: 500, height: 250)),
                       CGRect(x: 50, y: 250 - 75, width: 100, height: 50))
        // secondary display left of and above the main one: negative-x, non-zero-y origin
        let f = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let r = ScreenMarks.toScreen(CGRect(x: 0, y: 0, width: 100, height: 50), imageSize: CGSize(width: 1920, height: 1080), screenFrame: f)
        XCTAssertEqual(r, CGRect(x: -1920, y: 300 + 1080 - 50, width: 100, height: 50))
    }
    func testPromptNamesTheImageForClaudeOnly() {
        XCTAssertTrue(ScreenMarks.prompt("q", path: "/p/screen.png", size: size, claude: true).contains("/p/screen.png"))
        XCTAssertFalse(ScreenMarks.prompt("q", path: "/p/screen.png", size: size, claude: false).contains("/p/screen.png"))
    }
    func testWantsScreenHitsAndMisses() {
        for q in ["Look at my screen and help", "what's on my screen", "WHAT AM I LOOKING AT", "fix this error on screen", "help with this page", "look at this"] {
            XCTAssertTrue(ScreenMarks.wantsScreen(q), q)
        }
        for q in ["write a screenplay outline", "how do I set screen time limits", "explain monads", "what is a window function"] {
            XCTAssertFalse(ScreenMarks.wantsScreen(q), q)
        }
    }
}
