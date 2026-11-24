import EventKit
import SwiftUI

struct MaintenanceSettingsTab: View {
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var panelController = PinnedPanelController.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    private var isAuthorized: Bool {
        RemindersService.shared.isAuthorized
    }

    private var systemDefaultCalendarId: String? {
        RemindersService.shared.getDefaultCalendar()?.calendarIdentifier
    }

    private var hasMultipleCalendarSources: Bool {
        Set(pinnedStore.availableCalendars.map { $0.source.sourceIdentifier }).count > 1
    }

    private var syncStatusSubtitle: String {
        guard isAuthorized else {
            return "未授权，请在系统设置中开启访问权限"
        }
        let total = pinnedStore.availableCalendars.count
        let synced = pinnedStore.syncedCalendars.count
        if total == 0 {
            return "自动同步中 · \(pinnedStore.allItems.count) 项未完成任务"
        }
        if synced == 0 {
            return "已暂停全部列表同步"
        }
        if synced < total {
            return "自动同步中 · 已选 \(synced)/\(total) 个列表 · \(pinnedStore.allItems.count) 项未完成"
        }
        return "自动同步中 · 全部 \(total) 个列表 · \(pinnedStore.allItems.count) 项未完成"
    }

    private var autoSavingCalendarTitle: String {
        let synced = pinnedStore.syncedCalendars
        if let defaultId = systemDefaultCalendarId,
           let sysDefault = synced.first(where: { $0.calendarIdentifier == defaultId }) {
            return sysDefault.title
        }
        return synced.first?.title ?? "无"
    }

    private var savingCalendarSubtitle: String {
        if pinnedStore.syncedCalendars.isEmpty {
            return "请先至少开启一个同步列表"
        }
        if let preferredId = userPreferences.preferredCalendarIdentifierForSaving,
           let preferred = pinnedStore.syncedCalendars.first(where: { $0.calendarIdentifier == preferredId }) {
            return "快速新建及随笔转任务将写入「\(preferred.title)」"
        }
        if let defaultId = systemDefaultCalendarId,
           !userPreferences.isCalendarSynced(defaultId) {
            return "系统默认列表已关闭，当前自动写入「\(autoSavingCalendarTitle)」"
        }
        return "未指定时跟随系统默认列表"
    }

    private var savingCalendarSelection: Binding<String> {
        Binding(
            get: {
                guard let id = userPreferences.preferredCalendarIdentifierForSaving,
                      pinnedStore.syncedCalendars.contains(where: { $0.calendarIdentifier == id }) else {
                    return ""
                }
                return id
            },
            set: { newValue in
                userPreferences.preferredCalendarIdentifierForSaving = newValue.isEmpty ? nil : newValue
            }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "数据与关于")

                SettingsCard(title: "Apple 提醒事项") {
                    SettingsRow(
                        "同步状态",
                        subtitle: syncStatusSubtitle,
                        showDivider: isAuthorized && !pinnedStore.availableCalendars.isEmpty
                    ) {
                        if isAuthorized {
                            HStack(spacing: 6) {
                                if pinnedStore.hasExcludedCalendars {
                                    Button("全部同步") {
                                        userPreferences.enableAllCalendars()
                                    }
                                    .controlSize(.small)
                                }

                                Button("刷新") {
                                    NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
                                }
                                .controlSize(.small)
                                .help("默认实时自动同步；若 iCloud 延迟未即时更新，可手动重新拉取")
                            }
                        } else {
                            Button("前往授权") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    if isAuthorized && !pinnedStore.availableCalendars.isEmpty {
                        SettingsRow(
                            "新建默认列表",
                            subtitle: savingCalendarSubtitle,
                            showDivider: true
                        ) {
                            Picker("", selection: savingCalendarSelection) {
                                if pinnedStore.syncedCalendars.isEmpty {
                                    Text("无已同步列表").tag("")
                                } else {
                                    Text("自动（\(autoSavingCalendarTitle)）").tag("")
                                    ForEach(pinnedStore.syncedCalendars, id: \.calendarIdentifier) { calendar in
                                        Text(calendar.title).tag(calendar.calendarIdentifier)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .labelsHidden()
                            .frame(width: 152)
                            .disabled(pinnedStore.syncedCalendars.isEmpty)
                        }

                        VStack(spacing: 0) {
                            HStack {
                                Text("同步列表")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("默认全部同步，关闭后不在规划板与菜单栏显示")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary.opacity(0.85))
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 9)
                            .padding(.bottom, 5)

                            ForEach(
                                Array(pinnedStore.availableCalendars.enumerated()),
                                id: \.element.calendarIdentifier
                            ) { index, calendar in
                                let isSynced = userPreferences.isCalendarSynced(calendar.calendarIdentifier)
                                let isLast = index == pinnedStore.availableCalendars.count - 1
                                let isSystemDefault = calendar.calendarIdentifier == systemDefaultCalendarId

                                VStack(spacing: 0) {
                                    HStack(spacing: 9) {
                                        Circle()
                                            .fill(Color(calendar.color))
                                            .frame(width: 9, height: 9)
                                            .opacity(isSynced ? 1.0 : 0.35)

                                        Text(calendar.title)
                                            .font(.system(size: 12.5))
                                            .foregroundColor(isSynced ? .primary : .secondary)
                                            .lineLimit(1)

                                        if isSystemDefault {
                                            Text("默认")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.primary.opacity(0.065)))
                                        }

                                        if hasMultipleCalendarSources {
                                            Text(calendar.source.title)
                                                .font(.system(size: 10.5))
                                                .foregroundColor(.secondary.opacity(0.75))
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 8)

                                        Toggle("", isOn: Binding(
                                            get: { userPreferences.isCalendarSynced(calendar.calendarIdentifier) },
                                            set: { enabled in
                                                userPreferences.setCalendarSynced(enabled, for: calendar.calendarIdentifier)
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .labelsHidden()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7.5)

                                    if !isLast {
                                        Divider()
                                            .padding(.leading, 32)
                                            .opacity(0.35)
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsCard(title: "窗口") {
                    SettingsRow("窗口位置与尺寸") {
                        Button("恢复默认") {
                            panelController.resetDefaultBoardSize()
                        }
                        .controlSize(.small)
                    }

                    SettingsRow("右上角小窗", showDivider: false) {
                        Button(panelController.isCornerMiniMode ? "展开主窗口" : "切换至小窗") {
                            panelController.toggleCornerMiniMode()
                        }
                        .controlSize(.small)
                    }
                }

                SettingsCard(title: "关于") {
                    HStack(spacing: 12) {
                        PikoAppIconView(size: 38)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppConstants.appName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("轻量级 macOS 桌面工作台")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(AppConstants.displayVersion)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .padding(20)
        }
        .onAppear {
            if isAuthorized {
                Task {
                    await pinnedStore.refresh()
                }
            }
        }
    }
}
