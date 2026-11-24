import SwiftUI
import EventKit

@MainActor
struct ReminderEditView: View {
    enum Mode {
        case create
        case edit(EKReminder, reminderHasChildren: Bool)
    }

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @Binding var isPresented: Bool

    let mode: Mode
    @State private var title: String
    @State private var notes: String
    @State private var priority: EKReminderPriority
    @State private var selectedCalendar: EKCalendar?

    // Intuitive Date Range state (Start Date → End Date)
    @State private var hasDate: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var calendarMonth: Date
    @State private var isPickingRangeEnd = false
    @State private var showingRangeCalendar = false

    // Optional daily time slot & recurrence
    @State private var hasTimeSlot: Bool
    @State private var slotStartMinute: Int
    @State private var slotDurationMinutes: Int
    @State private var recurrence: RmbRecurrenceOption

    @State private var showingRemoveAlert = false

    private let initialHasDate: Bool
    private let initialStartDate: Date
    private let initialEndDate: Date
    private let initialRecurrence: RmbRecurrenceOption
    private let initialStartDateKey: String?

    private let baseDurationChoices = [30, 60, 90, 120, 180]
    private let baseRecurrenceChoices: [(option: RmbRecurrenceOption, label: String)] = [
        (.none, "不重复"),
        (.daily, "每天"),
        (.weekly, "每周"),
        (.monthly, "每月"),
        (.yearly, "每年")
    ]

    private var slotStartMinuteChoices: [Int] {
        var values = Array(stride(from: 7 * 60, through: 22 * 60 + 45, by: 15))
        if !values.contains(slotStartMinute) {
            values.append(slotStartMinute)
            values.sort()
        }
        return values
    }

    private var durationChoices: [Int] {
        var values = baseDurationChoices
        if !values.contains(slotDurationMinutes) {
            values.append(slotDurationMinutes)
            values.sort()
        }
        return values
    }

    private var recurrenceChoices: [(option: RmbRecurrenceOption, label: String)] {
        if recurrence == .custom {
            return baseRecurrenceChoices + [(.custom, "自定义")]
        }
        return baseRecurrenceChoices
    }

    private var reminderHasChildren: Bool {
        if case .edit(_, let hasChildren) = mode {
            return hasChildren
        }
        return false
    }

    private var isCreateMode: Bool {
        if case .create = mode { return true }
        return false
    }

    private var computedSpanDays: Int {
        max(1, PinnedTaskSchedule.dayDifference(from: startDate, to: endDate) + 1)
    }

    init(isPresented: Binding<Bool>, reminder: EKReminder, reminderHasChildren: Bool = false) {
        self.mode = .edit(reminder, reminderHasChildren: reminderHasChildren)
        _isPresented = isPresented

        let store = PinnedRemindersStore.shared
        let item = ReminderItem(for: reminder)
        let sched = store.effectiveSchedule(for: item)

        _title = State(initialValue: reminder.title ?? "")
        _notes = State(initialValue: reminder.notes ?? "")
        _priority = State(initialValue: reminder.ekPriority)
        _selectedCalendar = State(initialValue: reminder.calendar)
        let initialRecurrenceOption = RmbRecurrenceOption(from: reminder.recurrenceRules)
        _recurrence = State(initialValue: initialRecurrenceOption)

        let resolvedStart = Calendar.current.startOfDay(for: sched.startDate ?? reminder.resolvedDueDate ?? Date())
        let resolvedEnd = Calendar.current.date(byAdding: .day, value: max(0, sched.spanDays - 1), to: resolvedStart) ?? resolvedStart
        let initialDateExists = sched.startDate != nil || reminder.resolvedDueDate != nil
        _hasDate = State(initialValue: initialDateExists)
        _startDate = State(initialValue: resolvedStart)
        _endDate = State(initialValue: resolvedEnd)
        _calendarMonth = State(initialValue: resolvedStart)

        self.initialHasDate = initialDateExists
        self.initialStartDate = resolvedStart
        self.initialEndDate = resolvedEnd
        self.initialRecurrence = initialRecurrenceOption
        self.initialStartDateKey = initialDateExists ? PinnedTaskSchedule.dateKey(for: resolvedStart) : nil

        let targetKey = PinnedTaskSchedule.dateKey(for: resolvedStart)
        if let slot = sched.daySlots[targetKey] {
            _hasTimeSlot = State(initialValue: true)
            _slotStartMinute = State(initialValue: slot.startMinute)
            _slotDurationMinutes = State(initialValue: slot.durationMinutes)
        } else {
            let curHour = Calendar.current.component(.hour, from: Date())
            _hasTimeSlot = State(initialValue: false)
            _slotStartMinute = State(initialValue: max(7, min(21, curHour + 1)) * 60)
            _slotDurationMinutes = State(initialValue: 60)
        }
    }

    private var editableCalendars: [EKCalendar] {
        var result = pinnedStore.syncedCalendars
        if case .edit(let reminder, _) = mode,
           let current = reminder.calendar,
           !result.contains(where: { $0.calendarIdentifier == current.calendarIdentifier }) {
            result.insert(current, at: 0)
        }
        return result.isEmpty ? pinnedStore.availableCalendars : result
    }

    init(isPresented: Binding<Bool>) {
        self.mode = .create
        _isPresented = isPresented

        let today = Calendar.current.startOfDay(for: Date())
        _title = State(initialValue: "")
        _notes = State(initialValue: "")
        _priority = State(initialValue: .none)
        _selectedCalendar = State(initialValue: PinnedRemindersStore.shared.defaultSavingCalendar ?? RemindersService.shared.getDefaultCalendar())
        _recurrence = State(initialValue: .none)
        _hasDate = State(initialValue: false)
        _startDate = State(initialValue: today)
        _endDate = State(initialValue: today)
        _calendarMonth = State(initialValue: today)

        self.initialHasDate = false
        self.initialStartDate = today
        self.initialEndDate = today
        self.initialRecurrence = .none
        self.initialStartDateKey = nil

        let curHour = Calendar.current.component(.hour, from: Date())
        _hasTimeSlot = State(initialValue: false)
        _slotStartMinute = State(initialValue: max(7, min(21, curHour + 1)) * 60)
        _slotDurationMinutes = State(initialValue: 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(priority.quadrantColor)
                        .frame(width: 8, height: 8)
                    Text(isCreateMode ? "新建任务" : "编辑任务")
                        .font(.system(size: 14, weight: .semibold))
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Card 1: Title & Notes
                    VStack(spacing: 0) {
                        TextField("输入任务名称…", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .onSubmit { confirmAction() }

                        Divider().opacity(0.4).padding(.horizontal, 10)

                        PlaceholderNoteTextView(
                            text: $notes,
                            placeholder: "添加备注、步骤或参考链接…",
                            fontSize: 12,
                            horizontalInset: 8,
                            verticalInset: 8,
                            lineSpacing: 2.5
                        )
                        .frame(minHeight: 62, maxHeight: 88)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
                    )

                    // Card 2: Eisenhower 4-Quadrant Selector
                    ReminderPriorityEditView(priority: $priority)

                    // Card 3: Crystal-Clear Visual Date Range & Schedule
                    dateRangeScheduleCard

                    // Card 4: Calendar List Pills (only if user has > 1 synced list)
                    if !reminderHasChildren && editableCalendars.count > 1 {
                        calendarPillsSection
                    }
                }
                .padding(18)
            }

            Divider().opacity(0.4)

            // Bottom Action Bar
            HStack(spacing: 8) {
                if case .edit(let reminder, _) = mode {
                    Button {
                        showingRemoveAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("删除")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.red.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .alert(isPresented: $showingRemoveAlert) {
                        Alert(
                            title: Text("删除此任务？"),
                            message: Text("将从 Apple 提醒事项中永久移除「\(reminder.title ?? "")」。"),
                            primaryButton: .destructive(Text("删除")) {
                                pinnedStore.removeItem(reminder)
                                isPresented = false
                            },
                            secondaryButton: .cancel(Text("取消"))
                        )
                    }

                    Button {
                        PomodoroService.shared.focusOnTask(
                            id: reminder.calendarItemIdentifier,
                            title: title.isEmpty ? (reminder.title ?? "") : title
                        )
                        isPresented = false
                        PinnedPanelController.shared.snapPomodoroToTopRightCorner()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 11))
                            Text("专注")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.12)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    confirmAction()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: PinnedPanelController.shared.isCornerMiniMode ? 330 : 400)
        .frame(maxHeight: PinnedPanelController.shared.isCornerMiniMode ? 480 : 620)
        .onAppear {
            if isCreateMode, selectedCalendar == nil {
                selectedCalendar = pinnedStore.defaultSavingCalendar
                    ?? RemindersService.shared.getDefaultCalendar()
                    ?? editableCalendars.first
            }
        }
    }

    // MARK: - Intuitive Date Range Card (Start → End Visual Range Picker!)

    private var dateRangeScheduleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日期范围与排期")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                // Row 1: Clear Visual Start → End Range Bar (click to open/close full-width range calendar!)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if !hasDate {
                            hasDate = true
                            startDate = Calendar.current.startOfDay(for: Date())
                            endDate = startDate
                            calendarMonth = startDate
                        }
                        showingRangeCalendar.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(hasDate ? .accentColor : .secondary)

                        if hasDate {
                            HStack(spacing: 6) {
                                Text(formatMonthDay(startDate))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.primary)

                                if computedSpanDays > 1 {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(.secondary)

                                    Text(formatMonthDay(endDate))
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                }

                                Text(computedSpanDays == 1 ? "当天" : "共 \(computedSpanDays) 天")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                            }
                        } else {
                            Text("点击选择日期或日期范围…")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: showingRangeCalendar ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hasDate ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(showingRangeCalendar ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Row 2: 4 Unambiguous Quick Range Presets
                HStack(spacing: 6) {
                    quickRangePill("今天", isSelected: hasDate && computedSpanDays == 1 && Calendar.current.isDateInToday(startDate)) {
                        applyQuickRange(startOffset: 0, days: 1)
                    }
                    quickRangePill("明天", isSelected: hasDate && computedSpanDays == 1 && Calendar.current.isDateInTomorrow(startDate)) {
                        applyQuickRange(startOffset: 1, days: 1)
                    }
                    quickRangePill("连做 3 天", isSelected: hasDate && computedSpanDays == 3 && Calendar.current.isDateInToday(startDate)) {
                        applyQuickRange(startOffset: 0, days: 3)
                    }
                    quickRangePill("本周内", isSelected: isThisWeekRangeSelected) {
                        applyThisWeekRange()
                    }

                    if hasDate {
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                hasDate = false
                                hasTimeSlot = false
                                showingRangeCalendar = false
                                isPickingRangeEnd = false
                                recurrence = .none
                            }
                        } label: {
                            Text("清除")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4.5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Expandable Full-Width 2-Click Interactive Range Calendar!
                if showingRangeCalendar && hasDate {
                    RangeCalendarPickerView(
                        displayedMonth: $calendarMonth,
                        startDate: $startDate,
                        endDate: $endDate,
                        isPickingEnd: $isPickingRangeEnd
                    )
                }

                if hasDate {
                    Divider().opacity(0.35)

                    // Row 3: Optional Daily Time Slot
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("安排具体时段", systemImage: "clock")
                                .font(.system(size: 12))
                                .foregroundColor(.primary)

                            Spacer()

                            if hasTimeSlot {
                                Text("\(DayTimeSlot.formatMinute(slotStartMinute))–\(DayTimeSlot.formatMinute(min(24 * 60, slotStartMinute + slotDurationMinutes)))")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.accentColor)
                            }

                            Toggle("", isOn: $hasTimeSlot)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        if hasTimeSlot {
                            HStack(spacing: 8) {
                                Picker("", selection: $slotStartMinute) {
                                    ForEach(slotStartMinuteChoices, id: \.self) { min in
                                        Text(DayTimeSlot.formatMinute(min)).tag(min)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)

                                Spacer()

                                HStack(spacing: 4) {
                                    ForEach(durationChoices, id: \.self) { dur in
                                        let selected = slotDurationMinutes == dur
                                        Button {
                                            slotDurationMinutes = dur
                                        } label: {
                                            Text(DayTimeSlot.formatDuration(dur))
                                                .font(.system(size: 10.5, weight: selected ? .semibold : .regular, design: .monospaced))
                                                .foregroundColor(selected ? .white : .secondary)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.06))
                                                )
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    Divider().opacity(0.35)

                    // Row 4: Clean Recurrence Pills
                    VStack(alignment: .leading, spacing: 6) {
                        Label("重复", systemImage: "repeat")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)

                        HStack(spacing: 5) {
                            ForEach(recurrenceChoices, id: \.label) { entry in
                                let selected = recurrence == entry.option
                                Button {
                                    recurrence = entry.option
                                } label: {
                                    Text(entry.label)
                                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .white : .secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                                .fill(selected ? Color.accentColor : Color.primary.opacity(0.055))
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
        }
    }

    private var calendarPillsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("所属清单")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(editableCalendars, id: \.calendarIdentifier) { cal in
                        let isSelected = selectedCalendar?.calendarIdentifier == cal.calendarIdentifier
                        let calColor = Color(cal.color)
                        Button {
                            selectedCalendar = cal
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(calColor)
                                    .frame(width: 7.5, height: 7.5)
                                Text(cal.title)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? .primary : .secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                    .fill(isSelected ? calColor.opacity(0.16) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                    .strokeBorder(isSelected ? calColor.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: isSelected ? 1.2 : 0.75)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func quickRangePill(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applyQuickRange(startOffset: Int, days: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let s = cal.date(byAdding: .day, value: startOffset, to: today) ?? today
        let e = cal.date(byAdding: .day, value: max(0, days - 1), to: s) ?? s
        withAnimation(.easeInOut(duration: 0.14)) {
            hasDate = true
            startDate = s
            endDate = e
            calendarMonth = s
            isPickingRangeEnd = false
        }
    }

    private var isThisWeekRangeSelected: Bool {
        guard hasDate, Calendar.current.isDateInToday(startDate) else { return false }
        let cal = Calendar.current
        let weekday = (cal.component(.weekday, from: Date()) + 5) % 7 // Mon=0..Sun=6
        let expectedDays = max(1, 7 - weekday)
        return computedSpanDays == expectedDays && expectedDays > 1
    }

    private func applyThisWeekRange() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = (cal.component(.weekday, from: today) + 5) % 7
        let daysLeft = max(1, 7 - weekday)
        applyQuickRange(startOffset: 0, days: daysLeft)
    }

    private func formatMonthDay(_ date: Date) -> String {
        RmbFormatters.monthDayChinese.string(from: date)
    }

    // MARK: - Save

    private func confirmAction() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let cal = Calendar.current
        let finalSpan = computedSpanDays
        let finalRecurrence: RmbRecurrenceOption = hasDate ? recurrence : .none

        let dateChanged: Bool = {
            if isCreateMode {
                return hasDate
            }
            if hasDate != initialHasDate {
                return true
            }
            guard hasDate else { return false }
            return !cal.isDate(startDate, inSameDayAs: initialStartDate)
                || !cal.isDate(endDate, inSameDayAs: initialEndDate)
        }()

        let recurrenceChanged: Bool = isCreateMode
            ? (hasDate && finalRecurrence != .none)
            : (finalRecurrence != initialRecurrence)

        var draft = RmbReminder()
        draft.title = trimmed
        draft.notes = notes
        draft.priority = priority
        draft.calendar = selectedCalendar ?? pinnedStore.defaultSavingCalendar ?? RemindersService.shared.getDefaultCalendar()
        draft.hasDateChanges = dateChanged
        draft.hasRecurrenceChanges = recurrenceChanged
        draft.recurrence = finalRecurrence
        draft.hasDueDate = hasDate
        draft.hasTime = false
        draft.date = endDate

        let targetId: String
        switch mode {
        case .create:
            guard let cal = draft.calendar else { return }
            let created = RemindersService.shared.createNew(with: draft, in: cal)
            targetId = created.calendarItemIdentifier
        case .edit(let reminder, _):
            reminder.update(with: draft)
            RemindersService.shared.save(reminder: reminder)
            targetId = reminder.calendarItemIdentifier
        }

        if hasDate {
            let newStartKey = PinnedTaskSchedule.dateKey(for: startDate)
            if let oldKey = initialStartDateKey,
               oldKey != newStartKey,
               let oldDate = PinnedTaskSchedule.date(fromKey: oldKey) {
                pinnedStore.clearTimeSlot(for: targetId, on: oldDate)
            }

            pinnedStore.setDaySpan(
                for: targetId,
                startDate: startDate,
                spanDays: finalSpan,
                syncReminderDueDate: false
            )
            if hasTimeSlot {
                pinnedStore.setTimeSlot(
                    for: targetId,
                    on: startDate,
                    startMinute: slotStartMinute,
                    durationMinutes: slotDurationMinutes
                )
            } else {
                pinnedStore.clearTimeSlot(for: targetId, on: startDate)
            }
        } else {
            pinnedStore.unscheduleCompletely(for: targetId)
        }

        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
        isPresented = false
    }
}

// MARK: - Full-Width Interactive 2-Click Date Range Calendar

private struct RangeCalendarPickerView: View {
    @Binding var displayedMonth: Date
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var isPickingEnd: Bool

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var monthHeaderText: String {
        RmbFormatters.yearMonthChinese.string(from: displayedMonth)
    }

    private var dayCells: [Date?] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }
        let leading = (cal.component(.weekday, from: firstOfMonth) + 5) % 7
        var items: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            var dc = comps
            dc.day = day
            items.append(cal.date(from: dc))
        }
        while items.count % 7 != 0 {
            items.append(nil)
        }
        return items
    }

    var body: some View {
        VStack(spacing: 8) {
            // Month navigation + clear 1-line guidance
            HStack {
                Button {
                    if let prev = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) {
                        displayedMonth = prev
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 1) {
                    Text(monthHeaderText)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(isPickingEnd ? "再点一个更晚日期即可选中连续范围" : "点击开始日期（可连选开始→结束）")
                        .font(.system(size: 10))
                        .foregroundColor(isPickingEnd ? .accentColor : .secondary)
                }

                Spacer()

                Button {
                    if let next = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) {
                        displayedMonth = next
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Weekday row
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(weekdays, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                }
            }

            // Full-width interactive range cells
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(dayCells.enumerated()), id: \.offset) { _, maybeDate in
                    if let date = maybeDate {
                        rangeDayCell(date)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func rangeDayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let normDate = cal.startOfDay(for: date)
        let normStart = cal.startOfDay(for: startDate)
        let normEnd = cal.startOfDay(for: endDate)

        let isStart = normDate == normStart
        let isEnd = normDate == normEnd
        let isSingle = isStart && isEnd
        let isInRange = normDate >= normStart && normDate <= normEnd
        let isToday = cal.isDateInToday(normDate)
        let dayNum = cal.component(.day, from: normDate)

        return Button {
            handleTap(on: normDate)
        } label: {
            ZStack {
                // Continuous range background band
                if isInRange && !isSingle {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(isStart ? Color.clear : Color.accentColor.opacity(0.18))
                        Rectangle()
                            .fill(isEnd ? Color.clear : Color.accentColor.opacity(0.18))
                    }
                    .frame(height: 26)
                }

                // Endpoint circle
                if isStart || isEnd {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 26, height: 26)
                } else if isToday {
                    Circle()
                        .strokeBorder(Color.red.opacity(0.75), lineWidth: 1.2)
                        .frame(width: 26, height: 26)
                }

                Text("\(dayNum)")
                    .font(.system(size: 11.5, weight: (isStart || isEnd || isToday) ? .semibold : .regular, design: .rounded))
                    .foregroundColor((isStart || isEnd) ? .white : (isToday ? .red : .primary))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(on tappedDate: Date) {
        let normStart = Calendar.current.startOfDay(for: startDate)
        if isPickingEnd && tappedDate >= normStart {
            let maxSpanEnd = Calendar.current.date(byAdding: .day, value: 29, to: normStart) ?? tappedDate
            endDate = min(tappedDate, maxSpanEnd)
            isPickingEnd = false
        } else {
            startDate = tappedDate
            endDate = tappedDate
            isPickingEnd = true
        }
    }
}
