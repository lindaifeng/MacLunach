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
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
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
        panel.contentView = NSHostingView(rootView: HolidayCalendarPanelView().environmentObject(themeStore))
        installWindowTopDragRegion(in: panel)
    }

    func show() {
        cancelFeaturePanelDismissal(panel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    func windowDidResignKey(_ notification: Notification) {
        dismissFeaturePanelAfterResigningKey(panel, onHidden: onClose)
    }
}

private struct HolidayCalendarPanelView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selectedDate: Date?
    @State private var focusedMonth = Self.firstDay(of: .now)
    @State private var scrollMetrics = ThemedScrollMetrics()

    private let calendar = Calendar(identifier: .gregorian)
    // 预留足够的前后月份，避免点击月历边缘的相邻日期后找不到目标月份。
    private let monthOffsets = Array(-18...18)

    private var theme: ThemeDefinition { ThemeRegistry.shared.definition(for: themeStore.theme) }
    private var currentMonth: Date { Self.firstDay(of: .now) }
    private var months: [Date] {
        monthOffsets.compactMap { calendar.date(byAdding: .month, value: $0, to: currentMonth).map(Self.firstDay(of:)) }
    }

    var body: some View {
        ZStack {
            PanelThemeBackground(theme: theme, reduceTransparency: reduceTransparency, themeColorOpacity: 0.97)
            VStack(spacing: 12) {
                header
                HStack(alignment: .top, spacing: 14) {
                    GeometryReader { viewport in
                        ZStack(alignment: .trailing) {
                            ScrollViewReader { proxy in
                                ScrollView(.vertical) {
                                    LazyVStack(spacing: 18) {
                                        ForEach(months, id: \.self) { month in
                                            monthSection(month, proxy: proxy).id(month)
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 20)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: ThemedScrollContentMetricsPreferenceKey.self,
                                                value: ThemedScrollContentMetrics(
                                                    height: geometry.size.height,
                                                    minY: geometry.frame(in: .named("holiday-calendar-scroll")).minY
                                                )
                                            )
                                        }
                                    }
                                }
                                .coordinateSpace(name: "holiday-calendar-scroll")
                                .scrollIndicators(.hidden)
                                .background(ThemedScrollIndicatorConfigurator())
                                .onAppear { proxy.scrollTo(currentMonth, anchor: .top) }
                                .onPreferenceChange(MonthSectionOffsetPreferenceKey.self) { offsets in
                                    guard let nearest = offsets.min(by: { abs($0.value) < abs($1.value) })?.key else { return }
                                    guard !calendar.isDate(focusedMonth, equalTo: nearest, toGranularity: .month) else { return }
                                    focusedMonth = nearest
                                }
                                .onPreferenceChange(ThemedScrollContentMetricsPreferenceKey.self) { content in
                                    scrollMetrics = ThemedScrollMetrics(
                                        contentHeight: content.height,
                                        viewportHeight: viewport.size.height,
                                        offset: max(0, -content.minY)
                                    )
                                }
                                .onReceive(NotificationCenter.default.publisher(for: .holidayCalendarScrollToMonth)) { notification in
                                    guard let target = notification.object as? Date else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            ThemedVerticalScrollBar(metrics: scrollMetrics, theme: theme)
                                .padding(.trailing, 2)
                        }
                        .onAppear {
                            scrollMetrics.viewportHeight = viewport.size.height
                        }
                        .onChange(of: viewport.size.height) { _, newHeight in
                            scrollMetrics.viewportHeight = newHeight
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if let selectedDate {
                        selectedDayPanel(selectedDate)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 920, minHeight: 720)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(theme.panel.edgeBorder.color, lineWidth: 1) }
        .animation(.easeInOut(duration: 0.22), value: selectedDate)
        .onChange(of: selectedDate) { _, newValue in
            guard let newValue else { return }
            // 选择相邻月份日期后，等状态更新完成再定位滚动容器，避免按钮
            // 事件与 LazyVStack 布局同时发生时通知被当前布局吞掉。
            let targetMonth = Self.firstDay(of: newValue)
            focusedMonth = targetMonth
            scrollTo(targetMonth)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monthTitle(focusedMonth))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                    .accessibilityIdentifier("holiday-calendar.month-title")
                Text("向下滚动浏览月份 · 农历、国内假期与国际节日")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }
            Spacer()
            Button("今天") { focusedMonth = currentMonth; selectedDate = .now; scrollTo(currentMonth) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(theme.accent.color.opacity(0.12), in: Capsule())
            HStack(spacing: 4) {
                monthStep(symbol: "chevron.left", amount: -1)
                monthStep(symbol: "chevron.right", amount: 1)
            }
            .padding(3)
            .background(theme.card.fill.color.opacity(0.72), in: Capsule())
        }
    }

    private func monthSection(_ month: Date, proxy: ScrollViewProxy) -> some View {
        let entries = HolidayCalendar.entries(for: calendar.component(.year, from: month), calendar: calendar)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(monthTitle(month))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text.primary.color)
                if calendar.isDate(month, equalTo: currentMonth, toGranularity: .month) {
                    Text("本月")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.accent.color.opacity(0.12), in: Capsule())
                }
                Spacer()
                let monthly = entries.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
                if !monthly.isEmpty {
                    Text(monthly.map(localizedHolidayName).uniqued().joined(separator: " · "))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .lineLimit(1)
                }
            }
            weekdayHeader
            LazyVGrid(columns: gridColumns, spacing: 4) {
                ForEach(gridDays(for: month), id: \.self) { date in
                    dayCell(date, month: month, entries: entries, proxy: proxy)
                }
            }
            .padding(8)
            .background(theme.card.fill.color.opacity(0.34), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.card.border.color.opacity(0.45), lineWidth: 1) }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MonthSectionOffsetPreferenceKey.self,
                        value: [month: geometry.frame(in: .named("holiday-calendar-scroll")).minY]
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holiday-calendar.month-section.\(calendar.component(.year, from: month))-\(calendar.component(.month, from: month))")
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(["周日", "周一", "周二", "周三", "周四", "周五", "周六"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(day == "周日" || day == "周六" ? theme.accent.color : theme.text.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
        }
    }

    private func dayCell(_ date: Date, month: Date, entries: [HolidayEntry], proxy: ScrollViewProxy) -> some View {
        let isCurrentMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let matches = entriesForDay(date)
        return Button {
            selectedDate = date
            let targetMonth = Self.firstDay(of: date)
            focusedMonth = targetMonth
            // 月历网格会展示前后月份的相邻日期。点击这些日期时，必须同步把
            // 连续滚动列表定位到真实所属月份，否则标题会被当前可见月份覆盖。
            if !calendar.isDate(targetMonth, equalTo: month, toGranularity: .month) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(targetMonth, anchor: .top)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("\(calendar.component(.day, from: date))")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isToday ? Color.white : isSelected ? theme.accent.color : theme.text.primary.color)
                        .frame(width: 25, height: 25)
                        .background(isToday ? theme.accent.color : Color.clear, in: Circle())
                    Spacer(minLength: 2)
                    Text(lunarText(for: date)).font(.system(size: 9, weight: .medium)).foregroundStyle(theme.text.weak.color)
                }
                ForEach(matches.prefix(2)) { entry in
                    Text(shortHolidayName(entry))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color(for: entry.kind))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                        .background(color(for: entry.kind).opacity(0.28), in: Capsule())
                }
                if matches.isEmpty { Spacer(minLength: 18) }
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(isSelected ? theme.accent.color.opacity(0.12) : theme.card.fill.color.opacity(isCurrentMonth ? 0.48 : 0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? theme.accent.color.opacity(0.5) : theme.card.border.color.opacity(0.35), lineWidth: 1) }
            .opacity(isCurrentMonth ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(date, matches: matches))
    }

    private func selectedDayPanel(_ date: Date) -> some View {
        let matches = entriesForDay(date)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当天详情").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text.secondary.color)
                Spacer()
                iconButton(symbol: "xmark", label: "关闭日期详情") { selectedDate = nil }
            }
            Text("\(calendar.component(.day, from: date))").font(.system(size: 48, weight: .light, design: .rounded)).foregroundStyle(theme.text.primary.color)
            Text(numericDateText(date)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text.primary.color)
            Text("\(weekdayText(date)) · 农历\(fullLunarText(for: date))").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text.secondary.color)
            Rectangle().fill(theme.card.border.color.opacity(0.65)).frame(height: 1)
            Text("节假日").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text.secondary.color)
            if matches.isEmpty {
                Label("当天没有节假日安排", systemImage: "calendar").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text.weak.color)
            } else {
                ForEach(matches) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: entry.kind)).frame(width: 5, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localizedHolidayName(entry)).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text.primary.color)
                            Text(kindTitle(entry.kind)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(theme.text.secondary.color)
                        }
                    }
                }
            }
            Spacer()
            Text(sourceCaption(for: date)).font(.system(size: 9, weight: .medium)).foregroundStyle(theme.text.weak.color)
        }
        .padding(17)
        .frame(width: 244)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card.fill.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var gridColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: 7) }

    private func gridDays(for month: Date) -> [Date] {
        let weekdayOffset = calendar.component(.weekday, from: month) - 1
        let start = calendar.date(byAdding: .day, value: -weekdayOffset, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func monthTitle(_ date: Date) -> String { "\(calendar.component(.year, from: date)) 年 \(calendar.component(.month, from: date)) 月" }
    private func sourceCaption(for date: Date) -> String {
        switch calendar.component(.year, from: date) {
        case ...2026: "国内节假日数据 · 调休以官方公告为准"
        case 2027: "2027 预览节日 · 放假与调休以官方公告为准"
        default: "仅显示基础节日，不代表官方调休"
        }
    }

    private func monthStep(symbol: String, amount: Int) -> some View {
        Button {
            let target = calendar.date(byAdding: .month, value: amount, to: focusedMonth).map(Self.firstDay(of:)) ?? focusedMonth
            focusedMonth = target
            scrollTo(target)
        } label: { Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 27, height: 27) }
            .buttonStyle(.plain).foregroundStyle(theme.text.secondary.color)
            .accessibilityLabel(amount < 0 ? "上个月" : "下个月")
    }

    private func scrollTo(_ month: Date) {
        // 通过通知让当前 ScrollViewReader 在下一次布局时定位；按钮和“今天”均保持可用。
        NotificationCenter.default.post(name: .holidayCalendarScrollToMonth, object: month)
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).frame(width: 29, height: 29) }
            .buttonStyle(.plain).foregroundStyle(theme.text.secondary.color).background(theme.card.fill.color.opacity(0.8), in: Circle()).accessibilityLabel(label)
    }

    private func entriesForDay(_ date: Date) -> [HolidayEntry] { HolidayCalendar.entries(for: calendar.component(.year, from: date), calendar: calendar).filter { calendar.isDate($0.date, inSameDayAs: date) } }
    private func lunarText(for date: Date) -> String { let c = lunarComponents(date); guard let m = c.month, let d = c.day else { return "" }; return d == 1 ? lunarMonthName(m, isLeap: c.isLeapMonth ?? false) : lunarDayName(d) }
    private func fullLunarText(for date: Date) -> String { let c = lunarComponents(date); guard let m = c.month, let d = c.day else { return "" }; return lunarMonthName(m, isLeap: c.isLeapMonth ?? false) + lunarDayName(d) }
    private func lunarComponents(_ date: Date) -> DateComponents { Calendar(identifier: .chinese).dateComponents([.month, .day, .isLeapMonth], from: date) }
    private func lunarMonthName(_ month: Int, isLeap: Bool) -> String { let names = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]; guard names.indices.contains(month - 1) else { return "" }; return (isLeap ? "闰" : "") + names[month - 1] }
    private func lunarDayName(_ day: Int) -> String { let names = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十", "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十", "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]; guard names.indices.contains(day - 1) else { return "" }; return names[day - 1] }
    private func shortHolidayName(_ entry: HolidayEntry) -> String { entry.kind == .chinaWorkday ? "调休上班" : localizedHolidayName(entry).replacingOccurrences(of: "假期", with: "") }
    private func localizedHolidayName(_ entry: HolidayEntry) -> String { ["New Year's Day": "元旦", "Valentine's Day": "情人节", "International Women's Day": "国际妇女节", "Earth Day": "世界地球日", "International Children's Day": "国际儿童节", "Halloween": "万圣节", "Christmas Day": "圣诞节"][entry.name] ?? entry.name }
    private func numericDateText(_ date: Date) -> String { "\(calendar.component(.year, from: date)) 年 \(calendar.component(.month, from: date)) 月 \(calendar.component(.day, from: date)) 日" }
    private func weekdayText(_ date: Date) -> String { ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"][calendar.component(.weekday, from: date) - 1] }
    private func kindTitle(_ kind: HolidayKind) -> String { switch kind { case .chinaOfficial: "国内法定假期"; case .chinaWorkday: "调休工作日"; case .international: "国际节日" } }
    private func dayAccessibilityLabel(_ date: Date, matches: [HolidayEntry]) -> String { [numericDateText(date), "农历\(fullLunarText(for: date))", matches.map(localizedHolidayName).joined(separator: "、")].filter { !$0.isEmpty }.joined(separator: "，") }
    private func color(for kind: HolidayKind) -> Color { switch kind { case .chinaOfficial: theme.accent.color; case .chinaWorkday: theme.auxiliaryAccent.color; case .international: theme.text.secondary.color } }
    private static func firstDay(of date: Date) -> Date { Calendar(identifier: .gregorian).date(from: Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)) ?? date }
}

private extension Notification.Name {
    static let holidayCalendarScrollToMonth = Notification.Name("me.touch.holiday-calendar.scroll-to-month")
}

private struct MonthSectionOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]

    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
