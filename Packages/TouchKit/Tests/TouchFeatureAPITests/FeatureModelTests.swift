import Foundation
import Testing
@testable import TouchFeatureAPI

@Test func manifestIdentityIsStable() {
    let manifest = FeatureManifest(
        id: "me.touch.finder",
        name: "打开访达",
        summary: "打开 Finder",
        symbolName: "face.smiling",
        defaultOrder: 0,
        defaultShortcut: .init(modifiers: [.command], key: "1")
    )

    #expect(manifest.id == "me.touch.finder")
    #expect(manifest.defaultShortcut.displayValue == "⌘1")
}

@Test func manifestDescribesVersionedPluginBoundary() {
    let manifest = FeatureManifest(
        id: "me.touch.super-right",
        name: "超级右键",
        summary: "扩展 Finder 右键菜单",
        symbolName: "cursorarrow.click.2",
        defaultOrder: 2,
        defaultShortcut: .init(modifiers: [.command], key: "3"),
        pluginVersion: .init(major: 1, minor: 0, patch: 0),
        featureAPIVersion: .init(major: 1),
        minimumHostVersion: .init(major: 1, minor: 0, patch: 0),
        maximumTestedHostVersion: .init(major: 1, minor: 9, patch: 0),
        configurationSchemaVersion: 2,
        capabilities: .init(
            required: [.finderMenu, .fileSystemRead],
            optional: [.fileSystemWrite, .pasteboardWrite, .applicationLaunch]
        ),
        executionMode: .xpcService,
        primaryAction: .openSettings,
        settingsPresentation: .firstPartyProvider
    )

    #expect(manifest.pluginVersion == .init(major: 1, minor: 0, patch: 0))
    #expect(manifest.featureAPIVersion == .init(major: 1))
    #expect(manifest.minimumHostVersion == .init(major: 1, minor: 0, patch: 0))
    #expect(manifest.maximumTestedHostVersion == .init(major: 1, minor: 9, patch: 0))
    #expect(manifest.configurationSchemaVersion == 2)
    #expect(manifest.capabilities.required == [.finderMenu, .fileSystemRead])
    #expect(manifest.capabilities.optional == [.fileSystemWrite, .pasteboardWrite, .applicationLaunch])
    #expect(manifest.executionMode == .xpcService)
    #expect(manifest.primaryAction == .openSettings)
    #expect(manifest.settingsPresentation == .firstPartyProvider)
}

@Test func stateDescribesAvailability() {
    #expect(FeatureState.available.isSelectable)
    #expect(!FeatureState.disabled.isSelectable)
    #expect(!FeatureState.failed(message: "服务异常").isSelectable)
}

@Test func focusSessionCalculatesPomodorosFromDeadlineAndFallsBackToEstimate() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let deadlineRequest = FocusSessionRequest(
        title: "完成方案",
        plannedMinutes: 10,
        deadline: now.addingTimeInterval(61 * 60)
    )
    #expect(deadlineRequest.requiredPomodoroCount(referenceDate: now) == 3)

    let estimatedRequest = FocusSessionRequest(title: "整理资料", plannedMinutes: 45)
    #expect(estimatedRequest.requiredPomodoroCount(referenceDate: now) == 2)

    let overdueRequest = FocusSessionRequest(
        title: "补交任务",
        plannedMinutes: 25,
        deadline: now.addingTimeInterval(-60)
    )
    #expect(overdueRequest.requiredPomodoroCount(referenceDate: now) == 1)
}
