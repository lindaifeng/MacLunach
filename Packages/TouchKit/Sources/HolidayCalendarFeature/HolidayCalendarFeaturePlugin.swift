import Foundation
import TouchFeatureAPI

/// 不依赖系统日历权限的节假日能力。官方调休与国际纪念日采用不同来源标识，避免混淆。
public struct HolidayCalendarFeaturePlugin: FeaturePlugin {
    public static let id = "me.touch.holiday-calendar"

    public init() {}

    public let manifest = FeatureManifest(
        id: HolidayCalendarFeaturePlugin.id,
        name: "节假日历",
        summary: "国内假期与国际节日",
        symbolName: "calendar.badge.clock",
        defaultOrder: 5,
        defaultShortcut: .init(modifiers: [], key: "6"),
        executionMode: .inProcess,
        primaryAction: .perform,
        settingsPresentation: .none
    )

    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult { .presentPanel(featureID: Self.id) }
}

public enum HolidayKind: String, Codable, Equatable, Sendable {
    case chinaOfficial
    case chinaWorkday
    case international
}

public struct HolidayEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let name: String
    public let kind: HolidayKind

    public init(date: Date, name: String, kind: HolidayKind) {
        self.date = date
        self.name = name
        self.kind = kind
        id = "\(date.timeIntervalSince1970)-\(name)"
    }
}

public enum HolidayCalendar {
    public static func entries(for year: Int, calendar: Calendar = .current) -> [HolidayEntry] {
        var entries = internationalEntries(for: year, calendar: calendar)
        if year == 2026 {
            entries += china2026Entries(calendar: calendar)
        } else {
            entries += [
                entry(year, 1, 1, "元旦", .chinaOfficial, calendar),
                entry(year, 5, 1, "劳动节", .chinaOfficial, calendar),
                entry(year, 10, 1, "国庆节", .chinaOfficial, calendar)
            ]
        }
        return entries.sorted { $0.date < $1.date }
    }

    private static func internationalEntries(for year: Int, calendar: Calendar) -> [HolidayEntry] {
        [
            entry(year, 1, 1, "New Year's Day", .international, calendar),
            entry(year, 2, 14, "Valentine's Day", .international, calendar),
            entry(year, 3, 8, "International Women's Day", .international, calendar),
            entry(year, 4, 22, "Earth Day", .international, calendar),
            entry(year, 6, 1, "International Children's Day", .international, calendar),
            entry(year, 10, 31, "Halloween", .international, calendar),
            entry(year, 12, 25, "Christmas Day", .international, calendar)
        ]
    }

    private static func china2026Entries(calendar: Calendar) -> [HolidayEntry] {
        let holidays: [(ClosedRange<Int>, Int, String)] = [
            (1...3, 1, "元旦假期"), (15...23, 2, "春节假期"),
            (4...6, 4, "清明节假期"), (1...5, 5, "劳动节假期"),
            (19...21, 6, "端午节假期"), (25...27, 9, "中秋节假期"),
            (1...7, 10, "国庆节假期")
        ]
        var result = holidays.flatMap { days, month, _ in
            days.map { entry(2026, month, $0, holidayName(month, day: $0), .chinaOfficial, calendar) }
        }
        result += [
            entry(2026, 1, 4, "调休上班", .chinaWorkday, calendar),
            entry(2026, 2, 14, "调休上班", .chinaWorkday, calendar),
            entry(2026, 2, 28, "调休上班", .chinaWorkday, calendar),
            entry(2026, 5, 9, "调休上班", .chinaWorkday, calendar),
            entry(2026, 9, 20, "调休上班", .chinaWorkday, calendar),
            entry(2026, 10, 10, "调休上班", .chinaWorkday, calendar)
        ]
        return result
    }

    private static func holidayName(_ month: Int, day: Int) -> String {
        switch month {
        case 1: "元旦假期"
        case 2: "春节假期"
        case 4: "清明节假期"
        case 5: "劳动节假期"
        case 6: "端午节假期"
        case 9: "中秋节假期"
        case 10: "国庆节假期"
        default: "法定节假日"
        }
    }

    private static func entry(
        _ year: Int, _ month: Int, _ day: Int, _ name: String,
        _ kind: HolidayKind, _ calendar: Calendar
    ) -> HolidayEntry {
        HolidayEntry(date: calendar.date(from: .init(year: year, month: month, day: day))!, name: name, kind: kind)
    }
}
