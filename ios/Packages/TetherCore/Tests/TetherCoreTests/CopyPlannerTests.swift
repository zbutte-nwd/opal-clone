import XCTest
@testable import TetherCore

final class CopyPlannerTests: XCTestCase {
    let copy = BlockGroup(id: "grp_copy", name: "Socials", source: .server, copiedFrom: "lgrp_socials")
    let plain = BlockGroup(id: "grp_plain", name: "Games", source: .server)

    func testCopiesOnce() {
        XCTAssertEqual(CopyPlanner.copies(bundleGroups: [copy, plain], localGroupIds: ["lgrp_socials"], applied: []),
                       [CopyPlan(from: "lgrp_socials", to: "grp_copy")])
    }

    func testMissingSourceIgnored() {
        XCTAssertEqual(CopyPlanner.copies(bundleGroups: [copy], localGroupIds: [], applied: []), [])
    }

    func testClearedCopyNotRecopied() {
        XCTAssertEqual(CopyPlanner.copies(bundleGroups: [copy], localGroupIds: ["lgrp_socials"], applied: ["grp_copy"]), [])
    }
}
