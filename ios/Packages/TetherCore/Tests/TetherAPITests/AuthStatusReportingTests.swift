import XCTest
@testable import TetherAPI

final class AuthStatusReportingTests: XCTestCase {
    /// Returns the given readings in order (last one repeats).
    private func reader(_ values: [AuthorizationStatusValue]) -> () -> AuthorizationStatusValue {
        var i = 0
        return { defer { i += 1 }; return values[min(i, values.count - 1)] }
    }

    private func resolve(_ reads: [AuthorizationStatusValue], last: AuthorizationStatusValue?, ext: Bool) async -> AuthorizationStatusValue {
        await AuthStatusReporting.resolve(read: reader(reads), lastRecorded: last, isExtension: ext, attempts: 3, wait: {})
    }

    func testDefiniteReadsAreReportedImmediately() async {
        let r1 = await resolve([.approved], last: .denied, ext: false)
        XCTAssertEqual(r1, .approved)
        let r2 = await resolve([.denied], last: .approved, ext: true)   // a real tamper signal is never masked
        XCTAssertEqual(r2, .denied)
    }

    func testNothingRecordedReportsNotDetermined() async {
        let r1 = await resolve([.notDetermined], last: nil, ext: true)
        XCTAssertEqual(r1, .notDetermined)
        let r2 = await resolve([.notDetermined], last: .notDetermined, ext: false)
        XCTAssertEqual(r2, .notDetermined)
    }

    func testExtensionReportsAppsRecordedStatus() async {
        let r = await resolve([.notDetermined], last: .approved, ext: true)
        XCTAssertEqual(r, .approved)
    }

    func testAppWaitsOutLaunchBlip() async {
        let r = await resolve([.notDetermined, .notDetermined, .approved], last: .approved, ext: false)
        XCTAssertEqual(r, .approved)
    }

    func testAppReportsLastingNotDetermined() async {
        let r = await resolve([.notDetermined], last: .approved, ext: false)
        XCTAssertEqual(r, .notDetermined)
    }
}
