import AppKit
import Darwin
import CoreGraphics
import CryptoKit
import ImageIO
import ScreenshotFeature
@preconcurrency import ScreenCaptureKit
import XCTest

@MainActor
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

    func testRealXPCCapturesDisplayRegionWindowAndAvailableDisplays() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("当前测试宿主尚未取得屏幕录制权限")
        }
        let exclusionProbe = makeExclusionProbeWindow()
        exclusionProbe.orderFrontRegardless()
        defer { exclusionProbe.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let mainDisplayID = CGMainDisplayID()
        let mainDisplay = try XCTUnwrap(content.displays.first { $0.displayID == mainDisplayID })
        let virtualMinX = content.displays.map(\.frame.minX).min() ?? 0
        let virtualMaxY = content.displays.map(\.frame.maxY).max() ?? 0
        let client = ScreenshotClient()

        let touchWindow = try XCTUnwrap(content.windows.first {
            $0.windowID == CGWindowID(exclusionProbe.windowNumber)
                && $0.owningApplication?.bundleIdentifier == "me.touch.launcher"
        }, "必须枚举到触达自有探针窗口，才能验证捕获排除")
        do {
            _ = try await client.capture(.init(
                mode: .window,
                target: .window(windowID: touchWindow.windowID)
            ), timeout: .seconds(30))
            XCTFail("触达自有窗口不得被 XPC 捕获")
        } catch let error as ScreenshotFeatureError {
            XCTAssertEqual(error, .targetUnavailable)
        }

        let displayArtifact = try await client.capture(.init(
            mode: .fullScreen,
            target: .display(displayID: mainDisplayID)
        ), timeout: .seconds(30))
        try assertStoredImage(displayArtifact)
        XCTAssertEqual(displayArtifact.displays.map(\.id), [mainDisplayID])

        let region = ScreenshotRect(
            x: mainDisplay.frame.minX - virtualMinX,
            y: virtualMaxY - mainDisplay.frame.maxY,
            width: min(96, mainDisplay.frame.width),
            height: min(64, mainDisplay.frame.height)
        )
        let regionArtifact = try await client.capture(.init(
            mode: .region,
            target: .region(displayID: mainDisplayID, rect: region)
        ), timeout: .seconds(30))
        try assertStoredImage(regionArtifact)
        XCTAssertEqual(regionArtifact.pointSize, .init(width: region.width, height: region.height))

        let window = try XCTUnwrap(content.windows.first(where: {
            guard let bundleIdentifier = $0.owningApplication?.bundleIdentifier else {
                return false
            }
            return $0.isOnScreen
                && $0.frame.width >= 100
                && $0.frame.height >= 80
                && $0.title?.isEmpty == false
                && bundleIdentifier != "me.touch.launcher"
                && bundleIdentifier != "me.touch.launcher.ScreenshotService"
        }), "必须有一个可见、具名的第三方窗口，真实窗口捕获不得静默跳过")
        var shadowArtifacts: [String: ScreenshotArtifact] = [:]
        for shadow in [ScreenshotWindowShadow.included, .excluded] {
            let windowArtifact = try await client.capture(.init(
                mode: .window,
                target: .window(windowID: window.windowID),
                windowShadow: shadow
            ), timeout: .seconds(30))
            try assertStoredImage(windowArtifact)
            XCTAssertEqual(windowArtifact.captureMode, .window)
            shadowArtifacts[shadow.rawValue] = windowArtifact
        }
        print(
            "Real XPC window capture owner=\(window.owningApplication?.bundleIdentifier ?? "unknown") "
                + "title=\(window.title ?? "") "
                + "artifacts=\(shadowArtifacts.mapValues(\.relativePath))"
        )

        if let secondaryDisplay = content.displays.first(where: { $0.displayID != mainDisplayID }) {
            let secondaryArtifact = try await client.capture(.init(
                mode: .fullScreen,
                target: .display(displayID: secondaryDisplay.displayID)
            ), timeout: .seconds(30))
            try assertStoredImage(secondaryArtifact)
            XCTAssertEqual(secondaryArtifact.displays.map(\.id), [secondaryDisplay.displayID])
            print(
                "Real XPC secondary display=\(secondaryDisplay.displayID) "
                    + "path=\(secondaryArtifact.relativePath)"
            )
        } else {
            print("当前机器只有一个显示器，真实第二屏捕获未执行")
        }

        let displayIDs = content.displays.map(\.displayID)
        let allDisplaysArtifact = try await client.capture(.init(
            mode: .allDisplays,
            target: .allDisplays(displayIDs: displayIDs)
        ), timeout: .seconds(60))
        try assertStoredImage(allDisplaysArtifact)
        XCTAssertEqual(allDisplaysArtifact.displays.map(\.id), displayIDs)
        print(
            "Real XPC capture displayCount=\(displayIDs.count) "
                + "display=\(displayArtifact.relativePath) "
                + "region=\(regionArtifact.relativePath) "
                + "all=\(allDisplaysArtifact.relativePath)"
        )
    }

    private func makeExclusionProbeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 360, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = NSColor(
            calibratedRed: 17.0 / 255.0,
            green: 231.0 / 255.0,
            blue: 79.0 / 255.0,
            alpha: 1
        )
        let label = NSTextField(labelWithString: "TOUCH EXCLUSION PROBE")
        label.font = .boldSystemFont(ofSize: 24)
        label.textColor = .black
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 70, width: 320, height: 40)
        window.contentView?.addSubview(label)
        return window
    }

    private func assertStoredImage(
        _ artifact: ScreenshotArtifact,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let paths = try ScreenshotFeaturePaths.applicationSupport()
        let url = try paths.resolve(relativePath: artifact.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil),
            file: file,
            line: line
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil),
            file: file,
            line: line
        )
        XCTAssertEqual(Double(image.width), artifact.pixelSize.width, file: file, line: line)
        XCTAssertEqual(Double(image.height), artifact.pixelSize.height, file: file, line: line)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(
            Array(data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "PNG 文件头不匹配",
            file: file,
            line: line
        )
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(artifact.sha256, digest, file: file, line: line)
        XCTAssertEqual(artifact.sha256.count, 64, file: file, line: line)
    }
}
