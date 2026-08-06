import AppKit
import Foundation
import ServiceManagement

private struct RateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Int {
        min(100, max(0, Int((100 - usedPercent).rounded())))
    }

    var label: String {
        switch windowMinutes {
        case 0..<60: return "\(windowMinutes)м"
        case 60..<1_440 where windowMinutes.isMultiple(of: 60): return "\(windowMinutes / 60)ч"
        case 1_440..<10_080 where windowMinutes.isMultiple(of: 1_440): return "\(windowMinutes / 1_440)д"
        case 10_080 where windowMinutes.isMultiple(of: 10_080): return "\(windowMinutes / 10_080)н"
        default: return "\(windowMinutes)м"
        }
    }
}

private struct UsageSnapshot: Equatable {
    let windows: [RateWindow]
    let updatedAt: Date
    let activeSessions: Int
    let sessions: [SessionBrief]
    let recentMCPs: [String]
}

private enum SessionState: String {
    case working
    case paused
    case completed

    var label: String {
        switch self {
        case .working: return "работает"
        case .paused: return "без новых событий"
        case .completed: return "завершена"
        }
    }
}

private struct SessionBrief: Identifiable, Equatable {
    let id: String
    let state: SessionState
    let lastActivity: Date
    let taskCount: Int
}

private struct SessionUsage: Codable, Identifiable {
    let id: String
    let startedAt: Date?
    let completedAt: Date?
    let taskCount: Int
    let neuralWorkSeconds: Int
    let mcpCalls: Int
    let toolCalls: Int
    let skillReads: Int
    let codeLinesAdded: Int
    let codeLinesRemoved: Int
    let mcpByName: [String: Int]
    /// Internal ARC attribution. Optional to preserve compatibility with old reports.
    let arcRepository: String?
    let arcMeaningfulCodeLinesAdded: Int?
}

private struct UsageTotals: Codable {
    let sessions: Int
    let tasks: Int
    let neuralWorkSeconds: Int
    let mcpCalls: Int
    let toolCalls: Int
    let skillReads: Int
    let codeLinesAdded: Int
    let codeLinesRemoved: Int
    let arcRepositories: Int?
    let arcMeaningfulCodeLinesAdded: Int?
}

private struct DailyUsageReport: Codable {
    let day: String
    let generatedAt: Date
    let totals: UsageTotals
    let sessions: [SessionUsage]
}

private struct RateSample: Codable {
    let recordedAt: Date
    let remainingByWindow: [Int: Int]
}

private final class CodexStateReader {
    private let fileManager = FileManager.default
    private let codexDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    func load() -> UsageSnapshot {
        let files = sessionFiles()
        let latest = latestRateLimits()
        let sessions = recentSessions(from: files)
        return UsageSnapshot(
            windows: latest?.windows ?? [],
            updatedAt: latest?.updatedAt ?? .now,
            activeSessions: activeSessionCount(from: files),
            sessions: sessions,
            recentMCPs: recentMCPs()
        )
    }

    private func activeSessionCount(from files: [(url: URL, modificationDate: Date)]) -> Int {
        let cutoff = Date.now.addingTimeInterval(-86_400)
        return files.reduce(into: 0) { count, file in
            guard file.modificationDate >= cutoff, lastPayloadType(in: file.url) != "task_complete" else { return }
            count += 1
        }
    }

    private func recentSessions(from files: [(url: URL, modificationDate: Date)]) -> [SessionBrief] {
        let workingCutoff = Date.now.addingTimeInterval(-120)
        return files.prefix(5).map { file in
            let lastType = lastPayloadType(in: file.url)
            let state: SessionState
            if lastType == "task_complete" {
                state = .completed
            } else if file.modificationDate >= workingCutoff {
                state = .working
            } else {
                state = .paused
            }
            return SessionBrief(
                id: threadID(from: file.url) ?? file.url.deletingPathExtension().lastPathComponent,
                state: state,
                lastActivity: file.modificationDate,
                taskCount: taskCount(in: file.url)
            )
        }
    }

    private func latestRateLimits() -> (windows: [RateWindow], updatedAt: Date)? {
        for file in sessionFiles().prefix(30) {
            if let limits = latestRateLimits(in: file.url) { return limits }
        }
        return nil
    }

    private func sessionFiles() -> [(url: URL, modificationDate: Date)] {
        let sessionsURL = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate
            else { return nil }
            return (url, modificationDate)
        }
        .sorted { $0.modificationDate > $1.modificationDate }
    }

    private func lastPayloadType(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }
            return type
        }
        return nil
    }

    private func taskCount(in file: URL) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).reduce(into: 0) { count, line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "task_complete"
            else { return }
            count += 1
        }
    }

    private func latestRateLimits(in file: URL) -> (windows: [RateWindow], updatedAt: Date)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let windows = ["primary", "secondary"].compactMap { key -> RateWindow? in
                guard let value = limits[key] as? [String: Any],
                      let usedPercent = value["used_percent"] as? Double,
                      let minutes = value["window_minutes"] as? Int
                else { return nil }
                let resetTimestamp = (value["resets_at"] as? NSNumber)?.doubleValue
                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: minutes,
                    resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
                )
            }
            guard !windows.isEmpty else { continue }
            let updatedAt = (event["timestamp"] as? String).flatMap(Self.isoDate) ?? .now
            return (windows, updatedAt)
        }
        return nil
    }

    private func recentMCPs() -> [String] {
        let cutoff = Date.now.addingTimeInterval(-300)
        var names = Set<String>()
        for file in sessionFiles().prefix(30) where file.modificationDate >= cutoff {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = (event["timestamp"] as? String).flatMap(Self.isoDate), timestamp >= cutoff,
                      let payload = event["payload"] as? [String: Any], payload["type"] as? String == "mcp_tool_call_end",
                      let invocation = payload["invocation"] as? [String: Any],
                      let server = invocation["server"] as? String, let tool = invocation["tool"] as? String
                else { continue }
                names.insert("\(server)/\(tool)")
            }
        }
        return names.sorted()
    }

    private static func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func threadID(from url: URL) -> String? {
        let pattern = #"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }
}

private final class DailyUsageReporter {
    private let fileManager = FileManager.default
    private let codexDirectory: URL
    private let reportsDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        reportsDirectory = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Codex Quota Reports", isDirectory: true)
    }

    func write(_ report: DailyUsageReport) throws -> URL {
        let dayDirectory = reportsDirectory.appendingPathComponent(report.day, isDirectory: true)
        try fileManager.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report.totals).write(to: dayDirectory.appendingPathComponent("summary.json"), options: .atomic)
        try encoder.encode(report.sessions).write(to: dayDirectory.appendingPathComponent("sessions.json"), options: .atomic)
        try csv(for: report).data(using: .utf8)?.write(to: dayDirectory.appendingPathComponent("summary.csv"), options: .atomic)
        return dayDirectory
    }

    func currentDayReport() -> DailyUsageReport {
        let sessions = todaySessionFiles().compactMap(sessionUsage(in:)).sorted { $0.id < $1.id }
        let totals = UsageTotals(
            sessions: sessions.count,
            tasks: sessions.reduce(0) { $0 + $1.taskCount },
            neuralWorkSeconds: sessions.reduce(0) { $0 + $1.neuralWorkSeconds },
            mcpCalls: sessions.reduce(0) { $0 + $1.mcpCalls },
            toolCalls: sessions.reduce(0) { $0 + $1.toolCalls },
            skillReads: sessions.reduce(0) { $0 + $1.skillReads },
            codeLinesAdded: sessions.reduce(0) { $0 + $1.codeLinesAdded },
            codeLinesRemoved: sessions.reduce(0) { $0 + $1.codeLinesRemoved },
            arcRepositories: Set(sessions.compactMap(\.arcRepository)).count,
            arcMeaningfulCodeLinesAdded: sessions.reduce(0) { $0 + ($1.arcMeaningfulCodeLinesAdded ?? 0) }
        )
        return DailyUsageReport(day: Self.dayString(for: .now), generatedAt: .now, totals: totals, sessions: sessions)
    }

    func savedReports(limit: Int = 7) -> [DailyUsageReport] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap(loadSavedReport(from:))
    }

    private func loadSavedReport(from directory: URL) -> DailyUsageReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let totalsData = try? Data(contentsOf: directory.appendingPathComponent("summary.json")),
              let sessionsData = try? Data(contentsOf: directory.appendingPathComponent("sessions.json")),
              let totals = try? decoder.decode(UsageTotals.self, from: totalsData),
              let sessions = try? decoder.decode([SessionUsage].self, from: sessionsData)
        else { return nil }
        return DailyUsageReport(day: directory.lastPathComponent, generatedAt: .distantPast, totals: totals, sessions: sessions)
    }

    private func todaySessionFiles() -> [URL] {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        guard let year = components.year, let month = components.month, let day = components.day else { return [] }
        let directory = codexDirectory
            .appendingPathComponent("sessions/\(year)", isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }
    }

    private func sessionUsage(in file: URL) -> SessionUsage? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), let id = Self.threadID(from: file) else { return nil }
        var startedAt: Date?
        var completedAt: Date?
        var openTaskStartedAt: Date?
        var taskCount = 0
        var neuralWorkSeconds = 0
        var mcpCalls = 0
        var toolCalls = 0
        var skillReads = 0
        var codeLinesAdded = 0
        var codeLinesRemoved = 0
        var mcpByName: [String: Int] = [:]
        var arcRepository: String?
        var arcMeaningfulCodeLinesAdded = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any]
            else { continue }
            if event["type"] as? String == "session_meta", let cwd = payload["cwd"] as? String {
                arcRepository = Self.arcRepositoryName(for: cwd)
            }
            guard let type = payload["type"] as? String else { continue }
            let timestamp = (event["timestamp"] as? String).flatMap(Self.isoDate)
            switch type {
            case "task_started":
                startedAt = startedAt ?? timestamp
                openTaskStartedAt = timestamp
            case "task_complete":
                taskCount += 1
                completedAt = timestamp
                neuralWorkSeconds += Int(((payload["duration_ms"] as? NSNumber)?.doubleValue ?? 0) / 1_000)
                openTaskStartedAt = nil
            case "function_call", "custom_tool_call":
                toolCalls += 1
                if let input = payload["input"] as? String, input.contains(".codex/skills/"), input.contains("SKILL.md") {
                    skillReads += 1
                }
            case "mcp_tool_call_end":
                mcpCalls += 1
                if let invocation = payload["invocation"] as? [String: Any],
                   let server = invocation["server"] as? String, let tool = invocation["tool"] as? String {
                    mcpByName["\(server)/\(tool)", default: 0] += 1
                }
            case "patch_apply_end":
                let changes = payload["changes"] as? [String: Any] ?? [:]
                for (path, change) in changes where Self.isCodeFile(path) {
                    guard let diff = (change as? [String: Any])?["unified_diff"] as? String else { continue }
                    for diffLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                        if diffLine.hasPrefix("+") && !diffLine.hasPrefix("+++") { codeLinesAdded += 1 }
                        if diffLine.hasPrefix("-") && !diffLine.hasPrefix("---") { codeLinesRemoved += 1 }
                        if arcRepository != nil, Self.isMeaningfulAddedCodeLine(diffLine) {
                            arcMeaningfulCodeLinesAdded += 1
                        }
                    }
                }
            default: break
            }
        }

        if let openTaskStartedAt { neuralWorkSeconds += max(0, Int(Date.now.timeIntervalSince(openTaskStartedAt))) }
        return SessionUsage(
            id: id, startedAt: startedAt, completedAt: completedAt, taskCount: taskCount,
            neuralWorkSeconds: neuralWorkSeconds, mcpCalls: mcpCalls, toolCalls: toolCalls,
            skillReads: skillReads, codeLinesAdded: codeLinesAdded, codeLinesRemoved: codeLinesRemoved,
            mcpByName: mcpByName,
            arcRepository: arcRepository,
            arcMeaningfulCodeLinesAdded: arcRepository == nil ? nil : arcMeaningfulCodeLinesAdded
        )
    }

    private func csv(for report: DailyUsageReport) -> String {
        let header = "session_id,tasks,neural_work_seconds,mcp_calls,tool_calls,skill_reads,code_lines_added,code_lines_removed,arc_repository,arc_ai_meaningful_code_lines_added\n"
        let rows = report.sessions.map {
            "\($0.id),\($0.taskCount),\($0.neuralWorkSeconds),\($0.mcpCalls),\($0.toolCalls),\($0.skillReads),\($0.codeLinesAdded),\($0.codeLinesRemoved),\($0.arcRepository ?? ""),\($0.arcMeaningfulCodeLinesAdded ?? 0)"
        }
        return header + rows.joined(separator: "\n") + "\n"
    }

    private static func isCodeFile(_ path: String) -> Bool {
        ["c", "cc", "cpp", "cs", "go", "java", "js", "jsx", "kt", "kts", "m", "mm", "php", "py", "rb", "rs", "swift", "ts", "tsx"].contains {
            path.lowercased().hasSuffix(".\($0)")
        }
    }

    /// Arcadia mounts expose `.arcadia.root` at their true root. Walking upwards
    /// from Codex's cwd correctly handles an arbitrary number of virtual mounts
    /// and deliberately does not invoke Git or GitHub.
    private static func arcRepositoryName(for workingDirectory: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        while candidate.path != "/" {
            let marker = candidate.appendingPathComponent(".arcadia.root", isDirectory: false)
            if fileManager.fileExists(atPath: marker.path) {
                return candidate.lastPathComponent
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func isMeaningfulAddedCodeLine(_ diffLine: Substring) -> Bool {
        guard diffLine.hasPrefix("+"), !diffLine.hasPrefix("+++") else { return false }
        let line = diffLine.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        guard !line.hasPrefix("//"), !line.hasPrefix("/*"), !line.hasPrefix("*"), !line.hasPrefix("*/") else { return false }
        if line.hasPrefix("#"), !line.hasPrefix("#include"), !line.hasPrefix("#if"), !line.hasPrefix("#define"), !line.hasPrefix("#pragma") {
            return false
        }
        return !["{", "}", "};", "(", ")", ",", ";"].contains(String(line))
    }

    private static func threadID(from url: URL) -> String? {
        let pattern = #"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    private static func isoDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private final class RateHistoryStore {
    private let fileManager = FileManager.default
    private let fileURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexQuotaMenu", isDirectory: true)
            .appendingPathComponent("rate-history.json")
    }

    @discardableResult
    func record(_ snapshot: UsageSnapshot) -> [RateSample] {
        guard !snapshot.windows.isEmpty else { return samples() }
        var history = samples()
        let sample = RateSample(
            recordedAt: .now,
            remainingByWindow: Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.windowMinutes, $0.remainingPercent) })
        )
        if let last = history.last, Date.now.timeIntervalSince(last.recordedAt) < 60 {
            history[history.count - 1] = sample
        } else {
            history.append(sample)
        }
        let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
        history.removeAll { $0.recordedAt < cutoff }
        save(history)
        return history
    }

    func samples() -> [RateSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RateSample].self, from: data)) ?? []
    }

    private func save(_ history: [RateSample]) {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history).write(to: fileURL, options: .atomic)
        } catch {
            // История — дополнительная функция; ошибки записи не мешают индикатору.
        }
    }
}

@MainActor
private final class AppSettings {
    private enum Key {
        static let showMCPs = "showRecentMCPs"
        static let exportDailyReports = "exportDailyReports"
        static let refreshInterval = "refreshInterval"
    }

    private let defaults = UserDefaults.standard
    var showRecentMCPs: Bool { didSet { defaults.set(showRecentMCPs, forKey: Key.showMCPs) } }
    var exportDailyReports: Bool { didSet { defaults.set(exportDailyReports, forKey: Key.exportDailyReports) } }
    var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) } }

    init() {
        showRecentMCPs = defaults.object(forKey: Key.showMCPs) as? Bool ?? false
        exportDailyReports = defaults.object(forKey: Key.exportDailyReports) as? Bool ?? true
        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = [1.0, 5.0, 15.0, 30.0].contains(storedInterval) ? storedInterval : 5
    }

    var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Codex Quota Reports", isDirectory: true)
    }

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private let didChange: () -> Void
    private let showMCPsCheckbox = NSButton(checkboxWithTitle: "Показывать недавние MCP в строке меню", target: nil, action: nil)
    private let exportReportsCheckbox = NSButton(checkboxWithTitle: "Сохранять ежедневные отчёты", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Запускать при входе в macOS", target: nil, action: nil)
    private let refreshIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(settings: AppSettings, didChange: @escaping () -> Void) {
        self.settings = settings
        self.didChange = didChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 290),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Codex Quota — Настройки"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) { nil }

    private func configureWindow() {
        showMCPsCheckbox.state = settings.showRecentMCPs ? .on : .off
        showMCPsCheckbox.target = self
        showMCPsCheckbox.action = #selector(saveSettings)
        exportReportsCheckbox.state = settings.exportDailyReports ? .on : .off
        exportReportsCheckbox.target = self
        exportReportsCheckbox.action = #selector(saveSettings)
        launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        refreshIntervalPopup.addItems(withTitles: ["1 секунда", "5 секунд", "15 секунд", "30 секунд"])
        refreshIntervalPopup.selectItem(withTitle: "\(Int(settings.refreshInterval)) секунд")
        if settings.refreshInterval == 1 { refreshIntervalPopup.selectItem(withTitle: "1 секунда") }
        refreshIntervalPopup.target = self
        refreshIntervalPopup.action = #selector(saveSettings)

        let description = NSTextField(wrappingLabelWithString: "Отчёты хранятся локально в Documents/Codex Quota Reports.")
        description.textColor = .secondaryLabelColor
        let openReports = NSButton(title: "Открыть папку отчётов", target: self, action: #selector(openReportsDirectory))
        let intervalRow = NSStackView(views: [NSTextField(labelWithString: "Обновлять:"), refreshIntervalPopup])
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY
        intervalRow.spacing = 8
        let stack = NSStackView(views: [showMCPsCheckbox, exportReportsCheckbox, launchAtLoginCheckbox, intervalRow, description, openReports])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window?.contentView = stack
    }

    @objc private func saveSettings() {
        settings.showRecentMCPs = showMCPsCheckbox.state == .on
        settings.exportDailyReports = exportReportsCheckbox.state == .on
        settings.refreshInterval = Double(refreshIntervalPopup.selectedItem?.title.split(separator: " ").first ?? "5") ?? 5
        didChange()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(launchAtLoginCheckbox.state == .on)
        } catch {
            launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openReportsDirectory() {
        try? FileManager.default.createDirectory(at: settings.reportsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.reportsDirectory)
    }
}

private final class RateHistoryGraphView: NSView {
    var samples: [RateSample] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 14, dy: 22)
        NSColor.quaternaryLabelColor.setStroke()
        let grid = NSBezierPath()
        for level in [0.0, 0.5, 1.0] {
            let y = rect.minY + rect.height * level
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        grid.lineWidth = 1
        grid.stroke()

        let keys = Array(Set(samples.flatMap { $0.remainingByWindow.keys })).sorted()
        for (index, key) in keys.enumerated() {
            let points = samples.enumerated().compactMap { offset, sample -> NSPoint? in
                guard let remaining = sample.remainingByWindow[key] else { return nil }
                let x = samples.count == 1 ? rect.midX : rect.minX + rect.width * CGFloat(offset) / CGFloat(samples.count - 1)
                return NSPoint(x: x, y: rect.minY + rect.height * CGFloat(remaining) / 100)
            }
            guard let first = points.first else { continue }
            let line = NSBezierPath()
            line.move(to: first)
            for point in points.dropFirst() { line.line(to: point) }
            [NSColor.systemBlue, NSColor.systemGreen, NSColor.systemOrange][index % 3].setStroke()
            line.lineWidth = 2
            line.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        "0%                         Остаток лимита                         100%".draw(at: NSPoint(x: 14, y: 4), withAttributes: attributes)
    }
}

private final class DailyHistoryGraphView: NSView {
    var reports: [DailyUsageReport] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !reports.isEmpty else { return }
        let rect = bounds.insetBy(dx: 14, dy: 22)
        let maxSeconds = max(1, reports.map(\.totals.neuralWorkSeconds).max() ?? 1)
        let slotWidth = rect.width / CGFloat(reports.count)
        let barWidth = slotWidth * 0.6
        for (index, report) in reports.enumerated() {
            let height = rect.height * CGFloat(report.totals.neuralWorkSeconds) / CGFloat(maxSeconds)
            let bar = NSRect(x: rect.minX + CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2, y: rect.minY, width: barWidth, height: height)
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            String(report.day.suffix(5)).draw(at: NSPoint(x: bar.minX, y: 4), withAttributes: attributes)
        }
    }
}

@MainActor
private final class HistoryWindowController: NSWindowController {
    private let rateHistory: RateHistoryStore
    private let reporter: DailyUsageReporter
    private let rateGraph = RateHistoryGraphView()
    private let dailyGraph = DailyHistoryGraphView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let daysLabel = NSTextField(wrappingLabelWithString: "")

    init(rateHistory: RateHistoryStore, reporter: DailyUsageReporter) {
        self.rateHistory = rateHistory
        self.reporter = reporter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Codex Quota — История"
        window.minSize = NSSize(width: 520, height: 440)
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) { nil }

    func reload(currentReport: DailyUsageReport) {
        rateGraph.samples = rateHistory.samples()
        var reports = reporter.savedReports(limit: 7).filter { $0.day != currentReport.day }
        reports.append(currentReport)
        reports.sort { $0.day < $1.day }
        dailyGraph.reports = reports
        let yesterday = reports.last(where: { $0.day != currentReport.day })
        let comparison: String
        if let yesterday {
            let workDelta = currentReport.totals.neuralWorkSeconds - yesterday.totals.neuralWorkSeconds
            let mcpDelta = currentReport.totals.mcpCalls - yesterday.totals.mcpCalls
            comparison = "К вчера: \(workDelta >= 0 ? "+" : "")\(Self.duration(workDelta)) работы · MCP \(mcpDelta >= 0 ? "+" : "")\(mcpDelta)"
        } else {
            comparison = "Сравнение со вчера появится после первого сохранённого отчёта."
        }
        summaryLabel.stringValue = "Сегодня: \(Self.duration(currentReport.totals.neuralWorkSeconds)) · задач \(currentReport.totals.tasks) · MCP \(currentReport.totals.mcpCalls) · Tools \(currentReport.totals.toolCalls) · Skills \(currentReport.totals.skillReads) · код +\(currentReport.totals.codeLinesAdded) · ARC AI-код +\(currentReport.totals.arcMeaningfulCodeLinesAdded ?? 0) (репо \(currentReport.totals.arcRepositories ?? 0)). \(comparison)"
        daysLabel.stringValue = reports.map { "\($0.day): \(Self.duration($0.totals.neuralWorkSeconds)), задач \($0.totals.tasks), MCP \($0.totals.mcpCalls)" }.joined(separator: "\n")
    }

    private func configureWindow() {
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.maximumNumberOfLines = 3
        let rateTitle = NSTextField(labelWithString: "Расход лимита — последние 7 дней")
        rateTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let dayTitle = NSTextField(labelWithString: "Работа по дням")
        dayTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        rateGraph.translatesAutoresizingMaskIntoConstraints = false
        dailyGraph.translatesAutoresizingMaskIntoConstraints = false
        rateGraph.heightAnchor.constraint(equalToConstant: 160).isActive = true
        dailyGraph.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [summaryLabel, rateTitle, rateGraph, dayTitle, dailyGraph, daysLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        window?.contentView = scroll
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rateGraph.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            dailyGraph.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
    }

    private static func duration(_ seconds: Int) -> String {
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        let value = hours > 0 ? "\(hours)ч \(minutes)м" : "\(minutes)м"
        return seconds < 0 ? "−\(value)" : value
    }
}

@MainActor
private final class MenuBarController: NSObject {
    private let reader = CodexStateReader()
    private let reporter = DailyUsageReporter()
    private let rateHistory = RateHistoryStore()
    private let settings = AppSettings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var snapshot: UsageSnapshot?
    private var refreshTimer: Timer?
    private var dailyReport: DailyUsageReport?
    private var lastReportUpdate = Date.distantPast
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var rateSamples: [RateSample] = []

    func start() {
        guard let button = statusItem.button else { return }
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.toolTip = "Codex: загружаю состояние…"
        refresh()
        scheduleRefreshTimer()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: settings.refreshInterval,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func refresh() {
        snapshot = reader.load()
        if let snapshot { rateSamples = rateHistory.record(snapshot) }
        refreshDailyReportIfNeeded()
        updateStatusTitle()
        statusItem.menu = makeMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openReportsDirectory() {
        try? FileManager.default.createDirectory(at: settings.reportsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.reportsDirectory)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, didChange: { [weak self] in
                self?.lastReportUpdate = .distantPast
                self?.scheduleRefreshTimer()
                self?.refresh()
            })
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        guard let dailyReport else { return }
        if historyWindow == nil {
            historyWindow = HistoryWindowController(rateHistory: rateHistory, reporter: reporter)
        }
        historyWindow?.reload(currentReport: dailyReport)
        historyWindow?.showWindow(nil)
        historyWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusTitle() {
        guard let snapshot else {
            statusItem.button?.title = "Codex —"
            return
        }
        let limits = snapshot.windows.map { "\($0.remainingPercent)%" }.joined(separator: " · ")
        let activity = snapshot.sessions.filter { $0.state == .working }.count
        let mcp = settings.showRecentMCPs && !snapshot.recentMCPs.isEmpty ? "  MCP: \(shortMCPList(snapshot.recentMCPs))" : ""
        statusItem.button?.title = "● \(snapshot.activeSessions)  \(limits)\(mcp)"
        statusItem.button?.toolTip = "Codex: \(snapshot.activeSessions) активных сессий, из них \(activity) с новыми событиями; осталось: \(limits)\(mcp)"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let snapshot {
            let working = snapshot.sessions.filter { $0.state == .working }.count
            let paused = snapshot.sessions.filter { $0.state == .paused }.count

            if let dailyReport {
                let totals = dailyReport.totals
                let report = NSMenuItem(
                    title: "Сегодня: \(formatDuration(totals.neuralWorkSeconds)) · MCP \(totals.mcpCalls) · Tools \(totals.toolCalls) · Skills \(totals.skillReads) · Код +\(totals.codeLinesAdded)",
                    action: nil, keyEquivalent: ""
                )
                report.isEnabled = false
                menu.addItem(report)
            }

            for window in snapshot.windows {
                let reset = window.resetsAt.map { " · сброс \(Self.timeFormatter.string(from: $0))" } ?? ""
                let trend = rateTrend(for: window)
                let forecast = exhaustionForecast(for: window)
                let item = NSMenuItem(title: "\(window.label): осталось \(window.remainingPercent)%\(trend)\(forecast)\(reset)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            if let dailyReport {
                let totals = dailyReport.totals
                let arcTotals = NSMenuItem(
                    title: "ARC AI-код: +\(totals.arcMeaningfulCodeLinesAdded ?? 0) содержательных строк · репозиториев \(totals.arcRepositories ?? 0)",
                    action: nil,
                    keyEquivalent: ""
                )
                arcTotals.isEnabled = false
                menu.addItem(arcTotals)
                for (repository, lines) in arcRepositorySummary(for: dailyReport) {
                    let item = NSMenuItem(title: "  \(repository): +\(lines) строк Codex", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            let sessions = NSMenuItem(title: "Активных сессий: \(snapshot.activeSessions) · с новыми событиями: \(working) · без новых событий: \(paused)", action: nil, keyEquivalent: "")
            sessions.isEnabled = false
            menu.addItem(sessions)
            for session in snapshot.sessions {
                let item = NSMenuItem(
                    title: "  \(session.id.prefix(8)) · \(session.state.label) · задач \(session.taskCount) · \(Self.timeFormatter.string(from: session.lastActivity))",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }

            if settings.showRecentMCPs {
                let title = snapshot.recentMCPs.isEmpty
                    ? "MCP за последние 5 минут: нет"
                    : "MCP за последние 5 минут: \(snapshot.recentMCPs.joined(separator: ", "))"
                let mcp = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mcp.isEnabled = false
                menu.addItem(mcp)
            }
        } else {
            let item = NSMenuItem(title: "Лимит ещё не найден", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let history = NSMenuItem(title: "История и графики…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        history.isEnabled = dailyReport != nil
        menu.addItem(history)
        let refresh = NSMenuItem(title: "Обновить", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let reports = NSMenuItem(title: "Открыть отчёты", action: #selector(openReportsDirectory), keyEquivalent: "")
        reports.target = self
        menu.addItem(reports)
        let preferences = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        let quit = NSMenuItem(title: "Выйти из Codex Quota", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func refreshDailyReportIfNeeded() {
        guard settings.exportDailyReports else {
            dailyReport = nil
            return
        }
        guard Date.now.timeIntervalSince(lastReportUpdate) >= 60 else { return }
        let report = reporter.currentDayReport()
        dailyReport = report
        lastReportUpdate = .now
        _ = try? reporter.write(report)
    }

    private func shortMCPList(_ names: [String]) -> String {
        let visible = names.prefix(2).joined(separator: ",")
        return names.count > 2 ? "\(visible) +\(names.count - 2)" : visible
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours)ч \(minutes)м" : "\(minutes)м"
    }

    private func arcRepositorySummary(for report: DailyUsageReport) -> [(String, Int)] {
        Dictionary(grouping: report.sessions.compactMap { session -> (String, Int)? in
            guard let repository = session.arcRepository else { return nil }
            return (repository, session.arcMeaningfulCodeLinesAdded ?? 0)
        }, by: { $0.0 })
        .map { repository, entries in (repository, entries.reduce(0) { $0 + $1.1 }) }
        .filter { $0.1 > 0 }
        .sorted { $0.0 < $1.0 }
    }

    private func rateTrend(for window: RateWindow) -> String {
        let target = Date.now.addingTimeInterval(-3_600)
        guard let earlier = rateSamples.filter({ $0.recordedAt <= target }).max(by: { $0.recordedAt < $1.recordedAt }),
              let previous = earlier.remainingByWindow[window.windowMinutes]
        else { return "" }
        let delta = window.remainingPercent - previous
        guard delta != 0 else { return " · без изменений за час" }
        return delta < 0 ? " · ↓ \(-delta)% за час" : " · ↑ \(delta)% за час"
    }

    private func exhaustionForecast(for window: RateWindow) -> String {
        let target = Date.now.addingTimeInterval(-15 * 60)
        guard let earlier = rateSamples.filter({ $0.recordedAt <= target }).max(by: { $0.recordedAt < $1.recordedAt }),
              let previous = earlier.remainingByWindow[window.windowMinutes]
        else { return "" }
        let elapsedMinutes = Date.now.timeIntervalSince(earlier.recordedAt) / 60
        let spentPerMinute = Double(previous - window.remainingPercent) / elapsedMinutes
        guard spentPerMinute > 0.01 else { return "" }
        let minutes = Int((Double(window.remainingPercent) / spentPerMinute).rounded())
        return " · прогноз \(formatDuration(minutes * 60))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let controller = MenuBarController()
controller.start()
app.run()
