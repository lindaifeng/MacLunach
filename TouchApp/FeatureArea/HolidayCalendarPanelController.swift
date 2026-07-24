import AppKit
import HolidayCalendarFeature
import SwiftUI

@MainActor
final class HolidayCalendarPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let onClose: () -> Void

    init(themeStore: ThemeStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
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
        panel.contentView = NSHostingView(
            rootView: HolidayCalendarPanelView()
                .environmentObject(themeStore)
        )
        installWindowTopDragRegion(in: panel)
    }

    func show() {
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

private struct HolidayCalendarPanelView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var month = Self.firstDay(of: .now)
    @State private var selectedDate: Date?

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private var entries: [HolidayEntry] {
        HolidayCalendar.entries(for: calendar.component(.year, from: month), calendar: calendar)
    }

    var body: some View {
        ZStack {
            PanelThemeBackground(theme: theme, reduceTransparency: reduceTransparency, themeColorOpacity: 0.97)

            VStack(spacing: 14) {
                header
                HStack(alignment: .top, spacing: 0) {
                    calendarContent
                    if let selectedDate {
                        selectedDayPanel(selectedDate)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 920, minHeight: 640)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.panel.edgeBorder.color, lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.22), value: selectedDate)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(monthTitle)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                    .accessibilityIdentifier("holiday-calendar.month-title")
                Text("农历、国内假期与国际节日")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }

            Spacer()

            Button("今天") {
                month = Self.firstDay(of: .now)
                selectedDate = .now
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.accent.color)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(theme.accent.color.opacity(0.1), in: Capsule())

            HStack(spacing: 4) {
                monthStep(symbol: "chevron.left", amount: -1)
                monthStep(symbol: "chevron.right", amount: 1)
            }
            .padding(3)
            .background(theme.card.fill.color.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(theme.card.border.color.opacity(0.65), lineWidth: 1))
        }
        .padding(.leading, 58)
    }

    private var calendarContent: some View {
        VStack(spacing: 8) {
            weekdayHeader
            monthGrid
            footer
        }
        .padding(.trailing, selectedDate == nil ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(["周日", "周一", "周二", "周三", "周四", "周五", "周六"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(day == "周日" || day == "周六" ? theme.accent.color : theme.text.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(gridDays, id: \.self) { date in
                dayCell(date)
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let isCurrentMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let matches = entriesForDay(date)

        return Button {
            selectedDate = date
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text("\(calendar.component(.day, from: date))")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isToday ? Color.white : isSelected ? theme.accent.color : theme.text.primary.color)
                        .frame(width: 25, height: 25)
                        .background(isToday ? theme.accent.color : Color.clear, in: Circle())
                    Spacer(minLength: 2)
                    Text(lunarText(for: date))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.text.weak.color)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(matches.prefix(2)) { entry in
                        Text(shortHolidayName(entry))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(color(for: entry.kind))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                            .background(color(for: entry.kind).opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if matches.isEmpty {
                        Spacer(minLength: 16)
                    }
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(
                isSelected ? theme.accent.color.opacity(0.1) : theme.card.fill.color.opacity(isCurrentMonth ? 0.48 : 0.2),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? theme.accent.color.opacity(0.38) : theme.card.border.color.opacity(0.46), lineWidth: 1)
            }
            .opacity(isCurrentMonth ? 1 : 0.48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(date, matches: matches))
    }

    private func selectedDayPanel(_ date: Date) -> some View {
        let matches = entriesForDay(date)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("当天详情")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.secondary.color)
                Spacer()
                iconButton(symbol: "xmark", label: "关闭日期详情") { selectedDate = nil }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 48, weight: .light, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                Text(numericDateText(date))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text.primary.color)
                Text("\(weekdayText(date)) · 农历\(fullLunarText(for: date))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }

            Rectangle()
                .fill(theme.card.border.color.opacity(0.65))
                .frame(height: 1)

            Text("节假日")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text.secondary.color)

            if matches.isEmpty {
                Label("当天没有节假日安排", systemImage: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.weak.color)
                    .padding(.top, 8)
            } else {
                ForEach(matches) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: entry.kind))
                            .frame(width: 4, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localizedHolidayName(entry))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.text.primary.color)
                            Text(kindTitle(entry.kind))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(theme.text.secondary.color)
                        }
                    }
                }
            }

            Spacer()
            Text(sourceCaption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.text.weak.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .frame(width: 244)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card.fill.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(theme.card.border.color.opacity(0.65), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 13) {
            legendItem("国内放假", .chinaOfficial)
            legendItem("调休上班", .chinaWorkday)
            legendItem("国际节日", .international)
            Spacer()
            Text(sourceCaption)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(theme.text.weak.color)
                .lineLimit(1)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private var gridDays: [Date] {
        let weekdayOffset = calendar.component(.weekday, from: month) - 1
        let start = calendar.date(byAdding: .day, value: -weekdayOffset, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var monthTitle: String {
        "\(calendar.component(.year, from: month)) 年 \(calendar.component(.month, from: month)) 月"
    }

    private var sourceCaption: String {
        calendar.component(.year, from: month) == 2026
            ? "国内排期依据 2026 年国务院办公厅公告"
            : "非 2026 年仅显示固定节日，不代表官方调休"
    }

    private func monthStep(symbol: String, amount: Int) -> some View {
        Button {
            month = calendar.date(byAdding: .month, value: amount, to: month).map(Self.firstDay(of:)) ?? month
            selectedDate = nil
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text.secondary.color)
        .accessibilityLabel(amount < 0 ? "上个月" : "下个月")
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(theme.text.secondary.color)
                .frame(width: 29, height: 29)
                .background(theme.card.fill.color.opacity(0.8), in: Circle())
                .overlay(Circle().stroke(theme.card.border.color.opacity(0.65), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func legendItem(_ title: String, _ kind: HolidayKind) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color(for: kind)).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(theme.text.secondary.color)
    }

    private func entriesForDay(_ date: Date) -> [HolidayEntry] {
        entries.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }

    private func lunarText(for date: Date) -> String {
        let components = lunarComponents(date)
        guard let month = components.month, let day = components.day else { return "" }
        if day == 1 { return lunarMonthName(month, isLeap: components.isLeapMonth ?? false) }
        return lunarDayName(day)
    }

    private func fullLunarText(for date: Date) -> String {
        let components = lunarComponents(date)
        guard let month = components.month, let day = components.day else { return "" }
        return lunarMonthName(month, isLeap: components.isLeapMonth ?? false) + lunarDayName(day)
    }

    private func lunarComponents(_ date: Date) -> DateComponents {
        Calendar(identifier: .chinese).dateComponents([.month, .day, .isLeapMonth], from: date)
    }

    private func lunarMonthName(_ month: Int, isLeap: Bool) -> String {
        let names = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        guard names.indices.contains(month - 1) else { return "" }
        return (isLeap ? "闰" : "") + names[month - 1]
    }

    private func lunarDayName(_ day: Int) -> String {
        let names = [
            "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
        ]
        guard names.indices.contains(day - 1) else { return "" }
        return names[day - 1]
    }

    private func shortHolidayName(_ entry: HolidayEntry) -> String {
        let name = localizedHolidayName(entry)
        if entry.kind == .chinaWorkday { return "调休上班" }
        return name.replacingOccurrences(of: "假期", with: "")
    }

    private func localizedHolidayName(_ entry: HolidayEntry) -> String {
        let translations = [
            "New Year's Day": "元旦",
            "Valentine's Day": "情人节",
            "International Women's Day": "国际妇女节",
            "Earth Day": "世界地球日",
            "International Children's Day": "国际儿童节",
            "Halloween": "万圣节",
            "Christmas Day": "圣诞节"
        ]
        return translations[entry.name] ?? entry.name
    }

    private func numericDateText(_ date: Date) -> String {
        "\(calendar.component(.year, from: date)) 年 \(calendar.component(.month, from: date)) 月 \(calendar.component(.day, from: date)) 日"
    }

    private func weekdayText(_ date: Date) -> String {
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    private func kindTitle(_ kind: HolidayKind) -> String {
        switch kind {
        case .chinaOfficial: "国内法定假期"
        case .chinaWorkday: "调休工作日"
        case .international: "国际节日"
        }
    }

    private func dayAccessibilityLabel(_ date: Date, matches: [HolidayEntry]) -> String {
        let holidays = matches.map(localizedHolidayName).joined(separator: "、")
        return [numericDateText(date), "农历\(fullLunarText(for: date))", holidays]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    private func color(for kind: HolidayKind) -> Color {
        switch kind {
        case .chinaOfficial: theme.accent.color
        case .chinaWorkday: theme.text.failure.color
        case .international: theme.auxiliaryAccent.color
        }
    }

    private static func firstDay(of date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}
