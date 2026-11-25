import Foundation

extension Date {
    var isPast: Bool {
        return self.timeIntervalSinceNow < 0
    }
    
    var isToday: Bool {
        return Calendar.current.isDateInToday(self)
    }
    
    var isYesterday: Bool {
        return Calendar.current.isDateInYesterday(self)
    }
    
    var isDayBeforeYesterday: Bool {
        let dayBeforeYesterday = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? self
        return self.isSameDay(as: dayBeforeYesterday)
    }
                                                                   
    var isThisYear: Bool {
        return Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
    }
    
    var elapsedTimeInterval: TimeInterval {
        return Date().timeIntervalSince(self)
    }
    
    static func nextYear(of date: Date = Date()) -> Date {
        return Calendar.current.date(byAdding: .year, value: 1, to: date) ?? date
    }
    
    func isSameDay(as otherDate: Date) -> Bool {
        return Calendar.current.isDate(self, inSameDayAs: otherDate)
    }

    func withTime(from timeSource: Date) -> Date {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: timeSource)
        return calendar.date(
            bySettingHour: timeComponents.hour ?? 0,
            minute: timeComponents.minute ?? 0,
            second: timeComponents.second ?? 0,
            of: self
        ) ?? self
    }

    /// EventKit requires Gregorian calendar components for reminder due/start dates; using
    /// `Calendar.current` crashes with `NSInvalidArgumentException` on non-Gregorian system calendars.
    func dateComponents(withTime: Bool) -> DateComponents {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        var components: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]
        if withTime {
            components.formUnion([.timeZone, .hour, .minute, .second])
        }
        return gregorian.dateComponents(components, from: self)
    }
}
