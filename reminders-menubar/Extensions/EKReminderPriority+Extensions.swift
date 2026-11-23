import SwiftUI
import EventKit

extension EKReminderPriority {
    static let allQuadrants: [EKReminderPriority] = [.high, .medium, .low, .none]

    var title: String {
        switch self {
        case .high:
            return "重要且紧急"
        case .medium:
            return "重要不紧急"
        case .low:
            return "紧急不重要"
        default:
            return "不紧急不重要"
        }
    }

    var shortTitle: String {
        switch self {
        case .high:
            return "重要紧急"
        case .medium:
            return "重要缓办"
        case .low:
            return "紧急轻办"
        default:
            return "常规事务"
        }
    }

    /// Distinct Eisenhower quadrant accent color for timeline blocks & chips
    var quadrantColor: Color {
        switch self {
        case .high:
            return Color(red: 0.91, green: 0.29, blue: 0.28) // 珊瑚红：重要且紧急
        case .medium:
            return Color(red: 0.93, green: 0.56, blue: 0.15) // 暖琥珀橙：重要不紧急
        case .low:
            return Color(red: 0.21, green: 0.53, blue: 0.95) // 晴空蓝：紧急不重要
        default:
            return Color(red: 0.47, green: 0.55, blue: 0.63) // 石板灰：不紧急不重要
        }
    }
}
