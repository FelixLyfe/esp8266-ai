using System.IO.Ports;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace AIClockBridge;

/// USB-first transport for the SD2 clock. The CH340 serial link carries the
/// same device operations and live data as HTTP; Wi-Fi is only a fallback.
sealed class SerialLink : IDisposable
{
    const string PreferredPortKey = "usb_preferred_port";

    readonly StatusService _service;
    readonly NetSpeedMonitor _netMonitor;
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 20 };
    readonly List<byte> _rx = new();
    readonly Dictionary<ushort, Pending> _pending = new();
    readonly Dictionary<string, DateTime> _portCooldown = new(StringComparer.OrdinalIgnoreCase);

    SerialPort _port;
    DateTime _openedAt = DateTime.MinValue;
    DateTime _lastHelloAt = DateTime.MinValue;
    DateTime _lastHeartbeatAt = DateTime.MinValue;
    DateTime _lastDeviceFrameAt = DateTime.MinValue;
    DateTime _lastStatusAt = DateTime.MinValue;
    DateTime _lastNetAt = DateTime.MinValue;
    DateTime _lastCpuAt = DateTime.MinValue;
    ushort _nextSequence = 1;
    bool _legacyProbe;
    bool _outgoingTransferBusy;

    USBResource? _incomingResource;
    int _incomingExpected;
    readonly List<byte> _incomingData = new();
    TaskCompletionSource<byte[]> _incomingCompletion;
    DateTime _incomingDeadline = DateTime.MinValue;

    DateTime? _releasedUntil;
    string _releasedPort = "";
    bool _releasedPortDisappeared;

    sealed record Pending(DateTime Deadline, Func<USBFrame, bool> Handle, Action Timeout);

    public bool IsLinked { get; private set; }
    public bool LegacyFirmwareDetected { get; private set; }
    public string PortName => _port?.PortName ?? "";
    public event Action Changed;

    public SerialLink(StatusService service, NetSpeedMonitor netMonitor)
    {
        _service = service;
        _netMonitor = netMonitor;
        _timer.Tick += (_, _) => Tick();
    }

    public void Start() => _timer.Start();

    public string ConnectionDescription
    {
        get
        {
            if (LegacyFirmwareDetected) return "USB 检测到旧固件，需要升级到 0.5.0";
            if (_releasedUntil.HasValue) return "USB 已释放用于刷机";
            if (IsLinked) return $"USB 已连接 · {PortName}";
            return DeviceClient.BaseUrl != null ? "Wi-Fi 回退" : "未连接";
        }
    }

    public string PreferredPort
    {
        get => Settings.Get(PreferredPortKey);
        set
        {
            Settings.Set(PreferredPortKey, value?.Trim() ?? "");
            ClosePort(notify: false);
            NotifyChange();
        }
    }

    public string[] AvailablePorts
    {
        get
        {
            try
            {
                return SerialPort.GetPortNames()
                    .OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
            }
            catch
            {
                return Array.Empty<string>();
            }
        }
    }

    public void ReleaseForFlashing()
    {
        _releasedPort = PortName.Length > 0 ? PortName : PreferredPort;
        _releasedPortDisappeared = false;
        _releasedUntil = DateTime.UtcNow + TimeSpan.FromMinutes(2);
        LegacyFirmwareDetected = false;
        ClosePort();
    }

    public void ResumeAfterFlashing()
    {
        _releasedUntil = null;
        _releasedPortDisappeared = false;
        LegacyFirmwareDetected = false;
        NotifyChange();
    }

    public async Task<byte[]> FetchInfo()
    {
        EnsureLinked();
        var frame = await SendRequest(USBMessage.GetInfo, Array.Empty<byte>(), USBMessage.DeviceInfo,
            TimeSpan.FromSeconds(3));
        return frame.Payload;
    }

    public async Task SendCommand(Dictionary<string, object> command)
    {
        EnsureLinked();
        var data = JsonSerializer.SerializeToUtf8Bytes(command);
        if (data.Length > USBFrame.MaxPayload) throw new DeviceException("USB 数据格式错误");
        await SendAcked(USBMessage.Command, data, TimeSpan.FromSeconds(8));
    }

    public async Task UploadGif(byte[] data, string slot)
    {
        EnsureLinked();
        if (_outgoingTransferBusy) throw new DeviceException("USB 正在传输其他资源，请稍后重试");
        _outgoingTransferBusy = true;
        var resource = slot == "codex" ? USBResource.CodexGif : USBResource.ClaudeGif;
        try
        {
            var begin = new byte[5];
            begin[0] = (byte)resource;
            USBFrame.WriteUInt32(begin, 1, (uint)data.Length);
            await SendAcked(USBMessage.ResourceBegin, begin, TimeSpan.FromSeconds(8));

            var offset = 0;
            while (offset < data.Length)
            {
                var count = Math.Min(USBFrame.MaxPayload - 5, data.Length - offset);
                var chunk = new byte[count + 5];
                chunk[0] = (byte)resource;
                USBFrame.WriteUInt32(chunk, 1, (uint)offset);
                Array.Copy(data, offset, chunk, 5, count);
                await SendAcked(USBMessage.ResourceChunk, chunk, TimeSpan.FromSeconds(8));
                offset += count;
            }
            await SendAcked(USBMessage.ResourceEnd, new[] { (byte)resource }, TimeSpan.FromSeconds(60));
        }
        finally
        {
            _outgoingTransferBusy = false;
        }
    }

    public async Task<byte[]> FetchSprite(string slot)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try { return await FetchSpriteOnce(slot); }
            catch when (attempt == 0 && IsLinked) { }
        }
        throw new DeviceException("USB 设备响应超时");
    }

    async Task<byte[]> FetchSpriteOnce(string slot)
    {
        EnsureLinked();
        if (_incomingCompletion != null) throw new DeviceException("USB 正在传输其他资源，请稍后重试");
        var resource = slot == "codex" ? USBResource.CodexSprite : USBResource.ClaudeSprite;
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        _incomingResource = resource;
        _incomingExpected = 0;
        _incomingData.Clear();
        _incomingCompletion = completion;
        _incomingDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        Enqueue(new USBFrame(USBMessage.GetResource, TakeSequence(), new[] { (byte)resource }));
        return await completion.Task;
    }

    async Task<USBFrame> SendRequest(USBMessage type, byte[] payload, USBMessage responseType,
                                     TimeSpan timeout)
    {
        EnsureLinked();
        var completion = new TaskCompletionSource<USBFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sequence = TakeSequence();
        _pending[sequence] = new Pending(DateTime.UtcNow + timeout, frame =>
        {
            if (frame.Type != responseType) return false;
            completion.TrySetResult(frame);
            return true;
        }, () => completion.TrySetException(new DeviceException("USB 设备响应超时")));
        Enqueue(new USBFrame(type, sequence, payload));
        return await completion.Task;
    }

    async Task SendAcked(USBMessage type, byte[] payload, TimeSpan timeout)
    {
        Exception last = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                await SendAckedOnce(type, payload, timeout);
                return;
            }
            catch (TimeoutException error) when (attempt < 2 && IsLinked)
            {
                last = error;
            }
        }
        throw last ?? new TimeoutException("USB 设备响应超时");
    }

    async Task SendAckedOnce(USBMessage type, byte[] payload, TimeSpan timeout)
    {
        EnsureLinked();
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sequence = TakeSequence();
        _pending[sequence] = new Pending(DateTime.UtcNow + timeout, frame =>
        {
            if (frame.Type != USBMessage.Ack || frame.Payload.Length < 3) return false;
            if (frame.Payload[2] == 0) completion.TrySetResult(true);
            else completion.TrySetException(new DeviceException("设备拒绝了 USB 请求"));
            return true;
        }, () => completion.TrySetException(new TimeoutException("USB 设备响应超时")));
        Enqueue(new USBFrame(type, sequence, payload));
        await completion.Task;
    }

    void Tick()
    {
        ServiceReleaseState();
        if (_releasedUntil.HasValue) return;
        ExpirePending();
        ExpireIncoming();
        if (_port == null || !_port.IsOpen)
        {
            ScanAndOpen();
            return;
        }

        ReadPending();
        var now = DateTime.UtcNow;
        if (!IsLinked)
        {
            if (!_legacyProbe && now - _openedAt > TimeSpan.FromSeconds(3))
            {
                _legacyProbe = true;
                try
                {
                    _port.BaudRate = 115200;
                    _port.Write("#HELLO\n");
                }
                catch { ClosePort(); }
            }
            if (now - _openedAt > TimeSpan.FromSeconds(5))
            {
                _portCooldown[PortName] = now + TimeSpan.FromSeconds(3);
                ClosePort();
                return;
            }
            if (!_legacyProbe && now - _lastHelloAt >= TimeSpan.FromMilliseconds(500))
            {
                _lastHelloAt = now;
                Enqueue(new USBFrame(USBMessage.Hello, TakeSequence(),
                    Encoding.UTF8.GetBytes("{\"protocol\":1,\"host\":\"Windows\"}")));
            }
            return;
        }

        if (now - _lastDeviceFrameAt > TimeSpan.FromSeconds(5))
        {
            ClosePort();
            return;
        }
        if (now - _lastHeartbeatAt >= TimeSpan.FromSeconds(1))
        {
            _lastHeartbeatAt = now;
            Enqueue(new USBFrame(USBMessage.Heartbeat, TakeSequence(), Array.Empty<byte>()));
        }
        if (now - _lastStatusAt >= TimeSpan.FromSeconds(5))
        {
            _lastStatusAt = now;
            Enqueue(new USBFrame(USBMessage.Status, TakeSequence(), _service.Snapshot().ToJson()));
        }
        if (now - _lastNetAt >= TimeSpan.FromSeconds(2))
        {
            _lastNetAt = now;
            Enqueue(new USBFrame(USBMessage.Net, TakeSequence(),
                _netMonitor.ToJson(NetworkNameMonitor.Shared.DeviceName())));
        }
        if (now - _lastCpuAt >= TimeSpan.FromSeconds(1))
        {
            _lastCpuAt = now;
            Enqueue(new USBFrame(USBMessage.Cpu, TakeSequence(), SystemStatsMonitor.ToJson()));
        }
    }

    void ServiceReleaseState()
    {
        if (!_releasedUntil.HasValue) return;
        var exists = _releasedPort.Length > 0
            && AvailablePorts.Contains(_releasedPort, StringComparer.OrdinalIgnoreCase);
        if (!exists) _releasedPortDisappeared = true;
        if (DateTime.UtcNow >= _releasedUntil.Value || (_releasedPortDisappeared && exists))
            ResumeAfterFlashing();
    }

    void ScanAndOpen()
    {
        var candidates = PreferredPort.Length > 0 ? new[] { PreferredPort } : AutoDetectUsbPorts();
        var now = DateTime.UtcNow;
        foreach (var name in candidates)
        {
            if (_portCooldown.TryGetValue(name, out var until) && until > now) continue;
            if (OpenPort(name)) return;
            _portCooldown[name] = now + TimeSpan.FromSeconds(3);
        }
    }

    /// SerialPort.GetPortNames also returns motherboard/Bluetooth COM ports.
    /// Auto mode restricts itself to ports enumerated below USB in the Windows
    /// device registry; the menu still lists every port for explicit override.
    string[] AutoDetectUsbPorts()
    {
        var available = AvailablePorts.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            try
            {
                using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view)
                    .OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\USB");
                if (root == null) continue;
                foreach (var deviceName in root.GetSubKeyNames())
                using (var device = root.OpenSubKey(deviceName))
                {
                    if (device == null) continue;
                    foreach (var instanceName in device.GetSubKeyNames())
                    using (var parameters = device.OpenSubKey(instanceName + @"\Device Parameters"))
                    {
                        var port = parameters?.GetValue("PortName")?.ToString();
                        if (port != null && available.Contains(port)) result.Add(port);
                    }
                }
            }
            catch
            {
                // A locked registry branch is skipped; explicit selection remains available.
            }
        }
        return result.OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    bool OpenPort(string name)
    {
        try
        {
            var port = new SerialPort(name, 460800, Parity.None, 8, StopBits.One)
            {
                Handshake = Handshake.None,
                DtrEnable = false,
                RtsEnable = false,
                ReadTimeout = 1,
                WriteTimeout = 1000,
                ReadBufferSize = 64 * 1024,
                WriteBufferSize = 16 * 1024,
            };
            port.Open();
            port.DtrEnable = false;
            port.RtsEnable = false;
            _port = port;
            _openedAt = DateTime.UtcNow;
            _lastHelloAt = DateTime.MinValue;
            _legacyProbe = false;
            LegacyFirmwareDetected = false;
            _rx.Clear();
            Console.Error.WriteLine($"[usb] probing {name} at 460800");
            NotifyChange();
            return true;
        }
        catch
        {
            return false;
        }
    }

    void ClosePort(bool notify = true)
    {
        var wasLinked = IsLinked;
        try { _port?.Close(); } catch { }
        try { _port?.Dispose(); } catch { }
        _port = null;
        IsLinked = false;
        _rx.Clear();
        var callbacks = _pending.Values.ToArray();
        _pending.Clear();
        foreach (var pending in callbacks) pending.Timeout();
        if (_incomingCompletion != null)
        {
            var completion = _incomingCompletion;
            ClearIncoming();
            completion.TrySetException(new DeviceException("USB 设备未连接"));
        }
        _outgoingTransferBusy = false;
        if (wasLinked) Console.Error.WriteLine("[usb] disconnected");
        if (notify) NotifyChange();
    }

    void Enqueue(USBFrame frame)
    {
        if (_port == null || !_port.IsOpen) return;
        var data = frame.Encode();
        try { _port.Write(data, 0, data.Length); }
        catch { ClosePort(); }
    }

    void ReadPending()
    {
        if (_port == null || !_port.IsOpen) return;
        try
        {
            while (_port.BytesToRead > 0)
            {
                var bytes = new byte[Math.Min(8192, _port.BytesToRead)];
                var count = _port.Read(bytes, 0, bytes.Length);
                if (count <= 0) break;
                _rx.AddRange(bytes.Take(count));
                if (_legacyProbe)
                {
                    if (Encoding.ASCII.GetString(_rx.ToArray()).Contains("#DEVICE"))
                    {
                        LegacyFirmwareDetected = true;
                        _releasedPort = PortName;
                        _releasedUntil = DateTime.MaxValue;
                        Console.Error.WriteLine($"[usb] legacy firmware detected on {PortName}");
                        ClosePort();
                    }
                    continue;
                }
                while (USBFrame.TryDecode(_rx, out var frame)) Handle(frame);
                if (_rx.Count > 128 * 1024) _rx.RemoveRange(0, _rx.Count - 4096);
            }
        }
        catch (TimeoutException) { }
        catch { ClosePort(); }
    }

    void Handle(USBFrame frame)
    {
        _lastDeviceFrameAt = DateTime.UtcNow;
        if (frame.Type == USBMessage.HelloAck)
        {
            if (!IsLinked)
            {
                IsLinked = true;
                _lastStatusAt = DateTime.MinValue;
                _lastNetAt = DateTime.MinValue;
                _lastCpuAt = DateTime.MinValue;
                Console.Error.WriteLine($"[usb] linked {PortName}");
                NotifyChange();
            }
            return;
        }
        if (frame.Type == USBMessage.HeartbeatAck) return;
        if (frame.Type == USBMessage.Ack && frame.Payload.Length >= 2)
        {
            var sequence = USBFrame.ReadUInt16(frame.Payload, 0);
            if (_pending.TryGetValue(sequence, out var ackPending) && ackPending.Handle(frame))
                _pending.Remove(sequence);
            return;
        }
        if (_pending.TryGetValue(frame.Sequence, out var pending) && pending.Handle(frame))
        {
            _pending.Remove(frame.Sequence);
            return;
        }
        switch (frame.Type)
        {
            case USBMessage.ResourceBegin: HandleResourceBegin(frame.Payload); break;
            case USBMessage.ResourceChunk: HandleResourceChunk(frame.Payload); break;
            case USBMessage.ResourceEnd: HandleResourceEnd(frame.Payload); break;
        }
    }

    void HandleResourceBegin(byte[] payload)
    {
        if (payload.Length < 5 || !_incomingResource.HasValue
            || payload[0] != (byte)_incomingResource.Value) return;
        _incomingExpected = checked((int)USBFrame.ReadUInt32(payload, 1));
        _incomingData.Clear();
        if (_incomingExpected > 0) _incomingData.Capacity = Math.Max(_incomingData.Capacity, _incomingExpected);
    }

    void HandleResourceChunk(byte[] payload)
    {
        if (payload.Length < 5 || !_incomingResource.HasValue
            || payload[0] != (byte)_incomingResource.Value
            || USBFrame.ReadUInt32(payload, 1) != (uint)_incomingData.Count) return;
        _incomingData.AddRange(payload.Skip(5));
    }

    void HandleResourceEnd(byte[] payload)
    {
        if (!_incomingResource.HasValue || payload.Length < 1
            || payload[0] != (byte)_incomingResource.Value || _incomingCompletion == null) return;
        var completion = _incomingCompletion;
        var data = _incomingData.ToArray();
        var valid = data.Length == _incomingExpected && data.Length > 1;
        ClearIncoming();
        if (valid) completion.TrySetResult(data);
        else completion.TrySetException(new DeviceException("USB 数据格式错误"));
    }

    void ClearIncoming()
    {
        _incomingResource = null;
        _incomingExpected = 0;
        _incomingData.Clear();
        _incomingCompletion = null;
        _incomingDeadline = DateTime.MinValue;
    }

    void ExpirePending()
    {
        var now = DateTime.UtcNow;
        var expired = _pending.Where(pair => pair.Value.Deadline <= now).Select(pair => pair.Key).ToArray();
        foreach (var sequence in expired)
        {
            if (!_pending.Remove(sequence, out var pending)) continue;
            pending.Timeout();
        }
    }

    void ExpireIncoming()
    {
        if (_incomingCompletion == null || DateTime.UtcNow < _incomingDeadline) return;
        var completion = _incomingCompletion;
        ClearIncoming();
        completion.TrySetException(new DeviceException("USB 设备响应超时"));
    }

    ushort TakeSequence()
    {
        var value = _nextSequence++;
        if (_nextSequence == 0) _nextSequence = 1;
        return value;
    }

    void EnsureLinked()
    {
        if (!IsLinked) throw new DeviceException("USB 设备未连接");
    }

    void NotifyChange() => Changed?.Invoke();

    public void Dispose()
    {
        _timer.Stop();
        _timer.Dispose();
        ClosePort(notify: false);
    }
}
