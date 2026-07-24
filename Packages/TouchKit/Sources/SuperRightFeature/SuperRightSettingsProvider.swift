import AppKit
import SwiftUI
import TouchFeatureAPI

@MainActor
public struct SuperRightSettingsProvider: FeatureSettingsProvider {
    private let repository: SuperRightConfigurationRepository

    public init(storage: any FeatureStorage) {
        repository = SuperRightConfigurationRepository(storage: storage)
    }

    public func makeSettingsView(context _: FeatureSettingsContext) -> AnyView {
        AnyView(
            SuperRightSettingsView(
                repository: repository
            )
        )
    }
}

private struct SuperRightSettingsView: View {
    private let repository: SuperRightConfigurationRepository
    private let snapshotStore: SuperRightConfigurationSnapshotStore
    @State private var configuration: SuperRightFeatureConfiguration

    init(
        repository: SuperRightConfigurationRepository,
        snapshotStore: SuperRightConfigurationSnapshotStore = .init()
    ) {
        self.repository = repository
        self.snapshotStore = snapshotStore
        let initialConfiguration = (try? repository.load()) ?? .init()
        _configuration = State(initialValue: initialConfiguration)
        try? snapshotStore.save(initialConfiguration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionSection
            terminalSection
            fileFormatSection
        }
        .onChange(of: configuration) { _, configuration in
            persist(configuration)
        }
        .onAppear {
            persist(configuration)
        }
    }

    private var actionSection: some View {
        settingsSection(
            title: "Finder 菜单动作",
            subtitle: "关闭后，对应入口会在下一次打开右键菜单时消失。"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(configuration.actions.indices), id: \.self) { index in
                    actionRow(for: $configuration.actions[index])
                    if index < configuration.actions.count - 1 {
                        divider(indented: true)
                    }
                }
            }
        }
    }

    private var terminalSection: some View {
        settingsSection(
            title: "默认终端",
            subtitle: "“在终端中打开”会使用所选应用，并通过 URL 直接传入目录。"
        ) {
            HStack(spacing: 12) {
                terminalIcon(bundleIdentifier: configuration.terminalBundleIdentifier)

                VStack(alignment: .leading, spacing: 3) {
                    Text("终端应用")
                        .font(.system(size: 13, weight: .medium))
                    Text(configuredTerminalInstalled ? "用于打开当前文件夹或所选文件的父目录" : "所选应用未安装，运行时将回退到 Terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(configuredTerminalInstalled ? Color.secondary : Color.orange)
                }

                Spacer(minLength: 18)

                Menu {
                    ForEach(installedTerminalApplications) { terminal in
                        Button {
                            configuration.terminalBundleIdentifier = terminal.bundleIdentifier
                        } label: {
                            if terminal.bundleIdentifier == configuration.terminalBundleIdentifier {
                                Label(terminal.displayName, systemImage: "checkmark")
                            } else {
                                Text(terminal.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(configuredTerminalName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("默认终端")
                .accessibilityIdentifier("settings.super-right.terminal")
            }
            .padding(.vertical, 2)
        }
    }

    private var fileFormatSection: some View {
        settingsSection(
            title: "新建文件格式",
            subtitle: "已启用 \(configuration.fileFormats.filter(\.isEnabled).count) 项；顺序与 Finder 的“新建文件”子菜单一致。"
        ) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(Array(configuration.fileFormats.indices), id: \.self) { index in
                    let format = configuration.fileFormats[index]
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(format.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(".\(format.fileExtension)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $configuration.fileFormats[index].isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("\(format.displayName) 文件格式")
                            .accessibilityIdentifier("settings.super-right.format.\(format.id)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.primary.opacity(0.065), lineWidth: 1)
                    }
                }
            }
        }
    }

    private func actionRow(
        for action: Binding<SuperRightActionConfiguration>
    ) -> some View {
        let isAvailable = action.wrappedValue.id != .cut
        let toggleBinding = isAvailable ? action.isEnabled : .constant(false)

        return HStack(spacing: 12) {
            Image(systemName: action.wrappedValue.id.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(action.wrappedValue.id.displayName)
                        .font(.system(size: 12, weight: .medium))
                    if !isAvailable {
                        Text("开发中")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.11), in: Capsule())
                    }
                }
                Text(action.wrappedValue.id.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isAvailable)
                .accessibilityLabel(action.wrappedValue.id.displayName)
                .accessibilityIdentifier("settings.super-right.action.\(action.wrappedValue.id.rawValue)")
        }
        .padding(.vertical, 9)
        .opacity(isAvailable ? 1 : 0.72)
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.primary.opacity(0.075), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func terminalIcon(bundleIdentifier: String) -> some View {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
        }
    }

    private func divider(indented: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.075))
            .frame(height: 1)
            .padding(.leading, indented ? 34 : 0)
    }

    private var installedTerminalApplications: [TerminalApplicationDefinition] {
        var applications = TerminalApplicationCatalog.candidates.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
        if !applications.contains(where: { $0.bundleIdentifier == configuration.terminalBundleIdentifier }),
           let configured = TerminalApplicationCatalog.candidates.first(where: {
               $0.bundleIdentifier == configuration.terminalBundleIdentifier
           }) {
            applications.append(configured)
        }
        return applications
    }

    private var configuredTerminalInstalled: Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: configuration.terminalBundleIdentifier
        ) != nil
    }

    private var configuredTerminalName: String {
        TerminalApplicationCatalog.candidates.first {
            $0.bundleIdentifier == configuration.terminalBundleIdentifier
        }?.displayName ?? "Terminal"
    }

    private func persist(_ configuration: SuperRightFeatureConfiguration) {
        try? repository.save(configuration)
        try? snapshotStore.save(configuration)
    }
}

private extension SuperRightActionID {
    var displayName: String {
        switch self {
        case .newFile: "新建文件"
        case .newFolder: "新建文件夹"
        case .cut: "剪切"
        case .copyPath: "复制路径"
        case .openTerminal: "在终端中打开"
        }
    }

    var detail: String {
        switch self {
        case .newFile: "在空白处或文件夹上显示格式子菜单"
        case .newFolder: "在当前目录创建未命名文件夹"
        case .cut: "安全移动与目标粘贴流程接通后开放"
        case .copyPath: "多选时按每行一个路径复制"
        case .openTerminal: "文件使用父目录，文件夹使用自身目录"
        }
    }

    var symbolName: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .newFolder: "folder.badge.plus"
        case .cut: "scissors"
        case .copyPath: "link"
        case .openTerminal: "terminal"
        }
    }
}
