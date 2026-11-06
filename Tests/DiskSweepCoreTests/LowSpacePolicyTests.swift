import XCTest
@testable import DiskSweepCore

final class LowSpacePolicyTests: XCTestCase {
    func testNotifiesOnceBelowThreshold() {
        let threshold: Int64 = 20_000_000_000
        XCTAssertTrue(LowSpacePolicy.shouldNotify(available: threshold - 1, total: 100_000_000_000,
                                                  thresholdBytes: threshold, armed: true))
        XCTAssertFalse(LowSpacePolicy.shouldNotify(available: threshold - 1, total: 100_000_000_000,
                                                   thresholdBytes: threshold, armed: false))
        XCTAssertFalse(LowSpacePolicy.shouldNotify(available: threshold, total: 100_000_000_000,
                                                   thresholdBytes: threshold, armed: true))
    }

    func testRearmsOnlyBeyondHysteresis() {
        let threshold: Int64 = 20_000_000_000
        XCTAssertFalse(LowSpacePolicy.shouldRearm(available: 21_999_999_999, total: 100_000_000_000,
                                                  thresholdBytes: threshold))
        XCTAssertTrue(LowSpacePolicy.shouldRearm(available: 22_000_000_000, total: 100_000_000_000,
                                                 thresholdBytes: threshold))
    }

    func testInvalidReadingsDoNotNotifyOrRearm() {
        XCTAssertFalse(LowSpacePolicy.shouldNotify(available: 0, total: 0, thresholdBytes: 20, armed: true))
        XCTAssertFalse(LowSpacePolicy.shouldRearm(available: 100, total: 0, thresholdBytes: 20))
    }
}
