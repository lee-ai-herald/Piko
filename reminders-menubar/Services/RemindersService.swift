import EventKit

@MainActor
class RemindersService {
    static let shared = RemindersService()

    private let eventStore = EKEventStore()
    private var wasAuthorized = false

    private init() {
        wasAuthorized = Self.currentAuthorizationGranted()
    }

    private static func currentAuthorizationGranted() -> Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized
        }
    }

    var isAuthorized: Bool {
        let authorized = Self.currentAuthorizationGranted()
        if authorized && !wasAuthorized {
            wasAuthorized = true
            eventStore.reset()
        } else if !authorized && wasAuthorized {
            wasAuthorized = false
        }
        return authorized
    }

    func requestAccess(completion: @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                Task { @MainActor in
                    if granted {
                        self?.eventStore.reset()
                    }
                    completion(granted, error?.localizedDescription)
                }
            }
        } else {
            eventStore.requestAccess(to: .reminder) { [weak self] granted, error in
                Task { @MainActor in
                    if granted {
                        self?.eventStore.reset()
                    }
                    completion(granted, error?.localizedDescription)
                }
            }
        }
    }

    func getCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .reminder)
    }

    func getDefaultCalendar() -> EKCalendar? {
        eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
    }

    /// Returns `nil` if EventKit reports a fetch error (distinct from an empty `[]` result).
    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder]? {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { allReminders in
                continuation.resume(returning: allReminders)
            }
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
            let matched = getCalendars().filter { calendarIdentifiers.contains($0.calendarIdentifier) }
            if matched.isEmpty {
                return []
            }
            calendars = matched
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: interval.endingDate,
            calendars: calendars
        )
        var reminders = (await fetchReminders(matching: predicate) ?? []).map { ReminderItem(for: $0) }
        if interval == .due {
            reminders = reminders.filter { $0.reminder.isExpired }
        }
        return reminders.sortedUpcomingReminders
    }

    func fetchIncompleteReminders(for calendars: [EKCalendar]? = nil) async -> [EKReminder]? {
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

    func fetchRecentCompletedReminders(daysBack: Int? = 30, for calendars: [EKCalendar]? = nil) async -> [EKReminder]? {
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
        guard let fetched = await fetchReminders(matching: predicate) else {
            return nil
        }
        return fetched.sorted {
            ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast)
        }
    }

    @discardableResult
    func save(reminder: EKReminder) -> Bool {
        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("Error saving reminder:", error.localizedDescription)
            return false
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
        guard save(reminder: reminder) else { return nil }
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

    @discardableResult
    func remove(reminder: EKReminder) -> Bool {
        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            print("Error removing reminder:", error.localizedDescription)
            return false
        }
    }
}
