import Foundation
import SwiftUI
import TouchFeatureAPI

public struct OCRFeatureConfiguration: Codable, Equatable, Sendable {
    public var automaticallyCopiesRecognizedText: Bool

    public init(automaticallyCopiesRecognizedText: Bool = true) {
        self.automaticallyCopiesRecognizedText = automaticallyCopiesRecognizedText
    }
}

public struct OCRConfigurationRepository: Sendable {
    public static let schemaVersion = 1

    private let storage: any FeatureStorage

    public init(storage: any FeatureStorage) {
        self.storage = storage
    }

    public func load() throws -> OCRFeatureConfiguration {
        guard let snapshot = try storage.loadConfiguration(),
              snapshot.schemaVersion == Self.schemaVersion,
              let configuration = try? JSONDecoder().decode(
                  OCRFeatureConfiguration.self,
                  from: snapshot.data
              ) else {
            return .init()
        }
        return configuration
    }

    public func save(_ configuration: OCRFeatureConfiguration) throws {
        try storage.saveConfiguration(
            .init(
                schemaVersion: Self.schemaVersion,
                data: try JSONEncoder().encode(configuration)
            )
        )
    }
}

public struct OCRFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.ocr"

    private let storage: (any FeatureStorage)?

    public init(storage: (any FeatureStorage)? = nil) {
        self.storage = storage
    }

    public let manifest = FeatureManifest(
        id: Self.id,
        name: "文字识别",
        summary: "截图识别、校对并继续翻译",
        symbolName: "text.viewfinder",
        defaultOrder: 10,
        defaultShortcut: .init(modifiers: [], key: "-"),
        configurationSchemaVersion: OCRConfigurationRepository.schemaVersion,
        capabilities: .init(required: [.screenCapture, .pasteboardWrite]),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .firstPartyProvider
    )

    @MainActor
    public var settingsProvider: (any FeatureSettingsProvider)? {
        guard let storage else { return nil }
        return OCRSettingsProvider(storage: storage)
    }

    public func initialState() async -> FeatureState { .available }

    public func perform() async throws -> FeatureActionResult {
        .presentPanel(featureID: Self.id)
    }
}

@MainActor
public struct OCRSettingsProvider: FeatureSettingsProvider {
    private let repository: OCRConfigurationRepository

    public init(storage: any FeatureStorage) {
        repository = OCRConfigurationRepository(storage: storage)
    }

    public func makeSettingsView(context _: FeatureSettingsContext) -> AnyView {
        AnyView(OCRSettingsView(repository: repository))
    }
}

private struct OCRSettingsView: View {
    private let repository: OCRConfigurationRepository
    @State private var configuration: OCRFeatureConfiguration

    init(repository: OCRConfigurationRepository) {
        self.repository = repository
        _configuration = State(initialValue: (try? repository.load()) ?? .init())
    }

    var body: some View {
        Button {
            configuration.automaticallyCopiesRecognizedText.toggle()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("识别后自动复制")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("识别完成后，自动将识别文字写入剪贴板。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                OCRSettingsSwitch(
                    isOn: configuration.automaticallyCopiesRecognizedText
                )
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("识别后自动复制")
        .accessibilityValue(
            configuration.automaticallyCopiesRecognizedText ? "已开启" : "已关闭"
        )
        .accessibilityIdentifier("settings.ocr.auto-copy")
        .onChange(of: configuration) { _, configuration in
            try? repository.save(configuration)
        }
    }
}

private struct OCRSettingsSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18))
            .frame(width: 38, height: 22)
            .overlay {
                Circle()
                    .fill(Color.white.opacity(isOn ? 0.96 : 0.82))
                    .frame(width: 16, height: 16)
                    .offset(x: isOn ? 8 : -8)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .animation(.easeOut(duration: 0.16), value: isOn)
    }
}
