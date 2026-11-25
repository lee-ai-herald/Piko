import Cocoa
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Semantic Version

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    let prerelease: [String]

    init?(_ raw: String) {
        let pattern = #"(?:^|[^0-9A-Za-z])v?(\d+(?:\.\d+)+)(?:-([0-9A-Za-z.-]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }

        let parts = raw[range].split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.components = parts

        if match.range(at: 2).location != NSNotFound,
           let preRange = Range(match.range(at: 2), in: raw) {
            self.prerelease = raw[preRange].split(separator: ".").map(String.init)
        } else {
            self.prerelease = []
        }
    }

    var description: String {
        let core = components.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r {
                return l < r
            }
        }
        // Per SemVer 2.0: a prerelease version has lower precedence than the corresponding stable release.
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            if let li = Int(l), let ri = Int(r) {
                return li < ri
            }
            return l.localizedStandardCompare(r) == .orderedAscending
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

// MARK: - Release & State Models

struct AppUpdateRelease: Equatable {
    let tagName: String
    let version: SemanticVersion
    let title: String
    let notes: String
    let releasePageURL: URL
    let publishedAt: Date?
    let assetName: String?
    let downloadURL: URL?
    let assetSizeBytes: Int64?
    let expectedSHA256: String?

    var displayVersion: String {
        "v\(version.description)"
    }

    var isDirectZipInstallable: Bool {
        guard let assetName, downloadURL != nil, expectedSHA256 != nil else { return false }
        return assetName.lowercased().hasSuffix(".zip")
    }

    /// Concise bullet highlights extracted from the GitHub release body for compact display in Settings.
    var summaryHighlights: [String] {
        let lines = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var bullets: [String] = []
        var reachedInstallSection = false

        for line in lines {
            if line.hasPrefix("### 安装说明") || line.hasPrefix("### 校验和") {
                reachedInstallSection = true
            }
            if reachedInstallSection { break }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let cleaned = String(line.dropFirst(2))
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                if !cleaned.isEmpty {
                    bullets.append(cleaned)
                }
            }
        }
        return Array(bullets.prefix(4))
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(AppUpdateRelease)
    case downloading(release: AppUpdateRelease, progress: Double, writtenBytes: Int64, totalBytes: Int64)
    case verifying(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case error(message: String, release: AppUpdateRelease?)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing:
            return true
        case .idle, .upToDate, .available, .error:
            return false
        }
    }
}

// MARK: - GitHub API DTOs

private struct GitHubReleaseDTO: Decodable {
    struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let publishedAt: String?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [AssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

private enum UpdateInstallError: LocalizedError {
    case invalidResponse
    case rateLimited
    case httpStatus(Int)
    case noDownloadableAsset
    case sha256Mismatch(expected: String, actual: String)
    case extractionFailed(String)
    case appBundleNotFound
    case bundleIdentifierMismatch(String?)
    case signatureInvalid(String)
    case targetNotWritable(stagedAppURL: URL)
    case launchHelperFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无法解析 GitHub 更新信息"
        case .rateLimited:
            return "GitHub API 访问受限，请稍后重试或直接打开网页下载"
        case .httpStatus(let code):
            return "检查更新失败（HTTP \(code)）"
        case .noDownloadableAsset:
            return "该版本未附带可自动安装的安装包，请前往 GitHub 页面手动下载"
        case .sha256Mismatch:
            return "安装包完整性校验失败（SHA-256 不匹配），已取消安装"
        case .extractionFailed(let detail):
            return "解压更新包失败：\(detail)"
        case .appBundleNotFound:
            return "更新包中未找到 \(AppConstants.appName).app"
        case .bundleIdentifierMismatch:
            return "更新包应用标识不匹配，已取消安装"
        case .signatureInvalid:
            return "更新包签名完整性验证未通过，已取消安装"
        case .targetNotWritable:
            return "目标目录无写入权限，已为你打开下载好的更新包，请手动拖入「应用程序」覆盖"
        case .launchHelperFailed(let detail):
            return "启动自动更新脚本失败：\(detail)"
        }
    }
}

// MARK: - Download Delegate

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destinationURL: URL
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(
        destinationURL: URL,
        onProgress: @escaping (Int64, Int64) -> Void
    ) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            resumeOnce(with: .failure(UpdateInstallError.httpStatus(httpResponse.statusCode)))
            return
        }

        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destinationURL)
            try fm.moveItem(at: location, to: destinationURL)
            resumeOnce(with: .success(destinationURL))
        } catch {
            resumeOnce(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resumeOnce(with: .failure(error))
        }
    }
}

// MARK: - App Update Service

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var availableRelease: AppUpdateRelease?

    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadSession: URLSession?
    private var activeWorkDir: URL?
    private var periodicCheckTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isCheckingInFlight = false
    private var activeCheckUserInitiated = false
    private var downloadToken = 0

    private static let automaticCheckInterval: TimeInterval = 12 * 60 * 60

    private init() {}

    var hasAvailableUpdate: Bool {
        availableRelease != nil
    }

    var lastCheckedDisplayText: String? {
        let ts = UserPreferences.shared.lastUpdateCheckTimestamp
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        if Calendar.current.isDateInToday(date) {
            return "今天 \(RmbFormatters.hourMinute.string(from: date))"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天 \(RmbFormatters.hourMinute.string(from: date))"
        } else {
            return RmbFormatters.monthDayTime.string(from: date)
        }
    }

    // MARK: - Lifecycle Scheduling

    func startAutomaticCheckSchedule() {
        // Defer first background check slightly so app startup stays instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.performScheduledCheckIfNeeded()
            }
        }

        periodicCheckTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.automaticCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performScheduledCheckIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicCheckTimer = timer

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.performScheduledCheckIfNeeded()
                }
            }
        }
    }

    private func performScheduledCheckIfNeeded() async {
        guard UserPreferences.shared.automaticallyCheckForUpdates else { return }
        let last = UserPreferences.shared.lastUpdateCheckTimestamp
        let elapsed = Date().timeIntervalSince1970 - last
        guard last <= 0 || elapsed >= Self.automaticCheckInterval else { return }
        await checkForUpdates(userInitiated: false)
    }

    // MARK: - Check Latest GitHub Release

    func checkForUpdates(userInitiated: Bool) async {
        if isCheckingInFlight {
            // Promote an in-flight silent background check when the user manually clicks "检查更新".
            if userInitiated && !state.isBusy {
                activeCheckUserInitiated = true
                state = .checking
            }
            return
        }
        guard !state.isBusy else { return }
        isCheckingInFlight = true
        activeCheckUserInitiated = userInitiated
        defer {
            isCheckingInFlight = false
            activeCheckUserInitiated = false
        }

        if userInitiated {
            state = .checking
        }

        do {
            let release = try await fetchLatestRelease()
            UserPreferences.shared.lastUpdateCheckTimestamp = Date().timeIntervalSince1970

            let promotedUserInitiated = activeCheckUserInitiated
            // Never clobber an active download/install started while a background check was in flight.
            if !promotedUserInitiated && state.isBusy {
                return
            }

            let currentVersion = SemanticVersion(AppConstants.bundleVersion ?? "0.0.0")
                ?? SemanticVersion("0.0.0")!

            if release.version > currentVersion {
                availableRelease = release
                state = .available(release)
            } else {
                availableRelease = nil
                if promotedUserInitiated {
                    state = .upToDate(currentVersion: AppConstants.displayVersion)
                } else {
                    switch state {
                    case .available, .error:
                        state = .idle
                    default:
                        break
                    }
                }
            }
        } catch {
            if activeCheckUserInitiated {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                state = .error(message: message, release: availableRelease)
            }
        }
    }

    // MARK: - Download, Verify & Atomic Install

    func downloadAndInstallUpdate() {
        guard !state.isBusy else { return }

        let targetRelease: AppUpdateRelease?
        switch state {
        case .available(let release):
            targetRelease = release
        case .error(_, let release):
            targetRelease = release ?? availableRelease
        default:
            targetRelease = availableRelease
        }

        guard let release = targetRelease else { return }

        guard release.isDirectZipInstallable, let downloadURL = release.downloadURL else {
            openReleasePage(for: release)
            return
        }

        // Transition synchronously before spawning the Task so rapid double-clicks cannot launch two downloads.
        downloadToken += 1
        let currentToken = downloadToken
        state = .downloading(
            release: release,
            progress: 0,
            writtenBytes: 0,
            totalBytes: release.assetSizeBytes ?? 0
        )

        Task { @MainActor in
            await performDownloadAndInstall(release: release, downloadURL: downloadURL, token: currentToken)
        }
    }

    func cancelDownload() {
        downloadToken += 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
        if let release = availableRelease {
            state = .available(release)
        } else {
            state = .idle
        }
    }

    func openReleasePage(for release: AppUpdateRelease? = nil) {
        let url = release?.releasePageURL
            ?? availableRelease?.releasePageURL
            ?? URL(string: GithubConstants.releasesPage)!
        NSWorkspace.shared.open(url)
    }

    private func performDownloadAndInstall(release: AppUpdateRelease, downloadURL: URL, token currentToken: Int) async {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("PikoUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            if downloadToken == currentToken {
                state = .error(message: "无法创建临时下载目录：\(error.localizedDescription)", release: release)
            }
            return
        }
        activeWorkDir = workDir
        var ownedSession: URLSession?

        defer {
            ownedSession?.finishTasksAndInvalidate()
            if downloadToken == currentToken {
                activeDownloadTask = nil
                activeDownloadSession = nil
            }
        }

        let zipURL = workDir.appendingPathComponent(release.assetName ?? "Piko-update.zip")
        let expectedBytes = release.assetSizeBytes ?? 0

        do {
            let downloadedZip = try await downloadFile(
                from: downloadURL,
                to: zipURL,
                token: currentToken,
                onSessionCreated: { ownedSession = $0 }
            ) { [weak self] written, total in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadToken == currentToken else { return }
                    guard case .downloading = self.state else { return }
                    let resolvedTotal = total > 0 ? total : expectedBytes
                    let progress = resolvedTotal > 0 ? min(1.0, max(0.0, Double(written) / Double(resolvedTotal))) : 0
                    self.state = .downloading(
                        release: release,
                        progress: progress,
                        writtenBytes: written,
                        totalBytes: resolvedTotal
                    )
                }
            }

            guard downloadToken == currentToken else {
                try? fm.removeItem(at: workDir)
                return
            }

            state = .verifying(release)

            guard let expectedSHA = release.expectedSHA256 else {
                throw UpdateInstallError.noDownloadableAsset
            }
            let currentBundleURL = Bundle.main.bundleURL
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.verifyAndStageUpdate(
                    zipURL: downloadedZip,
                    workDir: workDir,
                    expectedSHA256: expectedSHA,
                    currentBundleURL: currentBundleURL
                )
            }.value

            guard downloadToken == currentToken else {
                try? fm.removeItem(at: workDir)
                return
            }

            state = .installing(release)
            try launchUpdaterScriptAndTerminate(
                release: release,
                targetAppURL: prepared.targetAppURL,
                stagedAppURL: prepared.stagedAppURL,
                workDir: workDir
            )
        } catch let nsError as NSError where nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            try? fm.removeItem(at: workDir)
            if activeWorkDir == workDir {
                activeWorkDir = nil
            }
            return
        } catch UpdateInstallError.targetNotWritable(let stagedAppURL) {
            NSWorkspace.shared.activateFileViewerSelecting([stagedAppURL])
            if downloadToken == currentToken {
                state = .error(
                    message: UpdateInstallError.targetNotWritable(stagedAppURL: stagedAppURL).localizedDescription,
                    release: release
                )
            }
        } catch {
            try? fm.removeItem(at: workDir)
            if activeWorkDir == workDir {
                activeWorkDir = nil
            }
            guard downloadToken == currentToken else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .error(message: message, release: release)
        }
    }

    private func downloadFile(
        from url: URL,
        to destinationURL: URL,
        token currentToken: Int,
        onSessionCreated: (URLSession) -> Void,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        let delegate = UpdateDownloadDelegate(destinationURL: destinationURL, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        onSessionCreated(session)

        guard downloadToken == currentToken else {
            session.invalidateAndCancel()
            throw URLError(.cancelled)
        }
        activeDownloadSession = session

        var request = URLRequest(url: url)
        request.setValue("\(AppConstants.appName)/\(AppConstants.bundleVersion ?? "0")", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            delegate.setContinuation(continuation)
            let task = session.downloadTask(with: request)
            self.activeDownloadTask = task
            task.resume()
        }
    }

    // MARK: - Verification & Staging (Off Main Thread)

    private struct PreparedUpdate {
        let targetAppURL: URL
        let stagedAppURL: URL
    }

    nonisolated private static func verifyAndStageUpdate(
        zipURL: URL,
        workDir: URL,
        expectedSHA256: String?,
        currentBundleURL: URL
    ) throws -> PreparedUpdate {
        if let expectedSHA256 {
            let data = try Data(contentsOf: zipURL)
            let digest = SHA256.hash(data: data)
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            if actual.lowercased() != expectedSHA256.lowercased() {
                throw UpdateInstallError.sha256Mismatch(expected: expectedSHA256, actual: actual)
            }
        }

        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let dittoResult = runSyncProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipURL.path, extractDir.path]
        )
        guard dittoResult.status == 0 else {
            throw UpdateInstallError.extractionFailed(dittoResult.stderr.isEmpty ? "ditto exit \(dittoResult.status)" : dittoResult.stderr)
        }

        guard let stagedAppURL = findAppBundle(in: extractDir) else {
            throw UpdateInstallError.appBundleNotFound
        }

        let infoPlistURL = stagedAppURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String,
              bundleId == AppConstants.mainBundleId else {
            throw UpdateInstallError.bundleIdentifierMismatch(nil)
        }

        // Remove quarantine flags from the staged bundle before verifying & replacing.
        _ = runSyncProcess(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", stagedAppURL.path]
        )

        let codesignResult = runSyncProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", stagedAppURL.path]
        )
        guard codesignResult.status == 0 else {
            throw UpdateInstallError.signatureInvalid(codesignResult.stderr)
        }

        let targetAppURL = resolveInstallTargetURL(currentBundleURL: currentBundleURL)
        let targetDir = targetAppURL.deletingLastPathComponent()
        let fm = FileManager.default
        let dirWritable = fm.isWritableFile(atPath: targetDir.path)
        let targetWritable = !fm.fileExists(atPath: targetAppURL.path) || fm.isWritableFile(atPath: targetAppURL.path)
        guard dirWritable && targetWritable else {
            throw UpdateInstallError.targetNotWritable(stagedAppURL: stagedAppURL)
        }

        return PreparedUpdate(targetAppURL: targetAppURL, stagedAppURL: stagedAppURL)
    }

    nonisolated private static func findAppBundle(in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("\(AppConstants.appName).app")
        if fm.fileExists(atPath: direct.path) {
            return direct
        }
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return children.first { $0.pathExtension.lowercased() == "app" }
    }

    nonisolated private static func resolveInstallTargetURL(currentBundleURL: URL) -> URL {
        let defaultApplicationsTarget = URL(fileURLWithPath: "/Applications/\(AppConstants.appName).app")
        let path = currentBundleURL.path
        if !path.hasSuffix(".app") || path.contains("/AppTranslocation/") {
            return defaultApplicationsTarget
        }
        if let values = try? currentBundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return defaultApplicationsTarget
        }
        return currentBundleURL
    }

    nonisolated private static func runSyncProcess(
        executable: String,
        arguments: [String]
    ) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            // Drain stderr BEFORE waitUntilExit() to prevent 64KB pipe deadlock.
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, errStr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func launchUpdaterScriptAndTerminate(
        release: AppUpdateRelease,
        targetAppURL: URL,
        stagedAppURL: URL,
        workDir: URL
    ) throws {
        let script = """
        PID="$1"
        TARGET="$2"
        STAGED="$3"
        WORKDIR="$4"
        BACKUP="${TARGET}.piko-backup.$$"
        trap 'rm -rf "$WORKDIR"' EXIT

        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 200 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        if kill -0 "$PID" 2>/dev/null; then
            exit 1
        fi

        if [ -e "$TARGET" ]; then
            mv "$TARGET" "$BACKUP" || exit 1
        fi

        if mv "$STAGED" "$TARGET"; then
            rm -rf "$BACKUP"
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            /usr/bin/open "$TARGET"
        else
            rm -rf "$TARGET"
            if [ -e "$BACKUP" ]; then
                mv "$BACKUP" "$TARGET"
                /usr/bin/open "$TARGET"
            fi
            exit 1
        fi
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "piko-updater",
            String(ProcessInfo.processInfo.processIdentifier),
            targetAppURL.path,
            stagedAppURL.path,
            workDir.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Recover gracefully if the helper script times out or fails while the app is still alive.
        process.terminationHandler = { [weak self] proc in
            guard proc.terminationStatus != 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, case .installing = self.state else { return }
                self.state = .error(
                    message: "自动安装未能完成（退出码 \(proc.terminationStatus)），请重试或前往网页手动下载",
                    release: release
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw UpdateInstallError.launchHelperFailed(error.localizedDescription)
        }

        // Keep workDir owned by the detached helper script; don't delete it here.
        activeWorkDir = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSApp.modalWindow != nil {
                NSApp.abortModal()
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: - GitHub API Fetching & Parsing

    private func fetchLatestRelease() async throws -> AppUpdateRelease {
        guard let url = URL(string: GithubConstants.latestReleaseAPIURL) else {
            throw UpdateInstallError.invalidResponse
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppConstants.appName)/\(AppConstants.bundleVersion ?? "0")", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateInstallError.invalidResponse
        }
        if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
            throw UpdateInstallError.rateLimited
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateInstallError.httpStatus(httpResponse.statusCode)
        }

        let dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        guard let version = SemanticVersion(dto.tagName) ?? SemanticVersion(dto.name ?? ""),
              let pageURL = URL(string: dto.htmlURL) else {
            throw UpdateInstallError.invalidResponse
        }

        let selectedAsset = Self.selectBestAsset(from: dto.assets)
        let notes = dto.body ?? ""
        let expectedSHA256 = selectedAsset.flatMap { Self.extractSHA256(for: $0.name, from: notes) }

        let isoFormatter = ISO8601DateFormatter()
        let publishedDate = dto.publishedAt.flatMap { isoFormatter.date(from: $0) }

        return AppUpdateRelease(
            tagName: dto.tagName,
            version: version,
            title: dto.name ?? dto.tagName,
            notes: notes,
            releasePageURL: pageURL,
            publishedAt: publishedDate,
            assetName: selectedAsset?.name,
            downloadURL: selectedAsset.flatMap { URL(string: $0.browserDownloadURL) },
            assetSizeBytes: selectedAsset?.size,
            expectedSHA256: expectedSHA256
        )
    }

    nonisolated private static func selectBestAsset(from assets: [GitHubReleaseDTO.AssetDTO]) -> GitHubReleaseDTO.AssetDTO? {
        #if arch(arm64)
        let archToken = "arm64"
        let incompatibleTokens = ["x86_64", "intel", "amd64"]
        #else
        let archToken = "x86_64"
        let incompatibleTokens = ["arm64", "apple-silicon"]
        #endif

        func isCompatible(_ name: String) -> Bool {
            let lower = name.lowercased()
            if lower.contains("universal") {
                return true
            }
            if lower.contains("arm64") && (lower.contains("x86_64") || lower.contains("intel") || lower.contains("amd64")) {
                return true
            }
            return !incompatibleTokens.contains(where: { lower.contains($0) })
        }

        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") && isCompatible($0.name) }
        if let archZip = zips.first(where: { $0.name.lowercased().contains(archToken) }) {
            return archZip
        }
        if let universalZip = zips.first(where: { $0.name.lowercased().contains("universal") }) {
            return universalZip
        }
        if let anyCompatibleZip = zips.first {
            return anyCompatibleZip
        }

        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") && isCompatible($0.name) }
        if let archDmg = dmgs.first(where: { $0.name.lowercased().contains(archToken) }) {
            return archDmg
        }
        return dmgs.first
    }

    nonisolated static func extractSHA256(for assetName: String, from releaseNotes: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: assetName)
        guard let nameRegex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9._-])\(escapedName)(?![A-Za-z0-9._-])"
        ),
              let hashRegex = try? NSRegularExpression(
                pattern: "(?<![0-9a-fA-F])([0-9a-fA-F]{64})(?![0-9a-fA-F])"
              ) else {
            return nil
        }

        for line in releaseNotes.components(separatedBy: .newlines) {
            let lineRange = NSRange(line.startIndex..., in: line)
            guard let nameMatch = nameRegex.firstMatch(in: line, range: lineRange) else {
                continue
            }
            let hashes = hashRegex.matches(in: line, range: lineRange)
            guard !hashes.isEmpty else { continue }

            let nameEnd = NSMaxRange(nameMatch.range)
            let nameStart = nameMatch.range.location

            // Prefer the closest standalone 64-hex token AFTER the exact filename (e.g. `file.zip (SHA-256): <hash>`),
            // otherwise fall back to the closest standalone 64-hex token BEFORE it (e.g. `shasum -a 256` output).
            let chosenMatch = hashes
                .filter { $0.range.location >= nameEnd }
                .min(by: { $0.range.location < $1.range.location })
                ?? hashes
                .filter { NSMaxRange($0.range) <= nameStart }
                .max(by: { NSMaxRange($0.range) < NSMaxRange($1.range) })

            if let match = chosenMatch, let swiftRange = Range(match.range(at: 1), in: line) {
                return String(line[swiftRange]).lowercased()
            }
        }
        return nil
    }
}
