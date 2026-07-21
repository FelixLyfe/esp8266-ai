<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">AI Mac 小屏幕</h1>

<p align="center">桌上的一台 AI 状态小电脑 —— ESP8266 · 开源硬件 · 桌面伴侣</p>

<p align="center">
  中文 ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://mac.qust.me">官网</a> ·
  <a href="https://mac.qust.me/#flash">网页刷机</a> ·
  <a href="https://github.com/FelixLyfe/esp8266-ai/releases/latest">下载</a>
</p>

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac 小屏幕">
</p>

一块 240×240 的复古小电视，放在桌上实时显示 **Claude Code / Codex CLI 在干什么，以及 Claude / Codex / Cursor 额度还剩多少**。不需要另填 API key：数据来自本机已有的登录凭据和会话记录。macOS 与 Windows 桥接程序都默认通过 USB 数据线直连设备，WiFi/HTTP 仅在 USB 断开后回退。

## 功能

| | |
|---|---|
| <img src="docs/images/feature1.jpg" width="360" alt="AI 工作状态"> | **AI 工作状态与额度**<br>Claude/Codex 显示工作状态，三家都显示额度。Cursor 只监测额度：通常外圈显示 Total、底部显示 Auto / API；API 剩余为 0% 时仅显示 Auto，外圈也切换为 Auto。仅展示已登录且成功取得额度的账号。 |
| 时钟 | **OpenAI 总部时钟**<br>独立页面显示旧金山的时间、日期和星期，并自动处理夏令时，通过 USB 或 WiFi 回退同步到设备。 |
| <img src="docs/images/feature3.jpg" width="360" alt="桌宠可换"> | **可换桌宠**<br>内置 [petdex.dev](https://petdex.dev) 画廊 3300+ 开源桌宠，也可上传任意 GIF，设备板上直接解码，无需重烧固件。 |

## 快速上手

需要的东西：一台「SD2 小电视」开发板（[开源硬件](https://oshwhub.com/q21182889/sd2)，也可[直接购买成品](https://mobile.yangkeduo.com/goods.html?ps=OuBjGMWE82)）、一根 USB **数据**线。

### 第 1 步 · 刷固件（约 30 秒）

用 Chrome / Edge 打开 **[mac.qust.me/#flash](https://mac.qust.me/#flash)**，USB 连接设备，点「连接设备并烧录」，选择串口等待完成即可，无需安装任何工具。

> 弹窗里看不到串口？Windows 需要装 [CH340 驱动](https://www.wch.cn/downloads/CH341SER_EXE.html)，Mac 系统自带无需安装；换根 USB 线（很多线只能充电）；更多排查见[官网 FAQ](https://mac.qust.me/#flash-faq)。
>
> 命令行党也可以用 esptool 把 [Releases](https://github.com/FelixLyfe/esp8266-ai/releases/latest) 里的 `esp8266-ai-firmware-*.bin` 刷到 `0x0`。

### 第 2 步 · 装桥接程序

从 [Releases](https://github.com/FelixLyfe/esp8266-ai/releases/latest) 下载并打开：

- **macOS**：`AIClockBridge-*-macOS-arm64.dmg`，拖入 Applications（Apple Silicon ARM64，ad-hoc 签名，首次启动需在「系统设置 → 隐私与安全性」允许）。保持 USB 数据线连接并启动应用，设备会自动握手，**无需配 WiFi**。
- **Windows**：`AIClockBridge-*-Windows-x64.exe`，双击即用。保持 USB 数据线连接并启动应用，设备会自动握手，**无需配 WiFi**；首次使用若看不到 COM 口，请先安装 CH340 驱动。

桥接程序常驻菜单栏/系统托盘并独占 USB 串口；右键菜单可选择「释放 USB 用于刷机」，设备重新枚举后自动恢复。设备上电先等待 USB 5 秒；USB 在线时 WiFi 保持关闭，连续 5 秒失联才启动 WiFi 回退。

### 第 3 步 · 可选：配置 WiFi 回退

macOS 与 Windows 日常使用都可跳过此步。拔掉 USB 或关闭桥接程序后，设备会尝试已有 WiFi；没有保存过网络时会开热点 **`AI-Clock-Setup`**。手机连接后打开 `192.168.4.1`，选择 WiFi 并输入密码。

<p align="center">
  <img src="docs/images/working.jpg" width="640" alt="工作演示">
</p>

日常使用都在托盘图标上：**左键**打开设备画面的实时镜像（底部有屏幕亮度滑条），**右键**是完整菜单（额度详情、屏幕切换、更换桌宠、时钟页等）。

## 常见问题

- **屏幕边框红色闪烁**：设备收不到桥接数据——先确认 USB 数据线、CH340 串口和桥接程序；WiFi 回退模式再检查两端是否在同一网络。
- **看不到某个 AI 项**：该应用没有登录，或本次启动后尚未成功取得额度。Claude、Codex、Cursor 会独立每 2 分钟刷新；连续 6 小时没有成功数据会从轮播中移除。
- **想立即重新获取额度**：右键菜单 →「手动重试额度」，可分别重试 Claude、Codex、Cursor；手动重试会跳过当前退避等待。
- **Cursor 额度说明**：通常外圈是 Total 剩余量，底部是 Auto / API 剩余量；API 剩余显示为 0% 时仅显示 Auto，外圈也改为 Auto。读取本机 Cursor 登录 token 并调用 Cursor 客户端当前使用的内部接口；Cursor 升级后接口可能变化，届时需要更新桥接程序。
- **想换桌宠**：右键托盘图标 → 「更换桌宠动画…」，挑一个点上传就行。

## 开发

```
firmware/     ESP8266 固件（PlatformIO + Arduino，含板上 GIF 解码）
mac-app/      macOS 菜单栏桥接（Swift/SPM，零第三方依赖）
windows-app/  Windows 托盘桥接（C# / .NET 8 WinForms）
tools/        GIF → RGB565 内置精灵图转换脚本
docs/         开发文档（硬件引脚、HTTP API、架构细节）
```

```bash
cd firmware && pio run -t upload   # 固件：编译 + USB 烧录
cd mac-app && swift run            # Mac 桥接：本地跑起来
```

硬件引脚表、屏幕驱动的坑、设备 HTTP API、GIF 板上解码架构等细节见 **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**。

硬件、固件、软件全部开源，拿去改、拿去做、拿去卖都行。
