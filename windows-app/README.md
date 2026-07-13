# AIClockBridge for Windows

Windows 10/11 系统托盘桥接程序，与 macOS 版使用同一套设备协议和页面。默认独占
CH340 COM 串口，通过 USB 直接向固件推送状态、额度、网速和 CPU 数据；USB 连续失联
5 秒后，固件与应用才使用 WiFi/HTTP 回退。

## 功能

- 左键托盘图标：240×240 设备实时镜像，底部可切换
  自动 / Claude / Codex / Cursor / 网速 / CPU，并可调亮度。
- 右键托盘图标：Claude、Codex、Cursor 剩余额度与重置时间；三家独立手动重试；
  USB 串口选择/自动扫描、刷机让渡、屏幕控制、petdex 桌宠、恢复默认动画，以及
  收纳在「高级 · Wi-Fi 回退」里的设备 IP 操作。
- Claude/Codex 显示工作状态；Cursor 只监测额度，不检测 Cursor 工作状态。
  Cursor 外圈为 Total 剩余量，底部同时显示 Auto / API 剩余量。
- 三家额度独立每 2 分钟刷新。凭据缺失、401/403 或本次启动尚无成功额度时，不进入
  设备轮播；数据超过 15 分钟标记 `STALE`，超过 6 小时移出轮播。
- 网速页 4Hz 采样物理网卡并显示当前 Wi-Fi SSID/以太网名称；CPU 页每秒显示
  Windows 系统总 CPU 占用率。音乐/Now Playing 功能已删除。
- USB v1 协议支持状态和控制、网速/CPU 推送、设备信息、GIF 分块上传、当前桌宠资源读取。
- WiFi 回退服务：`/status`、`/net`、`/cpu`、`POST /event`，监听失败后会自动重试。

额度凭据只从本机读取，并只发送给各自服务：

- Claude：`%USERPROFILE%\.claude\.credentials.json`
- Codex：`%USERPROFILE%\.codex\auth.json`
- Cursor：`%APPDATA%\Cursor\User\globalStorage\state.vscdb`（只读 access token）

## 运行与打包

需要 Windows 10 19041+ / Windows 11 与 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)。
若设备没有出现 COM 口，先安装 [CH340 驱动](https://www.wch.cn/downloads/CH341SER_EXE.html)。

```powershell
cd windows-app\AIClockBridge
dotnet run
```

生成自包含、单文件的 Windows x64 安装产物：

```powershell
cd windows-app
.\package-windows.ps1
```

产物位于 `dist\AIClockBridge-<version>-Windows-x64.exe`，不要求目标电脑预装 .NET。
版本号来自仓库根目录的 `VERSION`。配置保存在
`%APPDATA%\AIClockBridge\settings.json`。当前产物没有 Authenticode 签名，首次运行若被
SmartScreen 拦截，需要选择「更多信息 → 仍要运行」。

首次触发 WiFi 回退时，Windows 可能询问是否允许 8765 端口通过防火墙；只在可信网络
允许即可。USB 日常使用不依赖这个端口，但 Claude/Codex hooks 仍通过本机
`http://127.0.0.1:8765/event` 上报实时状态。

## 验证

```powershell
dotnet build .\AIClockBridge\AIClockBridge.csproj
dotnet run --project .\Tests\USBProtocolSmoke\USBProtocolSmoke.csproj
curl.exe -s http://localhost:8765/status | python -m json.tool
```

连接设备后，托盘右键第一条设备信息应显示 `USB 已连接 · COMx`。刷固件前选择
「释放 USB 用于刷机」；设备重新枚举或等待 2 分钟后自动恢复。

## 代码结构

| 文件 | 说明 |
|---|---|
| `Program.cs` | 入口、USB/HTTP 启动、回退路由与事件入口 |
| `SerialLink.cs` / `USBProtocol.cs` | COM 串口扫描、v1 帧、控制与资源传输 |
| `TrayAppContext.cs` | 托盘控制菜单、额度与手动重试 |
| `MirrorForm.cs` | Claude/Codex/Cursor/网速/CPU 屏幕镜像 |
| `UsageFetcher.cs` | 三家额度凭据读取、请求、刷新与退避 |
| `StatusService.cs` | Claude/Codex JSONL 工作状态与统一状态 JSON |
| `NetworkNameMonitor.cs` / `NetSpeedMonitor.cs` | 当前网络名与 4Hz 网速数据 |
| `SystemStatsMonitor.cs` | Windows 总 CPU 占用率 |
| `DeviceClient.cs` | USB 优先、HTTP 回退的统一设备操作 |
| `PetPickerForm.cs` / `PetdexService.cs` | petdex 桌宠选择、GIF 合成与上传 |
| `MiniHttpServer.cs` | WiFi 回退与本机 hooks HTTP 服务 |
