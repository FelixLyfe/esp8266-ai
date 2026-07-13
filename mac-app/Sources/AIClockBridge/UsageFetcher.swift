import Foundation

// Real quota ("额度") for the three supported clients. The bridge reuses the
// credentials each client already stores locally and never persists tokens.
// by reusing the OAuth tokens the CLIs already store locally, no extra login:
//   Claude: token from macOS Keychain item "Claude Code-credentials" (or
//           ~/.claude/.credentials.json), then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  token from ~/.codex/auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (5h + weekly windows)
//   Cursor: token from Cursor's state.vscdb, then Connect RPC
//           DashboardService/GetCurrentPeriodUsage (Total + Auto + API)
// Tokens never leave this machine except toward their own vendor's API.

enum UsageProvider: CaseIterable, Hashable {
    case claude, codex, cursor
}

struct ProviderUsage {
    var primaryPct: Double?     // short window used % (normally 5h)
    var primaryWindowMin: Int?
    var primaryResetMin: Int?   // minutes until it resets
    var weeklyPct: Double?      // 7d / weekly window used %
    var weeklyWindowMin: Int?
    var weeklyResetMin: Int?
    var error: String?
    var fetchedAt: Date?
    var rateLimited = false
    var credentialPresent = false
    var checkCompleted = false
    var authRejected = false

    // Cursor's current billing period. `totalPct` is mandatory for Cursor to
    // become display-eligible; Auto/API are independently optional.
    var totalPct: Double?
    var autoPct: Double?
    var apiPct: Double?
    var billingResetMin: Int?

    func isEligible(now: Date = Date()) -> Bool {
        guard credentialPresent, !authRejected, hasQuota, let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) <= 6 * 60 * 60
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > 15 * 60
    }

    var isLoggedOut: Bool { checkCompleted && (!credentialPresent || authRejected) }

    fileprivate var hasQuota: Bool {
        primaryPct != nil || weeklyPct != nil || totalPct != nil
    }

    var hasDisplayQuota: Bool { hasQuota }
}

/// Converts the providers' used percentage into the value shown to users.
/// Internal status remains "used" so quota-exhaustion checks stay correct.
func remainingPercent(fromUsed used: Double?) -> Double? {
    guard let used, used >= 0 else { return nil }
    return min(100, max(0, 100 - used))
}

struct CodexQuotaWindow {
    let usedPct: Double?
    let windowMin: Int?
    let resetMin: Int?

    init(_ object: [String: Any], now: Double) {
        usedPct = (object["used_percent"] as? NSNumber)?.doubleValue
        if let minutes = object["window_minutes"] as? NSNumber {
            windowMin = minutes.intValue
        } else if let seconds = object["limit_window_seconds"] as? NSNumber {
            windowMin = seconds.intValue / 60
        } else {
            windowMin = nil
        }
        let reset = (object["reset_at"] as? NSNumber)?.doubleValue
            ?? (object["resets_at"] as? NSNumber)?.doubleValue
        resetMin = reset.map { max(0, Int(($0 - now) / 60)) }
    }

    func isWeekly(fallback: Bool) -> Bool {
        windowMin.map { $0 >= 24 * 60 } ?? fallback
    }
}

final class UsageFetcher {
    private struct FetchState {
        var fetching = false
        var nextAllowed = Date.distantPast
    }

    private let lock = NSLock()
    private var _claude = ProviderUsage()
    private var _codex = ProviderUsage()
    private var _cursor = ProviderUsage()
    private var timer: Timer?
    private var fetchStates = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { ($0, FetchState()) })

    private let minFetchInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 300

    var claude: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _claude }
    var codex: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _codex }
    var cursor: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _cursor }

    var initialChecksCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _claude.checkCompleted && _codex.checkCompleted && _cursor.checkCompleted
    }

    /// Called on the main thread after either provider updates.
    var onUpdate: (() -> Void)?

    func startAutoRefresh(interval: TimeInterval = 120) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        for provider in UsageProvider.allCases { refresh(provider) }
    }

    @discardableResult
    func refresh(_ provider: UsageProvider, force: Bool = false) -> Bool {
        lock.lock()
        var state = fetchStates[provider] ?? FetchState()
        let blocked = state.fetching || (!force && Date() < state.nextAllowed)
        if !blocked {
            state.fetching = true
            fetchStates[provider] = state
        }
        lock.unlock()
        if blocked { return false }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result: ProviderUsage
            switch provider {
            case .claude: result = self.fetchClaude()
            case .codex: result = self.fetchCodex()
            case .cursor: result = self.fetchCursor()
            }
            self.lock.lock()
            switch provider {
            case .claude: self._claude = Self.merge(old: self._claude, new: result)
            case .codex: self._codex = Self.merge(old: self._codex, new: result)
            case .cursor: self._cursor = Self.merge(old: self._cursor, new: result)
            }
            var state = self.fetchStates[provider] ?? FetchState()
            state.fetching = false
            state.nextAllowed = Date().addingTimeInterval(result.rateLimited
                ? self.rateLimitBackoff : self.minFetchInterval)
            self.fetchStates[provider] = state
            self.lock.unlock()
            if let e = result.error {
                FileHandle.standardError.write(Data("[usage] \(provider): \(e)\n".utf8))
            }
            DispatchQueue.main.async { self.onUpdate?() }
        }
        return true
    }

    /// User-initiated retry: bypass provider backoff, but never duplicate an
    /// already-running request for the same provider.
    @discardableResult
    func retry(_ provider: UsageProvider) -> Bool { refresh(provider, force: true) }

    private static func merge(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        // Missing credentials and rejected credentials are definitive: remove
        // the provider immediately. Transient failures keep the last success.
        if !new.credentialPresent || new.authRejected { return new }
        if !new.hasQuota, old.hasQuota, old.fetchedAt != nil {
            var kept = old
            kept.error = new.error
            kept.rateLimited = new.rateLimited
            kept.credentialPresent = true
            kept.checkCompleted = true
            kept.authRejected = false
            return kept
        }
        return new
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    private func fetchClaude() -> ProviderUsage {
        var usage = ProviderUsage()
        usage.checkCompleted = true
        guard let token = Self.claudeAccessToken() else {
            usage.error = "未找到 Claude Code 登录凭据"
            return usage
        }
        usage.credentialPresent = true
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Claude 用量请求失败"
            return usage
        }
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.authRejected = code == 401 || code == 403
            usage.error = usage.authRejected ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : "Claude 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            usage.error = "Claude 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let w = obj["five_hour"] as? [String: Any] {
            usage.primaryPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.primaryResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        if let w = obj["seven_day"] as? [String: Any] {
            usage.weeklyPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.weeklyResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        usage.fetchedAt = Date()
        return usage
    }

    /// Claude Code stores OAuth credentials in the login Keychain on macOS
    /// (file fallback for older setups). JSON: {"claudeAiOauth":{"accessToken":…}}
    static func claudeAccessToken() -> String? {
        var raw: Data?
        let credFile = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: credFile) {
            raw = data
        } else {
            guard let out = runProcess("/usr/bin/security",
                arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                timeout: 15) else { return nil }
            raw = Data(String(decoding: out, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    private func fetchCodex() -> ProviderUsage {
        var usage = ProviderUsage()
        usage.checkCompleted = true
        guard let creds = Self.codexCredentials() else {
            usage.error = "未找到 Codex 登录凭据 (~/.codex/auth.json)"
            return usage
        }
        usage.credentialPresent = true
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        if let account = creds.accountId {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Codex 用量请求失败"
            return usage
        }
        guard (200...299).contains(code) else {
            usage.authRejected = code == 401 || code == 403
            usage.rateLimited = code == 429
            usage.error = usage.authRejected ? "Codex 凭据过期，运行 codex 重新登录"
                : code == 429 ? "Codex 用量接口限流，稍后自动重试"
                : "Codex 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            usage.error = "Codex 用量响应解析失败"
            return usage
        }
        usage = Self.parseCodexRateLimit(rateLimit, now: Date().timeIntervalSince1970)
        usage.checkCompleted = true
        usage.credentialPresent = true
        usage.fetchedAt = Date()
        return usage
    }

    static func parseCodexRateLimit(_ rateLimit: [String: Any], now: Double) -> ProviderUsage {
        var usage = ProviderUsage()
        for (key, fallbackWeekly) in [("primary_window", false), ("secondary_window", true)] {
            guard let object = rateLimit[key] as? [String: Any] else { continue }
            let window = CodexQuotaWindow(object, now: now)
            if window.isWeekly(fallback: fallbackWeekly) {
                usage.weeklyPct = window.usedPct
                usage.weeklyWindowMin = window.windowMin
                usage.weeklyResetMin = window.resetMin
            } else {
                usage.primaryPct = window.usedPct
                usage.primaryWindowMin = window.windowMin
                usage.primaryResetMin = window.resetMin
            }
        }
        return usage
    }

    private static func codexCredentials() -> (accessToken: String, accountId: String?)? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var accountId = tokens["account_id"] as? String
        if accountId == nil, let idToken = tokens["id_token"] as? String {
            accountId = Self.accountIdFromJWT(idToken)
        }
        return (access, accountId)
    }

    // MARK: - Cursor (internal Connect RPC used by the installed client)

    private func fetchCursor() -> ProviderUsage {
        var usage = ProviderUsage()
        usage.checkCompleted = true
        guard let token = Self.cursorAccessToken() else {
            usage.error = "未找到 Cursor 登录凭据"
            return usage
        }
        usage.credentialPresent = true

        let endpoint = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(Self.cursorVersion(), forHTTPHeaderField: "x-cursor-client-version")

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Cursor 用量请求失败"
            return usage
        }
        guard (200...299).contains(code) else {
            usage.authRejected = code == 401 || code == 403
            usage.rateLimited = code == 429
            usage.error = usage.authRejected ? "Cursor 凭据过期，请打开 Cursor 重新登录"
                : code == 429 ? "Cursor 用量接口限流，稍后自动重试"
                : "Cursor 用量接口 HTTP \(code)"
            return usage
        }
        guard let parsed = Self.parseCursorCurrentPeriodUsage(data) else {
            usage.error = "Cursor 用量响应格式已变化"
            return usage
        }
        usage.totalPct = parsed.totalPct
        usage.autoPct = parsed.autoPct
        usage.apiPct = parsed.apiPct
        usage.billingResetMin = parsed.billingResetMin
        usage.fetchedAt = Date()
        return usage
    }

    static func cursorAccessToken(databasePath: String? = nil) -> String? {
        let path = databasePath ?? ("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = runProcess("/usr/bin/sqlite3", arguments: ["-readonly", path,
            "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"],
            timeout: 5) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    struct CursorPeriodUsage {
        var totalPct: Double
        var autoPct: Double?
        var apiPct: Double?
        var billingResetMin: Int?
    }

    static func parseCursorCurrentPeriodUsage(_ data: Data, now: Double = Date().timeIntervalSince1970)
        -> CursorPeriodUsage? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let plan = (object["planUsage"] ?? object["plan_usage"]) as? [String: Any]
            if let plan, let total = double(plan["totalPercentUsed"] ?? plan["total_percent_used"]) {
                let end = double(object["billingCycleEnd"] ?? object["billing_cycle_end"])
                return CursorPeriodUsage(totalPct: clamped(total),
                    autoPct: double(plan["autoPercentUsed"] ?? plan["auto_percent_used"]).map(clamped),
                    apiPct: double(plan["apiPercentUsed"] ?? plan["api_percent_used"]).map(clamped),
                    billingResetMin: resetMinutes(epoch: end, now: now))
            }
        }
        return parseCursorProtobuf(data, now: now)
    }

    private static func parseCursorProtobuf(_ data: Data, now: Double) -> CursorPeriodUsage? {
        var index = 0
        var billingEnd: Double?
        var planData: Data?
        while index < data.count, let tag = readVarint(data, &index) {
            let field = Int(tag >> 3), wire = Int(tag & 7)
            if field == 2, wire == 0, let value = readVarint(data, &index) {
                billingEnd = Double(value)
            } else if field == 3, wire == 2, let length = readVarint(data, &index) {
                let end = index + Int(length)
                guard end <= data.count else { return nil }
                planData = data.subdata(in: index..<end)
                index = end
            } else if !skipField(data, &index, wire: wire) { return nil }
        }
        guard let planData else { return nil }
        var p = 0
        var auto: Double?, api: Double?, total: Double?
        while p < planData.count, let tag = readVarint(planData, &p) {
            let field = Int(tag >> 3), wire = Int(tag & 7)
            if (12...14).contains(field), wire == 1, p + 8 <= planData.count {
                let bits = planData[p..<(p + 8)].enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << UInt64($1.offset * 8))
                }
                let value = clamped(Double(bitPattern: bits))
                if field == 12 { auto = value }
                else if field == 13 { api = value }
                else { total = value }
                p += 8
            } else if !skipField(planData, &p, wire: wire) { return nil }
        }
        guard let total else { return nil }
        return CursorPeriodUsage(totalPct: total, autoPct: auto, apiPct: api,
            billingResetMin: resetMinutes(epoch: billingEnd, now: now))
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func clamped(_ value: Double) -> Double { min(100, max(0, value)) }

    private static func resetMinutes(epoch: Double?, now: Double) -> Int? {
        guard var epoch else { return nil }
        if epoch > 10_000_000_000 { epoch /= 1000 }
        return max(0, Int((epoch - now) / 60))
    }

    private static func readVarint(_ data: Data, _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0, shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]; index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func skipField(_ data: Data, _ index: inout Int, wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint(data, &index) != nil
        case 1: index += 8
        case 2:
            guard let length = readVarint(data, &index) else { return false }
            index += Int(length)
        case 5: index += 4
        default: return false
        }
        return index <= data.count
    }

    private static func cursorVersion() -> String {
        let path = "/Applications/Cursor.app/Contents/Info.plist"
        let dict = NSDictionary(contentsOfFile: path)
        return dict?["CFBundleShortVersionString"] as? String ?? "desktop"
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    private static func accountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String
        }
        return nil
    }

    // MARK: - helpers

    private static func minutesUntil(iso: String?, now: Double) -> Int? {
        guard let iso = iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let d = date else { return nil }
        return max(0, Int((d.timeIntervalSince1970 - now) / 60))
    }

    private static func syncRequest(_ req: URLRequest) -> (Data, Int)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, let http = resp as? HTTPURLResponse {
                result = (data, http.statusCode)
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + req.timeoutInterval + 2) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }

    /// Runs small local credential readers without allowing a Keychain prompt
    /// or locked SQLite database to block the provider's initial check forever.
    private static func runProcess(_ executable: String, arguments: [String],
                                   timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
