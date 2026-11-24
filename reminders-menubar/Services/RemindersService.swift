import EventKit

@MainActor
class RemindersService {
    static let shared = RemindersService()

    private init() {}

    private let eventStore = EKEventStore()

    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized
        }
    }

    func requestAccess(completion: @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                completion(granted, error?.localizedDescription)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                completion(granted, error?.localizedDescription)
            }
        }
    }

    func getCalendar(withIdentifier calendarIdentifier: String) -> EKCalendar? {
        eventStore.calendar(withIdentifier: calendarIdentifier)
    }

    func getCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .reminder)
    }

    func getDefaultCalendar() -> EKCalendar? {
        eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { allReminders in
                continuation.resume(returning: allReminders ?? [])
            }
        }
    }

    private func createReminderItems(for reminders: [EKReminder]) -> [ReminderItem] {
        let reminderIds = Set(reminders.map(\.calendarItemIdentifier))
        let remindersByParentId = Dictionary(grouping: reminders, by: { $0.parentId })
        let parentReminders = reminders.filter { reminder in
            guard let parentId = reminder.parentId else { return true }
            return !reminderIds.contains(parentId)
        }

        return parentReminders.map { parentReminder in
            let parentId = parentReminder.calendarItemIdentifier
            let children = remindersByParentId[parentId, default: []].map { ReminderItem(for: $0, isChild: true) }
            return ReminderItem(for: parentReminder, withChildren: children)
        }
    }

    func getUpcomingReminders(
        _ interval: ReminderInterval,
        for calendarIdentifiers: [String]? = nil
    ) async -> [ReminderItem] {
        var calendars: [EKCalendar]?
        if let calendarIdentifiers {
            if calendarIdentifiers.isEmpty {
                return []
            }
            calendars = getCalendars().filter { calendarIdentifiers.contains($0.calendarIdentifier) }
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: interval.endingDate,
            calendars: calendars
        )
        var reminders = await fetchReminders(matching: predicate).map { ReminderItem(for: $0) }
        if interval == .due {
            reminders = reminders.filter { $0.reminder.isExpired }
        }
        return reminders.sortedUpcomingReminders
    }

    func getAllIncompleteRemindersCount(for calendarIdentifiers: [String]? = nil) async -> Int {
        var calendars: [EKCalendar]?
        if let calendarIdentifiers {
            if calendarIdentifiers.isEmpty {
                return 0
            }
            calendars = getCalendars().filter { calendarIdentifiers.contains($0.calendarIdentifier) }
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        return await fetchReminders(matching: predicate).count
    }

    func getIncompleteReminders(withIdentifiers identifiers: [String]) async -> [ReminderItem] {
        guard !identifiers.isEmpty else { return [] }

        let targetIdSet = Set(identifiers)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let allIncomplete = await fetchReminders(matching: predicate)
        let remindersByParentId = Dictionary(grouping: allIncomplete, by: { $0.parentId })
        var itemsById: [String: ReminderItem] = [:]

        for reminder in allIncomplete where targetIdSet.contains(reminder.calendarItemIdentifier) {
            let reminderId = reminder.calendarItemIdentifier
            let children = remindersByParentId[reminderId, default: []].map { ReminderItem(for: $0, isChild: true) }
            itemsById[reminderId] = ReminderItem(for: reminder, withChildren: children)
        }

        return identifiers.compactMap { itemsById[$0] }
    }

    func fetchIncompleteReminders(for calendars: [EKCalendar]? = nil) async -> [EKReminder] {
        if let calendars, calendars.isEmpty {
            return []
        }
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        return await fetchReminders(matching: predicate)
    }

    func fetchRecentCompletedReminders(daysBack: Int? = 30, for calendars: [EKCalendar]? = nil) async -> [EKReminder] {
        if let calendars, calendars.isEmpty {
            return []
        }
        let startDate: Date? = daysBack.flatMap { days in
            Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))
        }
        let predicate = eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: startDate,
            ending: nil,
            calendars: calendars
        )
        let fetched = await fetchReminders(matching: predicate)
        return fetched.sorted {
            ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast)
        }
    }

    func save(reminder: EKReminder) {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            print("Error saving reminder:", error.localizedDescription)
        }
    }

    @discardableResult
    func createNew(with rmbReminder: RmbReminder, in calendar: EKCalendar) -> EKReminder {
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.update(with: rmbReminder)
        newReminder.calendar = calendar
        save(reminder: newReminder)
        return newReminder
    }

    @discardableResult
    func createQuickReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        in targetCalendar: EKCalendar? = nil
    ) -> EKReminder? {
        guard let calendar = targetCalendar ?? getDefaultCalendar() else { return nil }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNotes.isEmpty {
                reminder.notes = trimmedNotes
            }
        }
        reminder.calendar = calendar
        if let dueDate {
            reminder.addDueDateAndAlarm(for: dueDate, withTime: false)
        }
        save(reminder: reminder)
        return reminder
    }

    func updateDeadline(for reminder: EKReminder, date: Date?, withTime: Bool = false) {
        reminder.removeDueDateAndAlarms()
        if let date {
            reminder.addDueDateAndAlarm(for: date, withTime: withTime)
        }
        save(reminder: reminder)
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    func complete(reminderItem: ReminderItem) {
        reminderItem.reminder.isCompleted = true
        if reminderItem.reminder.completionDate == nil {
            reminderItem.reminder.completionDate = Date()
        }
        save(reminder: reminderItem.reminder)
        for child in reminderItem.childReminders where !child.reminder.isCompleted {
            child.reminder.isCompleted = true
            save(reminder: child.reminder)
        }
    }

    func uncomplete(reminderItem: ReminderItem) {
        reminderItem.reminder.isCompleted = false
        reminderItem.reminder.completionDate = nil
        save(reminder: reminderItem.reminder)
    }

    func searchReminders(matching query: String, in reminders: [EKReminder]) -> [ReminderItem] {
        let queryWords = query.lowercased().split(separator: " ").map(String.init)
        guard !queryWords.isEmpty else { return [] }

        let scored: [(ReminderItem, Int)] = reminders.compactMap { reminder in
            let title = (reminder.title ?? "").lowercased()
            let notes = (reminder.notes ?? "").lowercased()

            let allMatch = queryWords.allSatisfy { word in
                title.contains(word) || notes.contains(word)
            }
            guard allMatch else { return nil }

            var score = 0
            for word in queryWords {
                if title.contains(word) { score += 3 }
                if notes.contains(word) { score += 1 }
            }
            return (ReminderItem(for: reminder), score)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    func remove(reminder: EKReminder) {
        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Error removing reminder:", error.localizedDescription)
        }
    }
}
