import Foundation
import EventKit

struct RmbReminder {
    var title: String
    var notes: String
    var date: Date
    var hasDueDate: Bool
    var hasTime: Bool
    var recurrence: RmbRecurrenceOption
    var priority: EKReminderPriority
    var calendar: EKCalendar?

    var hasDateChanges: Bool
    var hasRecurrenceChanges: Bool

    init() {
        self.title = ""
        self.notes = ""
        self.date = Date().addingTimeInterval(3_600)
        self.hasDueDate = false
        self.hasTime = false
        self.recurrence = .none
        self.priority = .none
        self.calendar = nil
        self.hasDateChanges = false
        self.hasRecurrenceChanges = false
    }

    init(reminder: EKReminder) {
        self.title = reminder.title ?? ""
        self.notes = reminder.notes ?? ""
        self.hasDueDate = reminder.hasDueDate
        self.hasTime = reminder.hasTime
        self.date = reminder.dueDateComponents?.date ?? Date().addingTimeInterval(3_600)
        self.recurrence = RmbRecurrenceOption(from: reminder.recurrenceRules)
        self.priority = reminder.ekPriority
        self.calendar = reminder.calendar
        self.hasDateChanges = false
        self.hasRecurrenceChanges = false
    }
}
