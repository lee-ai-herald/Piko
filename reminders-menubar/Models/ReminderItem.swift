import EventKit

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let reminder: EKReminder
    let title: String
    let notes: String?
    let isCompleted: Bool
    let priority: Int
    let dueDateComponents: DateComponents?
    let calendarIdentifier: String?
    let lastModifiedDate: Date?
    let childReminders: [ReminderItem]
    let isChild: Bool
    let hasChildren: Bool

    init(for reminder: EKReminder, isChild: Bool = false, withChildren childReminders: [ReminderItem] = []) {
        self.id = reminder.calendarItemIdentifier
        self.reminder = reminder
        self.title = reminder.title ?? ""
        self.notes = reminder.notes
        self.isCompleted = reminder.isCompleted
        self.priority = reminder.priority
        self.dueDateComponents = reminder.dueDateComponents
        self.calendarIdentifier = reminder.calendar?.calendarIdentifier
        self.lastModifiedDate = reminder.lastModifiedDate
        self.childReminders = childReminders.sortedReminders
        self.isChild = isChild
        self.hasChildren = !childReminders.isEmpty
    }

    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.notes == rhs.notes
            && lhs.isCompleted == rhs.isCompleted
            && lhs.priority == rhs.priority
            && lhs.dueDateComponents == rhs.dueDateComponents
            && lhs.calendarIdentifier == rhs.calendarIdentifier
            && lhs.lastModifiedDate == rhs.lastModifiedDate
            && lhs.childReminders == rhs.childReminders
    }
}
