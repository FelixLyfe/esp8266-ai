using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace AIClockBridge;

// Live "mirror" of the ESP8266 screen, shown as a popup near the tray icon.
// Not a video stream: the PC re-renders the same scene from the same data —
// /api/info says which app the device is showing (and a sprite_rev that bumps
// when animations change), /sprite/<app>/raw provides the exact Claude/Codex
// frames, Cursor uses the same bundled RGB565 frames as firmware, and the local
// StatusService supplies the quota numbers the device gets from /status.
// Claude/Codex animate while working; Cursor loops its quota-only pet.

// MARK: - the 240x240 replica control

sealed class MirrorControl : Control
{
    // scene state, all in the device's 240x240 logical coordinates
    public List<Bitmap> Frames = new();
    public int FrameIdx;
    public int SpriteW = 120, SpriteH = 120;
    public double RingPct;
    public bool NeedsInput; // shown app waiting on approval -> red border flash
    public bool FlashOn;
    public string Line1 = "5h -";
    public string Line2 = "Weekly -";
    public string ShowingProvider = "claude";
    public bool Stale;
    public bool DeviceOK;
    public bool ClockMode;

    static readonly Image ClaudeLogo = LoadAsset("claude-logo.png");
    static readonly Image CodexLogo = LoadAsset("codex-logo.png");

    static readonly Color Green = Color.FromArgb(0, 217, 51);
    static readonly Color Yellow = Color.FromArgb(255, 204, 0);

    public MirrorControl()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
            | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    internal static Image LoadAsset(string name)
    {
        var asm = typeof(MirrorControl).Assembly;
        var resource = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(name, StringComparison.OrdinalIgnoreCase));
        if (resource == null) return new Bitmap(1, 1);
        using var stream = asm.GetManifestResourceStream(resource);
        return Image.FromStream(stream);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        var scale = Width / 240f;
        g.ScaleTransform(scale, scale);

        // panel background
        using (var panel = RoundedRect(new RectangleF(0, 0, 240, 240), 10))
        {
            g.FillPath(Brushes.Black, panel);
            g.SetClip(panel);
        }

        if (ClockMode)
        {
            DrawClockScene(g);
            return;
        }
        if (ShowingProvider is "none" or "checking")
        {
            using var font = new Font("Consolas", 14, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center };
            using var brush = new SolidBrush(ShowingProvider == "checking" ? Color.Cyan : Color.Orange);
            g.DrawString(ShowingProvider == "checking" ? "CHECKING ACCOUNTS..." : "NO AI LOGIN",
                font, brush, new RectangleF(0, 105, 240, 24), fmt);
            return;
        }

        // square quota ring: margin 1, thickness 6, clockwise from top-left
        const float m = 1, t = 6;
        const float side = 240 - 2 * m;
        var ringColor = ShowingProvider == "cursor" && RingPct <= 0 ? Color.Red
            : DeviceOK ? Green : Color.FromArgb(90, 90, 90);
        using (var ring = new SolidBrush(ringColor))
        {
            var remaining = side * 4 * (float)(Math.Clamp(RingPct, 0, 100) / 100);
            const float x0 = m, y0 = m, x1 = 240 - m;
            var seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x0, y0, seg, t);                    // top
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x1 - t, y0, t, seg);                // right
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x1 - seg, 240 - m - t, seg, t);     // bottom
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x0, 240 - m - seg, t, seg);         // left
        }

        // sprite, centered, pixel-crisp
        if (Frames.Count > 0)
        {
            var img = Frames[Math.Min(FrameIdx, Frames.Count - 1)];
            var state = g.Save();
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(img, new Rectangle(120 - SpriteW / 2, 120 - SpriteH / 2, SpriteW, SpriteH));
            g.Restore(state);
        }

        // app logo, top-left inside the ring (firmware draws it at 14,18 @40px)
        if (ShowingProvider == "cursor")
            DrawCursorMark(g, 34, 38, 40);
        else
            g.DrawImage(ShowingProvider == "claude" ? ClaudeLogo : CodexLogo,
                new Rectangle(14, 18, 40, 40));

        // quota text
        using (var font = new Font("Consolas", 13, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var fmt = new StringFormat { Alignment = StringAlignment.Center })
        {
            if (ShowingProvider == "cursor")
            {
                g.DrawString(Line1, font, Brushes.White, new RectangleF(14, 188, 100, 36), fmt);
                g.DrawString(Line2, font, Brushes.White, new RectangleF(126, 188, 100, 36), fmt);
            }
            else
            {
                g.DrawString(Line1, font, Brushes.White, new RectangleF(0, 188, 240, 18), fmt);
                g.DrawString(Line2, font, Brushes.White, new RectangleF(0, 206, 240, 18), fmt);
            }
        }

        if (Stale)
        {
            using var staleFont = new Font("Consolas", 9, FontStyle.Bold, GraphicsUnit.Pixel);
            using var staleFmt = new StringFormat { Alignment = StringAlignment.Far };
            g.DrawString("STALE", staleFont, Brushes.Orange,
                new RectangleF(174, 17, 50, 14), staleFmt);
        }

        if (!DeviceOK)
        {
            using var font = new Font("Microsoft YaHei UI", 14, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center };
            using var red = new SolidBrush(Color.FromArgb(255, 69, 58));
            g.DrawString("设备离线", font, red, new RectangleF(0, 60, 240, 20), fmt);
        }

        // approval pending: blink the whole border red over everything else
        if (NeedsInput && FlashOn)
        {
            using var red = new SolidBrush(Color.FromArgb(255, 59, 48));
            g.FillRectangle(red, m, m, side, t);
            g.FillRectangle(red, m, 240 - m - t, side, t);
            g.FillRectangle(red, m, m, t, side);
            g.FillRectangle(red, 240 - m - t, m, t, side);
        }
    }

    static void DrawCursorMark(Graphics g, float centerX, float centerY, float size)
    {
        using var path = new GraphicsPath(FillMode.Alternate);
        path.StartFigure();
        path.AddLine(48.0226f, 13.2547f, 25.6601f, 0.311786f);
        path.AddBezier(25.6601f, 0.311786f, 24.942f, -0.103929f, 24.0559f, -0.103929f, 23.3378f, 0.311786f);
        path.AddLine(23.3378f, 0.311786f, 0.976347f, 13.2547f);
        path.AddBezier(0.976347f, 13.2547f, 0.372691f, 13.6041f, 0, 14.2503f, 0, 14.9502f);
        path.AddLine(0, 14.9502f, 0, 41.0498f);
        path.AddBezier(0, 41.0498f, 0, 41.7496f, 0.372691f, 42.3958f, 0.976347f, 42.7453f);
        path.AddLine(0.976347f, 42.7453f, 23.3389f, 55.6882f);
        path.AddBezier(23.3389f, 55.6882f, 24.057f, 56.1039f, 24.943f, 56.1039f, 25.6611f, 55.6882f);
        path.AddLine(25.6611f, 55.6882f, 48.0237f, 42.7453f);
        path.AddBezier(48.0237f, 42.7453f, 48.6273f, 42.3958f, 49, 41.7496f, 49, 41.0498f);
        path.AddLine(49, 41.0498f, 49, 14.9502f);
        path.AddBezier(49, 14.9502f, 49, 14.2503f, 48.6273f, 13.6041f, 48.0226f, 13.2547f);
        path.CloseFigure();
        path.StartFigure();
        path.AddLine(46.6179f, 15.9964f, 25.0302f, 53.4802f);
        path.AddBezier(25.0302f, 53.4802f, 24.8842f, 53.7328f, 24.4989f, 53.6296f, 24.4989f, 53.337f);
        path.AddLine(24.4989f, 53.337f, 24.4989f, 28.793f);
        path.AddBezier(24.4989f, 28.793f, 24.4989f, 28.3026f, 24.2375f, 27.849f, 23.8134f, 27.6027f);
        path.AddLine(23.8134f, 27.6027f, 2.61094f, 15.3312f);
        path.AddBezier(2.61094f, 15.3312f, 2.35898f, 15.1849f, 2.46186f, 14.7987f, 2.75372f, 14.7987f);
        path.AddLine(2.75372f, 14.7987f, 45.9292f, 14.7987f);
        path.AddBezier(45.9292f, 14.7987f, 46.5423f, 14.7987f, 46.9255f, 15.4649f, 46.6179f, 15.9964f);
        path.CloseFigure();
        var scale = size / 56;
        using var transform = new Matrix(scale, 0, 0, scale,
            centerX - 49 * scale / 2, centerY - size / 2);
        path.Transform(transform);
        g.FillPath(Brushes.White, path);
    }

    void DrawClockScene(Graphics g)
    {
        var snapshot = ClockSnapshot.Current();
        using var center = new StringFormat { Alignment = StringAlignment.Center };
        using var title = new Font("Consolas", 13, FontStyle.Bold, GraphicsUnit.Pixel);
        using var time = new Font("Consolas", 42, FontStyle.Bold, GraphicsUnit.Pixel);
        using var date = new Font("Consolas", 20, FontStyle.Regular, GraphicsUnit.Pixel);
        using var weekday = new Font("Consolas", 15, FontStyle.Bold, GraphicsUnit.Pixel);
        using var cyan = new SolidBrush(Color.Cyan);
        using var yellow = new SolidBrush(Yellow);
        g.DrawString("LOCAL TIME", title, Brushes.LightGray, new RectangleF(0, 30, 240, 20), center);
        g.DrawString(snapshot.Time, time, cyan, new RectangleF(0, 70, 240, 58), center);
        g.DrawString(snapshot.Date, date, Brushes.White, new RectangleF(0, 148, 240, 26), center);
        g.DrawString(snapshot.Weekday, weekday, yellow, new RectangleF(0, 188, 240, 22), center);
    }

    static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// MARK: - popup form (the popover)

sealed class MirrorForm : Form
{
    const int CursorSpriteW = 96, CursorSpriteH = 104;
    static readonly List<Bitmap> CursorSpriteFrames = Rgb565.DecodeSpriteFrames(
        LoadBinaryAsset("cursor-sprite.bin"), CursorSpriteW, CursorSpriteH);

    readonly StatusService _service;
    readonly MirrorControl _mirror = new();
    readonly RadioButton[] _modeButtons;
    static readonly string[] Modes = { "auto", "claude", "codex", "cursor", "clock" };
    static readonly string[] ModeLabels = { "自动", "Claude", "Codex", "Cursor", "时钟" };
    readonly Label _statusLabel = new();
    readonly TrackBar _brightness = new() { Minimum = 0, Maximum = 100, TickStyle = TickStyle.None };
    readonly Label _brightnessValue = new();
    // Drag streams many scroll events; posts to the single-threaded ESP8266 web
    // server are throttled mid-drag and the final value always flushes on mouse-up.
    int? _pendingBrightness;
    DateTime _lastBrightnessSentAt = DateTime.MinValue;

    readonly System.Windows.Forms.Timer _pollTimer = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer _animTimer = new() { Interval = 120 };

    readonly Dictionary<string, (int Rev, List<Bitmap> Frames, int W, int H)> _spriteCache = new();
    DeviceInfo _lastInfo;
    string _fetchingSlot;
    bool _applyingMode; // suppress CheckedChanged while reflecting device state

    static byte[] LoadBinaryAsset(string name)
    {
        var asm = typeof(MirrorForm).Assembly;
        var resource = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(name, StringComparison.OrdinalIgnoreCase));
        if (resource == null) return Array.Empty<byte>();
        using var stream = asm.GetManifestResourceStream(resource);
        using var data = new MemoryStream();
        stream.CopyTo(data);
        return data.ToArray();
    }

    public MirrorForm(StatusService service)
    {
        _service = service;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = SystemColors.Control;
        Padding = new Padding(1);

        ClientSize = new Size(Px(316), Px(424));

        _mirror.SetBounds(Px(14), Px(14), Px(288), Px(288));
        Controls.Add(_mirror);

        _modeButtons = new RadioButton[Modes.Length];
        var segWidth = Px(288) / Modes.Length;
        for (int i = 0; i < Modes.Length; i++)
        {
            var btn = new RadioButton
            {
                Appearance = Appearance.Button,
                Text = ModeLabels[i],
                TextAlign = ContentAlignment.MiddleCenter,
                Tag = Modes[i],
                AutoSize = false,
                Enabled = i == 0 || i >= 4,
            };
            btn.SetBounds(Px(14) + i * segWidth, Px(312), segWidth, Px(28));
            btn.CheckedChanged += ModeChanged;
            _modeButtons[i] = btn;
            Controls.Add(btn);
        }

        var sunLabel = new Label
        {
            Text = "☀",
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = SystemColors.GrayText,
        };
        sunLabel.SetBounds(Px(12), Px(346), Px(24), Px(26));
        Controls.Add(sunLabel);
        _brightness.SetBounds(Px(36), Px(346), Px(216), Px(26));
        _brightness.Scroll += (_, _) => OnBrightnessInput(final: false);
        _brightness.MouseUp += (_, _) => OnBrightnessInput(final: true);
        Controls.Add(_brightness);
        _brightnessValue.SetBounds(Px(254), Px(346), Px(48), Px(26));
        _brightnessValue.TextAlign = ContentAlignment.MiddleRight;
        _brightnessValue.ForeColor = SystemColors.GrayText;
        _brightnessValue.Font = new Font("Microsoft YaHei UI", 8.5f);
        _brightnessValue.Text = "100%";
        Controls.Add(_brightnessValue);

        _statusLabel.SetBounds(Px(10), Px(378), Px(296), Px(36));
        _statusLabel.TextAlign = ContentAlignment.MiddleCenter;
        _statusLabel.ForeColor = SystemColors.GrayText;
        _statusLabel.Font = new Font("Microsoft YaHei UI", 8.5f);
        _statusLabel.Text = "连接设备中…";
        _statusLabel.AutoEllipsis = true;
        Controls.Add(_statusLabel);

        _pollTimer.Tick += async (_, _) => await Tick();
        _animTimer.Tick += (_, _) => AnimTick();
        Deactivate += (_, _) => HidePopup(); // transient, like NSPopover
    }

    float ScaleF() => DeviceDpi / 96f;
    int Px(int logical) => (int)Math.Round(logical * ScaleF());

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var pen = new Pen(Color.FromArgb(120, 120, 120));
        e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }

    public void Toggle()
    {
        if (Visible)
        {
            HidePopup();
            return;
        }
        // anchor to the tray corner of the primary screen, near the cursor
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        var x = Math.Min(Math.Max(Cursor.Position.X - Width / 2, area.Left + 8),
                         area.Right - Width - 8);
        var y = area.Bottom - Height - 8;
        Location = new Point(x, y);
        Show();
        Activate();
        _pollTimer.Start();
        _animTimer.Start();
        _ = Tick();
    }

    void HidePopup()
    {
        Hide();
        _pollTimer.Stop();
        _animTimer.Stop();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HidePopup();
        }
        base.OnFormClosing(e);
    }

    void OnBrightnessInput(bool final)
    {
        var level = _brightness.Value;
        _brightnessValue.Text = $"{level}%";
        _pendingBrightness = level;
        if (!final && (DateTime.Now - _lastBrightnessSentAt).TotalMilliseconds < 250) return;
        FlushBrightness();
    }

    void FlushBrightness()
    {
        if (_pendingBrightness is not int level) return;
        _pendingBrightness = null;
        _lastBrightnessSentAt = DateTime.Now;
        _ = DeviceClient.SetBrightness(level);
    }

    /// Follow the device's reported brightness (changed via its web page or
    /// another client) — but never while the user is mid-adjustment here.
    void SyncBrightness(DeviceInfo info)
    {
        if (_pendingBrightness != null ||
            (DateTime.Now - _lastBrightnessSentAt).TotalSeconds < 2) return;
        var level = Math.Clamp(info.Brightness, 0, 100);
        _brightness.Value = level;
        _brightnessValue.Text = $"{level}%";
    }

    async Task Tick()
    {
        DeviceInfo info;
        try
        {
            info = await DeviceClient.FetchInfo();
        }
        catch (Exception)
        {
            if (!Visible) return;
            _mirror.DeviceOK = false;
            _mirror.Invalidate();
            _statusLabel.Text = DeviceClient.ConnectionDescription;
            return;
        }
        if (!Visible) return;
        _lastInfo = info;
        _mirror.DeviceOK = true;
        ApplyScene(info);
        EnsureSprite(info);
        SyncBrightness(info);
        var modeIdx = Math.Max(0, Array.IndexOf(Modes, info.Mode));
        _applyingMode = true;
        _modeButtons[modeIdx].Checked = true;
        _applyingMode = false;
        var modeText = info.Mode == "auto" ? "自动切换"
            : info.Mode == "clock" ? "时钟" : "固定显示";
        _statusLabel.Text = $"{DeviceClient.ConnectionDescription} · {modeText}";
    }

    /// Quota lines & ring exactly as the firmware computes them from /status.
    void ApplyScene(DeviceInfo info)
    {
        _mirror.ClockMode = info.Effective == "clock";
        if (_mirror.ClockMode)
        {
            _mirror.Invalidate();
            return;
        }
        var snap = _service.Snapshot();
        _modeButtons[1].Enabled = snap.Claude.Eligible;
        _modeButtons[2].Enabled = snap.Codex.Eligible;
        _modeButtons[3].Enabled = snap.Cursor.Eligible;
        _mirror.ShowingProvider = info.Showing;
        if (info.Showing is "checking" or "none")
        {
            _mirror.Frames = new();
            _mirror.NeedsInput = false;
            _mirror.Stale = false;
            _mirror.Invalidate();
            return;
        }
        if (info.Showing == "claude")
        {
            var used = snap.Claude.FiveHourPct
                ?? (snap.Claude.SessionWindowMin > 0
                    ? 100.0 * snap.Claude.SessionMin / snap.Claude.SessionWindowMin : 0);
            var primary = UsageFetcher.RemainingPercent(used);
            var weekly = UsageFetcher.RemainingPercent(snap.Claude.SevenDayPct);
            _mirror.RingPct = primary ?? 0;
            _mirror.Line1 = primary.HasValue ? "5h LEFT " + PctText(primary) : "";
            _mirror.Line2 = weekly.HasValue ? "Weekly LEFT " + PctText(weekly) : "";
            _mirror.NeedsInput = snap.Claude.NeedsInput;
            _mirror.Stale = snap.Claude.Stale;
        }
        else if (info.Showing == "codex")
        {
            var primary = UsageFetcher.RemainingPercent(snap.Codex.PrimaryPct);
            var weekly = UsageFetcher.RemainingPercent(snap.Codex.WeeklyPct);
            _mirror.RingPct = UsageFetcher.RemainingPercent(snap.Codex.PrimaryPct ?? snap.Codex.WeeklyPct) ?? 0;
            _mirror.Line1 = primary.HasValue ? "5h LEFT " + PctText(primary) : "";
            _mirror.Line2 = weekly.HasValue ? "Weekly LEFT " + PctText(weekly) : "";
            _mirror.NeedsInput = snap.Codex.NeedsInput;
            _mirror.Stale = snap.Codex.Stale;
        }
        else
        {
            _mirror.RingPct = UsageFetcher.RemainingPercent(snap.Cursor.TotalPct) ?? 0;
            var auto = UsageFetcher.RemainingPercent(snap.Cursor.AutoPct);
            var api = UsageFetcher.RemainingPercent(snap.Cursor.ApiPct);
            _mirror.Line1 = auto.HasValue ? "AUTO LEFT\n" + PctText(auto) : "";
            _mirror.Line2 = api.HasValue ? "API LEFT\n" + PctText(api) : "";
            _mirror.NeedsInput = false;
            _mirror.Stale = snap.Cursor.Stale;
        }
        _mirror.Invalidate();
    }

    static string PctText(double? pct) =>
        pct.HasValue && pct.Value >= 0 ? $"{(int)Math.Round(pct.Value)}%" : "-";

    void EnsureSprite(DeviceInfo info)
    {
        if (info.Showing == "cursor")
        {
            _mirror.Frames = CursorSpriteFrames;
            _mirror.SpriteW = CursorSpriteW;
            _mirror.SpriteH = CursorSpriteH;
            return;
        }
        if (info.Showing != "claude" && info.Showing != "codex")
        {
            _mirror.Frames = new();
            return;
        }
        var slot = info.Showing == "codex" ? "codex" : "claude";
        var w = slot == "claude" ? info.ClaudeW : info.CodexW;
        var h = slot == "claude" ? info.ClaudeH : info.CodexH;
        if (_spriteCache.TryGetValue(slot, out var cached) && cached.Rev == info.SpriteRev)
        {
            _mirror.Frames = cached.Frames;
            _mirror.SpriteW = cached.W;
            _mirror.SpriteH = cached.H;
            return;
        }
        if (_fetchingSlot == slot) return;
        _fetchingSlot = slot;
        _ = FetchSprite(slot, info.SpriteRev, w, h);
    }

    async Task FetchSprite(string slot, int rev, int w, int h)
    {
        try
        {
            var data = await DeviceClient.FetchSpriteRaw(slot);
            var frames = Rgb565.DecodeSpriteFrames(data, w, h);
            if (frames.Count == 0) return;
            if (_spriteCache.TryGetValue(slot, out var old))
                foreach (var f in old.Frames) f.Dispose();
            _spriteCache[slot] = (rev, frames, w, h);
            if ((_lastInfo?.Showing == "codex" ? "codex" : "claude") == slot)
            {
                _mirror.Frames = frames;
                _mirror.SpriteW = w;
                _mirror.SpriteH = h;
                _mirror.Invalidate();
            }
        }
        catch (Exception)
        {
            // device unreachable / mid-upload: next tick retries
        }
        finally
        {
            _fetchingSlot = null;
        }
    }

    int _flashCounter;

    void AnimTick()
    {
        if (_lastInfo == null || _mirror.ClockMode) return;

        // ~400ms red-border flash while an approval is pending (device cadence)
        if (_mirror.NeedsInput)
        {
            _flashCounter++;
            if (_flashCounter >= 3) // 3 * 0.12s ≈ 0.36s
            {
                _flashCounter = 0;
                _mirror.FlashOn = !_mirror.FlashOn;
                _mirror.Invalidate();
            }
        }
        else if (_mirror.FlashOn)
        {
            _mirror.FlashOn = false;
            _mirror.Invalidate();
        }

        if (_mirror.Frames.Count == 0) return;
        var snap = _service.Snapshot();
        var working = _lastInfo.Showing == "cursor" || (_lastInfo.Showing == "codex"
            ? snap.Codex.Status == "working" : snap.Claude.Status == "working");
        if (working)
        {
            _mirror.FrameIdx = (_mirror.FrameIdx + 1) % _mirror.Frames.Count;
        }
        else if (_mirror.FrameIdx != 0)
        {
            _mirror.FrameIdx = 0;
        }
        _mirror.Invalidate();
    }

    async void ModeChanged(object sender, EventArgs e)
    {
        if (_applyingMode || sender is not RadioButton { Checked: true, Tag: string mode }) return;
        try
        {
            await DeviceClient.SetDisplayMode(mode);
        }
        catch (Exception)
        {
            // Tick() below re-syncs the buttons to the device's real state
        }
        await Tick();
    }
}
