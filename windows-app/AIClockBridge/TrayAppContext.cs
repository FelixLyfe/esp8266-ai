using System.Diagnostics;
using System.Drawing;

namespace AIClockBridge;

// Tray icon and control menu. Left click opens the live device mirror; right
// click exposes quota, USB/Wi-Fi transport and device controls.
sealed class TrayAppContext : ApplicationContext
{
    readonly NotifyIcon _trayIcon;
    readonly UsageFetcher _usage;
    readonly SerialLink _serialLink;
    readonly int _port;
    readonly MirrorForm _mirror;
    readonly ContextMenuStrip _menu = new();

    readonly ToolStripMenuItem _claudeUsageItem = new("Claude …") { Enabled = false };
    readonly ToolStripMenuItem _codexUsageItem = new("Codex …") { Enabled = false };
    readonly ToolStripMenuItem _cursorUsageItem = new("Cursor …") { Enabled = false };
    readonly ToolStripMenuItem _deviceInfoItem = new("设备：未连接") { Enabled = false };
    readonly ToolStripMenuItem _usbReleaseItem = new("释放 USB 用于刷机");
    readonly Dictionary<string, ToolStripMenuItem> _modeItems = new();

    public TrayAppContext(StatusService service, UsageFetcher usage, SerialLink serialLink, int port)
    {
        _usage = usage;
        _serialLink = serialLink;
        _port = port;
        _mirror = new MirrorForm(service);

        BuildMenu();
        _trayIcon = new NotifyIcon
        {
            Icon = TrayIconFromAsset(),
            Text = "AI Clock Bridge",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _trayIcon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) _mirror.Toggle();
        };
        _menu.Opening += (_, _) =>
        {
            _usage.Refresh();
            RefreshUsageLines();
            _ = RefreshDeviceSection();
        };
        _usage.OnUpdate = RefreshUsageLines;
        _serialLink.Changed += SerialLinkChanged;
    }

    void SerialLinkChanged()
    {
        if (Application.MessageLoop) _ = RefreshDeviceSection();
    }

    static Icon TrayIconFromAsset()
    {
        using var bmp = new Bitmap(MirrorControl.LoadAsset("happy-mac.png"), new Size(32, 32));
        return Icon.FromHandle(bmp.GetHicon());
    }

    void BuildMenu()
    {
        _menu.Items.Add(_claudeUsageItem);
        _menu.Items.Add(_codexUsageItem);
        _menu.Items.Add(_cursorUsageItem);

        var retryMenu = new ToolStripMenuItem("手动重试额度");
        foreach (var (title, provider) in new[]
        {
            ("立即重试 Claude", UsageProvider.Claude),
            ("立即重试 Codex", UsageProvider.Codex),
            ("立即重试 Cursor", UsageProvider.Cursor),
        })
        {
            retryMenu.DropDownItems.Add(MakeItem(title, (_, _) => RetryUsage(provider, title)));
        }
        _menu.Items.Add(retryMenu);
        _menu.Items.Add(new ToolStripSeparator());

        _menu.Items.Add(_deviceInfoItem);
        _usbReleaseItem.Click += (_, _) => ToggleUsbRelease();
        _menu.Items.Add(_usbReleaseItem);
        _menu.Items.Add(MakeItem("选择 USB 串口…", (_, _) => SelectUsbPort()));

        var displayMenu = new ToolStripMenuItem("屏幕显示");
        foreach (var (title, mode) in new[]
        {
            ("自动（谁在干活显示谁）", "auto"), ("固定 Claude", "claude"),
            ("固定 Codex", "codex"), ("固定 Cursor", "cursor"),
            ("时钟", "clock"),
        })
        {
            var item = new ToolStripMenuItem(title);
            item.Click += async (_, _) => await SetDisplayMode(mode);
            _modeItems[mode] = item;
            displayMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(displayMenu);

        _menu.Items.Add(MakeItem("更换桌宠动画…（petdex）", (_, _) => OpenPetPicker()));
        var resetMenu = new ToolStripMenuItem("恢复默认动画");
        foreach (var (title, slot) in new[] { ("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex") })
        {
            var item = new ToolStripMenuItem(title);
            item.Click += async (_, _) => await ResetSprite(slot);
            resetMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(resetMenu);

        var advanced = new ToolStripMenuItem("高级 · Wi-Fi 回退");
        advanced.DropDownItems.Add(MakeItem("自动查找 Wi-Fi 设备", async (_, _) => await AutoPairAction()));
        advanced.DropDownItems.Add(MakeItem("设置设备 IP…", (_, _) => SetDeviceAddress()));
        advanced.DropDownItems.Add(MakeItem("打开设备网页", (_, _) => OpenDevicePage()));
        advanced.DropDownItems.Add(MakeItem("把本机设为设备桥接", async (_, _) => await PointBridgeHere()));
        advanced.DropDownItems.Add(MakeItem("桥接服务地址", (_, _) => ShowAddress()));
        _menu.Items.Add(advanced);

        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("刷新", (_, _) =>
        {
            _usage.Refresh();
            RefreshUsageLines();
            _ = RefreshDeviceSection();
        }));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("退出", (_, _) =>
        {
            _trayIcon.Visible = false;
            Application.Exit();
        }));
    }

    static ToolStripMenuItem MakeItem(string title, EventHandler onClick)
    {
        var item = new ToolStripMenuItem(title);
        item.Click += onClick;
        return item;
    }

    void RefreshUsageLines()
    {
        _claudeUsageItem.Text = UsageLine("Claude", _usage.Claude, "7天");
        _codexUsageItem.Text = UsageLine("Codex", _usage.Codex, "周");
        _cursorUsageItem.Text = CursorUsageLine(_usage.Cursor);
        var providers = new Dictionary<string, ProviderUsage>
        {
            ["claude"] = _usage.Claude,
            ["codex"] = _usage.Codex,
            ["cursor"] = _usage.Cursor,
        };
        foreach (var (mode, provider) in providers)
        {
            var name = mode == "claude" ? "Claude" : mode == "codex" ? "Codex" : "Cursor";
            _modeItems[mode].Enabled = provider.IsEligible();
            _modeItems[mode].Text = $"固定 {name}" + (provider.IsLoggedOut ? "（未登录）" : "");
        }
    }

    static string UsageLine(string name, ProviderUsage usage, string weeklyLabel)
    {
        if (usage.IsLoggedOut) return $"{name}：未登录";
        if (usage.Error != null && !usage.HasDisplayQuota) return $"{name}：{usage.Error}";
        var parts = new List<string>();
        if (UsageFetcher.RemainingPercent(usage.PrimaryPct) is double primary)
        {
            var text = $"5h 剩余 {(int)primary}%";
            if (usage.PrimaryResetMin.HasValue) text += $"（{FmtMin(usage.PrimaryResetMin.Value)}后重置）";
            parts.Add(text);
        }
        if (UsageFetcher.RemainingPercent(usage.WeeklyPct) is double weekly)
        {
            var text = $"{weeklyLabel} 剩余 {(int)weekly}%";
            if (usage.WeeklyResetMin.HasValue) text += $"（{FmtMin(usage.WeeklyResetMin.Value)}）";
            parts.Add(text);
        }
        var result = parts.Count == 0 ? $"{name}：额度未知" : $"{name}　" + string.Join("　", parts);
        return AppendFreshness(result, usage);
    }

    static string CursorUsageLine(ProviderUsage usage)
    {
        if (usage.IsLoggedOut) return "Cursor：未登录";
        if (!usage.TotalPct.HasValue) return $"Cursor：{usage.Error ?? "额度未知"}";
        var parts = new List<string>();
        if (UsageFetcher.RemainingPercent(usage.AutoPct) is double auto)
            parts.Add($"Auto剩余{(int)Math.Round(auto)}%");
        if (UsageFetcher.RemainingPercent(usage.ApiPct) is double api)
            parts.Add($"API剩余{(int)Math.Round(api)}%");
        if (usage.BillingResetMin.HasValue) parts.Add($"（{FmtMin(usage.BillingResetMin.Value)}）");
        return AppendFreshness("Cursor　" + string.Join("　", parts), usage);
    }

    static string AppendFreshness(string text, ProviderUsage usage)
    {
        if (usage.Error == null) return usage.IsStale() ? text + "　STALE" : text;
        var success = usage.FetchedAt?.ToLocalTime().ToString("MM-dd HH:mm") ?? "从未";
        return $"{text}　错误：{usage.Error}　上次成功：{success}";
    }

    static string FmtMin(int min)
    {
        if (min >= 48 * 60) return $"{min / (24 * 60)}天";
        if (min >= 60) return $"{min / 60}h{(min % 60 > 0 ? $"{min % 60}m" : "")}";
        return $"{min}m";
    }

    void RetryUsage(UsageProvider provider, string title)
    {
        if (!_usage.Retry(provider))
            Toast("正在刷新", $"{title.Replace("立即重试 ", "")} 的额度请求仍在进行中。");
    }

    async Task RefreshDeviceSection()
    {
        _usbReleaseItem.Text = _serialLink.ConnectionDescription.Contains("已释放")
            ? "恢复 USB 连接" : "释放 USB 用于刷机";
        if (!_serialLink.IsLinked && DeviceClient.BaseUrl == null)
        {
            _deviceInfoItem.Text = $"设备：{DeviceClient.ConnectionDescription}";
            foreach (var item in _modeItems.Values) item.Checked = false;
            return;
        }
        _deviceInfoItem.Text = $"设备：{DeviceClient.ConnectionDescription}（读取中…）";
        DeviceInfo info;
        try { info = await DeviceClient.FetchInfo(); }
        catch
        {
            _deviceInfoItem.Text = $"设备：{DeviceClient.ConnectionDescription}（无法读取）";
            foreach (var item in _modeItems.Values) item.Checked = false;
            var seen = DeviceClient.LastSeenIp;
            var host = DeviceClient.Host;
            if (!_serialLink.IsLinked && seen.Length > 0 && !host.StartsWith(seen)
                && await DeviceClient.VerifyDevice(seen))
            {
                DeviceClient.Host = seen;
                await RefreshDeviceSection();
            }
            return;
        }
        var sprites = new[]
        {
            info.ClaudeCustomSprite ? "C:自定义" : "C:默认",
            info.CodexCustomSprite ? "X:自定义" : "X:默认",
        };
        var showing = info.Mode == "clock" ? "时钟"
            : info.Showing == "claude" ? "Claude"
            : info.Showing == "codex" ? "Codex"
            : info.Showing == "cursor" ? "Cursor" : "无 AI 登录";
        _deviceInfoItem.Text = $"设备：{DeviceClient.ConnectionDescription} · {showing} · {string.Join(" ", sprites)}";
        foreach (var (mode, item) in _modeItems) item.Checked = mode == info.Mode;
    }

    void ToggleUsbRelease()
    {
        if (_serialLink.ConnectionDescription.Contains("已释放")) _serialLink.ResumeAfterFlashing();
        else
        {
            _serialLink.ReleaseForFlashing();
            Toast("USB 已释放", "现在可以使用网页刷机或 PlatformIO；设备重新枚举后会自动恢复，或再次点击菜单手动恢复。");
        }
        _ = RefreshDeviceSection();
    }

    void SelectUsbPort()
    {
        var ports = _serialLink.AvailablePorts;
        var message = ports.Length == 0 ? "未发现串口。留空表示自动扫描。"
            : "留空表示自动扫描。当前发现：\n" + string.Join("\n", ports);
        var input = InputDialog.Show("USB 串口", message, _serialLink.PreferredPort, "自动扫描");
        if (input == null) return;
        _serialLink.PreferredPort = input;
        _serialLink.ResumeAfterFlashing();
        _ = RefreshDeviceSection();
    }

    async Task AutoPairAction()
    {
        _deviceInfoItem.Text = "设备：正在查找…";
        var ip = await DeviceClient.AutoPair(message => _deviceInfoItem.Text = $"设备：{message}");
        Toast(ip != null ? "配对成功" : "未找到设备", ip != null ? $"已找到设备并配对：{ip}" :
            "局域网内没有发现 ESP8266 时钟。请确认设备已连上同一个 WiFi，且路由器未开启客户端隔离。");
        await RefreshDeviceSection();
    }

    void SetDeviceAddress()
    {
        var input = InputDialog.Show("设备地址",
            "ESP8266 时钟的 IP（例如 192.168.1.50）", DeviceClient.Host, "192.168.1.50");
        if (input == null) return;
        DeviceClient.Host = input.Trim();
        _ = RefreshDeviceSection();
    }

    void OpenDevicePage()
    {
        var url = DeviceClient.BaseUrl;
        if (url == null) { SetDeviceAddress(); return; }
        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
    }

    async Task SetDisplayMode(string mode)
    {
        try { await DeviceClient.SetDisplayMode(mode); await RefreshDeviceSection(); }
        catch (Exception error) { Toast("切换失败", error.Message); }
    }

    void OpenPetPicker() => PetPickerForm.ShowShared();

    async Task ResetSprite(string slot)
    {
        try { await DeviceClient.ResetSprite(slot); await RefreshDeviceSection(); }
        catch (Exception error) { Toast("恢复失败", error.Message); }
    }

    async Task PointBridgeHere()
    {
        var ip = DeviceClient.LocalIPv4();
        if (ip == null) { Toast("失败", "获取本机局域网 IP 失败"); return; }
        var bridge = $"{ip}:{_port}";
        try
        {
            await DeviceClient.SetBridgeHost(bridge);
            Toast("已设置", $"设备将在 Wi-Fi 回退时从 http://{bridge}/status 拉取状态");
        }
        catch (Exception error) { Toast("设置失败", error.Message); }
    }

    void ShowAddress()
    {
        var ip = DeviceClient.LocalIPv4() ?? "<本机局域网IP>";
        Toast("桥接服务地址", $"http://{ip}:{_port}/status\n\n设备端 Bridge host 填：{ip}:{_port}");
    }

    static void Toast(string title, string text) =>
        MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _serialLink.Changed -= SerialLinkChanged;
            _trayIcon.Dispose();
            _mirror.Dispose();
            _menu.Dispose();
        }
        base.Dispose(disposing);
    }
}

static class InputDialog
{
    public static string Show(string title, string message, string value, string placeholder)
    {
        using var form = new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            Font = new Font("Microsoft YaHei UI", 9f),
            ClientSize = new Size(380, 160),
            TopMost = true,
        };
        var label = new Label { Text = message };
        label.SetBounds(14, 12, 352, 60);
        var textBox = new TextBox { Text = value, PlaceholderText = placeholder };
        textBox.SetBounds(14, 78, 352, 24);
        var ok = new Button { Text = "保存", DialogResult = DialogResult.OK };
        ok.SetBounds(196, 116, 80, 28);
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        cancel.SetBounds(286, 116, 80, 28);
        form.Controls.AddRange(new Control[] { label, textBox, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? textBox.Text : null;
    }
}
