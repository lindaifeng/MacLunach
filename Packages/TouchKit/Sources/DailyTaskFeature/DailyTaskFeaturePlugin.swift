import AppKit
import EventKit
import Foundation
import SwiftUI
import TouchFeatureAPI

public struct DailyTaskFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.daily-tasks"

    private let storage: any FeatureStorage

    public init(storage: any FeatureStorage) {
        self.storage = storage
    }

    public let manifest = FeatureManifest(
        id: DailyTaskFeaturePlugin.id,
        name: "每日任务",
        summary: "安排今天的日程与任务",
        symbolName: "checklist",
        defaultOrder: 3,
        defaultShortcut: .init(modifiers: [], key: "4"),
        configurationSchemaVersion: DailyTaskRepository.schemaVersion,
        capabilities: .init(optional: [.notifications]),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .none
    )

    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}

public enum DailyTaskStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case inProgress
    case completed

    public var title: String {
        switch self {
        case .pending: "待开始"
        case .inProgress: "进行中"
        case .completed: "已完成"
        }
    }
}

public enum DailyTaskPriority: String, Codable, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
    case urgent

    public var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .urgent: "紧急"
        }
    }
}

public struct DailyTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var scheduledDate: Date
    public var startMinute: Int?
    public var estimatedMinutes: Int
    public var status: DailyTaskStatus
    public var priority: DailyTaskPriority
    public var category: String
    public var deadline: Date?

    public var isCompleted: Bool {
        get { status == .completed }
        set {
            if newValue {
                status = .completed
            } else if status == .completed {
                status = .pending
            }
        }
    }

    public init(
        id: UUID = UUID(), title: String, scheduledDate: Date,
        detail: String = "", startMinute: Int? = nil, estimatedMinutes: Int = 25,
        status: DailyTaskStatus? = nil, priority: DailyTaskPriority = .medium,
        category: String = "工作", deadline: Date? = nil, isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.scheduledDate = scheduledDate
        self.startMinute = startMinute
        self.estimatedMinutes = estimatedMinutes
        self.status = isCompleted ? .completed : (status ?? .pending)
        self.priority = priority
        self.category = category
        self.deadline = deadline
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case scheduledDate
        case startMinute
        case estimatedMinutes
        case status
        case priority
        case category
        case deadline
        case isCompleted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        scheduledDate = try container.decode(Date.self, forKey: .scheduledDate)
        startMinute = try container.decodeIfPresent(Int.self, forKey: .startMinute)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 25
        let legacyCompletion = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        status = try container.decodeIfPresent(DailyTaskStatus.self, forKey: .status)
            ?? (legacyCompletion ? .completed : .pending)
        priority = try container.decodeIfPresent(DailyTaskPriority.self, forKey: .priority) ?? .medium
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "工作"
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(scheduledDate, forKey: .scheduledDate)
        try container.encodeIfPresent(startMinute, forKey: .startMinute)
        try container.encode(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encode(isCompleted, forKey: .isCompleted)
    }
}

public struct DailyTaskConfiguration: Codable, Equatable, Sendable {
    public var tasks: [DailyTask]
    public var focusTaskID: UUID?

    public init(tasks: [DailyTask] = [], focusTaskID: UUID? = nil) {
        self.tasks = tasks
        self.focusTaskID = focusTaskID
    }

    public mutating func add(_ task: DailyTask, asFocusTask: Bool = false) {
        tasks.append(task)
        if asFocusTask, task.status != .completed {
            focusTaskID = task.id
        }
    }

    @discardableResult
    public mutating func moveTask(id: UUID, to destination: DailyTaskStatus) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let source = tasks[index].status
        guard destination != source else { return false }
        var movedTask = tasks.remove(at: index)
        movedTask.status = destination
        let destinationStart = tasks.firstIndex { $0.status == destination } ?? tasks.endIndex
        tasks.insert(movedTask, at: destinationStart)
        if destination == .completed, focusTaskID == id {
            focusTaskID = nil
        }
        return true
    }

    public mutating func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        if focusTaskID == id {
            focusTaskID = nil
        }
    }

    @discardableResult
    public mutating func selectFocusTask(id: UUID?) -> Bool {
        guard let id else {
            focusTaskID = nil
            return true
        }
        guard tasks.contains(where: { $0.id == id && $0.status != .completed }) else {
            return false
        }
        focusTaskID = id
        return true
    }
}

public struct DailyTaskRepository: Sendable {
    public static let schemaVersion = 1
    private let storage: any FeatureStorage
    public init(storage: any FeatureStorage) { self.storage = storage }
    public func load() throws -> DailyTaskConfiguration {
        guard let snapshot = try storage.loadConfiguration() else { return .init() }
        guard snapshot.schemaVersion == Self.schemaVersion else { return .init() }
        return try JSONDecoder().decode(DailyTaskConfiguration.self, from: snapshot.data)
    }
    public func save(_ configuration: DailyTaskConfiguration) throws {
        try storage.saveConfiguration(.init(
            schemaVersion: Self.schemaVersion,
            data: try JSONEncoder().encode(configuration)
        ))
    }
}

@MainActor
public struct DailyTaskSettingsProvider: FeatureSettingsProvider {
    private let repository: DailyTaskRepository
    public init(storage: any FeatureStorage) { repository = DailyTaskRepository(storage: storage) }
    public func makeSettingsView(context: FeatureSettingsContext) -> AnyView {
        AnyView(DailyTaskSettingsView(repository: repository, context: context))
    }
}

private struct DailyTaskSettingsView: View {
    private let repository: DailyTaskRepository
    private let context: FeatureSettingsContext
    @State private var configuration: DailyTaskConfiguration
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var draftTitle = ""
    @State private var draftStartTime = Date()
    @State private var draftEstimatedMinutes = 25
    @State private var systemEvents: [SystemCalendarEvent] = []

    init(repository: DailyTaskRepository, context: FeatureSettingsContext) {
        self.repository = repository
        self.context = context
        _configuration = State(initialValue: (try? repository.load()) ?? .init())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedDate.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                        .font(.system(size: 19, weight: .bold))
                    Text(progressText).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    dateStepButton(symbol: "chevron.left", offset: -1)
                    Button("今天") { selectedDate = Calendar.current.startOfDay(for: .now) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    dateStepButton(symbol: "chevron.right", offset: 1)
                }
                .accessibilityIdentifier("daily-tasks.date")
            }

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("日程", systemImage: "calendar").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("系统日历", action: openSystemCalendar)
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor).accessibilityIdentifier("daily-tasks.open-system-calendar")
                }
                HStack(spacing: 8) {
                    ForEach(-3...3, id: \.self) { offset in
                        let date = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate)!
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        Button { selectedDate = Calendar.current.startOfDay(for: date) } label: {
                            VStack(spacing: 4) {
                                Text(date.formatted(.dateTime.weekday(.narrow)))
                                Text(date.formatted(.dateTime.day())).fontWeight(isSelected ? .bold : .medium)
                                Circle().fill(tasks(for: date).isEmpty ? Color.clear : Color.accentColor).frame(width: 4, height: 4)
                            }
                            .font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 48)
                            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }
                if SystemCalendarReader.authorizationStatus == .fullAccess {
                    ForEach(systemEvents) { event in
                        Label(event.title, systemImage: "circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("系统日程未显示，请在“设置 → 权限”中统一管理")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("任务清单").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(tasks(for: selectedDate).count) 项").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(tasks(for: selectedDate)) { task in
                    HStack(spacing: 10) {
                        Button { update(task) { $0.isCompleted.toggle() } } label: {
                            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isCompleted ? Color.green : Color.secondary)
                        }.buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).font(.system(size: 13, weight: .medium)).strikethrough(task.isCompleted)
                            Text(task.estimatedMinutes == 25 ? "一个番茄" : "预计 \(task.estimatedMinutes) 分钟")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let startMinute = task.startMinute {
                            Text(timeLabel(startMinute)).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.accentColor).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                        Button("开始番茄") {
                            context.startFocusSession(.init(
                                title: task.title,
                                plannedMinutes: task.estimatedMinutes,
                                deadline: task.deadline
                            ))
                        }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("daily-tasks.start-focus.\(task.id.uuidString)")
                        Button { delete(task) } label: { Image(systemName: "trash").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("删除任务 \(task.title)")
                    }
                    .padding(11)
                    .background(Color.primary.opacity(task.isCompleted ? 0.025 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if tasks(for: selectedDate).isEmpty {
                    Label("这一天还没有任务，留一点空白也很好。", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.vertical, 14)
                        .frame(maxWidth: .infinity).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("快速添加").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("写下要完成的事", text: $draftTitle).textFieldStyle(.plain).padding(.horizontal, 11).padding(.vertical, 9)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    draftStartTimeSelector
                    Button(action: addTask) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 31, height: 31).background(Color.accentColor, in: Circle()) }
                        .buttonStyle(.plain).disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 7) {
                    Text("专注时长").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach([25, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) 分钟") { draftEstimatedMinutes = minutes }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(draftEstimatedMinutes == minutes ? Color.white : Color.accentColor)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(draftEstimatedMinutes == minutes ? Color.accentColor : Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
        .onChange(of: configuration) { _, value in try? repository.save(value) }
        .onChange(of: selectedDate) { _, date in systemEvents = SystemCalendarReader.events(on: date) }
        .onAppear { systemEvents = SystemCalendarReader.events(on: selectedDate) }
        .accessibilityIdentifier("daily-tasks.settings")
    }

    private func tasks(for date: Date) -> [DailyTask] {
        configuration.tasks.filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: date) }
            .sorted { ($0.startMinute ?? .max) < ($1.startMinute ?? .max) }
    }

    private var progressText: String {
        let dayTasks = tasks(for: selectedDate)
        guard !dayTasks.isEmpty else { return "今天还没有安排" }
        return "已完成 \(dayTasks.filter(\.isCompleted).count) / \(dayTasks.count) 项"
    }

    private var draftStartTimeSelector: some View {
        let components = Calendar.current.dateComponents([.hour, .minute], from: draftStartTime)
        let selectedHour = components.hour ?? 0
        let selectedMinute = components.minute ?? 0

        return HStack(spacing: 2) {
            Menu {
                ForEach(0..<24, id: \.self) { hour in
                    Button { setDraftStartTime(hour: hour) } label: {
                        timeMenuLabel(value: hour, selected: hour == selectedHour)
                    }
                }
            } label: {
                timeSegment(String(format: "%02d", selectedHour))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("开始时间：小时")

            Text(":")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu {
                ForEach(0..<60, id: \.self) { minute in
                    Button { setDraftStartTime(minute: minute) } label: {
                        timeMenuLabel(value: minute, selected: minute == selectedMinute)
                    }
                }
            } label: {
                timeSegment(String(format: "%02d", selectedMinute))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("开始时间：分钟")
        }
        .padding(.horizontal, 7)
        .frame(height: 31)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-tasks.start-time")
    }

    private func timeSegment(_ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 2)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func timeMenuLabel(value: Int, selected: Bool) -> some View {
        Group {
            if selected {
                Label(String(format: "%02d", value), systemImage: "checkmark")
            } else {
                Text(String(format: "%02d", value))
            }
        }
    }

    private func setDraftStartTime(hour: Int? = nil, minute: Int? = nil) {
        var components = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: draftStartTime
        )
        components.hour = hour ?? components.hour ?? 0
        components.minute = minute ?? components.minute ?? 0
        guard let updatedTime = Calendar.current.date(from: components) else { return }
        draftStartTime = updatedTime
    }

    private func dateStepButton(symbol: String, offset: Int) -> some View {
        Button {
            let nextDate = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) ?? selectedDate
            selectedDate = Calendar.current.startOfDay(for: nextDate)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func openSystemCalendar() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
            configuration: .init()
        )
    }

    private func addTask() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let components = Calendar.current.dateComponents([.hour, .minute], from: draftStartTime)
        let startMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        configuration.tasks.append(.init(
            title: title,
            scheduledDate: selectedDate,
            startMinute: startMinute,
            estimatedMinutes: draftEstimatedMinutes
        ))
        draftTitle = ""
    }
    private func update(_ task: DailyTask, change: (inout DailyTask) -> Void) {
        guard let index = configuration.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        change(&configuration.tasks[index])
    }

    private func delete(_ task: DailyTask) {
        configuration.tasks.removeAll { $0.id == task.id }
    }

    private func timeLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct SystemCalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
}

private enum SystemCalendarReader {
    static var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static func events(on date: Date) -> [SystemCalendarEvent] {
        guard authorizationStatus == .fullAccess else { return [] }
        let store = EKEventStore()
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: calendar.startOfDay(for: date), end: end, calendars: nil))
            .prefix(3)
            .map { .init(id: $0.eventIdentifier, title: $0.title) }
    }
}
