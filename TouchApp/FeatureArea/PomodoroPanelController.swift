import AppKit
import PomodoroFeature
import SwiftUI
import TouchFeatureAPI

@MainActor
private var featurePanelDismissalTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

@MainActor
func cancelFeaturePanelDismissal(_ panel: NSWindow) {
    featurePanelDismissalTasks[ObjectIdentifier(panel)]?.cancel()
    featurePanelDismissalTasks[ObjectIdentifier(panel)] = nil
}

@MainActor
func dismissFeaturePanelAfterResigningKey(
    _ panel: NSWindow,
    keepsVisible: Bool = false,
    onHidden: (() -> Void)? = nil
) {
    if keepsVisible {
        cancelFeaturePanelDismissal(panel)
        return
    }
    let panelID = ObjectIdentifier(panel)
    featurePanelDismissalTasks[panelID]?.cancel()
    featurePanelDismissalTasks[panelID] = Task { @MainActor [weak panel] in
        // 给输入法候选窗、字段编辑器和系统 sheet 一个恢复 keyWindow 的短暂窗口。
        try? await Task.sleep(for: .milliseconds(120))
        guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
        guard panel.attachedSheet == nil else { return }
        // 输入法候选窗等瞬时系统窗口会让 keyWindow 短暂为空，但用户仍在当前功能窗口内编辑。
        // 切换到 Finder 或其他外部应用时只收起当前面板，绝不能通过 onHidden
        // 重新激活一念，否则 Finder 会被无意抢回焦点。
        guard NSApp.isActive else {
            panel.orderOut(nil)
            return
        }
        if NSApp.keyWindow == nil { return }
        if let keyWindow = NSApp.keyWindow,
           keyWindow === panel || keyWindow.sheetParent === panel {
            return
        }
        panel.orderOut(nil)
        onHidden?()
    }
}

@MainActor
final class PomodoroPanelController: NSObject, NSWindowDelegate {
    private let panel: PomodoroInputPanel
    private let model = PomodoroPanelModel()
    private let onClose: () -> Void
    private var restoresPinnedStateAfterFullscreen = false

    init(themeStore: ThemeStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = PomodoroInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.minSize = NSSize(width: 560, height: 680)
        panel.contentView = NSHostingView(
            rootView: PomodoroPanelView(
                model: model,
                onTogglePinned: { [weak self] in self?.togglePinned() },
                onToggleFullscreen: { [weak self] in self?.toggleFullscreen() }
            )
            .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
    }

    func show(request: FocusSessionRequest? = nil) {
        cancelFeaturePanelDismissal(panel)
        if let request { model.prepare(request) }
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if request != nil { model.startOrResume() }
    }

    func windowWillClose(_ notification: Notification) {
        model.pause()
        model.stopAllSounds()
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(
            panel,
            keepsVisible: model.isPinned || model.isFullscreen,
            onHidden: onClose
        )
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isFullscreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullscreen = false
        applyPinnedState(restoresPinnedStateAfterFullscreen)
        restoresPinnedStateAfterFullscreen = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        model.isFullscreen = false
        applyPinnedState(restoresPinnedStateAfterFullscreen)
        restoresPinnedStateAfterFullscreen = false
    }

    private func togglePinned() {
        guard !model.isFullscreen else { return }
        applyPinnedState(!model.isPinned)
        panel.makeKeyAndOrderFront(nil)
    }

    private func toggleFullscreen() {
        if model.isFullscreen || panel.styleMask.contains(.fullScreen) {
            panel.toggleFullScreen(nil)
            return
        }

        restoresPinnedStateAfterFullscreen = model.isPinned
        applyPinnedState(false)
        panel.collectionBehavior = [.fullScreenPrimary]
        model.isFullscreen = true
        panel.toggleFullScreen(nil)
    }

    private func applyPinnedState(_ isPinned: Bool) {
        model.isPinned = isPinned
        panel.isFloatingPanel = isPinned
        panel.level = isPinned ? .statusBar : .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenPrimary]
    }

}

@MainActor
final class PomodoroPanelModel: ObservableObject {
    enum Phase: String {
        case work = "专注"
        case shortBreak = "短休息"
        case longBreak = "长休息"

        var symbol: String {
            switch self {
            case .work: "scope"
            case .shortBreak: "cup.and.saucer"
            case .longBreak: "leaf"
            }
        }
    }

    enum SessionState {
        case ready
        case running
        case paused

        var title: String {
            switch self {
            case .ready: "开始"
            case .running: "专注中"
            case .paused: "已暂停"
            }
        }

        var symbol: String {
            switch self {
            case .ready: "sparkles"
            case .running: "waveform.path.ecg"
            case .paused: "pause.fill"
            }
        }
    }

    enum AlertSound: String, CaseIterable, Identifiable {
        case gentle = "轻铃声"
        case bright = "清脆"
        case mellow = "柔和"

        var id: String { rawValue }

        var systemName: String {
            switch self {
            case .gentle: "Glass"
            case .bright: "Ping"
            case .mellow: "Submarine"
            }
        }
    }

    @Published var title = "自由专注"
    @Published private(set) var phase: Phase = .work
    @Published private(set) var state: SessionState = .ready
    @Published private(set) var completedPomodoros = 0
    @Published private(set) var sessionFocusSeconds = 0
    @Published private(set) var plannedPomodoros: Int?
    @Published private(set) var targetPomodoros = 1
    @Published private(set) var taskCompletedPomodoros = 0
    @Published private(set) var targetDeadline: Date?
    @Published private(set) var totalSeconds = 25 * 60
    @Published private(set) var remainingSeconds = 25 * 60
    @Published private(set) var alertSound: AlertSound = .gentle
    @Published private(set) var previewingSound: AlertSound?
    @Published private(set) var isCompletionAlertPlaying = false
    @Published var isPinned = false
    @Published var isFullscreen = false

    static let completionAlertDuration: Duration = .seconds(10)
    static let completionAlertRepeatInterval: Duration = .milliseconds(1_250)
    static let completionAlertRepeatCount = 8

    private var preferredWorkSeconds = 25 * 60
    private var timer: Timer?
    private var previewSound: NSSound?
    private var previewTask: Task<Void, Never>?
    private var completionSound: NSSound?
    private var completionSoundTask: Task<Void, Never>?
    private var focusRequest: FocusSessionRequest?
    private var hasCustomizedTargetPomodoros = false

    var isRunning: Bool { state == .running }
    var selectedMinutes: Int { preferredWorkSeconds / 60 }

    func prepare(_ request: FocusSessionRequest, referenceDate: Date = .now) {
        stopTimer()
        focusRequest = request
        title = request.title
        targetDeadline = request.deadline
        completedPomodoros = 0
        sessionFocusSeconds = 0
        taskCompletedPomodoros = 0
        hasCustomizedTargetPomodoros = false
        configureWork(minutes: 25, referenceDate: referenceDate)
    }

    func configureWork(minutes: Int, referenceDate: Date = .now) {
        stopTimer()
        stopCompletionAlert()
        phase = .work
        preferredWorkSeconds = min(max(minutes, 1), 180) * 60
        totalSeconds = preferredWorkSeconds
        remainingSeconds = preferredWorkSeconds
        if let focusRequest {
            plannedPomodoros = focusRequest.requiredPomodoroCount(
                referenceDate: referenceDate,
                workMinutes: preferredWorkSeconds / 60
            )
            if !hasCustomizedTargetPomodoros {
                targetPomodoros = plannedPomodoros ?? targetPomodoros
            }
        }
        state = .ready
    }

    func setTargetPomodoros(_ count: Int) {
        stopCompletionAlert()
        targetPomodoros = min(max(count, 1), 12)
        hasCustomizedTargetPomodoros = true
    }

    func scrub(toElapsedProgress elapsedProgress: Double) {
        stopCompletionAlert()
        let normalizedProgress = min(max(elapsedProgress, 0), 1)
        remainingSeconds = Int((Double(totalSeconds) * (1 - normalizedProgress)).rounded())
    }

    func selectPhase(_ newPhase: Phase) {
        stopTimer()
        stopCompletionAlert()
        phase = newPhase
        switch newPhase {
        case .work:
            totalSeconds = preferredWorkSeconds
        case .shortBreak:
            totalSeconds = 5 * 60
        case .longBreak:
            totalSeconds = 15 * 60
        }
        remainingSeconds = totalSeconds
        state = .ready
    }

    func startOrResume(stopsCompletionAlert: Bool = true) {
        guard state != .running else { return }
        if stopsCompletionAlert {
            stopCompletionAlert()
        }
        if remainingSeconds <= 0 {
            remainingSeconds = totalSeconds
        }
        state = .running
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        stopCompletionAlert()
        guard state == .running else { return }
        stopTimer()
        state = .paused
    }

    func reset() {
        stopTimer()
        stopCompletionAlert()
        phase = .work
        totalSeconds = preferredWorkSeconds
        remainingSeconds = preferredWorkSeconds
        state = .ready
    }

    func selectAndPreview(_ sound: AlertSound) {
        stopCompletionAlert()
        alertSound = sound
        stopSoundPreview()

        guard let sample = NSSound(named: .init(sound.systemName)) else {
            NSSound.beep()
            return
        }

        previewSound = sample
        previewingSound = sound
        previewTask = Task { [weak self] in
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                sample.stop()
                sample.play()
                try? await Task.sleep(for: .milliseconds(1_250))
            }
            guard !Task.isCancelled, self?.previewingSound == sound else { return }
            self?.stopSoundPreview()
        }
    }

    func stopSoundPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewSound?.stop()
        previewSound = nil
        previewingSound = nil
    }

    func stopAllSounds() {
        stopSoundPreview()
        stopCompletionAlert()
    }

    private func playCompletionAlert() {
        stopCompletionAlert()
        let sample = NSSound(named: .init(alertSound.systemName))
        completionSound = sample
        isCompletionAlertPlaying = true
        completionSoundTask = Task { [weak self] in
            // 1.25 秒一次，共 8 次；无人操作时铃声持续约 10 秒。
            for _ in 0..<Self.completionAlertRepeatCount {
                guard !Task.isCancelled else { return }
                if let sample {
                    sample.stop()
                    sample.play()
                } else {
                    NSSound.beep()
                }
                try? await Task.sleep(for: Self.completionAlertRepeatInterval)
            }
            guard !Task.isCancelled else { return }
            sample?.stop()
            self?.completionSound = nil
            self?.completionSoundTask = nil
            self?.isCompletionAlertPlaying = false
        }
    }

    private func stopCompletionAlert() {
        completionSoundTask?.cancel()
        completionSoundTask = nil
        completionSound?.stop()
        completionSound = nil
        isCompletionAlertPlaying = false
    }

    private func beginBreak() {
        phase = completedPomodoros.isMultiple(of: 4) ? .longBreak : .shortBreak
        totalSeconds = (phase == .longBreak ? 15 : 5) * 60
        remainingSeconds = totalSeconds
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func completeCurrentPhase(playSound: Bool = true, automaticallyContinue: Bool = true) {
        stopTimer()
        remainingSeconds = 0
        state = .ready
        stopSoundPreview()
        if playSound {
            playCompletionAlert()
        } else {
            stopCompletionAlert()
        }

        if phase == .work {
            completedPomodoros += 1
            if plannedPomodoros != nil {
                taskCompletedPomodoros += 1
            }
            if completedPomodoros >= targetPomodoros {
                phase = .work
                totalSeconds = preferredWorkSeconds
                remainingSeconds = preferredWorkSeconds
                return
            }
            beginBreak()
        } else {
            phase = .work
            totalSeconds = preferredWorkSeconds
            remainingSeconds = preferredWorkSeconds
        }

        if automaticallyContinue {
            startOrResume(stopsCompletionAlert: false)
        }
    }

    private func tick() {
        guard remainingSeconds > 1 else {
            if phase == .work {
                sessionFocusSeconds += remainingSeconds
            }
            completeCurrentPhase()
            return
        }
        if phase == .work {
            sessionFocusSeconds += 1
        }
        remainingSeconds -= 1
    }
}

private struct PomodoroPanelView: View {
    private enum ActivePicker {
        case duration
        case sound
        case breakMode
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: PomodoroPanelModel
    let onTogglePinned: () -> Void
    let onToggleFullscreen: () -> Void

    @State private var activePicker: ActivePicker?
    @State private var customMinutes = ""
    @State private var hoveredPickerOption: String?
    @State private var isShowingStatisticsSummary = false
    @State private var isShowingTargetEditor = false

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PanelThemeBackground(
                    theme: theme,
                    reduceTransparency: reduceTransparency,
                    themeColorOpacity: 0.96
                )

                ambientGlow

                if activePicker != nil || isShowingStatisticsSummary || isShowingTargetEditor {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                                activePicker = nil
                                isShowingStatisticsSummary = false
                                isShowingTargetEditor = false
                            }
                        }
                        .zIndex(1)
                }

                contentLayout(in: proxy.size)
                    .zIndex(2)
            }
        }
        .frame(minWidth: 560, minHeight: 680)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .shadow(
            color: theme.panel.shadow.color.color,
            radius: theme.panel.shadow.radius,
            x: theme.panel.shadow.x,
            y: theme.panel.shadow.y
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: activePicker != nil)
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private func contentLayout(in size: CGSize) -> some View {
        if model.isFullscreen {
            fullscreenLayout(in: size)
        } else {
            standardLayout
        }
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            header
            heroHeading
                .padding(.top, 2)
            taskPill
                .padding(.top, 10)
            timerStage
                .padding(.top, 10)
            configurationCard
                .padding(.top, 10)
                .zIndex(20)
            actionRow
                .padding(.top, 10)
            statisticsCard
                .padding(.top, 10)
                .zIndex(isShowingTargetEditor ? 60 : 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
    }

    private func fullscreenLayout(in size: CGSize) -> some View {
        let horizontalInset = min(max(size.width * 0.045, 38), 76)
        let columnSpacing = min(max(size.width * 0.045, 38), 72)
        let timerColumnWidth = min(max(size.width * 0.34, 360), 460)
        let controlsColumnWidth = min(max(size.width * 0.4, 480), 560)

        return VStack(spacing: 0) {
            header

            Spacer(minLength: 22)

            HStack(alignment: .center, spacing: columnSpacing) {
                VStack(spacing: 0) {
                    heroHeading
                    taskPill
                        .padding(.top, 14)
                    timerStage
                        .padding(.top, 18)
                }
                .frame(width: timerColumnWidth)

                VStack(spacing: 14) {
                    configurationCard
                        .zIndex(20)
                    actionRow
                    statisticsCard
                        .zIndex(isShowingTargetEditor ? 60 : 0)
                }
                .frame(width: controlsColumnWidth)
            }
            .frame(maxWidth: 1_120)

            Spacer(minLength: 30)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 30)
    }

    private var ambientGlow: some View {
        ZStack {
            Circle()
                .fill(theme.accent.color.opacity(0.09))
                .frame(width: 400, height: 400)
                .blur(radius: 84)
                .offset(y: -32)
            Circle()
                .fill(theme.auxiliaryAccent.color.opacity(0.045))
                .frame(width: 300, height: 300)
                .blur(radius: 78)
                .offset(x: 210, y: 160)
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 18)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                sessionSummaryButton
                    .overlay(alignment: .topLeading) {
                        if isShowingStatisticsSummary {
                            statisticsSummaryPopover
                                .offset(y: 42)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                                .zIndex(40)
                        }
                    }

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    roundIconButton(
                        symbol: model.previewingSound == nil ? "music.note" : "speaker.wave.2.fill",
                        label: model.previewingSound == nil ? "试听\(model.alertSound.rawValue)" : "停止试听",
                        identifier: "pomodoro.preview-sound",
                        isSelected: model.previewingSound != nil
                    ) {
                        if model.previewingSound == nil {
                            model.selectAndPreview(model.alertSound)
                        } else {
                            model.stopSoundPreview()
                        }
                    }
                    roundIconButton(
                        symbol: model.isPinned ? "pin.fill" : "pin",
                        label: model.isPinned ? "取消置顶" : "置顶番茄闹钟",
                        identifier: "pomodoro.pin",
                        isSelected: model.isPinned,
                        isEnabled: !model.isFullscreen,
                        action: onTogglePinned
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .frame(height: 54)
        .zIndex(50)
    }

    private var sessionSummaryButton: some View {
        Button {
            activePicker = nil
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isShowingStatisticsSummary.toggle()
            }
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isShowingStatisticsSummary ? Color.white : theme.text.secondary.color)
                .frame(width: 34, height: 34)
                .background(
                    isShowingStatisticsSummary ? theme.accent.color : theme.card.fill.color.opacity(0.76),
                    in: Circle()
                )
                .overlay(Circle().stroke(theme.card.border.color.opacity(isShowingStatisticsSummary ? 0 : 0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowingStatisticsSummary ? "收起会话统计" : "查看会话统计")
        .accessibilityValue(sessionSummaryLabel)
        .accessibilityIdentifier("pomodoro.statistics-summary")
    }

    private var statisticsSummaryPopover: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("本次会话")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary.color)
            Label("完成 \(model.completedPomodoros) 个番茄", systemImage: "scope")
            Label("目标 \(model.targetPomodoros) 个番茄", systemImage: "flag.checkered")
            Label("专注 \(sessionDurationValue)", systemImage: "clock")
            Label("当前完成率 \(completionPercentage)%", systemImage: "target")
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(theme.text.secondary.color)
        .padding(13)
        .frame(width: 188, alignment: .leading)
        .background(theme.card.fill.color.opacity(0.99), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: theme.panel.shadow.color.color.opacity(0.45), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sessionSummaryLabel)
        .accessibilityIdentifier("pomodoro.statistics-popover")
    }

    private var heroHeading: some View {
        VStack(spacing: 5) {
            Text(phaseTitle)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(theme.text.primary.color)
                .accessibilityIdentifier("pomodoro.current-phase")
            Text(phaseSubtitle)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .tracking(1)
                .foregroundStyle(theme.text.secondary.color)
        }
    }

    private var taskPill: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text.secondary.color)
            Text("当前任务：\(model.title)")
                .lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(theme.text.primary.color)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(theme.card.fill.color.opacity(0.76), in: Capsule())
        .overlay(Capsule().stroke(theme.card.border.color.opacity(0.66), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(taskAccessibilityLabel)
        .accessibilityIdentifier(model.plannedPomodoros == nil ? "pomodoro.current-task" : "pomodoro.plan-summary")
    }

    private var timerStage: some View {
        ZStack {
            waveform
                .frame(maxWidth: .infinity)
                .offset(y: 14)
            timerDial
        }
        .frame(height: 258)
    }

    private var waveform: some View {
        HStack {
            waveformCluster
            Spacer()
            waveformCluster
        }
        .padding(.horizontal, 10)
        .opacity(0.5)
        .allowsHitTesting(false)
    }

    private var waveformCluster: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach([10, 22, 34, 18, 42, 26, 14, 30, 12], id: \.self) { height in
                Capsule()
                    .fill(theme.accent.color.opacity(0.14))
                    .frame(width: 3, height: CGFloat(height))
            }
        }
    }

    private var timerDial: some View {
        ZStack {
            Circle()
                .fill(theme.card.fill.color.opacity(0.72))
                .shadow(color: theme.accent.color.opacity(0.17), radius: 32, y: 13)
            Circle()
                .stroke(theme.card.border.color.opacity(0.5), lineWidth: 9)
                .padding(4)
            Circle()
                .trim(from: elapsedProgress, to: 1)
                .stroke(
                    theme.accent.color,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .padding(4)
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: elapsedProgress)
            progressIndicator
            Circle()
                .stroke(theme.panel.highlight.color.opacity(0.38), lineWidth: 1)
                .padding(18)
            timerTicks
                .padding(25)

            VStack(spacing: 9) {
                Image(systemName: model.phase.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent.color.opacity(0.82))
                Text(timeText)
                    .font(.system(size: 55, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.text.primary.color)
                    .accessibilityLabel("剩余时间")
                    .accessibilityValue(timeText)
                    .accessibilityIdentifier("pomodoro.remaining-time")
                Text(helperText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
                focusShieldControl
            }

        }
        .frame(width: 252, height: 252)
        .contentShape(Circle())
        .simultaneousGesture(timerScrubGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pomodoro.timer-dial")
    }

    @ViewBuilder
    private var focusShieldControl: some View {
        if model.phase == .work {
            Button(action: openSystemFocusSettings) {
                Label("打开系统专注模式", systemImage: "moon.fill")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background(theme.card.fill.color.opacity(0.86), in: Capsule())
                    .overlay(Capsule().stroke(theme.accent.color.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("macOS 不允许应用自动切换勿扰模式，点击前往系统设置")
            .accessibilityIdentifier("pomodoro.open-focus-settings")
        } else {
            Label(shieldText, systemImage: "cup.and.saucer")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.secondary.color)
                .padding(.horizontal, 12)
                .frame(height: 29)
                .background(theme.card.fill.color.opacity(0.82), in: Capsule())
                .overlay(Capsule().stroke(theme.card.border.color.opacity(0.55), lineWidth: 1))
        }
    }

    private var timerTicks: some View {
        ZStack {
            ForEach(0..<60, id: \.self) { tick in
                Capsule()
                    .fill(theme.text.weak.color.opacity(tick.isMultiple(of: 5) ? 0.34 : 0.17))
                    .frame(
                        width: tick.isMultiple(of: 5) ? 1.6 : 1,
                        height: tick.isMultiple(of: 5) ? 9 : 5
                    )
                    .offset(y: -99)
                    .rotationEffect(.degrees(Double(tick) * 6))
            }
        }
        .allowsHitTesting(false)
    }

    private var progressIndicator: some View {
        ZStack {
            Circle()
                .fill(theme.accent.color.opacity(0.2))
                .frame(width: 30, height: 30)
                .blur(radius: 7)
            Circle()
                .fill(theme.panel.highlight.color)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .stroke(theme.accent.color.opacity(0.38), lineWidth: 1)
                }
                .shadow(color: theme.panel.shadow.color.color.opacity(0.32), radius: 3, y: 2)
                .shadow(color: theme.accent.color.opacity(0.58), radius: 8)
            Circle()
                .fill(theme.accent.color)
                .frame(width: 6.5, height: 6.5)
                .overlay(Circle().stroke(theme.panel.highlight.color.opacity(0.8), lineWidth: 0.75))
                .shadow(color: theme.accent.color.opacity(0.72), radius: 3)
        }
        .offset(y: -122)
        .rotationEffect(.degrees(elapsedProgress * 360))
        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: model.remainingSeconds)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("倒计时进度点，已进行 \(elapsedSeconds) 秒")
        .accessibilityIdentifier("pomodoro.progress-indicator")
    }

    private var timerScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let radius = 126.0
                let deltaX = value.location.x - radius
                let deltaY = value.location.y - radius
                guard hypot(deltaX, deltaY) >= 96 else { return }
                var angle = atan2(deltaX, -deltaY)
                if angle < 0 { angle += 2 * .pi }
                model.scrub(toElapsedProgress: angle / (2 * .pi))
            }
    }

    private var configurationCard: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / 3
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    configurationButton(
                        symbol: "clock",
                        title: "专注时长",
                        value: "\(model.selectedMinutes) 分钟",
                        isSelected: activePicker == .duration
                    ) {
                        togglePicker(.duration)
                    }

                    configurationDivider

                    configurationButton(
                        symbol: "music.note",
                        title: "提示铃声",
                        value: model.alertSound.rawValue,
                        isSelected: activePicker == .sound
                    ) {
                        togglePicker(.sound)
                    }

                    configurationDivider

                    configurationButton(
                        symbol: "cup.and.saucer",
                        title: "休息方式",
                        value: breakModeText,
                        isSelected: activePicker == .breakMode
                    ) {
                        togglePicker(.breakMode)
                    }
                }
                .padding(.horizontal, 10)

                if let activePicker {
                    floatingPicker(activePicker)
                        .frame(width: pickerWidth(activePicker))
                        .offset(
                            x: pickerOffset(
                                activePicker,
                                columnWidth: columnWidth,
                                totalWidth: proxy.size.width
                            ),
                            y: 58
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        .zIndex(30)
                }
            }
        }
        .frame(height: 64)
        .background(theme.card.fill.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.66), lineWidth: 1)
        }
        .shadow(color: theme.card.shadow.color.color.opacity(0.4), radius: 12, y: 7)
    }

    private var configurationDivider: some View {
        Rectangle()
            .fill(theme.card.border.color.opacity(0.62))
            .frame(width: 1, height: 34)
    }

    private func configurationButton(
        symbol: String,
        title: String,
        value: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
                HStack(spacing: 7) {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.text.primary.color)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.text.weak.color)
                        .rotationEffect(.degrees(isSelected ? 180 : 0))
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? theme.accent.color.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(value)")
    }

    @ViewBuilder
    private func floatingPicker(_ picker: ActivePicker) -> some View {
        Group {
            switch picker {
            case .duration:
                VStack(spacing: 3) {
                    ForEach([25, 45, 60], id: \.self) { minutes in
                        pickerOption(
                            id: "duration-\(minutes)",
                            title: "\(minutes) 分钟",
                            isSelected: model.selectedMinutes == minutes
                        ) {
                            model.configureWork(minutes: minutes)
                            activePicker = nil
                        }
                    }
                    customTimeControl
                }
            case .sound:
                VStack(spacing: 3) {
                    ForEach(PomodoroPanelModel.AlertSound.allCases) { sound in
                        soundChoiceButton(sound)
                    }
                }
            case .breakMode:
                VStack(spacing: 3) {
                    pickerOption(
                        id: "break-short",
                        title: "短休息",
                        detail: "5 分钟",
                        isSelected: model.phase != .longBreak
                    ) {
                        model.selectPhase(.shortBreak)
                        activePicker = nil
                    }
                    pickerOption(
                        id: "break-long",
                        title: "长休息",
                        detail: "15 分钟",
                        isSelected: model.phase == .longBreak
                    ) {
                        model.selectPhase(.longBreak)
                        activePicker = nil
                    }
                }
            }
        }
        .padding(7)
        .background(theme.card.fill.color.opacity(0.99), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: theme.panel.shadow.color.color.opacity(0.48), radius: 20, y: 11)
    }

    private func pickerWidth(_ picker: ActivePicker) -> CGFloat {
        switch picker {
        case .duration: 184
        case .sound: 174
        case .breakMode: 188
        }
    }

    private func pickerOffset(_ picker: ActivePicker, columnWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        switch picker {
        case .duration:
            return 4
        case .sound:
            return columnWidth + (columnWidth - pickerWidth(picker)) / 2
        case .breakMode:
            return totalWidth - pickerWidth(picker) - 4
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            secondaryActionButton(
                title: "重置计时",
                symbol: "arrow.counterclockwise",
                identifier: "pomodoro.reset",
                isEnabled: model.phase != .work || model.state != .ready || model.remainingSeconds != model.totalSeconds,
                action: model.reset
            )

            primaryActionButton

            secondaryActionButton(
                title: model.isFullscreen ? "退出全屏" : "全屏专注",
                symbol: model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                identifier: "pomodoro.fullscreen",
                isEnabled: true,
                action: onToggleFullscreen
            )
        }
        .frame(height: 48)
    }

    private var primaryActionButton: some View {
        Button {
            activePicker = nil
            if model.isRunning {
                model.pause()
            } else {
                model.startOrResume()
            }
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionSymbol)
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    LinearGradient(
                        colors: [theme.accent.color, theme.auxiliaryAccent.color],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: theme.accent.color.opacity(0.23), radius: 11, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.state == .ready ? "开始" : primaryActionTitle)
        .accessibilityIdentifier("pomodoro.primary-action")
    }

    private func secondaryActionButton(
        title: String,
        symbol: String,
        identifier: String? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary.color)
                .frame(width: 120, height: 46)
                .background(theme.card.fill.color.opacity(0.76), in: Capsule())
                .overlay(Capsule().stroke(theme.card.border.color.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var statisticsCard: some View {
        HStack(spacing: 0) {
            Group {
                if isShowingTargetEditor {
                    targetEditor
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    targetStatisticButton
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            statisticsDivider

            statistic(
                symbol: "clock",
                title: "总专注时长",
                value: sessionDurationValue,
                suffix: "",
                detail: model.isRunning && model.phase == .work ? "正在累计" : "本次会话"
            )

            statisticsDivider

            statistic(
                symbol: "target",
                title: "完成率",
                value: "\(completionPercentage)%",
                suffix: "",
                detail: completionDetail
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 76)
        .background(theme.card.fill.color.opacity(0.58), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pomodoro.session-statistics")
    }

    private var targetStatisticButton: some View {
        Button {
            activePicker = nil
            isShowingStatisticsSummary = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isShowingTargetEditor.toggle()
            }
        } label: {
            targetStatisticContent
            .contentShape(Rectangle())
            .background(
                isShowingTargetEditor ? theme.accent.color.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设置目标番茄数")
        .accessibilityValue("已完成 \(model.completedPomodoros) 个，目标 \(model.targetPomodoros) 个")
        .accessibilityIdentifier("pomodoro.target-count")
    }

    private var targetStatisticContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("目标番茄数", systemImage: "scope")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.text.secondary.color)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(model.targetPomodoros)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                    .monospacedDigit()
                Text("个")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
            }
            HStack(spacing: 5) {
                Text("已完成 \(model.completedPomodoros) 个")
                    .foregroundStyle(theme.text.weak.color)
                Text("修改")
                    .foregroundStyle(theme.text.weak.color.opacity(0.88))
            }
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetEditor: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text("目标番茄数")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
                Spacer(minLength: 2)
                Button("完成") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        isShowingTargetEditor = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.weak.color)
                .accessibilityIdentifier("pomodoro.target-editor-done")
            }

            HStack(spacing: 7) {
                targetAdjustButton(
                    symbol: "minus",
                    label: "减少目标番茄数",
                    identifier: "pomodoro.target-decrease",
                    isEnabled: model.targetPomodoros > 1
                ) {
                    model.setTargetPomodoros(model.targetPomodoros - 1)
                }

                Text("\(model.targetPomodoros)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.text.primary.color)
                    .frame(minWidth: 28)
                    .accessibilityLabel("当前目标番茄数")
                    .accessibilityValue("\(model.targetPomodoros)")
                    .accessibilityIdentifier("pomodoro.target-value")

                targetAdjustButton(
                    symbol: "plus",
                    label: "增加目标番茄数",
                    identifier: "pomodoro.target-increase",
                    isEnabled: model.targetPomodoros < 12
                ) {
                    model.setTargetPomodoros(model.targetPomodoros + 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(theme.accent.color.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pomodoro.target-editor")
    }

    private func targetAdjustButton(
        symbol: String,
        label: String,
        identifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.text.primary.color)
                .frame(width: 28, height: 28)
                .background(theme.accent.color.opacity(isEnabled ? 0.12 : 0.04), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var statisticsDivider: some View {
        Rectangle()
            .fill(theme.card.border.color.opacity(0.58))
            .frame(width: 1, height: 54)
    }

    private func statistic(
        symbol: String,
        title: String,
        value: String,
        suffix: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.text.secondary.color)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                    .monospacedDigit()
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.text.secondary.color)
                }
            }
            Text(detail)
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.text.weak.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func togglePicker(_ picker: ActivePicker) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            activePicker = activePicker == picker ? nil : picker
        }
    }

    private func roundIconButton(
        symbol: String,
        label: String,
        identifier: String,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : theme.text.secondary.color)
                .frame(width: 34, height: 34)
                .background(isSelected ? theme.accent.color : theme.card.fill.color.opacity(0.76), in: Circle())
                .overlay(Circle().stroke(theme.card.border.color.opacity(isSelected ? 0 : 0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func pickerOption(
        id: String,
        title: String,
        detail: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? theme.accent.color : theme.text.weak.color)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(isSelected ? theme.accent.color : theme.text.primary.color)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected
                    ? theme.accent.color.opacity(0.11)
                    : (hoveredPickerOption == id ? theme.card.border.color.opacity(0.25) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                hoveredPickerOption = isHovering ? id : nil
            }
        }
    }

    private func soundChoiceButton(_ sound: PomodoroPanelModel.AlertSound) -> some View {
        let isSelected = model.alertSound == sound
        let isPreviewing = model.previewingSound == sound
        return Button {
            model.selectAndPreview(sound)
            activePicker = nil
        } label: {
            HStack(spacing: 8) {
                if isPreviewing {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                Text(sound.rawValue)
                Spacer(minLength: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? theme.accent.color : theme.text.primary.color)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected
                    ? theme.accent.color.opacity(0.11)
                    : (hoveredPickerOption == "sound-\(sound.id)" ? theme.card.border.color.opacity(0.25) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                hoveredPickerOption = isHovering ? "sound-\(sound.id)" : nil
            }
        }
        .accessibilityLabel(sound.rawValue)
    }

    private var customTimeControl: some View {
        let isSelected = ![25, 45, 60].contains(model.selectedMinutes)
        return HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .medium))
                .accessibilityHidden(true)
            TextField("自定义", text: $customMinutes)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .frame(minWidth: 42)
                .frame(height: 24)
                .onSubmit(applyCustomMinutes)
                .onChange(of: customMinutes) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue {
                        customMinutes = String(digits.prefix(3))
                    }
                }
                .accessibilityIdentifier("pomodoro.custom-minutes")
            Text("分钟")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .accessibilityHidden(true)
            Button(action: applyCustomMinutes) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(
                        theme.accent.color.opacity(isSelected ? 0.18 : 0.1),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("应用自定义时长")
            .accessibilityIdentifier("pomodoro.apply-custom-minutes")
        }
        .foregroundStyle(isSelected ? theme.accent.color : theme.text.secondary.color)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(isSelected ? theme.accent.color.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func applyCustomMinutes() {
        guard let minutes = Int(customMinutes), (1...180).contains(minutes) else { return }
        model.configureWork(minutes: minutes)
        activePicker = nil
    }

    private func openSystemFocusSettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.Focus-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for destination in destinations {
            if let url = URL(string: destination), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private var phaseTitle: String {
        switch model.phase {
        case .work: "深度专注"
        case .shortBreak: "短暂休息"
        case .longBreak: "深度休息"
        }
    }

    private var phaseSubtitle: String {
        switch model.phase {
        case .work: "屏蔽干扰 · 沉浸当下"
        case .shortBreak: "放松片刻 · 恢复精力"
        case .longBreak: "离开屏幕 · 充分恢复"
        }
    }

    private var helperText: String {
        switch model.state {
        case .ready:
            return model.phase == .work ? "准备好后，开始专注" : "准备好后，开始休息"
        case .running:
            return model.phase == .work ? "保持专注，只做这一件事" : "休息进行中，放松一下"
        case .paused:
            return "计时已暂停"
        }
    }

    private var shieldText: String {
        "休息结束自动进入下一轮"
    }

    private var primaryActionTitle: String {
        switch model.state {
        case .ready:
            return model.phase == .work ? "开始专注" : "开始休息"
        case .running:
            return "暂停计时"
        case .paused:
            return "继续计时"
        }
    }

    private var primaryActionSymbol: String {
        switch model.state {
        case .ready, .paused: "play.fill"
        case .running: "pause.fill"
        }
    }

    private var timeText: String {
        String(format: "%02d:%02d", model.remainingSeconds / 60, model.remainingSeconds % 60)
    }

    private var progress: Double {
        Double(model.remainingSeconds) / Double(max(1, model.totalSeconds))
    }

    private var elapsedProgress: Double {
        1 - progress
    }

    private var elapsedSeconds: Int {
        max(0, model.totalSeconds - model.remainingSeconds)
    }

    private var breakModeText: String {
        if model.phase == .longBreak {
            return "长休 15 分钟"
        }
        return "短休 5 分钟"
    }

    private var taskAccessibilityLabel: String {
        if let plannedPomodoros = model.plannedPomodoros {
            return "当前任务\(model.title)，计划\(plannedPomodoros)个番茄，已完成\(model.taskCompletedPomodoros)个"
        }
        return "当前任务\(model.title)"
    }

    private var sessionSummaryLabel: String {
        "本次完成\(model.completedPomodoros)个番茄，目标\(model.targetPomodoros)个，专注\(sessionDurationValue)"
    }

    private var plannedDetail: String {
        "目标番茄数 \(model.targetPomodoros)"
    }

    private var sessionDurationValue: String {
        let hours = model.sessionFocusSeconds / 3_600
        let minutes = (model.sessionFocusSeconds % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) 分钟"
    }

    private var completionPercentage: Int {
        let completed = Double(min(model.completedPomodoros, model.targetPomodoros))
        let currentProgress = model.phase == .work ? elapsedProgress : 0
        return Int(min(1, (completed + currentProgress) / Double(model.targetPomodoros)) * 100)
    }

    private var completionDetail: String {
        "\(min(model.completedPomodoros, model.targetPomodoros)) / \(model.targetPomodoros) 个番茄"
    }
}

private final class PomodoroInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
