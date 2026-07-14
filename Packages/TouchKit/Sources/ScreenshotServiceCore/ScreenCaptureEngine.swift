import CoreGraphics
import Foundation
import ScreenshotFeature
@preconcurrency import ScreenCaptureKit

public struct ScreenCaptureContentSnapshot: Equatable, Sendable {
    public let displays: [ScreenshotDisplayDescriptor]
    public let windows: [ScreenshotWindowDescriptor]

    public init(
        displays: [ScreenshotDisplayDescriptor],
        windows: [ScreenshotWindowDescriptor]
    ) {
        self.displays = displays
        self.windows = windows
    }
}

public enum ScreenCaptureFilterPlan: Equatable, Sendable {
    case display(displayID: UInt32)
    case desktopIndependentWindow(windowID: UInt32)
}

public struct ScreenCapturePlan: Equatable, Sendable {
    public let filter: ScreenCaptureFilterPlan
    public let sourceRect: ScreenshotRect?
    public let pixelSize: ScreenshotSize
    public let excludedApplicationBundleIdentifiers: [String]
    public let excludedWindowIDs: [UInt32]
    public let ignoresWindowShadow: Bool

    public init(
        filter: ScreenCaptureFilterPlan,
        sourceRect: ScreenshotRect?,
        pixelSize: ScreenshotSize,
        excludedApplicationBundleIdentifiers: [String],
        excludedWindowIDs: [UInt32],
        ignoresWindowShadow: Bool
    ) {
        self.filter = filter
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.excludedApplicationBundleIdentifiers = excludedApplicationBundleIdentifiers
        self.excludedWindowIDs = excludedWindowIDs
        self.ignoresWindowShadow = ignoresWindowShadow
    }
}

public struct CapturedScreenImage: @unchecked Sendable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }
}

public protocol ScreenCaptureBackend: Sendable {
    func availableContent() async throws -> ScreenCaptureContentSnapshot
    func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreenImage
}

public struct ScreenshotCaptureExclusions: Equatable, Sendable {
    public var applicationBundleIdentifiers: Set<String>
    public var serviceBundleIdentifiers: Set<String>
    public var thumbnailWindowIDs: Set<UInt32>
    public var editorWindowIDs: Set<UInt32>
    public var pinnedWindowIDs: Set<UInt32>

    public init(
        applicationBundleIdentifiers: Set<String> = [],
        serviceBundleIdentifiers: Set<String> = [],
        thumbnailWindowIDs: Set<UInt32> = [],
        editorWindowIDs: Set<UInt32> = [],
        pinnedWindowIDs: Set<UInt32> = []
    ) {
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        self.serviceBundleIdentifiers = serviceBundleIdentifiers
        self.thumbnailWindowIDs = thumbnailWindowIDs
        self.editorWindowIDs = editorWindowIDs
        self.pinnedWindowIDs = pinnedWindowIDs
    }

    public static let touchDefaults = ScreenshotCaptureExclusions(
        applicationBundleIdentifiers: ["me.touch.launcher"],
        serviceBundleIdentifiers: ["me.touch.launcher.ScreenshotService"]
    )

    public var allBundleIdentifiers: [String] {
        applicationBundleIdentifiers.union(serviceBundleIdentifiers).sorted()
    }

    public var allWindowIDs: [UInt32] {
        thumbnailWindowIDs.union(editorWindowIDs).union(pinnedWindowIDs).sorted()
    }
}

public protocol ScreenshotArtifactRecording: Sendable {
    func record(_ artifact: ScreenshotArtifact) async throws
}

public struct NullScreenshotArtifactRecorder: ScreenshotArtifactRecording {
    public init() {}
    public func record(_ artifact: ScreenshotArtifact) async throws {}
}

public actor ScreenCaptureEngine {
    private struct CaptureOutput {
        let image: CGImage
        let pointSize: ScreenshotSize
        let displays: [ScreenshotDisplayDescriptor]
    }

    private let backend: any ScreenCaptureBackend
    private let fileStore: ScreenshotFileStore
    private let exclusions: ScreenshotCaptureExclusions
    private let artifactRecorder: any ScreenshotArtifactRecording
    private let annotationRenderer: AnnotationRenderer

    public init(
        backend: any ScreenCaptureBackend = LiveScreenCaptureBackend(),
        fileStore: ScreenshotFileStore,
        exclusions: ScreenshotCaptureExclusions = .touchDefaults,
        artifactRecorder: any ScreenshotArtifactRecording = NullScreenshotArtifactRecorder(),
        annotationRenderer: AnnotationRenderer = AnnotationRenderer()
    ) {
        self.backend = backend
        self.fileStore = fileStore
        self.exclusions = exclusions
        self.artifactRecorder = artifactRecorder
        self.annotationRenderer = annotationRenderer
    }

    public func capture(_ request: ScreenshotCaptureRequest) async throws -> ScreenshotArtifact {
        if request.delay.rawValue > 0 {
            try await Task.sleep(for: .seconds(request.delay.rawValue))
        }
        try Task.checkCancellation()

        let content = try await backend.availableContent()
        let output: CaptureOutput
        switch request.target {
        case .interactive:
            throw ScreenshotFeatureError.targetUnavailable
        case let .region(displayID, rect):
            output = try await captureRegion(rect, displayID: displayID, content: content)
        case let .window(windowID):
            output = try await captureWindow(
                windowID,
                shadow: request.windowShadow,
                content: content
            )
        case let .display(displayID):
            output = try await captureDisplay(displayID, content: content)
        case let .allDisplays(displayIDs):
            output = try await captureAllDisplays(displayIDs, content: content)
        }

        try Task.checkCancellation()
        let renderedImage = try annotationRenderer.render(
            image: output.image,
            pointSize: output.pointSize,
            annotations: request.annotations
        )
        let artifact = try await fileStore.store(
            image: renderedImage,
            request: request,
            pointSize: annotationRenderer.outputPointSize(
                source: output.pointSize,
                annotations: request.annotations
            ),
            displays: output.displays
        )
        try Task.checkCancellation()
        try await artifactRecorder.record(artifact)
        return artifact
    }

    public func availableSelectionContent() async throws -> ScreenshotSelectionContent {
        let content = try await backend.availableContent()
        return ScreenshotSelectionContent(
            displays: content.displays,
            windows: content.windows
        )
    }

    /// 通过 ScreenCaptureKit 后端采集鼠标附近的小块物理像素，并统一转换为标准 sRGB RGBA8。
    /// 该路径只返回内存数据，不会创建截图文件或历史记录。
    public func sampleColor(
        _ request: ScreenshotColorSampleRequest
    ) async throws -> ScreenshotColorSample {
        try Task.checkCancellation()
        let content = try await backend.availableContent()
        let display = try requireDisplay(request.displayID, in: content)
        let geometry = try colorSampleGeometry(for: request, on: display)
        let captured = try await backend.capture(displayPlan(
            for: display,
            sourceRect: geometry.sourceRect,
            pixelSize: geometry.pixelSize
        ))
        try Task.checkCancellation()

        let width = Int(geometry.pixelSize.width)
        let height = Int(geometry.pixelSize.height)
        let rgba = try standardSRGBBytes(from: captured.image, width: width, height: height)
        let centerX = Int(geometry.centerPixel.x)
        let centerY = Int(geometry.centerPixel.y)
        let offset = ((centerY * width) + centerX) * 4
        guard offset >= 0, offset + 3 < rgba.count else {
            throw ScreenshotFeatureError.encodingFailed
        }

        return ScreenshotColorSample(
            color: .init(
                red: rgba[offset],
                green: rgba[offset + 1],
                blue: rgba[offset + 2],
                alpha: rgba[offset + 3]
            ),
            loupeRGBA: Data(rgba),
            loupePixelSize: geometry.pixelSize,
            centerPixel: geometry.centerPixel
        )
    }

    private func captureRegion(
        _ rect: ScreenshotRect,
        displayID: UInt32,
        content: ScreenCaptureContentSnapshot
    ) async throws -> CaptureOutput {
        let display = try requireDisplay(displayID, in: content)
        let geometry = try DisplayGeometry.captureGeometry(for: rect, on: display)
        let plan = displayPlan(
            for: display,
            sourceRect: geometry.sourceRect,
            pixelSize: geometry.pixelSize
        )
        let captured = try await backend.capture(plan)
        return CaptureOutput(
            image: captured.image,
            pointSize: .init(width: geometry.globalRect.width, height: geometry.globalRect.height),
            displays: [display]
        )
    }

    private func captureWindow(
        _ windowID: UInt32,
        shadow: ScreenshotWindowShadow,
        content: ScreenCaptureContentSnapshot
    ) async throws -> CaptureOutput {
        guard !exclusions.allWindowIDs.contains(windowID),
              let window = content.windows.first(where: { $0.id == windowID && $0.isOnScreen }),
              !(window.ownerBundleIdentifier.map(exclusions.allBundleIdentifiers.contains) ?? false) else {
            throw ScreenshotFeatureError.targetUnavailable
        }
        let scale = content.displays
            .filter { intersects($0.frame, window.frame) }
            .map(\.scaleFactor)
            .max() ?? 1
        let plan = ScreenCapturePlan(
            filter: .desktopIndependentWindow(windowID: windowID),
            sourceRect: nil,
            pixelSize: .init(
                width: ceil(window.frame.width * scale),
                height: ceil(window.frame.height * scale)
            ),
            excludedApplicationBundleIdentifiers: exclusions.allBundleIdentifiers,
            excludedWindowIDs: exclusions.allWindowIDs,
            ignoresWindowShadow: shadow == .excluded
        )
        let captured = try await backend.capture(plan)
        return CaptureOutput(
            image: captured.image,
            pointSize: .init(width: window.frame.width, height: window.frame.height),
            displays: content.displays.filter { intersects($0.frame, window.frame) }
        )
    }

    private func captureDisplay(
        _ displayID: UInt32,
        content: ScreenCaptureContentSnapshot
    ) async throws -> CaptureOutput {
        let display = try requireDisplay(displayID, in: content)
        let plan = displayPlan(
            for: display,
            sourceRect: .init(x: 0, y: 0, width: display.frame.width, height: display.frame.height),
            pixelSize: display.pixelSize
        )
        let captured = try await backend.capture(plan)
        return CaptureOutput(
            image: captured.image,
            pointSize: .init(width: display.frame.width, height: display.frame.height),
            displays: [display]
        )
    }

    private func captureAllDisplays(
        _ requestedIDs: [UInt32],
        content: ScreenCaptureContentSnapshot
    ) async throws -> CaptureOutput {
        let ids = requestedIDs.isEmpty ? content.displays.map(\.id) : requestedIDs
        guard !ids.isEmpty else { throw ScreenshotFeatureError.noDisplayAvailable }
        let uniqueIDs = ids.reduce(into: [UInt32]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let displays = try uniqueIDs.map { try requireDisplay($0, in: content) }
        let layout = try DisplayGeometry.compositeLayout(for: displays)
        var images: [UInt32: CGImage] = [:]
        for display in displays {
            try Task.checkCancellation()
            let captured = try await backend.capture(displayPlan(
                for: display,
                sourceRect: .init(x: 0, y: 0, width: display.frame.width, height: display.frame.height),
                pixelSize: display.pixelSize
            ))
            images[display.id] = captured.image
        }
        let composite = try compose(images: images, layout: layout)
        return CaptureOutput(
            image: composite,
            pointSize: .init(width: layout.pointBounds.width, height: layout.pointBounds.height),
            displays: displays
        )
    }

    private func requireDisplay(
        _ displayID: UInt32,
        in content: ScreenCaptureContentSnapshot
    ) throws -> ScreenshotDisplayDescriptor {
        guard let display = content.displays.first(where: { $0.id == displayID }) else {
            throw ScreenshotFeatureError.targetUnavailable
        }
        return display
    }

    private struct ColorSampleGeometry {
        let sourceRect: ScreenshotRect
        let pixelSize: ScreenshotSize
        let centerPixel: ScreenshotPoint
    }

    private func colorSampleGeometry(
        for request: ScreenshotColorSampleRequest,
        on display: ScreenshotDisplayDescriptor
    ) throws -> ColorSampleGeometry {
        let scale = display.scaleFactor
        let displayPixelWidth = Int(display.pixelSize.width.rounded(.down))
        let displayPixelHeight = Int(display.pixelSize.height.rounded(.down))
        let localX = request.desktopPoint.x - display.frame.x
        let localY = request.desktopPoint.y - display.frame.y
        guard scale > 0,
              displayPixelWidth > 0,
              displayPixelHeight > 0,
              localX >= 0,
              localY >= 0,
              localX < display.frame.width,
              localY < display.frame.height else {
            throw ScreenshotFeatureError.targetUnavailable
        }

        var diameter = min(31, max(1, request.loupePixelDiameter))
        if diameter.isMultiple(of: 2) {
            diameter = min(31, diameter + 1)
        }
        let width = min(diameter, displayPixelWidth)
        let height = min(diameter, displayPixelHeight)
        let targetX = min(displayPixelWidth - 1, max(0, Int(floor(localX * scale))))
        let targetY = min(displayPixelHeight - 1, max(0, Int(floor(localY * scale))))
        let originX = min(max(0, targetX - width / 2), displayPixelWidth - width)
        let originY = min(max(0, targetY - height / 2), displayPixelHeight - height)

        return ColorSampleGeometry(
            sourceRect: .init(
                x: Double(originX) / scale,
                y: Double(originY) / scale,
                width: Double(width) / scale,
                height: Double(height) / scale
            ),
            pixelSize: .init(width: Double(width), height: Double(height)),
            centerPixel: .init(
                x: Double(targetX - originX),
                y: Double(targetY - originY)
            )
        )
    }

    private func standardSRGBBytes(
        from image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ScreenshotFeatureError.encodingFailed
        }

        // 将返回数据定义为左上原点，便于主应用按行绘制像素放大镜。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private func displayPlan(
        for display: ScreenshotDisplayDescriptor,
        sourceRect: ScreenshotRect,
        pixelSize: ScreenshotSize
    ) -> ScreenCapturePlan {
        ScreenCapturePlan(
            filter: .display(displayID: display.id),
            sourceRect: sourceRect,
            pixelSize: pixelSize,
            excludedApplicationBundleIdentifiers: exclusions.allBundleIdentifiers,
            excludedWindowIDs: exclusions.allWindowIDs,
            ignoresWindowShadow: true
        )
    }

    private func compose(
        images: [UInt32: CGImage],
        layout: CompositeDisplayLayout
    ) throws -> CGImage {
        let width = Int(layout.pixelSize.width)
        let height = Int(layout.pixelSize.height)
        guard width > 0,
              height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotFeatureError.encodingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for placement in layout.placements {
            guard let image = images[placement.display.id] else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let rect = placement.destinationRect
            context.draw(
                image,
                in: CGRect(
                    x: rect.x,
                    y: CGFloat(height) - rect.y - rect.height,
                    width: rect.width,
                    height: rect.height
                )
            )
        }
        guard let result = context.makeImage() else {
            throw ScreenshotFeatureError.encodingFailed
        }
        return result
    }

    private func intersects(_ lhs: ScreenshotRect, _ rhs: ScreenshotRect) -> Bool {
        max(lhs.x, rhs.x) < min(lhs.x + lhs.width, rhs.x + rhs.width)
            && max(lhs.y, rhs.y) < min(lhs.y + lhs.height, rhs.y + rhs.height)
    }
}

public actor LiveScreenCaptureBackend: ScreenCaptureBackend {
    public init() {}

    public func availableContent() async throws -> ScreenCaptureContentSnapshot {
        let content = try await shareableContent()
        return snapshot(from: content)
    }

    public func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreenImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotFeatureError.permissionDenied
        }
        let content = try await shareableContent()
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.width = max(1, Int(plan.pixelSize.width.rounded(.up)))
        configuration.height = max(1, Int(plan.pixelSize.height.rounded(.up)))

        switch plan.filter {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            let excludedIDs = Set(plan.excludedWindowIDs)
            var excludedBundleIDs = Set(plan.excludedApplicationBundleIdentifiers)
            for window in content.windows where excludedIDs.contains(window.windowID) {
                if let bundleIdentifier = window.owningApplication?.bundleIdentifier {
                    excludedBundleIDs.insert(bundleIdentifier)
                }
            }
            let applications = content.applications.filter {
                excludedBundleIDs.contains($0.bundleIdentifier)
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: applications,
                exceptingWindows: []
            )
            if let source = plan.sourceRect {
                configuration.sourceRect = CGRect(
                    x: source.x,
                    y: source.y,
                    width: source.width,
                    height: source.height
                )
            }
            configuration.ignoreShadowsDisplay = true
        case let .desktopIndependentWindow(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID && $0.isOnScreen }) else {
                throw ScreenshotFeatureError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = plan.ignoresWindowShadow
            configuration.width = max(1, Int(ceil(filter.contentRect.width * CGFloat(filter.pointPixelScale))))
            configuration.height = max(1, Int(ceil(filter.contentRect.height * CGFloat(filter.pointPixelScale))))
        }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            try Task.checkCancellation()
            return CapturedScreenImage(image: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if try await targetStillExists(for: plan) == false {
                throw ScreenshotFeatureError.targetUnavailable
            }
            throw ScreenshotFeatureError.serviceFailed(message: String(describing: error))
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw ScreenshotFeatureError.permissionDenied
            }
            throw ScreenshotFeatureError.serviceFailed(message: String(describing: error))
        }
    }

    private func targetStillExists(for plan: ScreenCapturePlan) async throws -> Bool {
        let content = try await shareableContent()
        switch plan.filter {
        case let .display(displayID):
            return content.displays.contains { $0.displayID == displayID }
        case let .desktopIndependentWindow(windowID):
            return content.windows.contains { $0.windowID == windowID && $0.isOnScreen }
        }
    }

    private func snapshot(from content: SCShareableContent) -> ScreenCaptureContentSnapshot {
        let frames = content.displays.map(\.frame)
        let virtualMinX = frames.map(\.minX).min() ?? 0
        let virtualMaxY = frames.map(\.maxY).max() ?? 0
        let displays = content.displays.map { display in
            let scale = display.width > 0
                ? Double(CGDisplayPixelsWide(display.displayID)) / Double(display.width)
                : 1
            return ScreenshotDisplayDescriptor(
                id: display.displayID,
                frame: .init(
                    x: display.frame.minX - virtualMinX,
                    y: virtualMaxY - display.frame.maxY,
                    width: display.frame.width,
                    height: display.frame.height
                ),
                pixelSize: .init(
                    width: Double(display.width) * scale,
                    height: Double(display.height) * scale
                ),
                scaleFactor: scale
            )
        }
        let windows = content.windows.map { window in
            ScreenshotWindowDescriptor(
                id: window.windowID,
                ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                title: window.title,
                frame: .init(
                    x: window.frame.minX - virtualMinX,
                    y: virtualMaxY - window.frame.maxY,
                    width: window.frame.width,
                    height: window.frame.height
                ),
                isOnScreen: window.isOnScreen
            )
        }
        return ScreenCaptureContentSnapshot(displays: displays, windows: windows)
    }
}
