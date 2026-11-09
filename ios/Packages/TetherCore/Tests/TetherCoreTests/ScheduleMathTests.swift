import XCTest
@testable import TetherCore

final class ScheduleMathTests: XCTestCase {
    func testParseMinutes() {
        XCTAssertEqual(ScheduleMath.parseMinutes("00:00"), 0)
        XCTAssertEqual(ScheduleMath.parseMinutes("08:30"), 510)
        XCTAssertEqual(ScheduleMath.parseMinutes("8:30"), 510)
        XCTAssertEqual(ScheduleMath.parseMinutes("23:59"), 1439)
        XCTAssertEqual(ScheduleMath.parseMinutes("24:00"), 1440)
        for bad in ["24:01", "25:00", "12:60", "12", "ab:cd", "", "12:5", "-1:00", "+8:00", "12:00:00"] {
            XCTAssertNil(ScheduleMath.parseMinutes(bad), bad)
        }
    }

    func testIsoWeekdayAndDayString() {
        // 2026-11-09 is a Monday.
        XCTAssertEqual(ScheduleMath.isoWeekday(of: T.d("2026-11-09T12:00:00Z"), in: T.utc), 1)
        XCTAssertEqual(ScheduleMath.isoWeekday(of: T.d("2026-11-15T12:00:00Z"), in: T.utc), 7)
        XCTAssertEqual(ScheduleMath.isoWeekday(of: T.d("2026-11-14T12:00:00Z"), in: T.utc), 6)
        // Timezone shifts the local day: 07:30Z Monday is 23:30 Sunday in LA.
        let t = T.d("2026-11-09T07:30:00Z")
        XCTAssertEqual(ScheduleMath.isoWeekday(of: t, in: T.la), 7)
        XCTAssertEqual(ScheduleMath.dayString(t, in: T.la), "2026-11-08")
        XCTAssertEqual(ScheduleMath.dayString(t, in: T.utc), "2026-11-09")
    }

    func testSimpleWindowHalfOpen() {
        let w = Window(days: [1], start: "08:00", end: "15:00")
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T07:59:59Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-09T08:00:00Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-09T14:59:59Z"), in: T.utc))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T15:00:00Z"), in: T.utc))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-10T09:00:00Z"), in: T.utc), "Tuesday not in days")
    }

    func testOvernightWindowUsesStartDay() {
        // Friday 22:00 -> Saturday 06:00; days = [5] (start day).
        let w = Window(days: [5], start: "22:00", end: "06:00")
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-13T21:59:00Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-13T22:00:00Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-13T23:59:59Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-14T00:00:00Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-14T05:59:59Z"), in: T.utc))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-14T06:00:00Z"), in: T.utc))
        // Saturday evening is NOT active (Saturday is not a start day), nor Friday early morning.
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-14T23:00:00Z"), in: T.utc))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-13T03:00:00Z"), in: T.utc))
    }

    func testOvernightSundayWrapsToMonday() {
        let w = Window(days: [7], start: "23:00", end: "07:00")
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-09T06:59:00Z"), in: T.utc), "Monday morning tail of Sunday window")
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T07:00:00Z"), in: T.utc))
    }

    func testEndOf2400() {
        let w = Window(days: [1], start: "18:00", end: "24:00")
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-09T23:59:59Z"), in: T.utc))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-10T00:00:00Z"), in: T.utc), "no spill into Tuesday")
        let occ = ScheduleMath.occurrences(of: w, from: T.d("2026-11-09T00:00:00Z"), to: T.d("2026-11-10T12:00:00Z"), in: T.utc)
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0].end, T.d("2026-11-10T00:00:00Z"))
    }

    func testStartEqualsEndNeverActive() {
        let w = Window(days: [1, 2, 3, 4, 5, 6, 7], start: "09:00", end: "09:00")
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T09:00:00Z"), in: T.utc))
        XCTAssertTrue(ScheduleMath.occurrences(of: w, from: T.d("2026-11-09T00:00:00Z"), to: T.d("2026-11-16T00:00:00Z"), in: T.utc).isEmpty)
    }

    func testMalformedWindowNeverActive() {
        let w = Window(days: [1], start: "nope", end: "10:00")
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T09:00:00Z"), in: T.utc))
    }

    func testWindowInTimeZone() {
        let w = Window(days: [1], start: "08:00", end: "15:00")
        // 08:00 PST = 16:00Z.
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-11-09T15:59:00Z"), in: T.la))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-09T16:00:00Z"), in: T.la))
    }

    func testBoundariesOverRange() {
        let w = Window(days: [1, 2, 3, 4, 5], start: "08:00", end: "15:00")
        let b = ScheduleMath.boundaries(of: [w], after: T.d("2026-11-09T00:00:00Z"), through: T.d("2026-11-11T00:00:00Z"), in: T.utc)
        XCTAssertEqual(b, [T.d("2026-11-09T08:00:00Z"), T.d("2026-11-09T15:00:00Z"),
                           T.d("2026-11-10T08:00:00Z"), T.d("2026-11-10T15:00:00Z")])
    }

    func testBoundariesIncludeOvernightTail() {
        let w = Window(days: [5], start: "22:00", end: "06:00")
        let b = ScheduleMath.boundaries(of: [w], after: T.d("2026-11-14T00:00:00Z"), through: T.d("2026-11-15T00:00:00Z"), in: T.utc)
        XCTAssertEqual(b, [T.d("2026-11-14T06:00:00Z")])
    }

    // MARK: DST (America/Los_Angeles: spring forward 2026-03-08, fall back 2026-11-01)

    func testSpringForwardNonexistentStartRoundsForward() {
        // Sunday 2026-03-08, 02:30 does not exist. Gap ends 03:00 PDT = 10:00Z.
        let w = Window(days: [7], start: "02:30", end: "05:00")
        let occ = ScheduleMath.occurrences(of: w, from: T.d("2026-03-08T00:00:00Z"), to: T.d("2026-03-09T00:00:00Z"), in: T.la)
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0].start, T.d("2026-03-08T10:00:00Z"))
        XCTAssertEqual(occ[0].end, T.d("2026-03-08T12:00:00Z"))   // 05:00 PDT
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-03-08T10:00:00Z"), in: T.la))
        XCTAssertFalse(ScheduleMath.isActive(w, at: T.d("2026-03-08T09:59:00Z"), in: T.la))
    }

    func testSpringForwardLaterTimesUseNewOffset() {
        let w = Window(days: [7], start: "08:00", end: "09:00")
        let occ = ScheduleMath.occurrences(of: w, from: T.d("2026-03-08T00:00:00Z"), to: T.d("2026-03-09T00:00:00Z"), in: T.la)
        XCTAssertEqual(occ.first?.start, T.d("2026-03-08T15:00:00Z"), "08:00 PDT")
    }

    func testFallBackAmbiguousStartUsesFirstOccurrence() {
        // Sunday 2026-11-01: 01:30 happens twice. First = 01:30 PDT = 08:30Z.
        let w = Window(days: [7], start: "01:30", end: "03:00")
        let occ = ScheduleMath.occurrences(of: w, from: T.d("2026-11-01T00:00:00Z"), to: T.d("2026-11-02T00:00:00Z"), in: T.la)
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0].start, T.d("2026-11-01T08:30:00Z"))
        XCTAssertEqual(occ[0].end, T.d("2026-11-01T11:00:00Z"))   // 03:00 PST
        // Both passes through 01:30 wall clock are inside the window.
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-01T08:45:00Z"), in: T.la))
        XCTAssertTrue(ScheduleMath.isActive(w, at: T.d("2026-11-01T09:45:00Z"), in: T.la))
    }

    func testFallBackLaterTimeAfterTransition() {
        let w = Window(days: [7], start: "03:00", end: "04:00")
        let occ = ScheduleMath.occurrences(of: w, from: T.d("2026-11-01T00:00:00Z"), to: T.d("2026-11-02T00:00:00Z"), in: T.la)
        XCTAssertEqual(occ.first?.start, T.d("2026-11-01T11:00:00Z"))
    }

    func testMidnightsAcrossDST() {
        let m = ScheduleMath.midnights(after: T.d("2026-10-31T12:00:00Z"), through: T.d("2026-11-03T12:00:00Z"), in: T.la)
        XCTAssertEqual(m, [T.d("2026-11-01T07:00:00Z"), T.d("2026-11-02T08:00:00Z"), T.d("2026-11-03T08:00:00Z")])
    }
}
