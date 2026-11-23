import EventKit

extension EKReminder {
    // MARK: - Computed properties

    private var maxDueDate: Date? {
        guard let date = dueDateComponents?.date else {
            return nil
        }

        if hasTime {
            return date
        }

        return Calendar.current.date(byAdding: .day, value: 1, to: date)
    }

    var hasDueDate: Bool {
        dueDateComponents != nil
    }

    var hasTime: Bool {
        dueDateComponents?.hour != nil
    }

    var ekPriority: EKReminderPriority {
        get {
            EKReminderPriority(rawValue: UInt(self.priority)) ?? .none
        }
        set {
            self.priority = Int(newValue.rawValue)
        }
    }

    var isExpired: Bool {
        maxDueDate?.isPast ?? false
    }

    var relativeDateDescription: String? {
        guard let date = dueDateComponents?.date else {
            return nil
        }
        return date.relativeDateDescription(withTime: hasTime)
    }

    /// Compact deadline badge text for the desktop timeline board (e.g. "今天截止", "明天截止", "5/12 截止", "已逾期 2 天")
    var compactDeadlineLabel: String? {
        guard let dueDate = dueDateComponents?.date else {
            return nil
        }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let dueStart = cal.startOfDay(for: dueDate)
        let days = cal.dateComponents([.day], from: todayStart, to: dueStart).day ?? 0

        if isExpired {
            if days < 0 {
                return "逾期 \(-days) 天"
            }
            return "已逾期"
        }

        switch days {
        case 0:
            return "今天截止"
        case 1:
            return "明天截止"
        case 2...6:
            return "\(days) 天内截止"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = cal.isDate(dueDate, equalTo: Date(), toGranularity: .year) ? "M/d" : "yy/M/d"
            return "\(formatter.string(from: dueDate)) 截止"
        }
    }

    // MARK: - Date and recurrence helpers

    func removeDueDateAndAlarms() {
        dueDateComponents = nil
        alarms?.forEach { alarm in
            removeAlarm(alarm)
        }
    }

    func removeAllRecurrenceRules() {
        recurrenceRules?.forEach { rule in
            removeRecurrenceRule(rule)
        }
    }

    func addDueDateAndAlarm(for date: Date, withTime hasTime: Bool) {
        let dateComponents = date.dateComponents(withTime: hasTime)
        dueDateComponents = dateComponents

        if hasTime, let alarmDate = dateComponents.date {
            let ekAlarm = EKAlarm(absoluteDate: alarmDate)
            addAlarm(ekAlarm)
        }
    }

    // MARK: - Private API access (minimal: subtasks & flagged read-only)

    var parentId: String? {
        guard let backingObject = reminderBackingObject,
              let parentReminder = performPrivateSelector("parentReminderID", on: backingObject),
              let parentReminderId = performPrivateSelector("uuid", on: parentReminder) as? UUID else {
            return nil
        }
        return parentReminderId.uuidString
    }

    var isFlagged: Bool {
        guard let backingObject = reminderBackingObject else { return false }
        return performPrivateBoolGetter("flagged", on: backingObject)
    }

    private var reminderBackingObject: AnyObject? {
        guard let backingObject = performPrivateSelector("backingObject", on: self) else {
            return nil
        }
        return performPrivateSelector("_reminder", on: backingObject)
    }

    private func performPrivateSelector(_ name: String, on object: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func performPrivateBoolGetter(_ name: String, on object: AnyObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        return object.perform(selector) != nil
    }

    // MARK: - Update reminder

    func update(with rmbReminder: RmbReminder) {
        let trimmedTitle = rmbReminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        }

        notes = rmbReminder.notes.isEmpty ? nil : rmbReminder.notes

        if rmbReminder.hasDateChanges {
            removeDueDateAndAlarms()
            if rmbReminder.hasDueDate {
                addDueDateAndAlarm(for: rmbReminder.date, withTime: rmbReminder.hasTime)
            }
        }

        if rmbReminder.hasRecurrenceChanges {
            switch rmbReminder.recurrence {
            case .custom:
                break
            case .none:
                removeAllRecurrenceRules()
            case .daily, .weekly, .monthly, .yearly:
                removeAllRecurrenceRules()
                if let rule = rmbReminder.recurrence.ekRecurrenceRule {
                    addRecurrenceRule(rule)
                }
            }
        }

        ekPriority = rmbReminder.priority
        if let cal = rmbReminder.calendar {
            calendar = cal
        }
    }
}
