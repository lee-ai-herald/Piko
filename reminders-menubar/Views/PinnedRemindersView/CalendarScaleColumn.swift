import SwiftUI
import EventKit

struct MonthViewportFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct MonthCellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Month Calendar View (Grid + Quadrant Dots + Drag Drop + Selected Day Tasks)

@MainActor
struct MonthCalendarScaleView: View {
    let hoveredDropDateKey: String?
    let onSelectTaskForEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared

    private let weekdayHeaders = ["一", "二", "三", "四", "五", "六", "日"]
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var monthTitle: String {
        RmbFormatters.yearMonthChinese.string(from: pinnedStore.displayedMonthDate)
    }

    private var calendarCells: [Date?] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: pinnedStore.displayedMonthDate)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }

        // Convert Sunday=1..Saturday=7 to Monday=0..Sunday=6
        let firstWeekday = (cal.component(.weekday, from: firstOfMonth) + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: firstWeekday)

        for day in range {
            var dComps = comps
            dComps.day = day
            result.append(cal.date(from: dComps))
        }

        while result.count % 7 != 0 {
            result.append(nil)
        }
        return result
    }

    var body: some View {
        let displayedYear = Calendar.current.component(.year, from: pinnedStore.displayedMonthDate)
        let itemsByDateKey = pinnedStore.itemsByDateKey(forYear: displayedYear)

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(monthTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    Text("拖入排期")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Weekday headers
                LazyVGrid(columns: gridColumns, spacing: 4) {
                    ForEach(weekdayHeaders, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)

                // Month day grid
                LazyVGrid(columns: gridColumns, spacing: 4) {
                    ForEach(Array(calendarCells.enumerated()), id: \.offset) { _, maybeDate in
                        if let date = maybeDate {
                            let dateKey = PinnedTaskSchedule.dateKey(for: date)
                            monthDayCell(for: date, dateKey: dateKey, tasks: itemsByDateKey[dateKey] ?? [])
                        } else {
                            Color.clear.frame(height: 44)
                        }
                    }
                }
                .padding(.horizontal, 10)

                Divider().opacity(0.35).padding(.horizontal, 10)

                // Selected Day Tasks List
                selectedDayTasksSection(items: itemsByDateKey[pinnedStore.selectedDateKey] ?? pinnedStore.itemsCovering(date: pinnedStore.selectedDate))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MonthViewportFrameKey.self,
                    value: proxy.frame(in: .named("tripleBoardRoot"))
                )
            }
        )
    }

    private func monthDayCell(for date: Date, dateKey: String, tasks: [ReminderItem]) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(date)
        let isSelected = cal.isDate(date, inSameDayAs: pinnedStore.selectedDate)
        let isDropTarget = hoveredDropDateKey == dateKey
        let dayNum = cal.component(.day, from: date)

        let dominantColor: Color? = tasks
            .sorted { $0.reminder.ekPriority.sortRank < $1.reminder.ekPriority.sortRank }
            .first?.reminder.ekPriority.quadrantColor

        return VStack(spacing: 4) {
            Text("\(dayNum)")
                .font(.system(size: 11.5, weight: isToday || isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isToday ? .white : (isSelected ? .accentColor : .primary))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isToday ? Color.red : Color.clear)
                )

            // Up to 3 quadrant-colored micro dots (completed tasks shown in soft muted green)
            HStack(spacing: 2.5) {
                ForEach(Array(tasks.prefix(3))) { item in
                    Circle()
                        .fill(item.reminder.isCompleted ? Color.green.opacity(0.55) : item.reminder.ekPriority.quadrantColor)
                        .frame(width: 4.5, height: 4.5)
                }
                if tasks.count > 3 {
                    Text("+")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isDropTarget
                        ? Color.accentColor.opacity(0.20)
                        : (isSelected
                           ? Color.accentColor.opacity(0.11)
                           : (dominantColor?.opacity(min(0.14, 0.05 + Double(tasks.count) * 0.03)) ?? Color.primary.opacity(0.025)))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isDropTarget
                        ? Color.accentColor
                        : (isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.05)),
                    style: isDropTarget ? StrokeStyle(lineWidth: 1.4, dash: [4, 2]) : StrokeStyle(lineWidth: isSelected ? 1.2 : 0.6)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            pinnedStore.selectDate(date)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MonthCellFramesKey.self,
                    value: [dateKey: proxy.frame(in: .named("tripleBoardRoot"))]
                )
            }
        )
    }

    private func selectedDayTasksSection(items: [ReminderItem]) -> some View {
        let dayStr = RmbFormatters.monthDayChinese.string(from: pinnedStore.selectedDate)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(dayStr) 任务")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("\(items.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer()
            }

            if items.isEmpty {
                Text("当日暂无排期任务，可从左侧拖入日历格子")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.vertical, 4)
            } else {
                ForEach(items) { item in
                    let color = item.reminder.ekPriority.quadrantColor
                    let sched = pinnedStore.effectiveSchedule(for: item)
                    let isDone = item.reminder.isCompleted || pinnedStore.isCompleting(item.id)

                    HStack(spacing: 7) {
                        InstantCompleteCircle(color: color, isCompleted: isDone) {
                            pinnedStore.toggleComplete(item)
                        }

                        Text(item.reminder.title ?? "")
                            .font(.system(size: 12, weight: isDone ? .regular : .medium))
                            .strikethrough(isDone, color: .secondary)
                            .foregroundColor(isDone ? .secondary : .primary)
                            .lineLimit(1)

                        Spacer()

                        if sched.spanDays > 1 {
                            Text("\(sched.spanDays)天")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(isDone ? .secondary : color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill((isDone ? Color.green : color).opacity(0.14)))
                        }

                        if !isDone {
                            Button {
                                let comps = Calendar.current.dateComponents([.hour], from: Date())
                                let startMin = max(7, min(21, comps.hour ?? 9)) * 60
                                pinnedStore.setTimeSlot(for: item.id, on: pinnedStore.selectedDate, startMinute: startMin)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(color)
                            }
                            .buttonStyle(.plain)
                            .help("排入右栏当日时段")
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isDone ? Color.green.opacity(0.065) : color.opacity(0.11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isDone ? Color.green.opacity(0.22) : color.opacity(0.25), lineWidth: 0.75)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectTaskForEdit(item)
                    }
                }
            }
        }
    }
}

// MARK: - Year Heatmap Scale View (12-Month Quadrant Heatmap + Annual Task Index)

@MainActor
struct YearHeatmapScaleView: View {
    let onSelectTaskForEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared

    var body: some View {
        let year = pinnedStore.displayedYear
        let yearTasks = pinnedStore.itemsInYear(year)
        let itemsByDateKey = pinnedStore.itemsByDateKey(forYear: year)

        GeometryReader { geo in
            let colCount = geo.size.width < 290 ? 2 : 3
            let monthColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: colCount)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text("\(String(year))年 专注热力图")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(yearTasks.count) 项")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    // Adaptive 2x6 or 3x4 Mini Month Heatmaps
                    LazyVGrid(columns: monthColumns, spacing: 8) {
                        ForEach(1...12, id: \.self) { month in
                            miniMonthHeatmapCard(year: year, month: month, itemsByDateKey: itemsByDateKey)
                        }
                    }
                    .padding(.horizontal, 10)

                    Divider().opacity(0.35).padding(.horizontal, 10)

                    // Annual Scheduled Task List
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(String(year))年 任务列表")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)

                        if yearTasks.isEmpty {
                            Text("该年度暂无排期任务")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.vertical, 4)
                        } else {
                            ForEach(yearTasks, id: \.item.id) { entry in
                                let color = entry.item.reminder.ekPriority.quadrantColor
                                let dateLabel = RmbFormatters.monthDay.string(from: entry.startDate)

                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 7, height: 7)

                                    Text(dateLabel)
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(color)
                                        .frame(width: 34, alignment: .leading)

                                    Text(entry.item.reminder.title ?? "")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)

                                    Spacer()

                                    if entry.spanDays > 1 {
                                        Text("\(entry.spanDays)天")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(color.opacity(0.09))
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    pinnedStore.selectDate(entry.startDate)
                                    onSelectTaskForEdit(entry.item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func miniMonthHeatmapCard(
        year: Int,
        month: Int,
        itemsByDateKey: [String: [ReminderItem]]
    ) -> some View {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1

        let firstDay = cal.date(from: comps) ?? Date()
        let dayCount = cal.range(of: .day, in: .month, for: firstDay)?.count ?? 30
        let leadingPad = (cal.component(.weekday, from: firstDay) + 5) % 7
        let isCurrentMonth = cal.component(.year, from: Date()) == year && cal.component(.month, from: Date()) == month

        var cells: [Date?] = Array(repeating: nil, count: leadingPad)
        for day in 1...dayCount {
            var dc = comps
            dc.day = day
            cells.append(cal.date(from: dc))
        }

        let miniCols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(month)月")
                    .font(.system(size: 10.5, weight: isCurrentMonth ? .bold : .semibold))
                    .foregroundColor(isCurrentMonth ? .accentColor : .primary)
                Spacer()
            }

            LazyVGrid(columns: miniCols, spacing: 2) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, maybeDate in
                    if let date = maybeDate {
                        let dateKey = PinnedTaskSchedule.dateKey(for: date)
                        let tasks = itemsByDateKey[dateKey] ?? []
                        let isToday = cal.isDateInToday(date)
                        let isSelected = cal.isDate(date, inSameDayAs: pinnedStore.selectedDate)
                        let cellColor = heatmapColor(for: tasks)

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellColor)
                            .frame(height: 8.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(
                                        isToday ? Color.red : (isSelected ? Color.accentColor : Color.clear),
                                        lineWidth: isToday || isSelected ? 1 : 0
                                    )
                            )
                            .onTapGesture {
                                pinnedStore.selectDate(date)
                            }
                    } else {
                        Color.clear.frame(height: 8.5)
                    }
                }
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrentMonth ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCurrentMonth ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 0.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            pinnedStore.openMonthInMonthView(year: year, month: month)
        }
    }

    private func heatmapColor(for tasks: [ReminderItem]) -> Color {
        guard !tasks.isEmpty else {
            return Color.primary.opacity(0.065)
        }
        let dominant = tasks
            .sorted { $0.reminder.ekPriority.sortRank < $1.reminder.ekPriority.sortRank }
            .first?.reminder.ekPriority.quadrantColor ?? .accentColor

        let intensity: Double
        switch tasks.count {
        case 1:
            intensity = 0.55
        case 2:
            intensity = 0.78
        default:
            intensity = 1.0
        }
        return dominant.opacity(intensity)
    }
}

private extension EKReminderPriority {
    var sortRank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        default: return 3
        }
    }
}
