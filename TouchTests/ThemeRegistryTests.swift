import XCTest
import TouchCore
@testable import 触达

final class ThemeRegistryTests: XCTestCase {
    func testDefaultRegistryCoversEveryThemeExactlyOnce() {
        let definitions = ThemeRegistry.shared.allDefinitions

        XCTAssertEqual(definitions.count, TouchTheme.allCases.count)
        XCTAssertEqual(Set(definitions.map(\.id)), Set(TouchTheme.allCases))
    }

    func testDefinitionsKeepThemeSpecificSemanticValuesIsolated() {
        let registry = ThemeRegistry.shared
        let glass = registry.definition(for: .defaultGlass)
        let night = registry.definition(for: .night)
        let graphite = registry.definition(for: .graphite)
        let day = registry.definition(for: .day)

        XCTAssertEqual(glass.panel.tint.opacity, 0.38, accuracy: 0.001)
        XCTAssertEqual(glass.panel.effectOpacity, 0.86, accuracy: 0.001)
        XCTAssertEqual(night.panel.tint.opacity, 0.96, accuracy: 0.001)
        XCTAssertEqual(graphite.panel.tint.opacity, 0.94, accuracy: 0.001)
        XCTAssertEqual(day.panel.tint.opacity, 0.96, accuracy: 0.001)
        XCTAssertNotEqual(glass.accent, night.accent)
        XCTAssertNotEqual(night.accent, graphite.accent)
        XCTAssertNotEqual(night.accent, day.accent)
    }

    func testDefaultGlassFeatureIconMatchesSelectedSearchModeColor() {
        let glass = ThemeRegistry.shared.definition(for: .defaultGlass)

        XCTAssertEqual(glass.icon.primary, glass.accent)
    }

    func testLauncherCardsUseSemanticTextTokensInsteadOfHardCodedWhite() throws {
        let source = try sourceFile("TouchApp/Launcher/FeatureCardView.swift")

        XCTAssertFalse(source.contains("Color.white"))
        XCTAssertTrue(source.contains("theme.text.primary.color"))
        XCTAssertTrue(source.contains("theme.shortcut.text.color"))
    }

    func testLauncherGridUsesItsOwnThemedScrollerInsteadOfAppKitTraversal() throws {
        let source = try sourceFile("TouchApp/Launcher/FeatureGridView.swift")

        XCTAssertTrue(source.contains("ScrollView(.vertical, showsIndicators: false)"))
        XCTAssertFalse(source.contains("ThemedScrollIndicatorView"))
        XCTAssertFalse(source.contains("DispatchQueue.main.async"))
    }

    func testHolidayCalendarUsesThemedScrollerWithoutAppKitTraversal() throws {
        let source = try sourceFile("TouchApp/FeatureArea/HolidayCalendarPanelController.swift")

        XCTAssertTrue(source.contains("ScrollView(.vertical, showsIndicators: false)"))
        XCTAssertFalse(source.contains("ThemedScrollIndicatorConfigurator"))
    }

    func testLauncherKeyboardKeysUseSemanticTextTokensInsteadOfHardCodedWhite() throws {
        let source = try sourceFile("TouchApp/Launcher/FeatureGridView.swift")

        XCTAssertFalse(source.contains("foregroundStyle(Color.white.opacity"))
        XCTAssertTrue(source.contains("theme.text.primary.color"))
        XCTAssertTrue(source.contains("theme.shortcut.text.color"))
    }

    func testFinderExtensionDoesNotWriteUserPathsToPublicLogs() throws {
        let source = try sourceFile("Extensions/FinderExtension/FinderSync.swift")

        XCTAssertFalse(source.contains("privacy: .public"))
        XCTAssertFalse(source.contains("NSLog("))
        XCTAssertFalse(source.contains(".path, privacy:"))
    }

    func testFinderExtensionTargetsItsOwnMenuActionsAndDispatchesCutAndPaste() throws {
        let source = try sourceFile("Extensions/FinderExtension/FinderSync.swift")

        XCTAssertTrue(source.contains("item.target = self"))
        XCTAssertTrue(source.contains("#selector(cut(_:))"))
        XCTAssertTrue(source.contains("#selector(pasteMove(_:))"))
        XCTAssertTrue(source.contains("moveClipboardStore.save"))
        XCTAssertTrue(source.contains("actionDispatcher.move"))
    }

    func testFileActionServiceOnlyUsesSupportedTerminalBundleIdentifiers() throws {
        let source = try sourceFile("Services/FileActionService/FileActionServiceEndpoint.swift")

        XCTAssertTrue(source.contains("Self.terminalBundleIdentifiers.contains(preferred)"))
        XCTAssertFalse(source.contains("([preferred] + Self.terminalBundleIdentifiers)"))
    }

    func testXPCServicesValidateTheCallingHostBeforeResumingConnection() throws {
        for path in [
            "Services/FileActionService/FileActionServiceDelegate.swift",
            "Services/ScreenshotService/ScreenshotServiceDelegate.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertTrue(source.contains("TrustedXPCClientValidator.accepts"), path)
            XCTAssertTrue(source.contains("SecCodeCopyGuestWithAttributes"), path)
            XCTAssertTrue(source.contains("SecCodeCheckValidity"), path)
        }
    }

    func testSuperRightSettingsUseCustomToggleInsteadOfSystemSwitch() throws {
        let source = try sourceFile(
            "Packages/TouchKit/Sources/SuperRightFeature/SuperRightSettingsProvider.swift"
        )

        XCTAssertTrue(source.contains("TouchSettingsToggleStyle"))
        XCTAssertFalse(source.contains(".toggleStyle(.switch)"))
    }

    func testAppearanceSettingsUseThemeSliderInsteadOfSystemSlider() throws {
        let source = try sourceFile("TouchApp/Settings/GeneralSettingsView.swift")

        XCTAssertTrue(source.contains("ThemedSlider("))
        XCTAssertFalse(source.contains("\n                        Slider(\n"))
    }

    func testPermissionsCenterOwnsRecoverableSystemIntegrationStates() throws {
        let source = try sourceFile("TouchApp/Settings/GeneralSettingsView.swift")
        let permissionsRange = try XCTUnwrap(source.range(of: "private var permissionsContent"))
        let generalRange = try XCTUnwrap(source.range(of: "private var generalContent"))
        let permissionsSource = String(source[permissionsRange.lowerBound...])
        let generalSource = String(source[generalRange.lowerBound..<permissionsRange.lowerBound])

        XCTAssertTrue(permissionsSource.contains("AXIsProcessTrusted()"))
        XCTAssertTrue(permissionsSource.contains("SMAppService.mainApp.status"))
        XCTAssertTrue(permissionsSource.contains("Privacy_Accessibility"))
        XCTAssertTrue(permissionsSource.contains("Privacy_AllFiles"))
        XCTAssertTrue(permissionsSource.contains("Privacy_Calendars"))
        XCTAssertTrue(permissionsSource.contains("case .notDetermined"))
        XCTAssertTrue(permissionsSource.contains("case .fullAccess"))
        XCTAssertTrue(permissionsSource.contains("case .writeOnly"))
        XCTAssertTrue(permissionsSource.contains("case .denied"))
        XCTAssertTrue(permissionsSource.contains("case .restricted"))
        XCTAssertTrue(permissionsSource.contains("accessibilityPermissionCard"))
        XCTAssertTrue(permissionsSource.contains("fullDiskAccessPermissionCard"))
        XCTAssertTrue(permissionsSource.contains("launchAtLoginPermissionCard"))
        XCTAssertTrue(source.contains("权限页不得在出现或从系统设置返回时调用它"))
        XCTAssertFalse(source.contains("UNUserNotificationCenter.current().getNotificationSettings"))
        XCTAssertTrue(source.contains("launchAtLoginEnabled = status == .enabled"))
        XCTAssertFalse(generalSource.contains("settings.launch-at-login"))
    }

    func testScreenshotInspectorAndExportUseCustomRangeControls() throws {
        for path in [
            "TouchApp/Screenshot/AnnotationInspectorView.swift",
            "TouchApp/Screenshot/AnnotationExportOptions.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertTrue(source.contains("AnnotationRangeControl("), path)
            XCTAssertFalse(source.contains("\n                            Slider("), path)
        }
    }

    func testScreenshotEditorUsesCustomColorAndFormatControls() throws {
        let inspector = try sourceFile("TouchApp/Screenshot/AnnotationInspectorView.swift")
        let exportOptions = try sourceFile("TouchApp/Screenshot/AnnotationExportOptions.swift")

        XCTAssertTrue(inspector.contains("AnnotationColorControl("))
        XCTAssertFalse(inspector.contains("ColorPicker("))
        XCTAssertTrue(exportOptions.contains("AnnotationFormatSelector("))
        XCTAssertFalse(exportOptions.contains("Picker(\"导出格式\""))
    }

    func testAnnotationEditorUsesThemedButtonsInsteadOfSystemButtonStyles() throws {
        let editor = try sourceFile("TouchApp/Screenshot/AnnotationEditorView.swift")
        let canvas = try sourceFile("TouchApp/Screenshot/AnnotationCanvasView.swift")
        let appearance = try sourceFile("TouchApp/Screenshot/AnnotationEditorAppearance.swift")

        for source in [editor, canvas] {
            XCTAssertFalse(source.contains(".buttonStyle(.bordered)"))
            XCTAssertFalse(source.contains(".buttonStyle(.borderedProminent)"))
            XCTAssertFalse(source.contains(".accentColor"))
        }
        XCTAssertTrue(editor.contains(".annotationEditorTool(appearance: appearance"))
        XCTAssertTrue(editor.contains(".annotationEditorSecondaryAction(appearance: appearance)"))
        XCTAssertTrue(editor.contains(".annotationEditorPrimaryAction(appearance: appearance)"))
        XCTAssertTrue(canvas.contains(".annotationEditorSecondaryAction(appearance: appearance)"))
        XCTAssertTrue(canvas.contains(".annotationEditorPrimaryAction(appearance: appearance)"))
        XCTAssertTrue(appearance.contains("toolSelectedFill"))
        XCTAssertTrue(appearance.contains("toolText"))
        XCTAssertTrue(appearance.contains("primaryActionFill"))
    }

    func testDailyTaskQuickAddUsesCustomTimeSelectorInsteadOfSystemDatePicker() throws {
        let source = try sourceFile(
            "Packages/TouchKit/Sources/DailyTaskFeature/DailyTaskFeaturePlugin.swift"
        )

        XCTAssertTrue(source.contains("draftStartTimeSelector"))
        XCTAssertFalse(source.contains("DatePicker(\"开始时间\""))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
