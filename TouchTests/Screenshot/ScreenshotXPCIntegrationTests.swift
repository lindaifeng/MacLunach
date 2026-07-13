import Darwin
import ScreenshotFeature
import XCTest

final class ScreenshotXPCIntegrationTests: XCTestCase {
    func testServiceRestartsAfterCrashWithoutTerminatingHostApplication() async throws {
        let client = ScreenshotClient()
        let appPID = ProcessInfo.processInfo.processIdentifier
        let first = try await client.ping(timeout: .seconds(5))
        let health = try await client.healthCheck(timeout: .seconds(5))

        XCTAssertNotEqual(first.processID, appPID)
        XCTAssertEqual(health.processID, first.processID)
        do {
            _ = try await client.perform(
                action: .custom(name: "capture", isIdempotent: false),
                timeout: .seconds(5)
            )
            XCTFail("Task 2 的 XPC 服务不应接受尚未实现的 capture 动作")
        } catch let error as ScreenshotFeatureError {
            XCTAssertEqual(error, .unsupportedAction(action: "capture"))
        }
        XCTAssertEqual(kill(first.processID, SIGKILL), 0)

        let second = try await client.ping(timeout: .seconds(20))
        let appPIDAfterRestart = ProcessInfo.processInfo.processIdentifier

        print(
            "Screenshot XPC recovery appPID=\(appPID) "
                + "firstServicePID=\(first.processID) "
                + "secondServicePID=\(second.processID)"
        )
        XCTAssertEqual(appPIDAfterRestart, appPID)
        XCTAssertNotEqual(second.processID, first.processID)
        XCTAssertNotEqual(second.processID, appPID)
    }
}
