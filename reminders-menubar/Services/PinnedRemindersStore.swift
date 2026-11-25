import SwiftUI
import Combine
import EventKit

enum BoardTab: String, CaseIterable, Identifiable {
    case board
    case pomodoro
    case clipboard
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: return "规划板"
        case .pomodoro: return "番茄钟"
        case .clipboard: return "剪贴板"
        case .notes: return "随笔"
        }
    }

    var miniTitle: String {
        switch self {
        case .board: return "规划"
        case .pomodoro: return "番茄"
        case .clipboard: return "剪贴"
        case .notes: return "随笔"
        }
    }

    var symbol: String {
        switch self {
        case .board: return "rectangle.split.3x1"
        case .pomodoro: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        }
    }

    var miniSymbol: String {
        switch self {
        case .board: return "checklist"
        case .pomodoro: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        }
    }

    var accentColor: Color {
        switch self {
        case .board: return .accentColor
        case .pomodoro: return Color(red: 0.92, green: 0.34, blue: 0.31)
        case .clipboard: return .accentColor
        case .notes: return Color(red: 0.90, green: 0.64, blue: 0.12)
        }
    }
}

struct CompletionUndoToast: Equatable {
    let reminderId: String
    let title: String
}

@MainActor
final class PinnedRemindersStore: ObservableObject {
    static let shared = PinnedRemindersStore()

    private var cancellationTokens: [AnyCancellable] = []
    private var toastDismissWork: DispatchWorkItem?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var lastObservedTodayKey: String = PinnedTaskSchedule.dateKey(for: Date())

    @Published var activeTab: BoardTab = .board
    @Published var calendarScale: CalendarScaleMode = .week
    @Published private(set) var availableCalendars: [EKCalendar] = []
    @Published private(set) var allItems: [ReminderItem] = []
    @Published private(set) var completedItems: [ReminderItem] = []
    @Published private(set) var completingIds: Set<String> = []
    @Published var lastCompletionToast: CompletionUndoToast?
    @Published var schedules: [String: PinnedTaskSchedule]
    @Published var weekStartDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var displayedMonthDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var displayedYear: Int = Calendar.current.component(.year, from: Date())
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var searchText: String = ""
    @Published var priorityFilter: EKReminderPriority?
    @Published var completedTimeRange: CompletedTimeRange {
        didSet {
            UserPreferences.shared.completedTimeRange = completedTimeRange
            if completedTimeRange == .all && oldValue != .all {
                requestRefresh()
            }
        }
    }

    @Published var isPanelVisible: Bool {
        didSet {
            UserPreferences.shared.isPinnedPanelVisible = isPanelVisible
        }
    }

    @Published var isCollapsed: Bool {
        didSet {
            guard isCollapsed != oldValue else { return }
            UserPreferences.shared.isPinnedPanelCollapsed = isCollapsed
            PinnedPanelController.shared.applyCollapsedState(isCollapsed)
        }
    }

    private init() {
        self.schedules = UserPreferences.shared.pinnedSchedules
        self.isPanelVisible = false
        self.isCollapsed = UserPreferences.shared.isPinnedPanelCollapsed
        self.completedTimeRange = UserPreferences.shared.completedTimeRange
        addObservers()
    }

    private func addObservers() {
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged),
            NotificationCenter.default.publisher(for: .remindersDataShouldUpdate)
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.requestRefresh()
        }
        .store(in: &cancellationTokens)

        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.rollDatesForwardIfDayChanged()
            self?.requestRefresh()
        }
        .store(in: &cancellationTokens)

        UserPreferences.shared.$menuBarCounterType
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.updateMenuBarCount()
                }
            }
            .store(in: &cancellationTokens)

        UserPreferences.shared.$excludedReminderCalendarIdentifiers
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.requestRefresh()
            }
            .store(in: &cancellationTokens)
    }

    private func rollDatesForwardIfDayChanged() {
        let newTodayKey = PinnedTaskSchedule.dateKey(for: Date())
        guard newTodayKey != lastObservedTodayKey else { return }
        let oldTodayKey = lastObservedTodayKey
        lastObservedTodayKey = newTodayKey

        if PinnedTaskSchedule.dateKey(for: selectedDate) == oldTodayKey {
            goToToday()
        }
    }

    func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Synced Lists

    var syncedCalendars: [EKCalendar] {
        let excluded = UserPreferences.shared.excludedReminderCalendarIdentifiers
        return availableCalendars.filter { !excluded.contains($0.calendarIdentifier) }
    }

    var hasExcludedCalendars: Bool {
        syncedCalendars.count < availableCalendars.count
    }

    var allCalendarsExcluded: Bool {
        !availableCalendars.isEmpty && syncedCalendars.isEmpty
    }

    /// Resolves the target Apple Reminders list for newly created tasks, ensuring it is currently synced.
    var defaultSavingCalendar: EKCalendar? {
        let calendars = availableCalendars.isEmpty ? RemindersService.shared.getCalendars() : availableCalendars
        let excluded = UserPreferences.shared.excludedReminderCalendarIdentifiers
        let synced = calendars.filter { !excluded.contains($0.calendarIdentifier) }
        guard !synced.isEmpty else { return nil }

        if let preferredId = UserPreferences.shared.preferredCalendarIdentifierForSaving,
           let preferred = synced.first(where: { $0.calendarIdentifier == preferredId }) {
            return preferred
        }
        if let systemDefault = RemindersService.shared.getDefaultCalendar(),
           synced.contains(where: { $0.calendarIdentifier == systemDefault.calendarIdentifier }) {
            return systemDefault
        }
        return synced.first
    }

    // MARK: - Date navigation

    var visibleDays: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStartDate) }
    }

    var selectedDateKey: String {
        PinnedTaskSchedule.dateKey(for: selectedDate)
    }

    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    func selectDate(_ date: Date) {
        let normalized = Calendar.current.startOfDay(for: date)
        selectedDate = normalized
        displayedMonthDate = normalized
        displayedYear = Calendar.current.component(.year, from: normalized)
        let diff = PinnedTaskSchedule.dayDifference(from: weekStartDate, to: normalized)
        if diff < 0 || diff >= 7 {
            weekStartDate = normalized
        }
    }

    func shiftWeek(byDays days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: weekStartDate) {
            weekStartDate = Calendar.current.startOfDay(for: next)
        }
    }

    func shiftDisplayedMonth(byMonths months: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: months, to: displayedMonthDate) {
            displayedMonthDate = Calendar.current.startOfDay(for: next)
            displayedYear = Calendar.current.component(.year, from: displayedMonthDate)
        }
    }

    func shiftDisplayedYear(byYears years: Int) {
        displayedYear += years
    }

    func openMonthInMonthView(year: Int, month: Int) {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            displayedMonthDate = date
            displayedYear = year
            calendarScale = .month
        }
    }

    func itemsCovering(date: Date) -> [ReminderItem] {
        let active = filteredItems.filter { effectiveSchedule(for: $0).covers(date: date) }
        let completed = filteredCompletedItems.filter { effectiveSchedule(for: $0).covers(date: date) }
        return active + completed
    }

    /// Pre-indexed O(N) lookup table mapping `yyyy-MM-dd` -> covered items for fast Month & Year views.
    func itemsByDateKey(forYear year: Int? = nil) -> [String: [ReminderItem]] {
        let cal = Calendar.current
        var map: [String: [ReminderItem]] = [:]
        let combined = filteredItems + filteredCompletedItems

        for item in combined {
            let sched = effectiveSchedule(for: item)
            var seenKeys = Set<String>()

            if let start = sched.startDate {
                let normStart = cal.startOfDay(for: start)
                for offset in 0..<max(1, sched.spanDays) {
                    guard let day = cal.date(byAdding: .day, value: offset, to: normStart) else { continue }
                    if let year, cal.component(.year, from: day) != year { continue }
                    let key = PinnedTaskSchedule.dateKey(for: day)
                    if seenKeys.insert(key).inserted {
                        map[key, default: []].append(item)
                    }
                }
            }

            for key in sched.daySlots.keys where seenKeys.insert(key).inserted {
                if let year, !key.hasPrefix("\(year)-") { continue }
                map[key, default: []].append(item)
            }
        }
        return map
    }

    func itemsInYear(_ year: Int) -> [(item: ReminderItem, startDate: Date, spanDays: Int)] {
        let cal = Calendar.current
        return (filteredItems + filteredCompletedItems).compactMap { item in
            let sched = effectiveSchedule(for: item)
            guard let start = sched.startDate, let end = sched.endDate else {
                return nil
            }
            let startYear = cal.component(.year, from: start)
            let endYear = cal.component(.year, from: end)
            guard startYear <= year && endYear >= year else {
                return nil
            }
            return (item, start, sched.spanDays)
        }
        .sorted { $0.startDate < $1.startDate }
    }

    func shiftSelectedDate(byDays days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectDate(next)
        }
    }

    func goToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        weekStartDate = today
        displayedMonthDate = today
        displayedYear = Calendar.current.component(.year, from: today)
        selectedDate = today
    }

    // MARK: - Task Queries (All Incomplete Reminders Live Directly in the Board)

    var filteredItems: [ReminderItem] {
        applySearchAndPriorityFilter(to: allItems)
    }

    var filteredCompletedItems: [ReminderItem] {
        applySearchAndPriorityFilter(to: completedItems)
    }

    /// Completed items filtered by the user's selected time range (`今日` / `近 7 天` / `近 30 天`).
    var rangedCompletedItems: [ReminderItem] {
        filteredCompletedItems.filter { completedTimeRange.includes($0.reminder.completionDate) }
    }

    private func applySearchAndPriorityFilter(to source: [ReminderItem]) -> [ReminderItem] {
        let byPriority: [ReminderItem]
        if let priorityFilter {
            byPriority = source.filter { $0.reminder.ekPriority == priorityFilter }
        } else {
            byPriority = source
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return byPriority }
        return byPriority.filter { item in
            let title = (item.reminder.title ?? "").lowercased()
            let notes = (item.reminder.notes ?? "").lowercased()
            return title.contains(q) || notes.contains(q)
        }
    }

    func isCompleting(_ id: String) -> Bool {
        completingIds.contains(id)
    }

    func completionTimeText(for reminder: EKReminder) -> String {
        guard let date = reminder.completionDate else { return "已完成" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "刚刚"
        } else if Calendar.current.isDateInToday(date) {
            return RmbFormatters.hourMinute.string(from: date)
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        } else {
            return RmbFormatters.monthDay.string(from: date)
        }
    }

    /// Effective schedule for an item: uses user's explicit schedule, or falls back to its Apple Reminders due date.
    func effectiveSchedule(for item: ReminderItem) -> PinnedTaskSchedule {
        if let stored = schedules[item.id] {
            return stored
        }
        if let dueDate = item.reminder.resolvedDueDate {
            let key = PinnedTaskSchedule.dateKey(for: dueDate)
            var slots: [String: DayTimeSlot] = [:]
            if item.reminder.hasTime {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
                let mins = (comps.hour ?? 9) * 60 + (comps.minute ?? 0)
                slots[key] = DayTimeSlot(startMinute: mins, durationMinutes: 60)
            }
            return PinnedTaskSchedule(reminderId: item.id, startDateKey: key, spanDays: 1, daySlots: slots)
        }
        return PinnedTaskSchedule(reminderId: item.id)
    }

    /// Tasks shown in the Middle Week Column (both active & completed so finished schedules stay visible!)
    var dayVisibleItems: [(item: ReminderItem, schedule: PinnedTaskSchedule)] {
        (filteredItems + filteredCompletedItems).compactMap { item in
            let sched = effectiveSchedule(for: item)
            guard let start = sched.startDate else { return nil }
            let rawStart = PinnedTaskSchedule.dayDifference(from: weekStartDate, to: start)
            let rawEnd = rawStart + sched.spanDays - 1
            guard rawEnd >= 0 && rawStart < 7 else { return nil }
            return (item, sched)
        }
        .sorted { lhs, rhs in
            if lhs.item.reminder.isCompleted != rhs.item.reminder.isCompleted {
                return !lhs.item.reminder.isCompleted
            }
            return (lhs.schedule.startDateKey ?? "") < (rhs.schedule.startDateKey ?? "")
        }
    }

    /// Left Column — Group 1: Tasks not scheduled on any day or time slot
    var unscheduledTaskItems: [ReminderItem] {
        filteredItems.filter { item in
            let sched = effectiveSchedule(for: item)
            return sched.startDateKey == nil && sched.daySlots.isEmpty
        }
    }

    /// Left Column — Group 2: Tasks already placed on a day or time slot (never hidden!)
    var scheduledTaskItems: [ReminderItem] {
        filteredItems.filter { item in
            let sched = effectiveSchedule(for: item)
            return sched.startDateKey != nil || !sched.daySlots.isEmpty
        }
    }

    /// Tasks shown in the Right Column (hourly slots on `selectedDate`, keeping completed records visible)
    var timeSlotItemsForSelectedDate: [(item: ReminderItem, slot: DayTimeSlot)] {
        let key = selectedDateKey
        return (filteredItems + filteredCompletedItems).compactMap { item in
            let sched = effectiveSchedule(for: item)
            guard let slot = sched.daySlots[key] else { return nil }
            return (item, slot)
        }
        .sorted { lhs, rhs in
            if lhs.slot.startMinute != rhs.slot.startMinute {
                return lhs.slot.startMinute < rhs.slot.startMinute
            }
            return !lhs.item.reminder.isCompleted && rhs.item.reminder.isCompleted
        }
    }

    /// Tasks whose day-span covers `selectedDate` but don't yet have an hourly slot on `selectedDate`
    var dayCoveredWithoutSlotOnSelectedDate: [ReminderItem] {
        let key = selectedDateKey
        return filteredItems.filter { item in
            let sched = effectiveSchedule(for: item)
            return sched.covers(date: selectedDate) && sched.daySlots[key] == nil
        }
    }

    // MARK: - Create / Edit / Complete / Delete

    @discardableResult
    func quickCreate(title: String, notes: String? = nil) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let targetCalendar = defaultSavingCalendar else { return false }
        guard let reminder = RemindersService.shared.createQuickReminder(
            title: trimmed,
            notes: notes,
            in: targetCalendar
        ) else {
            return false
        }
        allItems.insert(ReminderItem(for: reminder), at: 0)
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
        return true
    }

    @discardableResult
    func quickCreateFromSelection(_ text: String, splitByLine: Bool = false) -> Int {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return 0 }

        if splitByLine {
            var createdCount = 0
            for line in lines.reversed() {
                let cleaned = Self.stripListPrefix(from: line)
                if quickCreate(title: cleaned) {
                    createdCount += 1
                }
            }
            return createdCount
        } else {
            let title = Self.stripListPrefix(from: lines[0])
            let extraNotes = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : nil
            return quickCreate(title: title, notes: extraNotes) ? 1 : 0
        }
    }

    private static func stripListPrefix(from line: String) -> String {
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "☐ ", "☑ ", "▎ ", "- ", "• ", "* ", "· "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            let remainder = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return line
    }

    /// Single-source-of-truth completion toggle: synchronizes animation & state across
    /// the left task list, week/month calendar, hourly timeline, and top-right mini checklist simultaneously.
    func toggleComplete(_ reminderItem: ReminderItem) {
        if reminderItem.reminder.isCompleted {
            uncompleteItem(reminderItem)
            return
        }

        let id = reminderItem.id
        guard !completingIds.contains(id) else { return }

        withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
            _ = completingIds.insert(id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.completingIds.contains(id) else { return }
            self.completingIds.remove(id)
            if let liveItem = self.allItems.first(where: { $0.id == id }) {
                self.completeItem(liveItem)
            }
        }
    }

    func completeItem(_ reminderItem: ReminderItem) {
        let isRecurring = reminderItem.reminder.hasRecurrenceRules
        let itemTitle = reminderItem.reminder.title ?? ""

        // Keep schedules[id] intact for non-recurring tasks so completed items stay visible
        // on Calendar & Hourly Timeline AND restore cleanly via Undo.
        RemindersService.shared.complete(reminderItem: reminderItem)

        if !isRecurring {
            let completedCopy = ReminderItem(for: reminderItem.reminder, withChildren: reminderItem.childReminders)
            withAnimation(.easeInOut(duration: 0.18)) {
                allItems.removeAll { $0.id == reminderItem.id }
                completedItems.removeAll { $0.id == reminderItem.id }
                completedItems.insert(completedCopy, at: 0)
            }
            showCompletionToast(id: reminderItem.id, title: itemTitle)
        } else {
            // Clear stale local schedule so the next recurrence follows EventKit's updated due date.
            schedules.removeValue(forKey: reminderItem.id)
            persistSchedules()
        }

        if PomodoroService.shared.linkedTaskId == reminderItem.id {
            PomodoroService.shared.clearLinkedTask()
        }

        Task {
            await updateMenuBarCount()
        }
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    func uncompleteItem(_ reminderItem: ReminderItem) {
        RemindersService.shared.uncomplete(reminderItem: reminderItem)
        let restoredCopy = ReminderItem(for: reminderItem.reminder, withChildren: reminderItem.childReminders)

        withAnimation(.easeInOut(duration: 0.18)) {
            completedItems.removeAll { $0.id == reminderItem.id }
            allItems.removeAll { $0.id == reminderItem.id }
            allItems.insert(restoredCopy, at: 0)
            if lastCompletionToast?.reminderId == reminderItem.id {
                lastCompletionToast = nil
            }
        }

        Task {
            await updateMenuBarCount()
        }
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    func undoLastCompletion() {
        guard let toast = lastCompletionToast else { return }
        toastDismissWork?.cancel()
        lastCompletionToast = nil
        if let completed = completedItems.first(where: { $0.id == toast.reminderId }) {
            uncompleteItem(completed)
        }
    }

    func dismissCompletionToast() {
        toastDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.14)) {
            lastCompletionToast = nil
        }
    }

    private func showCompletionToast(id: String, title: String) {
        toastDismissWork?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
            lastCompletionToast = CompletionUndoToast(reminderId: id, title: title)
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                if self?.lastCompletionToast?.reminderId == id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self?.lastCompletionToast = nil
                    }
                }
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    func updatePriority(for reminder: EKReminder, priority: EKReminderPriority) {
        reminder.ekPriority = priority
        RemindersService.shared.save(reminder: reminder)
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    func removeItem(_ reminder: EKReminder) {
        let id = reminder.calendarItemIdentifier
        allItems.removeAll { $0.id == id }
        completedItems.removeAll { $0.id == id }
        completingIds.remove(id)
        if lastCompletionToast?.reminderId == id {
            lastCompletionToast = nil
        }
        schedules.removeValue(forKey: id)
        persistSchedules()
        if PomodoroService.shared.linkedTaskId == id {
            PomodoroService.shared.clearLinkedTask()
        }
        RemindersService.shared.remove(reminder: reminder)
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    private func findItem(byId id: String) -> ReminderItem? {
        allItems.first(where: { $0.id == id }) ?? completedItems.first(where: { $0.id == id })
    }

    // MARK: - Left Column Mutations (Day-Dimension Occupancy)

    func setDaySpan(
        for reminderId: String,
        startDate: Date,
        spanDays: Int,
        syncReminderDueDate: Bool = true
    ) {
        let normalizedStart = Calendar.current.startOfDay(for: startDate)
        let clampedSpan = max(1, min(30, spanDays))

        var sched = schedules[reminderId] ?? {
            if let item = findItem(byId: reminderId) {
                return effectiveSchedule(for: item)
            }
            return PinnedTaskSchedule(reminderId: reminderId)
        }()

        sched.startDateKey = PinnedTaskSchedule.dateKey(for: normalizedStart)
        sched.spanDays = clampedSpan
        schedules[reminderId] = sched
        persistSchedules()

        if syncReminderDueDate,
           let item = findItem(byId: reminderId),
           let endDate = sched.endDate {
            RemindersService.shared.updateDeadline(for: item.reminder, date: endDate, withTime: false)
        }
    }

    func clearDaySpan(for reminderId: String) {
        unscheduleCompletely(for: reminderId)
    }

    /// Moves a task cleanly back to "待安排": clears both day span, all hourly slots, and Apple Reminders due date.
    func unscheduleCompletely(for reminderId: String) {
        schedules[reminderId] = PinnedTaskSchedule(
            reminderId: reminderId,
            startDateKey: nil,
            spanDays: 1,
            daySlots: [:]
        )
        persistSchedules()

        if let item = findItem(byId: reminderId) {
            RemindersService.shared.updateDeadline(for: item.reminder, date: nil, withTime: false)
        }
    }

    // MARK: - Right Column Mutations (Same-Day Hourly Occupancy)

    func setTimeSlot(
        for reminderId: String,
        on date: Date? = nil,
        startMinute: Int,
        durationMinutes: Int? = nil
    ) {
        let targetDate = Calendar.current.startOfDay(for: date ?? selectedDate)
        let key = PinnedTaskSchedule.dateKey(for: targetDate)

        var sched = schedules[reminderId] ?? {
            if let item = findItem(byId: reminderId) {
                return effectiveSchedule(for: item)
            }
            return PinnedTaskSchedule(reminderId: reminderId)
        }()

        let existingDur = sched.daySlots[key]?.durationMinutes ?? 60
        sched.daySlots[key] = DayTimeSlot(startMinute: startMinute, durationMinutes: durationMinutes ?? existingDur)

        // Ensure day-dimension span covers targetDate
        if sched.startDateKey == nil {
            sched.startDateKey = key
            sched.spanDays = 1
        } else if let start = sched.startDate, let end = sched.endDate {
            let cal = Calendar.current
            if targetDate < cal.startOfDay(for: start) {
                let extra = PinnedTaskSchedule.dayDifference(from: targetDate, to: start)
                sched.startDateKey = key
                sched.spanDays = min(30, sched.spanDays + extra)
            } else if targetDate > cal.startOfDay(for: end) {
                let newSpan = PinnedTaskSchedule.dayDifference(from: start, to: targetDate) + 1
                sched.spanDays = min(30, newSpan)
            }
        }

        schedules[reminderId] = sched
        persistSchedules()
    }

    func clearTimeSlot(for reminderId: String, on date: Date? = nil) {
        let key = PinnedTaskSchedule.dateKey(for: date ?? selectedDate)
        var sched = schedules[reminderId] ?? {
            if let item = allItems.first(where: { $0.id == reminderId }) {
                return effectiveSchedule(for: item)
            }
            return PinnedTaskSchedule(reminderId: reminderId)
        }()
        sched.daySlots.removeValue(forKey: key)
        schedules[reminderId] = sched
        persistSchedules()
    }

    // MARK: - Panel Visibility & Tab Switching

    func showPanel(tab: BoardTab? = nil) {
        if let tab {
            activeTab = tab
        }
        isCollapsed = false
        isPanelVisible = true
        let controller = PinnedPanelController.shared
        if controller.isCornerMiniMode, let tab {
            controller.switchCornerMiniTab(tab)
        }
        controller.show()
    }

    func hidePanel() {
        isPanelVisible = false
        PinnedPanelController.shared.hide()
    }

    func togglePanelVisibility(tab: BoardTab? = nil) {
        let controller = PinnedPanelController.shared
        let actuallyVisible = isPanelVisible && controller.isAnyPanelVisible

        if actuallyVisible {
            if let tab, activeTab != tab {
                activeTab = tab
                isCollapsed = false
                if controller.isCornerMiniMode {
                    controller.switchCornerMiniTab(tab)
                }
                controller.show()
                return
            }

            // In non-floating mode, if the window is buried behind another app, bring it to the front
            // instead of hiding a window the user cannot see.
            if !controller.isVisiblePanelInForeground {
                isCollapsed = false
                controller.show()
                return
            }

            hidePanel()
        } else {
            showPanel(tab: tab)
            requestRefresh()
        }
    }

    func toggleCollapsed() {
        isCollapsed.toggle()
    }

    func launchAndRestore() {
        guard RemindersService.shared.isAuthorized else { return }
        Task {
            await refresh()
            showPanel(tab: .board)
        }
    }

    // MARK: - Sync from Apple Reminders

    func refresh() async {
        guard RemindersService.shared.isAuthorized else { return }

        refreshGeneration += 1
        let generation = refreshGeneration

        let calendars = RemindersService.shared.getCalendars()
        self.availableCalendars = calendars

        let excluded = UserPreferences.shared.excludedReminderCalendarIdentifiers
        let synced = calendars.filter { !excluded.contains($0.calendarIdentifier) }
        let isFilteringCalendars = synced.count < calendars.count
        let fetchCalendars: [EKCalendar]? = isFilteringCalendars ? synced : nil

        let fetchDays: Int? = (completedTimeRange == .all) ? nil : 30
        async let incompleteFetch = RemindersService.shared.fetchIncompleteReminders(for: fetchCalendars)
        async let completedFetch = RemindersService.shared.fetchRecentCompletedReminders(
            daysBack: fetchDays,
            for: fetchCalendars
        )

        let incompleteResult = await incompleteFetch
        let completedResult = await completedFetch

        // Drop stale refreshes or transient EventKit fetch errors (nil) without wiping user state/schedules.
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard let incomplete = incompleteResult, let recentCompleted = completedResult else { return }

        let activeItems = incomplete.map { ReminderItem(for: $0) }
        let limit = (completedTimeRange == .all) ? 500 : 150
        let doneItems = Array(recentCompleted.prefix(limit)).map { ReminderItem(for: $0) }
        self.allItems = activeItems
        self.completedItems = doneItems

        // Only prune orphaned schedules when we have a complete unfiltered view (not 30-day capped / filtered),
        // preventing accidental schedule erasure during partial fetches or edit races.
        if !isFilteringCalendars && completedTimeRange == .all && doneItems.count < limit {
            let validIds = Set(activeItems.map(\.id)).union(Set(doneItems.map(\.id)))
            if !validIds.isEmpty {
                let prunedSchedules = schedules.filter { validIds.contains($0.key) }
                if prunedSchedules.count != schedules.count {
                    schedules = prunedSchedules
                    persistSchedules()
                }
            }
        }

        await updateMenuBarCount()
    }

    private func updateMenuBarCount() async {
        let count: Int
        switch UserPreferences.shared.menuBarCounterType {
        case .due:
            count = allItems.filter { $0.reminder.isExpired }.count
        case .today:
            let filterIds: [String]? = hasExcludedCalendars ? syncedCalendars.map(\.calendarIdentifier) : nil
            count = await RemindersService.shared.getUpcomingReminders(.today, for: filterIds).count
        case .allReminders:
            count = allItems.count
        case .disabled:
            count = -1
        }
        AppDelegate.shared?.updateMenuBarCount(to: count)
    }

    private func persistSchedules() {
        UserPreferences.shared.pinnedSchedules = schedules
    }
}
