import AppKit
import DailyTaskFeature
import SwiftUI
import TouchFeatureAPI

@MainActor
final class DailyTaskPanelController: NSObject, NSWindowDelegate, FeaturePanelSessionController {
    private let panel: NSPanel
    private let model: DailyTaskPanelModel
    private let onClose: () -> Void
    private let onStartFocus: (FocusSessionRequest) -> Void

    init(
        repository: DailyTaskRepository,
        themeStore: ThemeStore,
        onStartFocus: @escaping (FocusSessionRequest) -> Void,
        onClose: @escaping () -> Void
    ) {
        model = DailyTaskPanelModel(repository: repository)
        self.onStartFocus = onStartFocus
        self.onClose = onClose
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 720),
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
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 780, height: 680)
        panel.contentView = NSHostingView(
            rootView: DailyTaskPanelView(
                model: model,
                onStartFocus: { [weak self] request in
                    self?.onStartFocus(request)
                }
            )
            .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
    }

    var sessionWindow: NSWindow { panel }

    func show() {
        cancelFeaturePanelDismissal(panel)
        model.reload()
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel)
    }
}

private struct DailyTaskDraft {
    var title = ""
    var detail = ""
    var estimatedMinutes = 25
    var status: DailyTaskStatus = .pending
    var priority: DailyTaskPriority = .medium
    var category = "工作"
    var deadline: Date?
    var isFocusTask = false

    init(status: DailyTaskStatus = .pending) {
        self.status = status
    }

    init(task: DailyTask, isFocusTask: Bool) {
        title = task.title
        detail = task.detail
        estimatedMinutes = task.estimatedMinutes
        status = task.status
        priority = task.priority
        category = task.category
        deadline = task.deadline
        self.isFocusTask = isFocusTask
    }
}

@MainActor
private final class DailyTaskPanelModel: ObservableObject {
    @Published private(set) var configuration: DailyTaskConfiguration
    private let repository: DailyTaskRepository

    init(repository: DailyTaskRepository) {
        self.repository = repository
        configuration = (try? repository.load()) ?? .init()
    }

    var todaysTasks: [DailyTask] {
        configuration.tasks
            .filter { Calendar.current.isDateInToday($0.scheduledDate) }
    }

    var focusTask: DailyTask? {
        guard let focusTaskID = configuration.focusTaskID else { return nil }
        return todaysTasks.first { $0.id == focusTaskID && $0.status != .completed }
    }

    var inProgressTasks: [DailyTask] {
        tasks(for: .inProgress)
    }

    func tasks(for status: DailyTaskStatus) -> [DailyTask] {
        todaysTasks.filter { $0.status == status }
    }

    func reload() {
        configuration = (try? repository.load()) ?? .init()
        normalizeFocusTask()
    }

    func add(_ draft: DailyTaskDraft) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = DailyTask(
            title: title,
            scheduledDate: .now,
            detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedMinutes: draft.estimatedMinutes,
            status: draft.status,
            priority: draft.priority,
            category: draft.category,
            deadline: draft.deadline
        )
        configuration.add(task, asFocusTask: draft.isFocusTask)
        persist()
    }

    func update(_ task: DailyTask, with draft: DailyTaskDraft) {
        guard configuration.tasks.contains(where: { $0.id == task.id }) else { return }

        if task.status != draft.status {
            _ = configuration.moveTask(id: task.id, to: draft.status)
        }
        guard let index = configuration.tasks.firstIndex(where: { $0.id == task.id }) else { return }

        configuration.tasks[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.tasks[index].detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.tasks[index].estimatedMinutes = draft.estimatedMinutes
        configuration.tasks[index].priority = draft.priority
        configuration.tasks[index].category = draft.category
        configuration.tasks[index].deadline = draft.deadline

        if draft.isFocusTask, draft.status != .completed {
            _ = configuration.selectFocusTask(id: task.id)
        } else if configuration.focusTaskID == task.id {
            _ = configuration.selectFocusTask(id: nil)
        }
        persist()
    }

    func advance(_ task: DailyTask) {
        let destination: DailyTaskStatus
        switch task.status {
        case .pending: destination = .inProgress
        case .inProgress: destination = .completed
        case .completed: return
        }
        _ = moveTask(id: task.id, to: destination)
    }

    func moveTask(id: UUID, to destination: DailyTaskStatus) -> Bool {
        guard configuration.moveTask(id: id, to: destination) else { return false }
        persist()
        return true
    }

    func remove(_ task: DailyTask) {
        configuration.removeTask(id: task.id)
        persist()
    }

    func setFocusTask(_ id: UUID?) {
        guard let id else {
            _ = configuration.selectFocusTask(id: nil)
            persist()
            return
        }
        guard todaysTasks.contains(where: { $0.id == id && $0.status != .completed }) else { return }
        guard configuration.selectFocusTask(id: id) else { return }
        persist()
    }

    private func normalizeFocusTask() {
        guard configuration.focusTaskID != nil, focusTask == nil else { return }
        configuration.focusTaskID = nil
        persist()
    }

    private func persist() {
        try? repository.save(configuration)
    }
}

private extension DailyTaskStatus {
    var symbol: String {
        switch self {
        case .pending: "tray.full.fill"
        case .inProgress: "play.fill"
        case .completed: "checkmark"
        }
    }
}

private struct DailyTaskLayoutMetrics {
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let headerHeight: CGFloat
    let summaryHeight: CGFloat
    let lowerCardsHeight: CGFloat
    let boardRowHeight: CGFloat

    init(availableHeight: CGFloat) {
        let roomy = availableHeight >= 780
        horizontalPadding = roomy ? 24 : 21
        topPadding = roomy ? 26 : 21
        bottomPadding = roomy ? 18 : 16
        sectionSpacing = roomy ? 10 : 8
        headerHeight = roomy ? 44 : 38
        summaryHeight = roomy ? 90 : 82
        lowerCardsHeight = roomy ? 170 : 150
        boardRowHeight = roomy ? 60 : 55
    }
}

private struct DailyTaskPanelView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: DailyTaskPanelModel
    let onStartFocus: (FocusSessionRequest) -> Void

    @State private var presentsAddTask = false
    @State private var addTaskStatus: DailyTaskStatus = .pending
    @State private var presentsFocusPicker = false
    @State private var selectedStartTaskID: UUID?
    @State private var editingTask: DailyTask?

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }
    private var completedCount: Int { model.tasks(for: .completed).count }
    private var completion: Double {
        guard !model.todaysTasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(model.todaysTasks.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = DailyTaskLayoutMetrics(availableHeight: proxy.size.height)

            ZStack {
                PanelThemeBackground(theme: theme, reduceTransparency: reduceTransparency, themeColorOpacity: 0.97)

                Circle()
                    .fill(theme.interactiveAccent.color.opacity(reduceTransparency ? 0.035 : 0.07))
                    .frame(width: 430, height: 430)
                    .blur(radius: 100)
                    .offset(x: 360, y: -330)

                VStack(spacing: metrics.sectionSpacing) {
                    header
                        .frame(height: metrics.headerHeight)
                    summaryCard
                        .frame(height: metrics.summaryHeight)
                    board(rowHeight: metrics.boardRowHeight)
                    lowerCards
                        .frame(height: metrics.lowerCardsHeight)
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)

                addTaskButton
                    .padding(.trailing, metrics.horizontalPadding - 11)
                    .padding(.bottom, metrics.bottomPadding - 7)
            }
        }
        .frame(minWidth: 780, minHeight: 680)
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .shadow(
            color: theme.panel.shadow.color.color,
            radius: theme.panel.shadow.radius,
            x: theme.panel.shadow.x,
            y: theme.panel.shadow.y
        )
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $presentsAddTask) {
            DailyTaskEditorSheet(
                initialStatus: addTaskStatus,
                task: nil,
                isFocusTask: false,
                theme: theme,
                onCancel: { presentsAddTask = false },
                onSave: { draft in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: theme.motion.duration)) {
                        model.add(draft)
                    }
                    presentsAddTask = false
                }
            )
            .id(addTaskStatus)
        }
        .sheet(item: $editingTask) { task in
            DailyTaskEditorSheet(
                initialStatus: task.status,
                task: task,
                isFocusTask: model.focusTask?.id == task.id,
                theme: theme,
                onCancel: { editingTask = nil },
                onSave: { draft in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: theme.motion.duration)) {
                        model.update(task, with: draft)
                    }
                    editingTask = nil
                }
            )
            .id(task.id)
        }
        .sheet(isPresented: $presentsFocusPicker) {
            DailyTaskFocusPicker(
                tasks: model.todaysTasks.filter { $0.status != .completed },
                selectedID: model.focusTask?.id,
                theme: theme,
                onSelect: { id in
                    model.setFocusTask(id)
                    presentsFocusPicker = false
                },
                onCancel: { presentsFocusPicker = false }
            )
        }
        .onAppear(perform: selectFirstRunningTaskIfNeeded)
        .onChange(of: model.inProgressTasks.map(\.id)) { _, _ in
            selectFirstRunningTaskIfNeeded()
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("每日任务")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .tracking(0.35)
                .foregroundStyle(theme.text.primary.color)
            Text("今天 · 已完成 \(completedCount) / \(model.todaysTasks.count) 项")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.text.secondary.color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var summaryCard: some View {
        HStack(spacing: 0) {
            HStack(spacing: 15) {
                DailyTaskProgressRing(progress: completion, theme: theme)
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日完成率")
                        .font(.system(size: 14, weight: .semibold))
                    Text("目标 \(model.todaysTasks.count) 项")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                    DailyTaskLinearProgress(progress: completion, theme: theme)
                        .frame(maxWidth: 145)
                        .accessibilityLabel("今日完成率")
                        .accessibilityValue("\(Int(completion * 100))%")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            summaryDivider

            HStack(spacing: 14) {
                Text("\(model.todaysTasks.count)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日任务").font(.system(size: 14, weight: .semibold))
                    Text("待开始 \(model.tasks(for: .pending).count) · 进行中 \(model.inProgressTasks.count) · 已完成 \(completedCount)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            summaryDivider

            HStack(spacing: 13) {
                Image(systemName: completion >= 0.5 ? "star.fill" : "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
                    .frame(width: 48, height: 48)
                    .background(theme.interactiveAccent.color.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle).font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .foregroundStyle(theme.text.primary.color)
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(theme.card.fill.color.opacity(0.92), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: theme.card.shadow.color.color, radius: theme.card.shadow.radius, y: theme.card.shadow.y)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(theme.card.border.color.opacity(0.75))
            .frame(width: 1, height: 54)
    }

    private func board(rowHeight: CGFloat) -> some View {
        HStack(spacing: 12) {
            ForEach(DailyTaskStatus.allCases, id: \.self) { status in
                DailyTaskBoardColumn(
                    status: status,
                    tasks: model.tasks(for: status),
                    theme: theme,
                    rowHeight: rowHeight,
                    onRemove: model.remove,
                    onEdit: { editingTask = $0 },
                    onDropTask: { id in model.moveTask(id: id, to: status) },
                    onAdd: { showAddTask(status: status) }
                )
            }
        }
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var lowerCards: some View {
        HStack(spacing: 12) {
            focusCard
            startTaskCard
        }
        .frame(maxHeight: .infinity)
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("今日专注事项", systemImage: "scope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text.primary.color)
                Spacer()
                Button("编辑") { presentsFocusPicker = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityLabel("选择今日专注事项")
            }

            if let task = model.focusTask {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text.primary.color)
                            .lineLimit(1)
                        categoryChip(task.category)
                        Spacer()
                        if let deadline = task.deadline {
                            Text(deadlineLabel(deadline))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(deadline < .now ? theme.text.failure.color : theme.text.secondary.color)
                        }
                    }
                    Text(task.detail.isEmpty ? "把今天最重要的一件事留在视线中央。" : task.detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                        .lineLimit(2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                }
            } else {
                Button { presentsFocusPicker = true } label: {
                    Label("从今日任务中选择一项专注事项", systemImage: "star")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.interactiveAccent.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.card.fill.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card.fill.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: theme.card.shadow.color.color.opacity(0.72), radius: 9, y: 4)
    }

    private var startTaskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Label("开始任务", systemImage: "play.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                    Text("（将打开番茄闹钟）")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer()
                Text("进行中 \(model.inProgressTasks.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
            }

            if model.inProgressTasks.isEmpty {
                Label("将待开始任务拖入“进行中”后即可开始", systemImage: "arrow.right")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
                    .frame(maxWidth: .infinity, minHeight: 51)
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(model.inProgressTasks.prefix(2))) { task in
                        startTaskRow(task)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 51, alignment: .top)
            }

            Button(action: startSelectedTask) {
                Label("开始任务", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(selectedStartTask == nil ? 0.62 : 1))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(
                        selectedStartTask == nil
                            ? theme.text.weak.color.opacity(0.28)
                            : theme.interactiveAccent.color,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedStartTask == nil)
            .accessibilityHint("打开番茄钟并使用任务的预计时长")
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card.fill.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: theme.card.shadow.color.color.opacity(0.72), radius: 9, y: 4)
    }

    private func startTaskRow(_ task: DailyTask) -> some View {
        Button { selectedStartTaskID = task.id } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedStartTaskID == task.id ? "record.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
                Text(task.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                    .lineLimit(1)
                Spacer()
                Text("\(task.estimatedMinutes) 分钟")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                selectedStartTaskID == task.id ? theme.card.selectedFill.color : theme.card.fill.color.opacity(0.65),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var addTaskButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { showAddTask(status: .pending) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(theme.interactiveAccent.color, in: Circle())
                        .shadow(color: theme.interactiveAccent.color.opacity(0.28), radius: 12, y: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加任务")
            }
        }
    }

    private var statusTitle: String {
        if model.todaysTasks.isEmpty { return "等待计划" }
        if completion >= 0.5 { return "状态良好" }
        return model.inProgressTasks.isEmpty ? "准备开始" : "稳步推进"
    }

    private var statusSubtitle: String {
        if model.todaysTasks.isEmpty { return "添加第一项任务" }
        if completion >= 0.5 { return "继续保持专注，稳步推进" }
        return model.inProgressTasks.isEmpty ? "选择一项任务开始行动" : "正在朝今日目标前进"
    }

    private var selectedStartTask: DailyTask? {
        model.inProgressTasks.first { $0.id == selectedStartTaskID }
    }

    private func showAddTask(status: DailyTaskStatus) {
        addTaskStatus = status
        presentsAddTask = true
    }

    private func startSelectedTask() {
        guard let task = selectedStartTask else { return }
        onStartFocus(.init(
            title: task.title,
            plannedMinutes: task.estimatedMinutes,
            deadline: task.deadline
        ))
    }

    private func selectFirstRunningTaskIfNeeded() {
        if selectedStartTask == nil {
            selectedStartTaskID = model.inProgressTasks.first?.id
        }
    }

    private func categoryChip(_ category: String) -> some View {
        Text(category)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(theme.interactiveAccent.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.interactiveAccent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func deadlineLabel(_ deadline: Date) -> String {
        if Calendar.current.isDateInToday(deadline) {
            return "截止 今天 \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInTomorrow(deadline) {
            return "截止 明天 \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        return "截止 \(deadline.formatted(date: .numeric, time: .shortened))"
    }
}

private struct DailyTaskProgressRing: View {
    let progress: Double
    let theme: ThemeDefinition

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.interactiveAccent.color.opacity(0.14), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [theme.auxiliaryAccent.color, theme.interactiveAccent.color], center: .center),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary.color)
                .monospacedDigit()
        }
        .frame(width: 64, height: 64)
    }
}

private struct DailyTaskLinearProgress: View {
    let progress: Double
    let theme: ThemeDefinition

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.text.weak.color.opacity(0.14))
                Capsule()
                    .fill(theme.interactiveAccent.color)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

private struct DailyTaskBoardColumn: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let status: DailyTaskStatus
    let tasks: [DailyTask]
    let theme: ThemeDefinition
    let rowHeight: CGFloat
    let onRemove: (DailyTask) -> Void
    let onEdit: (DailyTask) -> Void
    let onDropTask: (UUID) -> Bool
    let onAdd: () -> Void

    @State private var isDropTargeted = false
    @State private var hoveredTaskID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: status.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(iconForeground)
                    .frame(width: 22, height: 22)
                    .background(iconBackground, in: Circle())
                Text(status.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text.primary.color)
                Text("\(tasks.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.secondary.color)
                    .frame(minWidth: 23, minHeight: 23)
                    .background(theme.shortcut.fill.color, in: Circle())
                Spacer()
                if status != .completed {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.text.weak.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 44)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        DailyTaskBoardRow(
                            task: task,
                            theme: theme,
                            rowHeight: rowHeight,
                            onRemove: { onRemove(task) },
                            onEdit: { onEdit(task) },
                            onHoverChange: { isHovered in
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                                    if isHovered {
                                        hoveredTaskID = task.id
                                    } else if hoveredTaskID == task.id {
                                        hoveredTaskID = nil
                                    }
                                }
                            }
                        )
                        .draggable(task.id.uuidString)

                        if task.id != tasks.last?.id {
                            Rectangle()
                                .fill(theme.card.border.color.opacity(0.60))
                                .frame(height: 1)
                                .padding(.horizontal, 14)
                        }
                    }

                    if tasks.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "arrow.down.to.line.compact")
                                .font(.system(size: 17, weight: .medium))
                            Text(status == .pending ? "添加今天的第一项任务" : "将任务拖到这里")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(theme.text.weak.color)
                        .frame(maxWidth: .infinity, minHeight: 182)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)

            Button(action: onAdd) {
                Label("添加任务", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.interactiveAccent.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(theme.card.fill.color.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isDropTargeted ? theme.card.selectedFill.color : theme.card.fill.color.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? theme.interactiveAccent.color.opacity(0.65) : theme.card.border.color.opacity(0.82), lineWidth: isDropTargeted ? 1.5 : 1)
        }
        .shadow(color: theme.card.shadow.color.color.opacity(0.62), radius: 9, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first, let id = UUID(uuidString: rawID) else { return false }
            return onDropTask(id)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                if let tooltipTask,
                   let index = tasks.firstIndex(where: { $0.id == tooltipTask.id }) {
                    tooltipBubble(for: tooltipTask)
                        .offset(
                            x: tooltipXOffset(
                                containerWidth: proxy.size.width,
                                tooltipWidth: tooltipWidth(for: tooltipTask.title)
                            ),
                            y: 44 + (CGFloat(index) * (rowHeight + 1)) - 31
                        )
                        .transition(
                            .opacity.combined(
                                with: .scale(scale: 0.97, anchor: tooltipScaleAnchor)
                            )
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .zIndex(tooltipTask == nil ? 0 : 100)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.title)看板，\(tasks.count) 项任务")
    }

    private var tooltipTask: DailyTask? {
        guard let hoveredTaskID,
              let task = tasks.first(where: { $0.id == hoveredTaskID }),
              titleNeedsTooltip(task.title) else { return nil }
        return task
    }

    private func titleNeedsTooltip(_ title: String) -> Bool {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        return (title as NSString).size(withAttributes: [.font: font]).width > 118
    }

    private func tooltipWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 22
    }

    private func tooltipXOffset(containerWidth: CGFloat, tooltipWidth: CGFloat) -> CGFloat {
        switch status {
        case .pending:
            return 14
        case .inProgress:
            return (containerWidth - tooltipWidth) / 2
        case .completed:
            return containerWidth - tooltipWidth - 14
        }
    }

    private var tooltipScaleAnchor: UnitPoint {
        switch status {
        case .pending: .bottomLeading
        case .inProgress: .bottom
        case .completed: .bottomTrailing
        }
    }

    private func tooltipBubble(for task: DailyTask) -> some View {
        VStack(spacing: -4) {
            Text(task.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.tooltip.text.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    tooltipFill,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .shadow(color: theme.tooltip.shadow.color, radius: 10, y: 5)

            Rectangle()
                .fill(tooltipFill)
                .frame(width: 8, height: 8)
                .rotationEffect(.degrees(45))
                .offset(x: tooltipPointerOffset(for: task.title))
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var tooltipFill: Color {
        theme.tooltip.fill.color.opacity(reduceTransparency ? 0.98 : 0.82)
    }

    private func tooltipPointerOffset(for title: String) -> CGFloat {
        let edgeInset: CGFloat = 19
        let halfWidth = tooltipWidth(for: title) / 2
        switch status {
        case .pending:
            return -(halfWidth - edgeInset)
        case .inProgress:
            return 0
        case .completed:
            return halfWidth - edgeInset
        }
    }

    private var iconForeground: Color {
        switch status {
        case .pending: theme.interactiveAccent.color
        case .inProgress: .orange
        case .completed: .white
        }
    }

    private var iconBackground: Color {
        switch status {
        case .pending: theme.interactiveAccent.color.opacity(0.12)
        case .inProgress: Color.orange.opacity(0.14)
        case .completed: theme.text.success.color
        }
    }
}

private struct DailyTaskBoardRow: View {
    let task: DailyTask
    let theme: ThemeDefinition
    let rowHeight: CGFloat
    let onRemove: () -> Void
    let onEdit: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(task.status == .completed ? theme.text.secondary.color : theme.text.primary.color)
                    .strikethrough(task.status == .completed, color: theme.text.secondary.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(task.category)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(theme.interactiveAccent.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.interactiveAccent.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if task.priority == .urgent || task.priority == .high {
                        Text(task.priority.title)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(task.priority == .urgent ? theme.text.failure.color : .orange)
                    }
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.text.failure.color)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除任务 \(task.title)")
            } else {
                Text(trailingText)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(trailingColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered in
            self.isHovered = isHovered
            onHoverChange(isHovered)
        }
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title)，\(task.status.title)，\(trailingText)")
        .accessibilityHint("双击编辑；长按可拖动到其他看板")
    }

    private var trailingText: String {
        if task.status == .completed { return "今天完成" }
        if task.status == .inProgress { return "预计 \(task.estimatedMinutes) 分钟" }
        guard let deadline = task.deadline else { return "\(task.estimatedMinutes) 分钟" }
        if Calendar.current.isDateInToday(deadline) {
            return "截止 今天\n\(deadline.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInTomorrow(deadline) {
            return "截止 明天\n\(deadline.formatted(date: .omitted, time: .shortened))"
        }
        return deadline.formatted(date: .abbreviated, time: .shortened)
    }

    private var trailingColor: Color {
        guard let deadline = task.deadline, task.status != .completed, deadline < .now else {
            return theme.text.secondary.color
        }
        return theme.text.failure.color
    }
}

private struct DailyTaskEditorSheet: View {
    private enum DropdownField {
        case dueDay
        case dueTime
        case category
        case priority
        case status
    }

    @Environment(\.dismiss) private var dismiss
    let task: DailyTask?
    let theme: ThemeDefinition
    let onCancel: () -> Void
    let onSave: (DailyTaskDraft) -> Void

    @State private var draft: DailyTaskDraft
    @State private var dueDate: Date? = Calendar.current.startOfDay(for: .now)
    @State private var dueTime = "18:00"
    @State private var expandedField: DropdownField?

    init(
        initialStatus: DailyTaskStatus,
        task: DailyTask?,
        isFocusTask: Bool,
        theme: ThemeDefinition,
        onCancel: @escaping () -> Void,
        onSave: @escaping (DailyTaskDraft) -> Void
    ) {
        self.task = task
        self.theme = theme
        self.onCancel = onCancel
        self.onSave = onSave
        let initialDraft = task.map { DailyTaskDraft(task: $0, isFocusTask: isFocusTask) }
            ?? DailyTaskDraft(status: initialStatus)
        _draft = State(initialValue: initialDraft)
        if let deadline = initialDraft.deadline {
            _dueDate = State(initialValue: Calendar.current.startOfDay(for: deadline))
            let components = Calendar.current.dateComponents([.hour, .minute], from: deadline)
            _dueTime = State(initialValue: String(format: "%02d:%02d", components.hour ?? 18, components.minute ?? 0))
        } else if task != nil {
            _dueDate = State(initialValue: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(task == nil ? "添加任务" : "编辑任务")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                Spacer()
                Button(action: cancelEditor) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.interactiveAccent.color)
                        .frame(width: 28, height: 28)
                        .background(theme.shortcut.fill.color, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task == nil ? "关闭添加任务" : "关闭编辑任务")
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("任务名称")
                TextField("例如：撰写产品需求文档", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text.primary.color)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(theme.search.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(theme.search.border.color, lineWidth: 1) }
                    .accessibilityIdentifier("daily-tasks.editor.title")
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("任务说明（可选）")
                ZStack(alignment: .topLeading) {
                    if draft.detail.isEmpty {
                        Text("补充任务背景、目标或备注…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.search.placeholder.color)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.text.primary.color)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .background(Color.clear)
                }
                .frame(height: 126)
                .background(theme.search.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(theme.search.border.color, lineWidth: 1) }
                .accessibilityIdentifier("daily-tasks.editor.detail")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("截止日期")
                    dropdown(
                        field: .dueDay,
                        title: dueDateTitle,
                        options: dateOptions,
                        identifier: "daily-tasks.editor.due-day"
                    ) { selected in
                        selectDate(named: selected)
                    }
                }
                .zIndex(expandedField == .dueDay ? 20 : 0)

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("截止时间")
                    dropdown(
                        field: .dueTime,
                        title: dueTime,
                        options: timeOptions,
                        isEnabled: dueDate != nil,
                        identifier: "daily-tasks.editor.due-time"
                    ) { dueTime = $0 }
                }
                .zIndex(expandedField == .dueTime ? 20 : 0)
            }
            .zIndex(20)

            HStack(alignment: .top, spacing: 10) {
                editorDropdownGroup(title: "分类", field: .category) {
                    dropdown(
                        field: .category,
                        title: draft.category,
                        options: ["工作", "学习", "健康", "个人成长"],
                        identifier: "daily-tasks.editor.category"
                    ) { draft.category = $0 }
                }
                editorDropdownGroup(title: "优先级", field: .priority) {
                    dropdown(
                        field: .priority,
                        title: draft.priority.title,
                        options: DailyTaskPriority.allCases.map(\.title),
                        identifier: "daily-tasks.editor.priority"
                    ) { selected in
                        guard let priority = DailyTaskPriority.allCases.first(where: { $0.title == selected }) else { return }
                        draft.priority = priority
                    }
                }
                editorDropdownGroup(title: "状态", field: .status) {
                    dropdown(
                        field: .status,
                        title: draft.status.title,
                        options: DailyTaskStatus.allCases.map(\.title),
                        identifier: "daily-tasks.editor.status"
                    ) { selected in
                        guard let status = DailyTaskStatus.allCases.first(where: { $0.title == selected }) else { return }
                        draft.status = status
                        if status == .completed { draft.isFocusTask = false }
                    }
                }
            }
            .zIndex(10)

            Button {
                draft.isFocusTask.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: draft.isFocusTask ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.interactiveAccent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设为今日专注事项")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.text.primary.color)
                        Text("勾选后会替换当前专注事项")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                    Spacer()
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.orange)
                }
                .padding(.horizontal, 12)
                .frame(height: 45)
                .background(theme.card.selectedFill.color.opacity(draft.isFocusTask ? 1 : 0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(draft.status == .completed)
            .opacity(draft.status == .completed ? 0.48 : 1)
            .zIndex(1)

            HStack(spacing: 12) {
                Button(action: cancelEditor) {
                    Text("取消")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.text.primary.color)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                        .background(theme.shortcut.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("daily-tasks.editor.cancel")
                Button(action: saveEditor) {
                    Text("保存任务")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                        .background(
                            canSave ? theme.interactiveAccent.color : theme.text.weak.color.opacity(0.28),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("daily-tasks.editor.save")
            }
            .zIndex(0)
        }
        .padding(22)
        .frame(width: 492, height: 614)
        .background {
            ZStack {
                theme.panel.fallback.color
                Circle()
                    .fill(theme.interactiveAccent.color.opacity(0.045))
                    .frame(width: 240, height: 240)
                    .blur(radius: 70)
                    .offset(x: 190, y: -250)
            }
        }
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.text.secondary.color)
    }

    private func editorDropdownGroup<Content: View>(
        title: String,
        field: DropdownField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            content()
        }
        .zIndex(expandedField == field ? 20 : 0)
    }

    private func dropdown(
        field: DropdownField,
        title: String,
        options: [String],
        isEnabled: Bool = true,
        identifier: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        DailyTaskDropdown(
            title: title,
            options: options,
            isExpanded: expandedField == field,
            isEnabled: isEnabled,
            theme: theme,
            identifier: identifier,
            onToggle: {
                withAnimation(.easeInOut(duration: 0.14)) {
                    expandedField = expandedField == field ? nil : field
                }
            },
            onSelect: { option in
                onSelect(option)
                expandedField = nil
            }
        )
    }

    private var timeOptions: [String] {
        stride(from: 0, through: 23 * 60 + 30, by: 30).map { minute in
            String(format: "%02d:%02d", minute / 60, minute % 60)
        }
    }

    private var dateOptions: [String] {
        ["不设截止"] + (0..<14).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now)) else {
                return nil
            }
            return dateTitle(for: date)
        }
    }

    private var dueDateTitle: String {
        guard let dueDate else { return "不设截止" }
        return dateTitle(for: dueDate)
    }

    private func dateTitle(for date: Date) -> String {
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(date) {
            prefix = "今天"
        } else if calendar.isDateInTomorrow(date) {
            prefix = "明天"
        } else {
            let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            prefix = weekdayNames[max(0, min(calendar.component(.weekday, from: date) - 1, 6))]
        }
        return "\(prefix) · \(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private func selectDate(named title: String) {
        guard title != "不设截止" else {
            dueDate = nil
            return
        }
        guard let index = dateOptions.firstIndex(of: title), index > 0 else { return }
        dueDate = Calendar.current.date(
            byAdding: .day,
            value: index - 1,
            to: Calendar.current.startOfDay(for: .now)
        )
    }

    private func cancelEditor() {
        expandedField = nil
        dismiss()
        onCancel()
    }

    private func saveEditor() {
        guard canSave else { return }
        draft.deadline = selectedDeadline
        dismiss()
        onSave(draft)
    }

    private var selectedDeadline: Date? {
        guard let dueDate else { return nil }
        let calendar = Calendar.current
        let timeParts = dueTime.split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 2 else { return nil }
        return calendar.date(bySettingHour: timeParts[0], minute: timeParts[1], second: 0, of: dueDate)
    }
}

private struct DailyTaskDropdown: View {
    let title: String
    let options: [String]
    let isExpanded: Bool
    let isEnabled: Bool
    let theme: ThemeDefinition
    let identifier: String
    let onToggle: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.primary.color)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(isEnabled ? theme.interactiveAccent.color : theme.text.weak.color)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
                .background(theme.search.fill.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isExpanded ? theme.interactiveAccent.color.opacity(0.65) : theme.search.border.color, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.46)
            .accessibilityIdentifier(identifier)

            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(options, id: \.self) { option in
                            Button { onSelect(option) } label: {
                                Text(option)
                                    .font(.system(size: 10.5, weight: option == title ? .semibold : .medium))
                                    .foregroundStyle(option == title ? theme.interactiveAccent.color : theme.text.primary.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .contentShape(Rectangle())
                                    .background(
                                        option == title ? theme.card.selectedFill.color : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.visible)
                .frame(height: min(CGFloat(options.count) * 32 + 10, 164))
                .background(theme.panel.fallback.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.card.border.color, lineWidth: 1)
                }
                .shadow(color: theme.card.hoverShadow.color.color, radius: 12, y: 7)
                .offset(y: 40)
                .zIndex(100)
            }
        }
        .frame(height: 36, alignment: .top)
        .zIndex(isExpanded ? 100 : 0)
    }
}

private struct DailyTaskFocusPicker: View {
    let tasks: [DailyTask]
    let selectedID: UUID?
    let theme: ThemeDefinition
    let onSelect: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日专注事项")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("每次只能选择一项，新选择会自动替换")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .foregroundStyle(theme.interactiveAccent.color)
                        .frame(width: 28, height: 28)
                        .background(theme.shortcut.fill.color, in: Circle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 7) {
                    Button { onSelect(nil) } label: {
                        focusRow(title: "暂不设置", category: "", isSelected: selectedID == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(tasks) { task in
                        Button { onSelect(task.id) } label: {
                            focusRow(title: task.title, category: task.category, isSelected: selectedID == task.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(24)
        .frame(width: 440, height: 390)
        .foregroundStyle(theme.text.primary.color)
        .background(theme.panel.fallback.color)
    }

    private func focusRow(title: String, category: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(theme.interactiveAccent.color)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.text.primary.color)
                .lineLimit(1)
            Spacer()
            if !category.isEmpty {
                Text(category)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.interactiveAccent.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(isSelected ? theme.card.selectedFill.color : theme.card.fill.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
