import Foundation

enum CalendarScaleMode: String, Codable, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week:
            return "周"
        case .month:
            return "月"
        case .year:
            return "年"
        }
    }
}

enum CompletedTimeRange: String, Codable, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        case .all: return "全部"
        }
    }

    var shortTitle: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "近7天"
        case .last30Days: return "近30天"
        case .all: return "全部"
        }
    }

    var startDate: Date? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        switch self {
        case .today:
            return todayStart
        case .last7Days:
            return cal.date(byAdding: .day, value: -6, to: todayStart)
        case .last30Days:
            return cal.date(byAdding: .day, value: -29, to: todayStart)
        case .all:
            return nil
        }
    }

    func includes(_ date: Date?) -> Bool {
        guard let start = startDate else { return true }
        guard let date else { return false }
        return date >= start
    }
}

struct DayTimeSlot: Codable, Equatable {
    /// Minutes from 00:00 (0...1425), snapped to 15-minute increments.
    var startMinute: Int
    /// Execution duration in minutes (15...480), snapped to 15-minute increments.
    var durationMinutes: Int

    init(startMinute: Int, durationMinutes: Int = 60) {
        let dur = max(15, min(480, DayTimeSlot.snap(durationMinutes)))
        let maxStart = max(0, 24 * 60 - dur)
        self.startMinute = max(0, min(maxStart, DayTimeSlot.snap(startMinute)))
        self.durationMinutes = dur
    }

    var endMinute: Int {
        min(24 * 60, startMinute + durationMinutes)
    }

    var timeRangeText: String {
        "\(Self.formatMinute(startMinute))–\(Self.formatMinute(endMinute))"
    }

    var durationText: String {
        Self.formatDuration(durationMinutes)
    }

    static func snap(_ minutes: Int) -> Int {
        Int((Double(minutes) / 15.0).rounded()) * 15
    }

    static func formatMinute(_ totalMinutes: Int) -> String {
        let clamped = max(0, min(24 * 60, totalMinutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 {
            return "\(mins)m"
        } else if mins == 0 {
            return "\(hours)h"
        } else if mins == 30 {
            return "\(hours).5h"
        } else {
            return "\(hours)h\(mins)m"
        }
    }
}

struct PinnedTaskSchedule: Codable, Equatable {
    var reminderId: String
    /// Start day of the multi-day occupancy span (`yyyy-MM-dd`), or `nil` if not placed on any day.
    var startDateKey: String?
    /// Inclusive number of days occupied (1 = single day, 3 = 3 consecutive days).
    var spanDays: Int
    /// Per-day hourly execution slots keyed by `yyyy-MM-dd`.
    var daySlots: [String: DayTimeSlot]

    init(
        reminderId: String,
        startDateKey: String? = nil,
        spanDays: Int = 1,
        daySlots: [String: DayTimeSlot] = [:]
    ) {
        self.reminderId = reminderId
        self.startDateKey = startDateKey
        self.spanDays = max(1, min(30, spanDays))
        self.daySlots = daySlots
    }

    // Custom decoding for backward compatibility with older stored schedules
    private enum CodingKeys: String, CodingKey {
        case reminderId
        case startDateKey
        case spanDays
        case daySlots
        case scheduledDateKey
        case startMinute
        case durationMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reminderId = try container.decode(String.self, forKey: .reminderId)

        if let slots = try container.decodeIfPresent([String: DayTimeSlot].self, forKey: .daySlots) {
            self.startDateKey = try container.decodeIfPresent(String.self, forKey: .startDateKey)
            self.spanDays = max(1, min(30, try container.decodeIfPresent(Int.self, forKey: .spanDays) ?? 1))
            self.daySlots = slots
        } else {
            // Migrate v1 single-slot schedule seamlessly
            let oldDate = try container.decodeIfPresent(String.self, forKey: .scheduledDateKey)
            let oldStart = try container.decodeIfPresent(Int.self, forKey: .startMinute)
            let oldDur = try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60
            self.startDateKey = oldDate
            self.spanDays = 1
            if let oldDate, let oldStart {
                self.daySlots = [oldDate: DayTimeSlot(startMinute: oldStart, durationMinutes: oldDur)]
            } else {
                self.daySlots = [:]
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reminderId, forKey: .reminderId)
        try container.encodeIfPresent(startDateKey, forKey: .startDateKey)
        try container.encode(spanDays, forKey: .spanDays)
        try container.encode(daySlots, forKey: .daySlots)
    }

    var startDate: Date? {
        guard let startDateKey else { return nil }
        return Self.date(fromKey: startDateKey)
    }

    var endDate: Date? {
        guard let start = startDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: max(0, spanDays - 1), to: start)
    }

    func covers(date: Date) -> Bool {
        if daySlots[Self.dateKey(for: date)] != nil {
            return true
        }
        guard let start = startDate, let end = endDate else { return false }
        let cal = Calendar.current
        let target = cal.startOfDay(for: date)
        return target >= cal.startOfDay(for: start) && target <= cal.startOfDay(for: end)
    }

    var daySpanLabel: String? {
        guard let start = startDate, let end = endDate else { return nil }
        if spanDays <= 1 {
            return "\(RmbFormatters.monthDay.string(from: start)) · 1天"
        }
        return "\(RmbFormatters.monthDay.string(from: start))–\(RmbFormatters.monthDay.string(from: end)) · \(spanDays)天"
    }

    static func dateKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return Calendar.current.date(from: comps)
    }

    static func dayDifference(from start: Date, to end: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0
    }
}
