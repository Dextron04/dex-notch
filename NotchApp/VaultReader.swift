import Foundation

/// One row in the recall view: an agent's latest conversation, or (from search) a single session.
struct AgentSummary: Identifiable, Equatable {
    var id: URL { notePath }
    let name: String
    let sessions: Int
    let lastTitle: String
    let lastProject: String
    let lastUpdated: Date
    let notePath: URL
    let state: String   // recorder state for this agent: ok | unsupported | error
}

/// One cell per agent per day (a session counts on the day it started and the day it last changed).
struct ActivityGrid: Equatable {
    let days: [Date]                 // oldest → newest, local midnights
    let agents: [String]             // only agents with activity in the window
    let cells: [String: [Int]]       // agent → sessions per day, aligned with `days`
    let maxCount: Int
    func total(onDay i: Int) -> Int { cells.values.reduce(0) { $0 + (($1.indices.contains(i)) ? $1[i] : 0) } }
    var total: Int { cells.values.reduce(0) { $0 + $1.reduce(0, +) } }
}

struct ProjectStat: Equatable { let name: String; let sessions: Int; let turns: Int }

struct VaultSnapshot: Equatable {
    let totalSessions: Int
    let todayCount: Int      // sessions updated since local midnight
    let recorderOK: Bool     // heartbeat newer than 3 minutes
    let agents: [AgentSummary]
}

/// Reads the vault the Python recorder writes (header of each note + .recorder/status.json). No UI deps.
// ponytail: scans every note header per call (~ms for hundreds of notes). Cache by mtime if the vault grows past a few thousand.
enum VaultReader {
    static var defaultVault: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Vault") }

    private struct Note { let agent: String; let title: String; let project: String; let started: Date; let updated: Date; let turns: Int; let url: URL }

    static func snapshot(vault: URL, now: Date = Date()) -> VaultSnapshot {
        let all = notes(in: vault)
        let status = statusFile(vault)
        let states = (status?["agents"] as? [String: [String: Any]]) ?? [:]
        let lastRun = (status?["last_run"] as? String).flatMap(parseDate)
        let midnight = Calendar.current.startOfDay(for: now)

        let grouped = Dictionary(grouping: all, by: \.agent)
        let agents = grouped.keys.sorted().compactMap { name -> AgentSummary? in
            guard let last = grouped[name]?.max(by: { $0.updated < $1.updated }) else { return nil }
            return AgentSummary(name: name, sessions: grouped[name]!.count, lastTitle: last.title, lastProject: last.project,
                                lastUpdated: last.updated, notePath: last.url, state: (states[name]?["state"] as? String) ?? "ok")
        }
        return VaultSnapshot(totalSessions: all.count,
                             todayCount: all.filter { $0.updated >= midnight }.count,
                             recorderOK: lastRun.map { now.timeIntervalSince($0) < 180 } ?? false,
                             agents: agents)
    }

    /// Matches title, project or agent (case-insensitive). Empty query lists everything. Newest first, max 30.
    static func search(vault: URL, query: String) -> [AgentSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return notes(in: vault)
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.project.lowercased().contains(q) || $0.agent.lowercased().contains(q) }
            .sorted { $0.updated > $1.updated }
            .prefix(30)
            .map { AgentSummary(name: $0.agent, sessions: 1, lastTitle: $0.title, lastProject: $0.project,
                                lastUpdated: $0.updated, notePath: $0.url, state: "ok") }
    }

    static func activity(vault: URL, days: Int = 84, now: Date = Date(), calendar: Calendar = .current) -> ActivityGrid {
        let today = calendar.startOfDay(for: now)
        let grid = (0..<days).map { calendar.date(byAdding: .day, value: $0 - (days - 1), to: today)! }
        var cells: [String: [Int]] = [:]
        for n in notes(in: vault) {
            var seen = Set<Int>()
            for d in [n.started, n.updated] where d != .distantPast {
                let i = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: today).day.map { days - 1 - $0 } ?? -1
                if (0..<days).contains(i), seen.insert(i).inserted { cells[n.agent, default: Array(repeating: 0, count: days)][i] += 1 }
            }
        }
        return ActivityGrid(days: grid, agents: cells.keys.sorted(), cells: cells, maxCount: cells.values.flatMap { $0 }.max() ?? 0)
    }

    /// Sessions that started or last changed on `day`, newest first (max 4).
    static func sessions(on day: Date, vault: URL, calendar: Calendar = .current) -> [AgentSummary] {
        notes(in: vault)
            .filter { calendar.isDate($0.started, inSameDayAs: day) || calendar.isDate($0.updated, inSameDayAs: day) }
            .sorted { $0.updated > $1.updated }.prefix(4)
            .map { AgentSummary(name: $0.agent, sessions: 1, lastTitle: $0.title, lastProject: $0.project, lastUpdated: $0.updated, notePath: $0.url, state: "ok") }
    }

    /// Where the conversation went: turns per project, biggest first.
    static func projects(vault: URL, limit: Int = 6) -> [ProjectStat] {
        var acc: [String: (sessions: Int, turns: Int)] = [:]
        for n in notes(in: vault) {
            let k = n.project.isEmpty ? "misc" : n.project
            acc[k, default: (0, 0)].sessions += 1; acc[k, default: (0, 0)].turns += n.turns
        }
        return acc.map { ProjectStat(name: $0.key, sessions: $0.value.sessions, turns: $0.value.turns) }
            .sorted { $0.turns != $1.turns ? $0.turns > $1.turns : $0.name < $1.name }.prefix(limit).map { $0 }
    }

    /// ↑/↓ over the rows that are actually DRAWN (search can return more than fit); wraps around.
    static func moveIndex(_ i: Int, by d: Int, rows: Int, visible: Int) -> Int {
        let n = min(rows, visible)
        guard n > 0 else { return 0 }
        return ((i + d) % n + n) % n
    }

    // MARK: internals

    private static func notes(in vault: URL) -> [Note] {
        let fm = FileManager.default
        let root = vault.appendingPathComponent("Sessions")
        var out: [Note] = []
        for agentDir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for monthDir in (try? fm.contentsOfDirectory(at: agentDir, includingPropertiesForKeys: nil)) ?? [] {
                for url in (try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil)) ?? []
                where url.pathExtension == "md" && !url.lastPathComponent.contains(".sync-conflict-") {
                    let h = header(url)
                    out.append(Note(agent: (h["agent"] as? String) ?? agentDir.lastPathComponent,
                                    title: (h["title"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                                    project: (h["project"] as? String) ?? "",
                                    started: (h["started"] as? String).flatMap(parseDate) ?? (h["updated"] as? String).flatMap(parseDate) ?? .distantPast,
                                    updated: (h["updated"] as? String).flatMap(parseDate) ?? .distantPast,
                                    turns: (h["turns"] as? Int) ?? 0,
                                    url: url))
                }
            }
        }
        return out
    }

    /// Frontmatter of a note: `key: <json value>` lines between the first two `---`. Reads only the first 4 KB.
    private static func header(_ url: URL) -> [String: Any] {
        guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: 4096) else { return [:] }
        try? h.close()
        var result: [String: Any] = [:]
        var inside = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" { if inside { break }; inside = true; continue }
            guard inside, let sep = line.range(of: ": ") else { continue }
            let value = line[sep.upperBound...]
            if let d = value.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) {
                result[String(line[..<sep.lowerBound])] = v
            }
        }
        return result
    }

    private static func statusFile(_ vault: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: vault.appendingPathComponent(".recorder/status.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: s) ?? frac.date(from: s)
    }
}
