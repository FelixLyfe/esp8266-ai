using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AIClockBridge;

// Real quota for Claude, Codex and Cursor. Existing local credentials are
// reused in memory and are sent only to the corresponding vendor endpoint.
enum UsageProvider { Claude, Codex, Cursor }

class ProviderUsage
{
    public double? PrimaryPct;
    public int? PrimaryWindowMin;
    public int? PrimaryResetMin;
    public double? WeeklyPct;
    public int? WeeklyWindowMin;
    public int? WeeklyResetMin;
    public double? TotalPct;
    public double? AutoPct;
    public double? ApiPct;
    public int? BillingResetMin;
    public string Error;
    public DateTime? FetchedAt;
    public bool RateLimited;
    public bool CredentialPresent;
    public bool CheckCompleted;
    public bool AuthRejected;

    public bool HasDisplayQuota => PrimaryPct.HasValue || WeeklyPct.HasValue || TotalPct.HasValue;
    public bool IsLoggedOut => CheckCompleted && (!CredentialPresent || AuthRejected);
    public bool IsEligible(DateTime? now = null) => CredentialPresent && !AuthRejected
        && HasDisplayQuota && FetchedAt.HasValue
        && (now ?? DateTime.UtcNow) - FetchedAt.Value <= TimeSpan.FromHours(6);
    public bool IsStale(DateTime? now = null) => FetchedAt.HasValue
        && (now ?? DateTime.UtcNow) - FetchedAt.Value > TimeSpan.FromMinutes(15);
}

sealed class UsageFetcher
{
    sealed class FetchState
    {
        public bool Fetching;
        public DateTime NextAllowed = DateTime.MinValue;
    }

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    static readonly TimeSpan MinFetchInterval = TimeSpan.FromSeconds(60);
    static readonly TimeSpan RateLimitBackoff = TimeSpan.FromMinutes(5);

    readonly object _lock = new();
    readonly Dictionary<UsageProvider, FetchState> _states = Enum.GetValues<UsageProvider>()
        .ToDictionary(provider => provider, _ => new FetchState());
    ProviderUsage _claude = new();
    ProviderUsage _codex = new();
    ProviderUsage _cursor = new();
    System.Windows.Forms.Timer _timer;
    SynchronizationContext _ui;

    public ProviderUsage Claude { get { lock (_lock) return _claude; } }
    public ProviderUsage Codex { get { lock (_lock) return _codex; } }
    public ProviderUsage Cursor { get { lock (_lock) return _cursor; } }
    public bool InitialChecksCompleted
    {
        get { lock (_lock) return _claude.CheckCompleted && _codex.CheckCompleted && _cursor.CheckCompleted; }
    }

    /// Raised on the UI thread after any provider updates.
    public Action OnUpdate;

    public void StartAutoRefresh(int intervalSeconds = 120)
    {
        _ui = SynchronizationContext.Current;
        Refresh();
        _timer = new System.Windows.Forms.Timer { Interval = intervalSeconds * 1000 };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
    }

    public void Refresh()
    {
        foreach (var provider in Enum.GetValues<UsageProvider>()) Refresh(provider);
    }

    public bool Refresh(UsageProvider provider, bool force = false)
    {
        lock (_lock)
        {
            var state = _states[provider];
            if (state.Fetching || (!force && DateTime.UtcNow < state.NextAllowed)) return false;
            state.Fetching = true;
        }
        _ = Task.Run(async () =>
        {
            ProviderUsage result;
            try
            {
                result = provider switch
                {
                    UsageProvider.Claude => await FetchClaude(),
                    UsageProvider.Codex => await FetchCodex(),
                    _ => await FetchCursor(),
                };
            }
            catch (Exception error)
            {
                result = new ProviderUsage
                {
                    CheckCompleted = true,
                    CredentialPresent = true,
                    Error = $"额度请求失败：{error.Message}",
                };
            }
            lock (_lock)
            {
                switch (provider)
                {
                    case UsageProvider.Claude: _claude = Merge(_claude, result); break;
                    case UsageProvider.Codex: _codex = Merge(_codex, result); break;
                    case UsageProvider.Cursor: _cursor = Merge(_cursor, result); break;
                }
                var state = _states[provider];
                state.Fetching = false;
                state.NextAllowed = DateTime.UtcNow
                    + (result.RateLimited ? RateLimitBackoff : MinFetchInterval);
            }
            if (result.Error != null)
                Console.Error.WriteLine($"[usage] {provider.ToString().ToLowerInvariant()}: {result.Error}");
            if (_ui != null) _ui.Post(_ => OnUpdate?.Invoke(), null);
            else OnUpdate?.Invoke();
        });
        return true;
    }

    /// User-triggered retry bypasses provider backoff, but never duplicates an
    /// in-flight request for the same provider.
    public bool Retry(UsageProvider provider) => Refresh(provider, force: true);

    static ProviderUsage Merge(ProviderUsage old, ProviderUsage fresh)
    {
        // Missing/rejected credentials are definitive. Transient errors retain
        // the last successful values, error text and freshness timestamp.
        if (!fresh.CredentialPresent || fresh.AuthRejected) return fresh;
        if (!fresh.HasDisplayQuota && old.HasDisplayQuota && old.FetchedAt.HasValue)
        {
            old.Error = fresh.Error;
            old.RateLimited = fresh.RateLimited;
            old.CredentialPresent = true;
            old.CheckCompleted = true;
            old.AuthRejected = false;
            return old;
        }
        return fresh;
    }

    static async Task<ProviderUsage> FetchClaude()
    {
        var usage = new ProviderUsage { CheckCompleted = true };
        var token = ClaudeAccessToken();
        if (token == null)
        {
            usage.Error = "未找到 Claude Code 登录凭据";
            return usage;
        }
        usage.CredentialPresent = true;
        using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        req.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.0");

        HttpResponseMessage response;
        try { response = await Http.SendAsync(req); }
        catch { usage.Error = "Claude 用量请求失败"; return usage; }
        using (response)
        {
            var code = (int)response.StatusCode;
            if (code != 200)
            {
                usage.RateLimited = code == 429;
                usage.AuthRejected = code is 401 or 403;
                usage.Error = usage.AuthRejected ? "Claude 凭据过期，运行 claude 重新登录"
                    : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                    : $"Claude 用量接口 HTTP {code}";
                return usage;
            }
            try
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
                var now = DateTimeOffset.UtcNow;
                if (doc.RootElement.TryGetProperty("five_hour", out var primary))
                {
                    usage.PrimaryPct = NumberOrNull(primary, "utilization");
                    usage.PrimaryResetMin = MinutesUntil(StringOrNull(primary, "resets_at"), now);
                }
                if (doc.RootElement.TryGetProperty("seven_day", out var weekly))
                {
                    usage.WeeklyPct = NumberOrNull(weekly, "utilization");
                    usage.WeeklyResetMin = MinutesUntil(StringOrNull(weekly, "resets_at"), now);
                }
                usage.FetchedAt = DateTime.UtcNow;
            }
            catch { usage.Error = "Claude 用量响应解析失败"; }
        }
        return usage;
    }

    static string ClaudeAccessToken()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", ".credentials.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth)
                && oauth.TryGetProperty("accessToken", out var token)
                && token.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(token.GetString()))
                return token.GetString();
        }
        catch { }
        return null;
    }

    static async Task<ProviderUsage> FetchCodex()
    {
        var usage = new ProviderUsage { CheckCompleted = true };
        var credentials = CodexCredentials();
        if (!credentials.HasValue)
        {
            usage.Error = "未找到 Codex 登录凭据 (~/.codex/auth.json)";
            return usage;
        }
        usage.CredentialPresent = true;
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://chatgpt.com/backend-api/wham/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {credentials.Value.AccessToken}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge");
        if (credentials.Value.AccountId != null)
            req.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", credentials.Value.AccountId);

        HttpResponseMessage response;
        try { response = await Http.SendAsync(req); }
        catch { usage.Error = "Codex 用量请求失败"; return usage; }
        using (response)
        {
            var code = (int)response.StatusCode;
            if (!response.IsSuccessStatusCode)
            {
                usage.RateLimited = code == 429;
                usage.AuthRejected = code is 401 or 403;
                usage.Error = usage.AuthRejected ? "Codex 凭据过期，运行 codex 重新登录"
                    : code == 429 ? "Codex 用量接口限流，稍后自动重试"
                    : $"Codex 用量接口 HTTP {code}";
                return usage;
            }
            try
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
                if (!doc.RootElement.TryGetProperty("rate_limit", out var rateLimit))
                {
                    usage.Error = "Codex 用量响应解析失败";
                    return usage;
                }
                var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                ParseCodexWindow(rateLimit, "primary_window", fallbackWeekly: false, now, usage);
                ParseCodexWindow(rateLimit, "secondary_window", fallbackWeekly: true, now, usage);
                usage.FetchedAt = DateTime.UtcNow;
            }
            catch { usage.Error = "Codex 用量响应解析失败"; }
        }
        return usage;
    }

    static void ParseCodexWindow(JsonElement rateLimit, string key, bool fallbackWeekly,
                                 long now, ProviderUsage usage)
    {
        if (!rateLimit.TryGetProperty(key, out var window)) return;
        var used = NumberOrNull(window, "used_percent");
        var duration = NumberOrNull(window, "window_minutes")
            ?? NumberOrNull(window, "limit_window_seconds") / 60;
        var resetAt = NumberOrNull(window, "reset_at") ?? NumberOrNull(window, "resets_at");
        int? reset = resetAt.HasValue ? Math.Max(0, (int)((resetAt.Value - now) / 60)) : null;
        var weekly = duration.HasValue ? duration.Value >= 24 * 60 : fallbackWeekly;
        if (weekly)
        {
            usage.WeeklyPct = used;
            usage.WeeklyWindowMin = duration.HasValue ? (int)duration.Value : null;
            usage.WeeklyResetMin = reset;
        }
        else
        {
            usage.PrimaryPct = used;
            usage.PrimaryWindowMin = duration.HasValue ? (int)duration.Value : null;
            usage.PrimaryResetMin = reset;
        }
    }

    static (string AccessToken, string AccountId)? CodexCredentials()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex", "auth.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("tokens", out var tokens)
                || !tokens.TryGetProperty("access_token", out var accessElement)
                || accessElement.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(accessElement.GetString())) return null;
            string accountId = null;
            if (tokens.TryGetProperty("account_id", out var account)
                && account.ValueKind == JsonValueKind.String) accountId = account.GetString();
            if (accountId == null && tokens.TryGetProperty("id_token", out var idToken)
                && idToken.ValueKind == JsonValueKind.String)
                accountId = AccountIdFromJwt(idToken.GetString());
            return (accessElement.GetString(), accountId);
        }
        catch { return null; }
    }

    static async Task<ProviderUsage> FetchCursor()
    {
        var usage = new ProviderUsage { CheckCompleted = true };
        var token = CursorAccessToken();
        if (token == null)
        {
            usage.Error = "未找到 Cursor 登录凭据";
            return usage;
        }
        usage.CredentialPresent = true;
        using var req = new HttpRequestMessage(HttpMethod.Post,
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage");
        req.Content = new StringContent("{}", Encoding.UTF8, "application/json");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
        req.Headers.TryAddWithoutValidation("x-cursor-client-version", CursorVersion());

        HttpResponseMessage response;
        try { response = await Http.SendAsync(req); }
        catch { usage.Error = "Cursor 用量请求失败"; return usage; }
        using (response)
        {
            var code = (int)response.StatusCode;
            if (!response.IsSuccessStatusCode)
            {
                usage.RateLimited = code == 429;
                usage.AuthRejected = code is 401 or 403;
                usage.Error = usage.AuthRejected ? "Cursor 凭据过期，请打开 Cursor 重新登录"
                    : code == 429 ? "Cursor 用量接口限流，稍后自动重试"
                    : $"Cursor 用量接口 HTTP {code}";
                return usage;
            }
            var parsed = ParseCursorCurrentPeriodUsage(await response.Content.ReadAsByteArrayAsync());
            if (!parsed.HasValue)
            {
                usage.Error = "Cursor 用量响应格式已变化";
                return usage;
            }
            usage.TotalPct = parsed.Value.TotalPct;
            usage.AutoPct = parsed.Value.AutoPct;
            usage.ApiPct = parsed.Value.ApiPct;
            usage.BillingResetMin = parsed.Value.BillingResetMin;
            usage.FetchedAt = DateTime.UtcNow;
        }
        return usage;
    }

    static string CursorAccessToken()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Cursor", "User", "globalStorage", "state.vscdb");
        if (!File.Exists(path)) return null;
        try
        {
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadOnly,
                Cache = SqliteCacheMode.Private,
                Pooling = false,
                DefaultTimeout = 3,
            };
            using var connection = new SqliteConnection(builder.ToString());
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1";
            var value = command.ExecuteScalar()?.ToString()?.Trim();
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }
        catch { return null; }
    }

    readonly record struct CursorPeriodUsage(double TotalPct, double? AutoPct, double? ApiPct,
                                              int? BillingResetMin);

    static CursorPeriodUsage? ParseCursorCurrentPeriodUsage(byte[] data)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            var plan = Property(root, "planUsage", "plan_usage");
            if (plan.HasValue)
            {
                var total = Number(plan.Value, "totalPercentUsed", "total_percent_used");
                if (total.HasValue)
                {
                    var end = Number(root, "billingCycleEnd", "billing_cycle_end");
                    return new CursorPeriodUsage(Clamp(total.Value),
                        Number(plan.Value, "autoPercentUsed", "auto_percent_used") is double auto ? Clamp(auto) : null,
                        Number(plan.Value, "apiPercentUsed", "api_percent_used") is double api ? Clamp(api) : null,
                        ResetMinutes(end, now));
                }
            }
        }
        catch (JsonException) { }
        return ParseCursorProtobuf(data, now);
    }

    static CursorPeriodUsage? ParseCursorProtobuf(byte[] data, long now)
    {
        var index = 0;
        double? billingEnd = null;
        byte[] plan = null;
        while (index < data.Length && TryReadVarint(data, ref index, out var tag))
        {
            var field = (int)(tag >> 3);
            var wire = (int)(tag & 7);
            if (field == 2 && wire == 0 && TryReadVarint(data, ref index, out var end))
                billingEnd = end;
            else if (field == 3 && wire == 2 && TryReadVarint(data, ref index, out var length)
                     && length <= int.MaxValue && index + (int)length <= data.Length)
            {
                plan = data.AsSpan(index, (int)length).ToArray();
                index += (int)length;
            }
            else if (!SkipField(data, ref index, wire)) return null;
        }
        if (plan == null) return null;
        var p = 0;
        double? auto = null, api = null, total = null;
        while (p < plan.Length && TryReadVarint(plan, ref p, out var tag))
        {
            var field = (int)(tag >> 3);
            var wire = (int)(tag & 7);
            if (field is >= 12 and <= 14 && wire == 1 && p + 8 <= plan.Length)
            {
                var raw = BitConverter.Int64BitsToDouble(
                    (long)BinaryPrimitives.ReadUInt64LittleEndian(plan.AsSpan(p, 8)));
                if (!double.IsFinite(raw)) return null;
                var value = Clamp(raw);
                if (field == 12) auto = value;
                else if (field == 13) api = value;
                else total = value;
                p += 8;
            }
            else if (!SkipField(plan, ref p, wire)) return null;
        }
        return total.HasValue
            ? new CursorPeriodUsage(total.Value, auto, api, ResetMinutes(billingEnd, now)) : null;
    }

    static bool TryReadVarint(byte[] data, ref int index, out ulong value)
    {
        value = 0;
        var shift = 0;
        while (index < data.Length && shift < 64)
        {
            var b = data[index++];
            value |= (ulong)(b & 0x7f) << shift;
            if ((b & 0x80) == 0) return true;
            shift += 7;
        }
        return false;
    }

    static bool SkipField(byte[] data, ref int index, int wire)
    {
        switch (wire)
        {
            case 0: return TryReadVarint(data, ref index, out _);
            case 1: index += 8; break;
            case 2:
                if (!TryReadVarint(data, ref index, out var length) || length > int.MaxValue) return false;
                index += (int)length;
                break;
            case 5: index += 4; break;
            default: return false;
        }
        return index <= data.Length;
    }

    static string CursorVersion()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        foreach (var root in new[] { "cursor", "Cursor" })
        {
            var package = Path.Combine(local, "Programs", root, "resources", "app", "package.json");
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(package));
                if (doc.RootElement.TryGetProperty("version", out var version)
                    && version.ValueKind == JsonValueKind.String) return version.GetString();
            }
            catch { }
            var exe = Path.Combine(local, "Programs", root, "Cursor.exe");
            try
            {
                var version = FileVersionInfo.GetVersionInfo(exe).ProductVersion;
                if (!string.IsNullOrWhiteSpace(version)) return version;
            }
            catch { }
        }
        return "desktop";
    }

    static JsonElement? Property(JsonElement obj, params string[] names)
    {
        foreach (var name in names) if (obj.TryGetProperty(name, out var value)) return value;
        return null;
    }

    static double? Number(JsonElement obj, params string[] names)
    {
        var value = Property(obj, names);
        if (!value.HasValue) return null;
        if (value.Value.ValueKind == JsonValueKind.Number && value.Value.TryGetDouble(out var number)) return number;
        if (value.Value.ValueKind == JsonValueKind.String
            && double.TryParse(value.Value.GetString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out number)) return number;
        return null;
    }

    static double Clamp(double value) => Math.Clamp(value, 0, 100);

    static int? ResetMinutes(double? epoch, long now)
    {
        if (!epoch.HasValue) return null;
        var value = epoch.Value > 10_000_000_000 ? epoch.Value / 1000 : epoch.Value;
        return Math.Max(0, (int)((value - now) / 60));
    }

    static string AccountIdFromJwt(string jwt)
    {
        var parts = jwt?.Split('.') ?? Array.Empty<string>();
        if (parts.Length < 2) return null;
        var b64 = parts[1].Replace('-', '+').Replace('_', '/');
        while (b64.Length % 4 != 0) b64 += "=";
        try
        {
            using var doc = JsonDocument.Parse(Convert.FromBase64String(b64));
            if (doc.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth)
                && auth.TryGetProperty("chatgpt_account_id", out var id)
                && id.ValueKind == JsonValueKind.String) return id.GetString();
        }
        catch { }
        return null;
    }

    static double? NumberOrNull(JsonElement obj, string key) =>
        obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble() : null;

    static string StringOrNull(JsonElement obj, string key) =>
        obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    static int? MinutesUntil(string iso, DateTimeOffset now)
    {
        if (iso == null || !DateTimeOffset.TryParse(iso, null,
                System.Globalization.DateTimeStyles.RoundtripKind, out var reset)) return null;
        return Math.Max(0, (int)(reset - now).TotalMinutes);
    }

    public static double? RemainingPercent(double? used) => used.HasValue && used.Value >= 0
        ? Math.Clamp(100 - used.Value, 0, 100) : null;
}
