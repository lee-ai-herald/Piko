import Foundation

enum AppConstants {
    static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    static let displayVersion: String = {
        guard let bundleVersion else {
            return "-"
        }
        
        return "v\(bundleVersion)"
    }()
    
    static let appName = "Piko"
    // Keep legacy bundle identifier so existing UserDefaults, KeyboardShortcuts,
    // and macOS Reminders privacy authorization carry over seamlessly.
    static let mainBundleId = "br.com.damascenorafael.reminders-menubar"
    static let launcherBundleId = "br.com.damascenorafael.reminders-menubar-launcher"
}

enum AppStoragePaths {
    private static let currentFolderName = "Piko"
    private static let legacyFolderName = "RemindersMenuBar"

    /// Canonical Application Support directory (`~/Library/Application Support/Piko`).
    /// Automatically migrates existing data from `RemindersMenuBar` on first access.
    static var applicationSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let targetDir = base.appendingPathComponent(currentFolderName, isDirectory: true)
        let legacyDir = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        migrateLegacyStorageIfNeeded(from: legacyDir, to: targetDir, fileManager: fm)
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        return targetDir
    }

    private static func migrateLegacyStorageIfNeeded(
        from legacyDir: URL,
        to targetDir: URL,
        fileManager fm: FileManager
    ) {
        guard fm.fileExists(atPath: legacyDir.path) else { return }

        if !fm.fileExists(atPath: targetDir.path) {
            do {
                try fm.moveItem(at: legacyDir, to: targetDir)
                return
            } catch {
                // Fall back to item-by-item copy below if atomic move fails.
            }
        }

        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            let destination = targetDir.appendingPathComponent(entry.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: entry, to: destination)
        }
    }
}

enum GithubConstants {
    static let repository = "DamascenoRafael/reminders-menubar"
    static let repositoryPage = "https://github.com/\(repository)"
}

#if APPSTORE
enum AppStoreConstants {
    static let appId = "PLACEHOLDER_APP_ID"
    static let appPage = "macappstore://apps.apple.com/app/id\(appId)"
    static let versionCheckUrl = "https://itunes.apple.com/lookup?bundleId=\(AppConstants.mainBundleId)"
}
#endif
