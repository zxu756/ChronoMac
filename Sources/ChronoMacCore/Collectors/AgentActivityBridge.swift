import Foundation
import SQLite3

/// Read-only bridge that correlates system resource timelines with local AI coding agent sessions
/// (Claude Code, Codex CLI, OpenCode Desktop, Antigravity) without reading prompt bodies.
public enum AgentActivityBridge {
    public static func detectLiveAgentSummary(now: Int64 = Int64(Date().timeIntervalSince1970)) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var windows: [AgentBurstWindow] = []

        windows.append(contentsOf: scanClaudeWindows(home: home, sinceTs: now - 86_400))
        windows.append(contentsOf: scanOpenCodeWindows(home: home, sinceTs: now - 86_400))
        windows.append(contentsOf: scanCodexWindows(home: home, sinceTs: now - 86_400))

        let activeCutoff = now - 180
        let activeVendors = Array(Set(windows.filter { $0.endTs >= activeCutoff }.map(\.vendor))).sorted()
        let summary = activeVendors.joined(separator: ", ")
        return (activeVendors.count, summary, windows.sorted { $0.startTs < $1.startTs })
    }

    private static func scanClaudeWindows(home: URL, sinceTs: Int64) -> [AgentBurstWindow] {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [AgentBurstWindow] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]),
                  let mtime = vals.contentModificationDate else { continue }
            let endTs = Int64(mtime.timeIntervalSince1970)
            guard endTs >= sinceTs else { continue }
            let ctime = vals.creationDate ?? mtime.addingTimeInterval(-300)
            let startTs = max(sinceTs, min(endTs - 60, Int64(ctime.timeIntervalSince1970)))
            let projectSlug = fileURL.deletingLastPathComponent().lastPathComponent
            out.append(
                AgentBurstWindow(
                    id: "claude-\(fileURL.deletingPathExtension().lastPathComponent)",
                    vendor: "Claude Code",
                    workspace: String(projectSlug.suffix(22)),
                    startTs: startTs,
                    endTs: endTs
                )
            )
        }
        return Array(out.suffix(16))
    }

    private static func scanOpenCodeWindows(home: URL, sinceTs: Int64) -> [AgentBurstWindow] {
        let dbPath = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle = db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)

        let sql = "SELECT id, title, time_created, time_updated FROM session ORDER BY time_updated DESC LIMIT 12;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }

        var out: [AgentBurstWindow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let id = sqlite3_column_text(s, 0).map { String(cString: $0) } ?? UUID().uuidString
            let title = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? "OpenCode"
            let rawStart = sqlite3_column_int64(s, 2)
            let rawEnd = sqlite3_column_int64(s, 3)
            let startSec = rawStart > 10_000_000_000 ? rawStart / 1000 : rawStart
            let endSec = rawEnd > 10_000_000_000 ? rawEnd / 1000 : rawEnd
            guard endSec >= sinceTs else { continue }
            out.append(
                AgentBurstWindow(
                    id: "opencode-\(id)",
                    vendor: "OpenCode",
                    workspace: String(title.prefix(22)),
                    startTs: max(sinceTs, min(endSec - 60, startSec)),
                    endTs: endSec
                )
            )
        }
        return out
    }

    private static func scanCodexWindows(home: URL, sinceTs: Int64) -> [AgentBurstWindow] {
        let dbPath = home.appendingPathComponent(".codex/state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle = db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)

        let sql = "SELECT id, cwd, created_at, updated_at FROM threads ORDER BY updated_at DESC LIMIT 12;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }

        var out: [AgentBurstWindow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let id = sqlite3_column_text(s, 0).map { String(cString: $0) } ?? UUID().uuidString
            let cwd = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? "Codex"
            let rawStart = sqlite3_column_int64(s, 2)
            let rawEnd = sqlite3_column_int64(s, 3)
            let startSec = rawStart > 10_000_000_000 ? rawStart / 1000 : rawStart
            let endSec = rawEnd > 10_000_000_000 ? rawEnd / 1000 : rawEnd
            guard endSec >= sinceTs else { continue }
            out.append(
                AgentBurstWindow(
                    id: "codex-\(id)",
                    vendor: "Codex CLI",
                    workspace: URL(fileURLWithPath: cwd).lastPathComponent,
                    startTs: max(sinceTs, min(endSec - 60, startSec)),
                    endTs: endSec
                )
            )
        }
        return out
    }
}
