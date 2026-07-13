<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">AI Mac Mini Display</h1>

<p align="center">A tiny AI status computer for your desk — ESP8266 · Open Source Hardware · Desktop Companion</p>

<p align="center">
  <a href="README.md">中文</a> ·
  English
</p>

<p align="center">
  <a href="https://mac.qust.me">Website</a> ·
  <a href="https://mac.qust.me/#flash">Web Flasher</a> ·
  <a href="https://github.com/pengchujin/esp8266-ai/releases/latest">Download</a>
</p>

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac Mini Display">
</p>

A retro mini-TV with a 240×240 screen that sits on your desk showing **what Claude Code / Codex CLI are doing and how much Claude / Codex / Cursor quota you have left**. No separate API key is needed: everything comes from credentials and session data already on your machine. Both macOS and Windows bridges use USB by default and fall back to WiFi/HTTP only after USB disconnects.

## Features

| | |
|---|---|
| <img src="docs/images/feature1.jpg" width="360" alt="AI status"> | **AI status & quota**<br>Claude/Codex show working state; all three show quota. Cursor is quota-only: its ring is Total and the bottom row shows Auto / API remaining. Only signed-in providers with a successful quota fetch are shown. |
| <img src="docs/images/feature2.jpg" width="360" alt="Network monitor"> | **Live network monitor**<br>Task-manager-style upload/download curves, 56-second rolling window, auto-scaling axis, and the current computer's network name. |
| CPU | **CPU usage**<br>A dedicated page shows the current computer's system CPU usage, status color, and progress bar in real time. |
| <img src="docs/images/feature3.jpg" width="360" alt="Swappable pets"> | **Swappable pets**<br>Built-in [petdex.dev](https://petdex.dev) gallery with 3300+ open-source pets, or upload any GIF — decoded on the board itself, no reflashing needed. |

## Getting started

What you need: an "SD2 mini-TV" dev board ([open-source hardware](https://oshwhub.com/q21182889/sd2), or [buy one assembled](https://mobile.yangkeduo.com/goods.html?ps=OuBjGMWE82)) and a USB **data** cable.

### Step 1 · Flash the firmware (~30 s)

Open **[mac.qust.me/#flash](https://mac.qust.me/#flash)** in Chrome / Edge, plug the device in over USB, click "Connect & Flash", pick the serial port and wait. No tools to install.

> Serial port not showing up? On Windows install the [CH340 driver](https://www.wch.cn/downloads/CH341SER_EXE.html); macOS has it built in. Try another USB cable (many are charge-only). More troubleshooting in the [website FAQ](https://mac.qust.me/#flash-faq).
>
> Command-line folks can also flash `esp8266-ai-firmware-*.bin` from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) to address `0x0` with esptool.

### Step 2 · Install the bridge app

Download from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) and open:

- **macOS**: `AIClockBridge-*-macOS.dmg`, drag into Applications (ad-hoc signed; allow it in "System Settings → Privacy & Security" on first launch). Keep the USB data cable connected and start the app; it handshakes automatically, with **no WiFi setup required**.
- **Windows**: `AIClockBridge-*-Windows-x64.exe`, just double-click. Keep the USB data cable connected and the app handshakes automatically, with **no WiFi setup required**. Install the CH340 driver first if no COM port appears.

The bridge owns the USB serial port while connected. Use “Release USB for flashing” in its menu before web/PlatformIO flashing; it resumes after the device is re-enumerated. Firmware waits five seconds for USB at boot, keeps WiFi off while USB is healthy, and starts WiFi fallback after five seconds without the link.

### Step 3 · Optional WiFi fallback

Normal macOS and Windows use can skip this step. When USB or the bridge app is unavailable, the device tries saved WiFi. If none is configured, join the **`AI-Clock-Setup`** hotspot and open `192.168.4.1` to choose a network.

<p align="center">
  <img src="docs/images/working.jpg" width="640" alt="In action">
</p>

Daily use is all on the tray icon: **left-click** opens a live mirror of the device screen (with a brightness slider at the bottom), **right-click** opens the full menu (quota details, screen switching, pet swapping, CPU/network pages, and more).

## FAQ

- **Screen border flashing red**: no bridge data is arriving — check the USB data cable, CH340 serial port, and bridge app first; in fallback mode check that both sides are on the same WiFi.
- **A provider is missing**: it is not signed in, or this launch has not completed a successful quota fetch. Claude, Codex, and Cursor refresh independently every two minutes; data with no successful refresh for six hours leaves rotation.
- **Retry quota now**: right-click → “手动重试额度” and retry Claude, Codex, or Cursor individually. A manual retry bypasses the current backoff delay.
- **Cursor quota notes**: the ring is Total remaining and the bottom row is Auto / API remaining. The bridge reads Cursor's local login token and calls the internal endpoint used by the Cursor client; a future Cursor update may require a bridge update.
- **Want a different pet**: right-click the tray icon → "Change pet animation…", pick one and upload.

## Development

```
firmware/     ESP8266 firmware (PlatformIO + Arduino, with on-board GIF decoding)
mac-app/      macOS menu bar bridge (Swift/SPM, zero third-party dependencies)
windows-app/  Windows tray bridge (C# / .NET 8 WinForms)
tools/        GIF → RGB565 built-in sprite conversion script
docs/         Developer docs (pinout, HTTP API, architecture details)
```

```bash
cd firmware && pio run -t upload   # firmware: build + flash over USB
cd mac-app && swift run            # Mac bridge: run locally
```

Hardware pinout, display-driver gotchas, the device HTTP API and the on-board GIF decoding architecture are documented in **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** (Chinese).

Hardware, firmware and software are all open source — modify it, build it, even sell it.
