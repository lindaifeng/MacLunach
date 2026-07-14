import ScreenshotFeature
import XCTest
@testable import 触达

final class CaptureCountdownTests: XCTestCase {
    func testSupportedDelaysProduceDescendingVisibleSeconds() {
        XCTAssertEqual(CaptureCountdownTimeline.seconds(for: .none), [])
        XCTAssertEqual(CaptureCountdownTimeline.seconds(for: .threeSeconds), [3, 2, 1])
        XCTAssertEqual(CaptureCountdownTimeline.seconds(for: .fiveSeconds), [5, 4, 3, 2, 1])
        XCTAssertEqual(
            CaptureCountdownTimeline.seconds(for: .tenSeconds),
            [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
        )
    }
}
