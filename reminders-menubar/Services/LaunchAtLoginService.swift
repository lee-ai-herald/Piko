import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
    enum Status {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static let shared = LaunchAtLoginService()

    @Published private(set) var status: Status = .disabled
    @Published private(set) var errorMessage: String?

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private init() {
        refresh()
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ isEnabled: Bool) {
        errorMessage = nil
        let mainAppService = SMAppService.mainApp
        let isRegistered = mainAppService.status == .enabled || mainAppService.status == .requiresApproval
        guard isRegistered != isEnabled else {
            refresh()
            return
        }

        do {
            if isEnabled {
                try mainAppService.register()
            } else {
                try mainAppService.unregister()
            }
        } catch {
            let bundlePath = Bundle.main.bundleURL.path
            if isEnabled && (bundlePath.contains("/AppTranslocation/") || !bundlePath.hasPrefix("/Applications/")) {
                errorMessage = "请先将 \(AppConstants.appName) 移至「应用程序」文件夹后再开启"
            } else {
                errorMessage = "\(isEnabled ? "开启" : "关闭")失败：\(error.localizedDescription)"
            }
            print("Failed to \(isEnabled ? "enable" : "disable") launch at login:", error.localizedDescription)
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            status = .enabled
            errorMessage = nil
        case .requiresApproval:
            status = .requiresApproval
            errorMessage = nil
        case .notFound:
            // macOS returns `.notFound` before an app has ever been registered in BTM; allow toggling from a real `.app` bundle.
            status = isRunningFromAppBundle ? .disabled : .unavailable
        case .notRegistered:
            status = .disabled
        @unknown default:
            status = .disabled
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
