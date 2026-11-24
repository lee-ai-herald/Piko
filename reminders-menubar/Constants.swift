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
    private static let migrationDoneKey = "pikoDidMigrateLegacyApplicationSupport"

    /// Canonical Application Support directory (`~/Library/Application Support/Piko`).
    /// Computed once per process; migrates legacy `RemindersMenuBar` data at most once.
    static let applicationSupportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let targetDir = base.appendingPathComponent(currentFolderName, isDirectory: true)
        let legacyDir = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        if !UserDefaults.standard.bool(forKey: migrationDoneKey) {
            migrateLegacyStorageIfNeeded(from: legacyDir, to: targetDir, fileManager: fm)
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
        }
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        return targetDir
    }()

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

enum RmbFormatters {
    private static func makeFormatter(_ format: String, locale: Locale? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        if let locale {
            formatter.locale = locale
        }
        formatter.dateFormat = format
        return formatter
    }

    static let monthDay: DateFormatter = makeFormatter("M/d")
    static let monthDayChinese: DateFormatter = makeFormatter("M月d日")
    static let yearMonthChinese: DateFormatter = makeFormatter("yyyy年 M月")
    static let monthDayTime: DateFormatter = makeFormatter("M/d HH:mm")
    static let hourMinute: DateFormatter = makeFormatter("HH:mm")
    static let weekdayShortZH: DateFormatter = makeFormatter("EEE", locale: Locale(identifier: "zh_CN"))

    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter
    }()
}

enum GithubConstants {
    static let repository = "lee-ai-herald/Piko"
    static let repositoryPage = "https://github.com/\(repository)"
    static let releasesPage = "\(repositoryPage)/releases"
    static let latestReleaseAPIURL = "https://api.github.com/repos/\(repository)/releases/latest"
}

enum SocialConstants {
    static let authorName = "Lee | Ai 吹号人"
    static let xiaohongshuProfileURL = "https://xhslink.cn/o/5FpAxjYpHyH"
}
