import XCTest
import SwiftUI

final class SVGPathTests: XCTestCase {
    private func box(_ d: String) -> CGRect { SVGPath.parse(d).cgPath.boundingBoxOfPath }   // the curve itself, not its control points
    private func close(_ a: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, tol: Double = 0.05, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, x, accuracy: tol, file: file, line: line); XCTAssertEqual(a.minY, y, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.width, w, accuracy: tol, file: file, line: line); XCTAssertEqual(a.height, h, accuracy: tol, file: file, line: line)
    }

    func testAbsoluteLinesAndClose() { close(box("M0 0H10V10H0Z"), 0, 0, 10, 10) }
    func testRelativeCommandsAndImplicitLinetoAfterMove() {
        close(box("m1 1 4 0 0 4z"), 1, 1, 4, 4)                       // "m x y x y x y": the extra pairs are relative linetos
        close(box("M2 2l3 0l0 3"), 2, 2, 3, 3)
    }
    func testCompactNumberForms() {
        close(box("M.5.5L5.5.5L5.5 5.5"), 0.5, 0.5, 5, 5)               // ".5.5" is two numbers
        close(box("M1-1L4-1L4 2"), 1, -1, 3, 3)                         // a minus sign separates
        close(box("M0 0L1e1 0L1e1 5E0"), 0, 0, 10, 5)                   // exponents
    }
    func testCubicIsMeasuredOnTheCurveNotTheControlPoints() { close(box("M0 0C0 10 10 10 10 0"), 0, 0, 10, 7.5, tol: 0.1) }
    func testSmoothCubicReflectsTheLastControlPoint() {
        close(box("M0 0C0 4 4 4 4 0S8 -4 8 0"), 0, -3, 8, 6, tol: 0.2)
    }
    func testQuadraticAndSmoothQuadratic() { close(box("M0 0Q5 10 10 0T20 0"), 0, -5, 20, 10, tol: 0.2) }   // T mirrors the control point: a hump, then a dip
    func testSemicircleArc() {
        let b = box("M0 0A5 5 0 0 1 10 0"); XCTAssertEqual(b.width, 10, accuracy: 0.1); XCTAssertEqual(b.height, 5, accuracy: 0.1)
    }
    func testArcFlagsMayBePackedWithoutSeparators() {
        let spaced = box("M0 0a5 5 0 0 1 10 0"), packed = box("M0 0a5 5 0 0110 0")   // flags 0 and 1, then x=10
        XCTAssertEqual(packed.width, spaced.width, accuracy: 0.01); XCTAssertEqual(packed.height, spaced.height, accuracy: 0.01)
    }
    func testArcTooSmallIsScaledUpInsteadOfFailing() { XCTAssertEqual(box("M0 0A1 1 0 0 1 10 0").width, 10, accuracy: 0.1) }
    func testLargeArcFlagChoosesTheLongWay() {
        XCTAssertGreaterThan(box("M0 0A6 6 0 1 1 10 0").height, box("M0 0A6 6 0 0 1 10 0").height)
    }
    func testAfterCloseTheCurrentPointIsTheSubpathStart() {
        let p = SVGPath.parse("M10 10h5zh2"); XCTAssertEqual(p.cgPath.currentPoint.x, 12, accuracy: 0.001); XCTAssertEqual(p.cgPath.currentPoint.y, 10, accuracy: 0.001)
    }
    func testGarbageNeverCrashes() {
        for d in ["", "M", "M0", "L5 5", "Q", "A1 2 3", "zzz", "M0 0L", "not a path", "M0 0 1 2 3"] { _ = SVGPath.parse(d) }
    }

    func testTheOfficialMarksFitTheir24Grid() {
        for (name, d) in [("claude", OfficialMarks.claude), ("codex", OfficialMarks.codex)] {
            let b = box(d)
            XCTAssertFalse(b.isEmpty, name)
            XCTAssertGreaterThan(b.width, 18, name); XCTAssertGreaterThan(b.height, 18, name)             // fills most of the grid
            XCTAssertGreaterThan(b.minX, -0.6, name); XCTAssertLessThan(b.maxX, 24.6, name)
            XCTAssertGreaterThan(b.minY, -0.6, name); XCTAssertLessThan(b.maxY, 24.6, name)
        }
    }
}
