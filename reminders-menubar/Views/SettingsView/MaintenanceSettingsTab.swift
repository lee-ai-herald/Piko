import SwiftUI

struct MaintenanceSettingsTab: View {
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var panelController = PinnedPanelController.shared

    private var isAuthorized: Bool {
        RemindersService.shared.isAuthorized
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "数据与关于")

                SettingsCard(title: "Apple 提醒事项") {
                    SettingsRow(
                        "同步状态",
                        subtitle: isAuthorized
                            ? "已授权 · \(pinnedStore.allItems.count) 项未完成任务"
                            : "未授权，请在系统设置中开启访问权限",
                        showDivider: false
                    ) {
                        if isAuthorized {
                            Button("刷新") {
                                NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
                            }
                            .controlSize(.small)
                        } else {
                            Button("前往授权") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
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
    }
}
