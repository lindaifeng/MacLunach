import XCTest
@testable import TranslationFeature
import TouchFeatureAPI

final class TranslationFeatureTests: XCTestCase {
    func testRequiresMacOS15() async {
        let plugin = TranslationFeaturePlugin(systemVersion: .init(majorVersion: 14, minorVersion: 6, patchVersion: 0))
        let initialState = await plugin.initialState()
        XCTAssertEqual(initialState, .restricted(message: "需要 macOS 15 才能使用系统离线翻译"))
        XCTAssertFalse(plugin.manifest.capabilities.required.contains(.network))
    }

    func testRouterHandsPureTextToTranslationWithoutCapture() async throws {
        let recorder = RequestRecorder()
        let router = TextWorkflowRouter()
        await router.registerTranslationHandler { request in await recorder.record(request) }
        try await router.routeToTranslation(.init(text: "校对文字", source: .ocrWorkspace, recognizedLanguageCode: "zh-Hans"))
        let request = await recorder.value
        XCTAssertEqual(request?.text, "校对文字")
        XCTAssertEqual(request?.source, .ocrWorkspace)
    }

    func testRouterRejectsVersionAndEmptyText() async {
        let router = TextWorkflowRouter()
        do { try await router.routeToTranslation(.init(version: 99, text: "a", source: .external)); XCTFail() }
        catch { XCTAssertEqual(error as? TextWorkflowError, .unsupportedVersion(99)) }
    }

    func testSystemOfflineProviderShortCircuitsOnMacOS14WithoutInvokingSession() async {
        let recorder = TranslationBackendRecorder()
        let provider = AppleOfflineTranslationProvider(
            systemVersion: .init(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        )
        await provider.installSessionTranslator { _, _, _ in
            await recorder.markInvoked()
            return .init(sourceText: "原文", translatedText: "译文")
        }

        do {
            _ = try await provider.translate("原文", sourceLanguageCode: nil, targetLanguageCode: "en")
            XCTFail("macOS 14 不应进入系统翻译会话")
        } catch {
            XCTAssertEqual(error as? TranslationProviderError, .requiresMacOS15)
        }

        let wasInvoked = await recorder.wasInvoked
        XCTAssertFalse(wasInvoked)
    }
}
private actor RequestRecorder { var value: TextTranslationRequest?; func record(_ request: TextTranslationRequest) { value = request } }
private actor TranslationBackendRecorder {
    private(set) var wasInvoked = false
    func markInvoked() { wasInvoked = true }
}
