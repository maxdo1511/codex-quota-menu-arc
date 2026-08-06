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

private struct MonthlyUsageArchive: Codable {
    let month: String
    let archivedAt: Date
    let days: Int
    let totals: UsageTotals
}

private struct RateSample: Codable {
    let recordedAt: Date
    let remainingByWindow: [Int: Int]
}

private final class CodexStateReader {
    private struct SessionFile {
        let url: URL
        var modificationDate: Date
    }

    private struct RateLimitEvent {
        let windows: [RateWindow]
        let updatedAt: Date
    }

    private struct MCPEvent {
        let timestamp: Date
        let name: String
    }

    private struct FileMetrics {
        let modificationDate: Date
        let lastPayloadType: String?
        let taskCount: Int
        let latestRateLimits: RateLimitEvent?
        let mcpEvents: [MCPEvent]
    }

    private let fileManager = FileManager.default
    private let codexDirectory: URL
    private var cachedSessionFiles: [SessionFile] = []
    private var fileMetrics: [URL: FileMetrics] = [:]
    private var lastDirectoryScan = Date.distantPast
    private let directoryScanInterval: TimeInterval = 10

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    func load() -> UsageSnapshot {
        let files = sessionFiles()
        let latest = latestRateLimits(from: files)
        let sessions = recentSessions(from: files)
        return UsageSnapshot(
            windows: latest?.windows ?? [],
            updatedAt: latest?.updatedAt ?? .now,
            activeSessions: activeSessionCount(from: files),
            sessions: sessions,
            recentMCPs: recentMCPs(from: files)
        )
    }

    private func activeSessionCount(from files: [SessionFile]) -> Int {
        let cutoff = Date.now.addingTimeInterval(-86_400)
        return files.reduce(into: 0) { count, file in
            guard file.modificationDate >= cutoff, metrics(for: file).lastPayloadType != "task_complete" else { return }
            count += 1
        }
    }

    private func recentSessions(from files: [SessionFile]) -> [SessionBrief] {
        let workingCutoff = Date.now.addingTimeInterval(-120)
        return files.prefix(5).map { file in
            let metrics = metrics(for: file)
            let lastType = metrics.lastPayloadType
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
                taskCount: metrics.taskCount
            )
        }
    }

    private func latestRateLimits(from files: [SessionFile]) -> RateLimitEvent? {
        for file in files.prefix(30) {
            if let limits = metrics(for: file).latestRateLimits { return limits }
        }
        return nil
    }

    private func sessionFiles() -> [SessionFile] {
        if Date.now.timeIntervalSince(lastDirectoryScan) >= directoryScanInterval {
            cachedSessionFiles = scanRecentSessionDirectories()
            let liveFiles = Set(cachedSessionFiles.map(\.url))
            fileMetrics = fileMetrics.filter { liveFiles.contains($0.key) }
            lastDirectoryScan = .now
        } else {
            refreshKnownFileDates()
        }
        return cachedSessionFiles
    }

    /// Codex keeps sessions in day folders. Looking at the last week avoids an
    /// expensive recursive walk through the entire archive on every refresh.
    private func scanRecentSessionDirectories() -> [SessionFile] {
        let calendar = Calendar.current
        let sessionsURL = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        var files: [SessionFile] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = sessionsURL
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files += urls.compactMap { url in
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let modificationDate = values.contentModificationDate
                else { return nil }
                return SessionFile(url: url, modificationDate: modificationDate)
            }
        }
        return files.sorted { $0.modificationDate > $1.modificationDate }
    }

    /// A one-second refresh only stats recently active files; their content is
    /// parsed again solely after their modification date changes.
    private func refreshKnownFileDates() {
        var refreshed = cachedSessionFiles
        for index in refreshed.indices.prefix(30) {
            let url = refreshed[index].url
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date != refreshed[index].modificationDate
            else { continue }
            refreshed[index].modificationDate = date
            fileMetrics.removeValue(forKey: url)
        }
        cachedSessionFiles = refreshed.sorted { $0.modificationDate > $1.modificationDate }
    }

    private func metrics(for file: SessionFile) -> FileMetrics {
        if let cached = fileMetrics[file.url], cached.modificationDate == file.modificationDate {
            return cached
        }

        var lastPayloadType: String?
        var taskCount = 0
        var latestRateLimits: RateLimitEvent?
        var mcpEvents: [MCPEvent] = []
        if let text = try? String(contentsOf: file.url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = event["payload"] as? [String: Any]
                else { continue }
                let timestamp = (event["timestamp"] as? String).flatMap(Self.isoDate)
                if let type = payload["type"] as? String {
                    lastPayloadType = type
                    if type == "task_complete" { taskCount += 1 }
                    if type == "mcp_tool_call_end",
                       let timestamp,
                       let invocation = payload["invocation"] as? [String: Any],
                       let server = invocation["server"] as? String,
                       let tool = invocation["tool"] as? String {
                        mcpEvents.append(MCPEvent(timestamp: timestamp, name: "\(server)/\(tool)"))
                        if mcpEvents.count > 100 { mcpEvents.removeFirst(mcpEvents.count - 100) }
                    }
                }
                guard let limits = payload["rate_limits"] as? [String: Any] else { continue }
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
                if !windows.isEmpty {
                    latestRateLimits = RateLimitEvent(windows: windows, updatedAt: timestamp ?? .now)
                }
            }
        }
        let metrics = FileMetrics(
            modificationDate: file.modificationDate,
            lastPayloadType: lastPayloadType,
            taskCount: taskCount,
            latestRateLimits: latestRateLimits,
            mcpEvents: mcpEvents
        )
        fileMetrics[file.url] = metrics
        return metrics
    }

    private func recentMCPs(from files: [SessionFile]) -> [String] {
        let cutoff = Date.now.addingTimeInterval(-300)
        var names = Set<String>()
        for file in files.prefix(30) where file.modificationDate >= cutoff {
            metrics(for: file).mcpEvents
                .filter { $0.timestamp >= cutoff }
                .forEach { names.insert($0.name) }
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

    /// Compresses only this app's own completed daily reports. The original
    /// folders are removed only after a non-empty ZIP has been created.
    @discardableResult
    func archiveCompletedMonths(olderThan retentionDays: Int, now: Date = .now) -> [String] {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now),
              let directories = try? fileManager.contentsOfDirectory(
                at: reportsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let datedDirectories = directories.compactMap { directory -> (url: URL, date: Date, month: String)? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let date = Self.reportDate(from: directory.lastPathComponent)
            else { return nil }
            return (directory, date, Self.monthString(for: date))
        }
        let currentMonth = Self.monthString(for: now)
        let groups = Dictionary(grouping: datedDirectories, by: \.month)
        let archivesDirectory = reportsDirectory.appendingPathComponent("Archives", isDirectory: true)
        var archivedMonths: [String] = []

        for (month, entries) in groups.sorted(by: { $0.key < $1.key }) {
            guard month != currentMonth,
                  let latestReportDate = entries.map(\.date).max(),
                  latestReportDate < cutoff
            else { continue }

            let archiveURL = archivesDirectory.appendingPathComponent("CodexQuotaMenu-\(month).zip")
            guard !fileManager.fileExists(atPath: archiveURL.path) else { continue }

            do {
                try fileManager.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
                let stagingDirectory = reportsDirectory.appendingPathComponent(".archive-\(month)-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: stagingDirectory) }

                let reports = try entries.sorted { $0.date < $1.date }.map { entry -> DailyUsageReport in
                    guard let report = loadSavedReport(from: entry.url) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try fileManager.copyItem(at: entry.url, to: stagingDirectory.appendingPathComponent(entry.url.lastPathComponent, isDirectory: true))
                    return report
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let summary = MonthlyUsageArchive(
                    month: month,
                    archivedAt: now,
                    days: reports.count,
                    totals: Self.monthlyTotals(for: reports)
                )
                try encoder.encode(summary).write(to: stagingDirectory.appendingPathComponent("monthly-summary.json"), options: .atomic)
                try zip(stagingDirectory, to: archiveURL)
                let fileSize = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize > 0 else { continue }
                try entries.forEach { try fileManager.removeItem(at: $0.url) }
                archivedMonths.append(month)
            } catch {
                // Keep the original daily reports when an archive cannot be made.
                continue
            }
        }
        return archivedMonths
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

    private static func monthlyTotals(for reports: [DailyUsageReport]) -> UsageTotals {
        let allSessions = reports.flatMap(\.sessions)
        return UsageTotals(
            sessions: allSessions.count,
            tasks: reports.reduce(0) { $0 + $1.totals.tasks },
            neuralWorkSeconds: reports.reduce(0) { $0 + $1.totals.neuralWorkSeconds },
            mcpCalls: reports.reduce(0) { $0 + $1.totals.mcpCalls },
            toolCalls: reports.reduce(0) { $0 + $1.totals.toolCalls },
            skillReads: reports.reduce(0) { $0 + $1.totals.skillReads },
            codeLinesAdded: reports.reduce(0) { $0 + $1.totals.codeLinesAdded },
            codeLinesRemoved: reports.reduce(0) { $0 + $1.totals.codeLinesRemoved },
            arcRepositories: Set(allSessions.compactMap(\.arcRepository)).count,
            arcMeaningfulCodeLinesAdded: reports.reduce(0) { $0 + ($1.totals.arcMeaningfulCodeLinesAdded ?? 0) }
        )
    }

    private static func reportDate(from directoryName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: directoryName)
    }

    private static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// `ditto` is bundled with macOS, so creating an archive does not add a
    /// runtime dependency for people who download the app from a release.
    private func zip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
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
                for (path, change) in changes where Self.isTrackableWorkFile(path) {
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

    /// Counts implementation and configuration changes made by Codex. Configuration
    /// is deliberately included: in Arcadia, meaningful AI-authored work often
    /// lives in API specs, CI and service YAML rather than a source file.
    private static func isTrackableWorkFile(_ path: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let extensions: Set<String> = [
            "c", "cc", "cpp", "cs", "css", "go", "graphql", "h", "hpp", "html",
            "java", "js", "jsx", "json", "kt", "kts", "m", "mm", "php", "proto",
            "py", "rb", "rs", "scss", "sh", "sql", "swift", "toml", "ts", "tsx",
            "vue", "xml", "yaml", "yml", "zsh"
        ]
        return extensions.contains(fileExtension)
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
        static let archiveReportsAfterDays = "archiveReportsAfterDays"
    }

    private let defaults = UserDefaults.standard
    var showRecentMCPs: Bool { didSet { defaults.set(showRecentMCPs, forKey: Key.showMCPs) } }
    var exportDailyReports: Bool { didSet { defaults.set(exportDailyReports, forKey: Key.exportDailyReports) } }
    var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) } }
    /// Zero disables archiving. Non-zero values archive closed months after the retention period.
    var archiveReportsAfterDays: Int { didSet { defaults.set(archiveReportsAfterDays, forKey: Key.archiveReportsAfterDays) } }

    init() {
        showRecentMCPs = defaults.object(forKey: Key.showMCPs) as? Bool ?? false
        exportDailyReports = defaults.object(forKey: Key.exportDailyReports) as? Bool ?? true
        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = [1.0, 5.0, 15.0, 30.0].contains(storedInterval) ? storedInterval : 5
        let storedArchivePeriod = defaults.object(forKey: Key.archiveReportsAfterDays) as? Int ?? 30
        archiveReportsAfterDays = [0, 30, 90, 180].contains(storedArchivePeriod) ? storedArchivePeriod : 30
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
    private let archiveReportsPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(settings: AppSettings, didChange: @escaping () -> Void) {
        self.settings = settings
        self.didChange = didChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
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
        archiveReportsPopup.addItems(withTitles: ["Не архивировать", "30 дней", "90 дней", "180 дней"])
        archiveReportsPopup.selectItem(withTitle: settings.archiveReportsAfterDays == 0 ? "Не архивировать" : "\(settings.archiveReportsAfterDays) дней")
        archiveReportsPopup.target = self
        archiveReportsPopup.action = #selector(saveSettings)

        let description = NSTextField(wrappingLabelWithString: "Отчёты хранятся локально в Documents/Codex Quota Reports. Архивы месяцев сохраняются в подпапке Archives.")
        description.textColor = .secondaryLabelColor
        let openReports = NSButton(title: "Открыть папку отчётов", target: self, action: #selector(openReportsDirectory))
        let intervalRow = NSStackView(views: [NSTextField(labelWithString: "Обновлять:"), refreshIntervalPopup])
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY
        intervalRow.spacing = 8
        let archiveRow = NSStackView(views: [NSTextField(labelWithString: "Архивировать месяцы через:"), archiveReportsPopup])
        archiveRow.orientation = .horizontal
        archiveRow.alignment = .centerY
        archiveRow.spacing = 8
        let stack = NSStackView(views: [showMCPsCheckbox, exportReportsCheckbox, launchAtLoginCheckbox, intervalRow, archiveRow, description, openReports])
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
        settings.archiveReportsAfterDays = Int(archiveReportsPopup.selectedItem?.title.split(separator: " ").first ?? "0") ?? 0
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

private class DashboardChartView: NSView {
    override var isFlipped: Bool { true }

    func drawSurface() -> NSRect {
        let surface = bounds.insetBy(dx: 0, dy: 0)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: surface, xRadius: 12, yRadius: 12).fill()
        return surface.insetBy(dx: 18, dy: 16)
    }

    func drawEmptyState(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

private final class RateHistoryGraphView: DashboardChartView {
    var samples: [RateSample] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = drawSurface()
        let keys = Array(Set(samples.flatMap { $0.remainingByWindow.keys })).sorted()
        guard !keys.isEmpty, samples.count > 1 else {
            drawEmptyState("История лимита начнёт строиться после первых измерений")
            return
        }

        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        for level in [0.0, 0.5, 1.0] {
            let y = rect.minY + rect.height * level
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        grid.lineWidth = 1
        grid.stroke()

        let colors = [NSColor.systemBlue, NSColor.systemTeal, NSColor.systemIndigo]
        for (index, key) in keys.enumerated() {
            let points = samples.enumerated().compactMap { offset, sample -> NSPoint? in
                guard let remaining = sample.remainingByWindow[key] else { return nil }
                let x = rect.minX + rect.width * CGFloat(offset) / CGFloat(samples.count - 1)
                let y = rect.maxY - rect.height * CGFloat(remaining) / 100
                return NSPoint(x: x, y: y)
            }
            guard let first = points.first else { continue }
            let line = NSBezierPath()
            line.move(to: first)
            for point in points.dropFirst() { line.line(to: point) }
            colors[index % colors.count].setStroke()
            line.lineWidth = 2.5
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.stroke()
        }
    }
}

private final class DailyHistoryGraphView: DashboardChartView {
    var reports: [DailyUsageReport] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = drawSurface()
        let maxSeconds = reports.map(\.totals.neuralWorkSeconds).max() ?? 0
        guard !reports.isEmpty, maxSeconds > 0 else {
            drawEmptyState("В этом периоде ещё нет работы Codex")
            return
        }

        let slotWidth = rect.width / CGFloat(reports.count)
        let barWidth = min(52, slotWidth * 0.58)
        for (index, report) in reports.enumerated() {
            let height = max(3, rect.height * CGFloat(report.totals.neuralWorkSeconds) / CGFloat(maxSeconds))
            let x = rect.minX + CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2
            let bar = NSRect(x: x, y: rect.maxY - height, width: barWidth, height: height)
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()

            let label = String(report.day.suffix(5))
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: x + (barWidth - size.width) / 2, y: rect.maxY + 5), withAttributes: attributes)
        }
    }
}

private final class MetricCardView: NSView {
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "—")

    init(title: String, tint: NSColor) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textColor = .labelColor
        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 76) }

    func setValue(_ value: String) { valueLabel.stringValue = value }
}

@MainActor
private final class HistoryWindowController: NSWindowController {
    private let rateHistory: RateHistoryStore
    private let reporter: DailyUsageReporter
    private let rateGraph = RateHistoryGraphView()
    private let dailyGraph = DailyHistoryGraphView()
    private let workCard = MetricCardView(title: "ВРЕМЯ РАБОТЫ", tint: .systemBlue)
    private let taskCard = MetricCardView(title: "ЗАДАЧИ", tint: .systemIndigo)
    private let arcCard = MetricCardView(title: "ARC AI‑КОД", tint: .systemPurple)
    private let mcpCard = MetricCardView(title: "MCP ВЫЗОВЫ", tint: .systemTeal)
    private let comparisonLabel = NSTextField(labelWithString: "")
    private let daysLabel = NSTextField(wrappingLabelWithString: "")

    init(rateHistory: RateHistoryStore, reporter: DailyUsageReporter) {
        self.rateHistory = rateHistory
        self.reporter = reporter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Codex Quota — Статистика"
        window.minSize = NSSize(width: 680, height: 590)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) { nil }

    func showCentered() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload(currentReport: DailyUsageReport) {
        rateGraph.samples = rateHistory.samples()
        var reports = reporter.savedReports(limit: 7).filter { $0.day != currentReport.day }
        reports.append(currentReport)
        reports.sort { $0.day < $1.day }
        dailyGraph.reports = reports

        let totals = currentReport.totals
        workCard.setValue(Self.duration(totals.neuralWorkSeconds))
        taskCard.setValue("\(totals.tasks)")
        arcCard.setValue("+\(totals.arcMeaningfulCodeLinesAdded ?? 0)")
        mcpCard.setValue("\(totals.mcpCalls)")

        if let yesterday = reports.last(where: { $0.day != currentReport.day }) {
            if totals.neuralWorkSeconds == 0 {
                comparisonLabel.stringValue = "Сегодня пока нет активности · вчера: \(Self.duration(yesterday.totals.neuralWorkSeconds))"
            } else {
                let delta = totals.neuralWorkSeconds - yesterday.totals.neuralWorkSeconds
                comparisonLabel.stringValue = "К вчера: \(delta >= 0 ? "+" : "")\(Self.duration(delta)) работы · ARC AI‑код +\(totals.arcMeaningfulCodeLinesAdded ?? 0)"
            }
        } else {
            comparisonLabel.stringValue = "Сравнение появится после первого сохранённого дня"
        }

        daysLabel.stringValue = reports.suffix(4).map {
            "\($0.day)    \(Self.duration($0.totals.neuralWorkSeconds))    задач \($0.totals.tasks)    ARC +\($0.totals.arcMeaningfulCodeLinesAdded ?? 0)"
        }.joined(separator: "\n")
    }

    private func configureWindow() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window?.contentView = content

        let title = NSTextField(labelWithString: "Статистика Codex")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Работа, лимиты и вклад Codex в Arcadia")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        comparisonLabel.font = .systemFont(ofSize: 12, weight: .medium)
        comparisonLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, subtitle, comparisonLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let metrics = NSStackView(views: [workCard, taskCard, arcCard, mcpCard])
        metrics.orientation = .horizontal
        metrics.alignment = .centerY
        metrics.distribution = .fillEqually
        metrics.spacing = 10

        let rateSection = section(title: "Лимит", subtitle: "Остаток по текущим окнам", chart: rateGraph, height: 150)
        let daySection = section(title: "Работа по дням", subtitle: "Длительность задач Codex", chart: dailyGraph, height: 118)

        daysLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        daysLabel.textColor = .secondaryLabelColor
        daysLabel.maximumNumberOfLines = 4
        let activityTitle = NSTextField(labelWithString: "Последние дни")
        activityTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let activity = NSStackView(views: [activityTitle, daysLabel])
        activity.orientation = .vertical
        activity.alignment = .leading
        activity.spacing = 6

        let stack = NSStackView(views: [header, metrics, rateSection, daySection, activity])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            metrics.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func section(title: String, subtitle: String, chart: NSView, height: CGFloat) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labelStack = NSStackView(views: [heading, detail])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: height).isActive = true
        let stack = NSStackView(views: [labelStack, chart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
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
    private var lastRateHistoryUpdate = Date.distantPast
    private var lastArchiveRunDay: String?
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
        let previousSnapshot = snapshot
        snapshot = reader.load()
        var shouldRebuildMenu = snapshot != previousSnapshot
        if let snapshot, Date.now.timeIntervalSince(lastRateHistoryUpdate) >= 60 {
            rateSamples = rateHistory.record(snapshot)
            lastRateHistoryUpdate = .now
            shouldRebuildMenu = true
        }
        shouldRebuildMenu = refreshDailyReportIfNeeded() || shouldRebuildMenu
        if shouldRebuildMenu {
            updateStatusTitle()
            statusItem.menu = makeMenu()
        }
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
                self?.lastArchiveRunDay = nil
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
        historyWindow?.showCentered()
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

    @discardableResult
    private func refreshDailyReportIfNeeded() -> Bool {
        guard settings.exportDailyReports else {
            let changed = dailyReport != nil
            dailyReport = nil
            return changed
        }
        guard Date.now.timeIntervalSince(lastReportUpdate) >= 60 else { return false }
        let report = reporter.currentDayReport()
        dailyReport = report
        lastReportUpdate = .now
        if (try? reporter.write(report)) != nil, lastArchiveRunDay != report.day {
            _ = reporter.archiveCompletedMonths(olderThan: settings.archiveReportsAfterDays)
            lastArchiveRunDay = report.day
        }
        return true
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
