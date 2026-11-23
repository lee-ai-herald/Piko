enum RmbMenuBarCounterType: String, Codable, CaseIterable {
    case due
    case today
    case allReminders
    case disabled
    
    var title: String {
        switch self {
        case .due:
            return "已逾期"
        case .today:
            return "今日待办"
        case .allReminders:
            return "全部未完成"
        case .disabled:
            return "不显示"
        }
    }
}
