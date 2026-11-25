import EventKit

extension EKReminder {
    // MARK: - Computed properties

    private static func gregorianCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// Resolves `dueDateComponents` reliably even when CalDAV/Exchange omits `components.calendar`
    /// or the system uses a non-Gregorian calendar.
    var resolvedDueDate: Date? {
        guard let components = dueDateComponents else { return nil }
        return components.date
            ?? Self.gregorianCalendar().date(from: components)
            ?? Calendar.current.date(from: components)
    }

    private var maxDueDate: Date? {
        guard let date = resolvedDueDate else {
            return nil
        }

        if hasTime {
            return date
        }

        let start = Calendar.current.startOfDay(for: date)
        return Calendar.current.date(byAdding: .day, value: 1, to: start)
    }

    var hasDueDate: Bool {
        dueDateComponents != nil
    }

    var hasTime: Bool {
        dueDateComponents?.hour != nil
    }

    var ekPriority: EKReminderPriority {
        get {
            // Map full RFC 5545 priority ranges (1–4 high, 5 medium, 6–9 low) instead of dropping 2–4 / 6–8.
            switch self.priority {
            case 1...4:
                return .high
            case 5:
                return .medium
            case 6...9:
                return .low
            default:
                return .none
            }
        }
        set {
            self.priority = Int(newValue.rawValue)
        }
    }

    var isExpired: Bool {
        maxDueDate?.isPast ?? false
    }

    // MARK: - Date and recurrence helpers

    func removeDueDateAndAlarms() {
        dueDateComponents = nil
        startDateComponents = nil
        alarms?.filter { $0.absoluteDate != nil }.forEach { alarm in
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
        if hasRecurrenceRules {
            startDateComponents = dateComponents
        }

        if hasTime, let alarmDate = dateComponents.date ?? Self.gregorianCalendar().date(from: dateComponents) {
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
        guard object.responds(to: selector),
              let nsObj = object as? NSObject,
              let value = nsObj.value(forKey: name) as? NSNumber else {
            return false
        }
        return value.boolValue
    }

    // MARK: - Update reminder

    func update(with rmbReminder: RmbReminder) {
        let trimmedTitle = rmbReminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        }

        notes = rmbReminder.notes.isEmpty ? nil : rmbReminder.notes

        // Apply recurrence changes before date changes so `addDueDateAndAlarm` sees the updated
        // `hasRecurrenceRules` flag and populates `startDateComponents` consistently.
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

        if rmbReminder.hasDateChanges {
            removeDueDateAndAlarms()
            if rmbReminder.hasDueDate {
                addDueDateAndAlarm(for: rmbReminder.date, withTime: rmbReminder.hasTime)
            }
        } else if rmbReminder.hasRecurrenceChanges {
            if hasRecurrenceRules {
                if let due = dueDateComponents, startDateComponents == nil {
                    startDateComponents = due
                }
            } else {
                startDateComponents = nil
            }
        }

        ekPriority = rmbReminder.priority
        if let cal = rmbReminder.calendar {
            calendar = cal
        }
    }
}
