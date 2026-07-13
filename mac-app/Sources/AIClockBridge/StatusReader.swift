import Foundation

// Port of the old bridge.py log-reading logic. No account APIs / keys are
// touched - everything comes from the JSONL session logs Claude Code and Codex
// CLI already write to disk:
//   ~/.claude/projects/**/*.jsonl   (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl    (Codex CLI rollouts, incl. rate_limits)

struct ClaudeStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var sessionMin: Int = 0
    var sessionWindowMin: Int = 300
    var fiveHourPct: Double? = nil
    var fiveHourResetMin: Int? = nil
    var sevenDayPct: Double? = nil
    var sevenDayResetMin: Int? = nil
    var needsInput: Bool = false // waiting on a permission/approval prompt
    var eligible = false
    var stale = false
}

struct CodexStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var primaryPct: Double? = nil
    var primaryWindowMin: Int? = nil
    var primaryResetMin: Int? = nil
    var weeklyPct: Double? = nil
    var weeklyWindowMin: Int? = nil
    var weeklyResetMin: Int? = nil
    var needsInput: Bool = false
    var eligible = false
    var stale = false
}

struct CursorStatus {
    var totalPct: Double?
    var autoPct: Double?
    var apiPct: Double?
    var billingResetMin: Int?
    var eligible = false
    var stale = false
}

struct Snapshot {
    var claude: ClaudeStatus
    var codex: CodexStatus
    var cursor: CursorStatus
    var ts: Int
    var accountsChecked = false
}

/// Reads the logs and derives status, with a small time cache so back-to-back
/// HTTP polls and the menu-bar timer don't each re-scan the whole tree.
final class StatusService {
    private let claudeDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let codexDir = ("~/.codex/sessions" as NSString).expandingTildeInPath

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    var usage: UsageFetcher?

    // Hook-pushed live state (POST /event from Claude Code / Codex hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    private struct AgentEvent {
        let state: String // "working" | "idle"
        let at: TimeInterval
    }

    private var claudeEvent: AgentEvent?
    private var codexEvent: AgentEvent?
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    private var claudeNeedsInputAt: TimeInterval?
    private var codexNeedsInputAt: TimeInterval?
    private let workingEventTTL: TimeInterval = 10 * 60
    private let idleEventTTL: TimeInterval = 60
    private let needsInputTTL: TimeInterval = 5 * 60

    private static let workingEvents: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "WorktreeCreate",
    ]
    private static let idleEvents: Set<String> = [
        "Stop", "SessionEnd", "SessionStart",
    ]
    // Codex PermissionRequest and MCP Elicitation are always a real "act now"
    // prompt. Claude's Notification is broader — it also fires on task
    // completion / 60s-idle — so it only counts as needs-input when its
    // message is actually a permission request (see isPermissionNotification).
    private static let attentionEvents: Set<String> = [
        "Elicitation", "PermissionRequest",
    ]

    private func isPermissionNotification(_ message: String?) -> Bool {
        guard let m = message?.lowercased() else { return false }
        return m.contains("permission") || m.contains("approve") || m.contains("approval")
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    func recordEvent(agent: String, event: String, message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        // Claude Notification: flash only for permission prompts, not for
        // "task done / waiting for your input" notifications.
        if event == "Notification" {
            if isPermissionNotification(message) {
                if agent == "claude" { claudeNeedsInputAt = now }
                else if agent == "codex" { codexNeedsInputAt = now }
            }
            return
        }
        if Self.attentionEvents.contains(event) {
            if agent == "claude" { claudeNeedsInputAt = now }
            else if agent == "codex" { codexNeedsInputAt = now }
            return
        }
        let state: String
        if Self.workingEvents.contains(event) { state = "working" }
        else if Self.idleEvents.contains(event) { state = "idle" }
        else { return }
        let ev = AgentEvent(state: state, at: now)
        // any concrete lifecycle event means the prompt (if any) was answered
        if agent == "claude" { claudeEvent = ev; claudeNeedsInputAt = nil }
        else if agent == "codex" { codexEvent = ev; codexNeedsInputAt = nil }
    }

    private func needsInput(_ at: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = at else { return false }
        return now - at < needsInputTTL
    }

    /// Event override, applied on top of the log-derived status. "offline"
    /// from logs is only upgraded by a fresh working event (a live hook means
    /// the CLI is definitely running).
    private func overrideStatus(_ logStatus: String, with event: AgentEvent?, now: TimeInterval) -> String {
        guard let ev = event else { return logStatus }
        let age = now - ev.at
        if ev.state == "working", age < workingEventTTL { return "working" }
        if ev.state == "idle", age < idleEventTTL, logStatus == "working" { return "idle" }
        return logStatus
    }

    private let workingThreshold: TimeInterval = 20        // log touched within this -> "working"
    private let idleThreshold: TimeInterval = 30 * 60      // within this -> "idle", else "offline"
    private let cacheTTL: TimeInterval = 5

    private let lock = NSLock()
    private var cached: Snapshot?
    private var cachedAt: TimeInterval = 0

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var snap: Snapshot
        if let c = cached, now - cachedAt < cacheTTL {
            snap = c
        } else {
            snap = Snapshot(claude: readClaude(), codex: readCodex(), cursor: CursorStatus(), ts: Int(now))
            cached = snap
            cachedAt = now
        }
        snap.ts = Int(now)

        // overlays are cheap and applied on every call, so hook events and
        // fresh quota show through instantly even while the log scan is cached
        if let u = usage {
            let claudeUsage = u.claude
            snap.claude.fiveHourPct = claudeUsage.primaryPct
            snap.claude.fiveHourResetMin = claudeUsage.primaryResetMin
            snap.claude.sevenDayPct = claudeUsage.weeklyPct
            snap.claude.sevenDayResetMin = claudeUsage.weeklyResetMin
            snap.claude.eligible = claudeUsage.isEligible()
            snap.claude.stale = claudeUsage.isStale()
            let codexUsage = u.codex
            if codexUsage.fetchedAt != nil {
                // A successful API response is authoritative, including an
                // absent short window (for example Codex Pro Lite's weekly-only plan).
                snap.codex.primaryPct = codexUsage.primaryPct
                snap.codex.primaryWindowMin = codexUsage.primaryWindowMin
                snap.codex.primaryResetMin = codexUsage.primaryResetMin
                snap.codex.weeklyPct = codexUsage.weeklyPct
                snap.codex.weeklyWindowMin = codexUsage.weeklyWindowMin
                snap.codex.weeklyResetMin = codexUsage.weeklyResetMin
            }
            snap.codex.eligible = codexUsage.isEligible()
            snap.codex.stale = codexUsage.isStale()
            let cursorUsage = u.cursor
            snap.cursor.totalPct = cursorUsage.totalPct
            snap.cursor.autoPct = cursorUsage.autoPct
            snap.cursor.apiPct = cursorUsage.apiPct
            snap.cursor.billingResetMin = cursorUsage.billingResetMin
            snap.cursor.eligible = cursorUsage.isEligible()
            snap.cursor.stale = cursorUsage.isStale()
            snap.accountsChecked = u.initialChecksCompleted
        }
        snap.claude.status = overrideStatus(snap.claude.status, with: claudeEvent, now: now)
        snap.codex.status = overrideStatus(snap.codex.status, with: codexEvent, now: now)
        snap.claude.needsInput = needsInput(claudeNeedsInputAt, now: now)
        snap.codex.needsInput = needsInput(codexNeedsInputAt, now: now)
        return snap
    }

    // MARK: - helpers

    private func statusFromDelta(_ delta: TimeInterval) -> String {
        if delta < workingThreshold { return "working" }
        if delta < idleThreshold { return "idle" }
        return "offline"
    }

    private func parseISO(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        if let d = isoFrac.date(from: s) { return d.timeIntervalSince1970 }
        if let d = isoPlain.date(from: s) { return d.timeIntervalSince1970 }
        return nil
    }

    private func todayStartEpoch() -> Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    /// Lossy UTF-8 read (matches Python's errors="ignore") split into lines.
    private func readLines(_ url: URL) -> [Substring]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func intVal(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Claude

    private func readClaude() -> ClaudeStatus {
        let todayStart = todayStartEpoch()
        let now = Date().timeIntervalSince1970
        var tokensToday = 0
        var lastMtime: TimeInterval = 0
        var firstActiveInWindow: Double? = nil

        let fm = FileManager.default
        let root = URL(fileURLWithPath: claudeDir)
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 else { continue }
                if mtime > lastMtime { lastMtime = mtime }
                if mtime < todayStart { continue } // no activity today, skip parsing
                guard let lines = readLines(url) else { continue }
                for line in lines {
                    if !line.contains("\"usage\":{") { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }
                    let entryEpoch = parseISO(obj["timestamp"] as? String)
                    if let e = entryEpoch, e < todayStart { continue }
                    tokensToday += intVal(usage["input_tokens"]) + intVal(usage["output_tokens"])
                        + intVal(usage["cache_creation_input_tokens"]) + intVal(usage["cache_read_input_tokens"])
                    if let e = entryEpoch, now - e < 5 * 3600 {
                        if firstActiveInWindow == nil || e < firstActiveInWindow! { firstActiveInWindow = e }
                    }
                }
            }
        }

        var s = ClaudeStatus()
        s.tokensToday = tokensToday
        if let first = firstActiveInWindow { s.sessionMin = Int((now - first) / 60) }
        s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        return s
    }

    // MARK: - Codex

    private func readCodex() -> CodexStatus {
        let now = Date().timeIntervalSince1970
        var lastMtime: TimeInterval = 0
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexDir)

        // Whole-tree scan just for the freshest mtime (drives working/idle).
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970, mtime > lastMtime {
                    lastMtime = mtime
                }
            }
        }

        // Tokens + rate limits only from today's day directory.
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0))
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0))
            .appendingPathComponent(String(format: "%02d", comps.day ?? 0))

        var tokensToday = 0
        var latestRateLimits: [String: Any]? = nil
        var latestRateLimitsTs: Double = 0

        if let names = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) {
            for url in names where url.pathExtension == "jsonl" {
                guard let lines = readLines(url) else { continue }
                var sessionMaxTokens = 0
                for line in lines {
                    if !line.contains("\"token_count\"") { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count" else { continue }
                    let info = payload["info"] as? [String: Any]
                    let totalUsage = info?["total_token_usage"] as? [String: Any]
                    let total = intVal(totalUsage?["total_tokens"])
                    if total > sessionMaxTokens { sessionMaxTokens = total }
                    if let rl = payload["rate_limits"] as? [String: Any] {
                        let e = parseISO(obj["timestamp"] as? String) ?? 0
                        if e >= latestRateLimitsTs { latestRateLimitsTs = e; latestRateLimits = rl }
                    }
                }
                tokensToday += sessionMaxTokens
            }
        }

        var s = CodexStatus()
        s.tokensToday = tokensToday
        s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        if let rl = latestRateLimits {
            for (key, fallbackWeekly) in [("primary", false), ("secondary", true)] {
                guard let object = rl[key] as? [String: Any] else { continue }
                let window = CodexQuotaWindow(object, now: now)
                if window.isWeekly(fallback: fallbackWeekly) {
                    s.weeklyPct = window.usedPct
                    s.weeklyWindowMin = window.windowMin
                    s.weeklyResetMin = window.resetMin
                } else {
                    s.primaryPct = window.usedPct
                    s.primaryWindowMin = window.windowMin
                    s.primaryResetMin = window.resetMin
                }
            }
        }
        return s
    }
}

extension Snapshot {
    /// Serializes to the exact JSON shape the firmware's parseStatusJson expects.
    func jsonData() -> Data {
        func num(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func num(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let dict: [String: Any] = [
            "ts": ts,
            "accounts_checked": accountsChecked,
            "claude": [
                "status": claude.status,
                "tokens_today": claude.tokensToday,
                "session_min": claude.sessionMin,
                "session_window_min": claude.sessionWindowMin,
                "five_hour_pct": num(claude.fiveHourPct),
                "five_hour_reset_min": num(claude.fiveHourResetMin),
                "seven_day_pct": num(claude.sevenDayPct),
                "seven_day_reset_min": num(claude.sevenDayResetMin),
                "needs_input": claude.needsInput,
                "eligible": claude.eligible,
                "stale": claude.stale,
            ],
            "codex": [
                "status": codex.status,
                "tokens_today": codex.tokensToday,
                "primary_pct": num(codex.primaryPct),
                "primary_window_min": num(codex.primaryWindowMin),
                "primary_reset_min": num(codex.primaryResetMin),
                "weekly_pct": num(codex.weeklyPct),
                "weekly_window_min": num(codex.weeklyWindowMin),
                "weekly_reset_min": num(codex.weeklyResetMin),
                "needs_input": codex.needsInput,
                "eligible": codex.eligible,
                "stale": codex.stale,
            ],
            "cursor": [
                "status": "idle",
                "total_pct": num(cursor.totalPct),
                "auto_pct": num(cursor.autoPct),
                "api_pct": num(cursor.apiPct),
                "billing_reset_min": num(cursor.billingResetMin),
                "eligible": cursor.eligible,
                "stale": cursor.stale,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

}
