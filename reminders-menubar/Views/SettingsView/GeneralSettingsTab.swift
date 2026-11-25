import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var userPreferences = UserPreferences.shared
    @ObservedObject private var launchAtLoginService = LaunchAtLoginService.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "通用")

                SettingsCard(title: "启动与窗口") {
                    SettingsRow(
                        "开机启动",
                        subtitle: launchAtLoginService.status == .requiresApproval ? "需在系统设置「登录项」中批准" : nil
                    ) {
                        HStack(spacing: 8) {
                            if launchAtLoginService.status == .requiresApproval {
                                Button("前往批准") {
                                    launchAtLoginService.openSystemSettings()
                                }
                                .controlSize(.small)
                            }

                            Toggle("", isOn: Binding(
                                get: { launchAtLoginService.isEnabled },
                                set: { launchAtLoginService.setEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(launchAtLoginService.status == .unavailable)
                        }
                    }

                    SettingsRow(
                        "窗口置顶",
                        subtitle: "始终悬浮于其他窗口上方",
                        showDivider: false
                    ) {
                        Toggle("", isOn: $userPreferences.isBoardAlwaysOnTop)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

                SettingsCard(title: "外观") {
                    SettingsRow("外观主题") {
                        Picker("", selection: $userPreferences.rmbColorScheme) {
                            ForEach(RmbColorScheme.allCases, id: \.self) { scheme in
                                Text(scheme.title).tag(scheme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 196)
                    }

                    SettingsRow(
                        "半透明背景",
                        subtitle: userPreferences.reduceTransparency ? "受系统「降低透明度」设置限制" : nil
                    ) {
                        Toggle("", isOn: $userPreferences.preferTransparentBackground)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(userPreferences.reduceTransparency)
                    }

                    SettingsRow("卡片显示备注", showDivider: false) {
                        Toggle("", isOn: $userPreferences.showNotesInReminderItem)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

                SettingsCard(title: "菜单栏") {
                    SettingsRow("待办计数") {
                        Picker("", selection: $userPreferences.menuBarCounterType) {
                            ForEach(RmbMenuBarCounterType.allCases, id: \.self) { counterType in
                                Text(counterType.title).tag(counterType)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 126)
                    }

                    SettingsRow("显示番茄倒计时") {
                        Toggle("", isOn: $userPreferences.pomodoroShowInMenuBar)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    SettingsRow(
                        "有内容时隐藏图标",
                        subtitle: "显示计数或倒计时时自动隐藏",
                        showDivider: false
                    ) {
                        Toggle("", isOn: $userPreferences.hideMenuBarIconWhenContentIsShown)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            launchAtLoginService.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginService.refresh()
        }
    }
}
