# 开发文档

> 面向想改代码 / 自己折腾硬件的人，普通使用看仓库根目录的 [README](../README.md) 即可。

一个 ESP8266 桌面状态屏固件：通过 USB（默认）或 WiFi（回退）显示 Claude Code / Codex CLI 的实时工作状态，以及 Claude / Codex / Cursor 的用量。Cursor 只监测额度，不检测工作状态。
不需要任何官方账单 API key —— 数据来自两处本地已有的来源：

- **工作状态**（working/idle/offline）：本地会话日志的新旧程度
  - `~/.claude/projects/**/*.jsonl`（Claude Code 会话记录）
  - `~/.codex/sessions/**/*.jsonl`（Codex CLI 会话记录）
- **真实额度**（接口返回已用百分比 + 重置时间，界面换算为剩余量）：复用应用已经存在本机的登录凭据：
  - Claude：macOS Keychain 的 `Claude Code-credentials`，或两端的 `~/.claude/.credentials.json` → `api.anthropic.com/api/oauth/usage`
  - Codex：`~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`
  - Cursor：macOS `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`，或 Windows `%APPDATA%\Cursor\User\globalStorage\state.vscdb` 的 access token → Cursor 客户端使用的 DashboardService 内部接口

三家独立每 2 分钟刷新。凭据缺失、401/403 或本次启动后从未成功取得额度的 provider 不进入屏幕轮播；成功数据超过 15 分钟标记 `STALE`，超过 6 小时移出轮播。Cursor 接口不是公开稳定 API，Cursor 升级后字段或端点可能变化；bridge 只读取 access token，不读取 refresh token、不写 Cursor 数据库。

架构：`mac-app/` 是 **Swift 原生菜单栏 app**，`windows-app/` 是 **.NET 8 WinForms 托盘 app**。两端都默认独占 CH340 串口，通过同一套版本化二进制帧主动推送状态和资源；USB 连续 5 秒不可用时，`firmware/` 才启动 WiFi，并通过原有 HTTP 服务回退。桌宠 GIF 的解码仍全部在 ESP8266 板上完成（详见第 4 节）。

## 目录结构

```
mac-app/      Mac 原生菜单栏 app (Swift / SPM，仅用系统框架，无第三方依赖)
windows-app/  Windows 托盘 app (C# / .NET 8 WinForms)，默认 USB、WiFi/HTTP 回退
firmware/     ESP8266 固件 (PlatformIO + Arduino framework)，含板上 GIF 解码
tools/        GIF -> RGB565 默认精灵图头文件的转换脚本（改编译进固件的默认动画时用）
```

## 1. 跑起 Mac 端菜单栏 app

> Windows 托盘版的构建、打包和文件结构见 [`windows-app/README.md`](../windows-app/README.md)。两端页面、额度规则和 USB v1 协议保持一致。

需要 Xcode / Swift 工具链（macOS 自带 `swift`）。

```bash
cd mac-app
swift run                # 前台运行；或 swift build 后跑 .build/debug/AIClockBridge
```

菜单栏会出现一个**复古麦金塔小电脑图标**（代码画的模板图，自动适配深浅色菜单栏，
不占宽度显示额度数字）：

- **左键点击** → 弹出 ESP8266 屏幕的**实时镜像**：Mac 端用与固件完全相同的数据
  重绘同一个画面（方形额度环 + 当前桌宠动画 + logo + 额度文字），动画帧直接从设备
  通过 USB 资源帧读取（WiFi 回退时使用 `GET /sprite/<app>/raw`；设备正在用什么就播什么），
  working 时同步播放走路循环，随设备 2s/6s 切换同步换角色；底部附
  自动/Claude/Codex/Cursor/时钟快速切换。
- **右键点击** → 控制菜单：完整额度（5h/周 剩余量 + 重置倒计时）+ 设备遥控：

- **USB 已连接 / WiFi 回退 / 未连接**：正常流程只显示当前传输状态；设备 IP 和配对操作收进「高级 · WiFi 回退」。
- **释放 USB 用于刷机**：临时关闭串口独占；设备重新枚举或等待 2 分钟后自动恢复，也可手动恢复。
- **选择 USB 串口**：默认自动扫描；多设备时 macOS 可固定 `/dev/cu.*`，Windows 可固定 `COMx`。
- **自动查找 WiFi 设备**：只用于回退。设备轮询本机 `/status` 时，
  bridge 记下来访 IP 即完成发现（零扫描）；地址为空时自动配对，设备 DHCP 换了 IP
  也会自愈。菜单项走完整流程：最近来访 IP → 已配置地址复验 → 子网 /24 扫描兜底
  （覆盖"刚配完 WiFi、还没设过桥接"的全新设备）。
- **设置设备 IP…**：手动填写 WiFi 回退地址
- **屏幕显示**：自动（谁在干活显示谁）/ 固定 Claude / 固定 Codex / 固定 Cursor / 时钟；未登录项禁用并标注“未登录”
- **手动重试额度**：Claude、Codex、Cursor 可分别立即重试；绕过该 provider 的 60 秒/429 退避，但同一家已有请求运行时不会重复并发。
- **更换桌宠动画…**：内置 [petdex.dev](https://petdex.dev) 画廊（3300+ 开源桌宠），
  搜索 → 选动画（待机/跑步/挥手…9 种）→ 预览 → 一键上传到设备
- **恢复默认动画**：删掉自定义 GIF，回到固件内置形象
- **把本机设为设备桥接**：一键把设备的 Bridge host 指到这台 Mac

验证服务是否正常：

```bash
curl -s http://localhost:8765/status | python3 -m json.tool
```

已验证返回示例（真实数据）：

```json
{
  "claude": {"status": "working", "tokens_today": 4868001, "session_min": 26, "session_window_min": 300},
  "codex":  {"status": "offline", "tokens_today": 61471, "primary_pct": 1.0, "primary_window_min": 300,
             "primary_reset_min": 0, "weekly_pct": 2.0, "weekly_window_min": 10080, "weekly_reset_min": 8729},
  "cursor": {"status": "idle", "total_pct": 29.6, "auto_pct": 15.3, "api_pct": 77.3,
             "eligible": true, "stale": false}
}
```

想要开机自启：`swift build -c release` 得到 `.build/release/AIClockBridge`，把它包成
LaunchAgent（`~/Library/LaunchAgents/`）即可，未内置，按需再加。

生成可安装的 macOS App 和 DMG：

```bash
cd mac-app
./package-macos.sh
```

产物位于仓库根目录的 `dist/AIClockBridge.app` 和
`dist/AIClockBridge-<version>-macOS.dmg`。DMG 内把 App 拖到 Applications 即可；
产物使用 ad-hoc 签名，首次启动若被 Gatekeeper 拦截，请在「系统设置 → 隐私与安全性」中允许。

**注意**：USB 模式不依赖 HTTP，但回退服务仍监听 `0.0.0.0:8765`。同一局域网内的设备都能读到状态和 token 计数（不含 API key）；建议只在可信网络使用。

### 数据来源与局限

- **额度（三家都是真实值）**：app 对每一家独立每 2 分钟请求一次用量接口（见开头），拿到
  已用百分比和重置时间，合并进 `/status` 下发给设备；Mac 和固件展示时
  换算为 `100% - 已用百分比`。Codex 按窗口实际时长分类，兼容只有 7 天窗口的 Pro Lite。接口 429 限流时
  自动退避 5 分钟并沿用上一次的数值。
- Claude 的 OAuth token 存在 Keychain，app 通过 `security` CLI 读取，第一次运行
  macOS 可能弹一次授权框（选"始终允许"即可）；`~/.claude/.credentials.json` 存在时
  优先读文件。
- Cursor 的 Total 是进入轮播的必需字段；Auto/API 可分别缺失，缺失的一行不画。百分比先限制到 0...100，再四舍五入为整数展示。
- 若凭据缺失、401/403 或首次获取失败，该 provider 不展示；临时网络错误沿用上一次成功值，并保留精确错误和上次成功时间供菜单查看。

## 2. 烧录 ESP8266 固件

已确认的硬件：ESP8266EX（ESP-12S 模组）/ 4MB flash / CH340C 转串口，设备节点
`/dev/cu.usbserial-130`。这是拼多多"WiFi天气时钟 MG01"成品板，本质是 oshwhub 上
["SD2/小电视"开源方案](https://oshwhub.com/q21182889/sd2) 的量产版。

**接线是厂家固定的，一体成型无法重接**，网上能搜到的几份"看起来像"的教程接线图实测
都是错的——真正正确的引脚来自该开源项目附带的厂家参考固件源码
（`TFT_eSPI/User_Setup.h` + `SmallDesktopDisplay.ino`），已在实机验证点亮：

| 屏幕引脚 | 说明 | ESP-12S | GPIO |
|---|---|---|---|
| SCLK | SPI 时钟 | D5 | GPIO14（硬件 SPI）|
| MOSI | SPI 数据 | D7 | GPIO13（硬件 SPI）|
| CS   | 片选 | D8 | GPIO15 |
| DC   | 数据/命令选择 | D3 | GPIO0  |
| RESET| 复位 | D4 | GPIO2  |
| 背光 | LED 背光，**低电平点亮**，厂家固件用 PWM 调光 | D1 | GPIO5  |
| VCC  | 电源 | 3V3 | - |
| GND  | 地 | GND | - |

驱动型号也有讲究：要用 TFT_eSPI 的 `ST7789_2_DRIVER`（一个专门的简化初始化变体），
用普通的 `ST7789_DRIVER` 配合正确引脚依然点不亮。`platformio.ini` 里已经按这个组合
配置好了。

如果你买到的是完全不同的板子，改 `firmware/platformio.ini` 里 `build_flags` 的
`TFT_*` 几行即可；但如果就是这款"WiFi天气时钟 MG01"，直接用现在的配置就行，不用再猜。

```bash
cd firmware
python3 -m venv .pio-venv && source .pio-venv/bin/activate
pip install platformio
pio run -t upload          # 烧录前先在菜单选择“释放 USB 用于刷机”
```

固件上电后先以 `460800` 等待 USB 握手 5 秒。握手成功时 WiFi 保持关闭；没有握手或 USB 连续失联 5 秒后，才非阻塞连接已保存的 WiFi。10 秒仍未连接时开启 `AI-Clock-Setup` 配网页。WiFi 凭据仍只通过这个网页配置。

查看串口日志：

```bash
pio device monitor -b 460800
```

## 3. 屏幕布局

全屏单应用视图（不显示时钟），一次显示 Claude、Codex、Cursor 中一个可用 provider，规则：

- **只有一个在工作** → 固定显示正在工作的 provider
- **多个在工作** → 按 Claude → Codex → Cursor 固定顺序每 2 秒交替
- **都空闲** → 同样按固定顺序每 6 秒慢速交替
- Mac 菜单栏里可以强制固定显示某个可用 provider（`POST /api/display`）；固定项失去凭据后自动回到 AUTO
- 首轮账号检查期间显示 `CHECKING ACCOUNTS...`；全部完成仍无可用账号时显示 `NO AI LOGIN`

视觉元素：

- 屏幕中央：Claude/Codex 显示大幅像素动画，仅在 `working` 时播放；Cursor 显示静态专用标记。
- 屏幕四周一圈方形进度环：环的填充长度 = 剩余额度百分比（Claude 无接口值时用
  5 小时会话时间近似已用量再反算；Codex 按真实窗口时长区分 5h / 周额度；Cursor 外圈为 Total，底部为 Auto/API）；环的颜色/动画参考
  [vibecoding-signal-light](https://github.com/starlight36/vibecoding-signal-light)
  的红绿灯设计：
  - **常亮绿** = 空闲/离线，不需要关注
  - **绿→黄→红缓慢循环** = 正在工作
  - **红色闪烁**（最高优先级，覆盖其他状态）= 桥接服务连不上或数据过期（超过
    2 个轮询周期没更新），需要马上看一眼
- **整圈边框红色闪烁 = 需要你确认操作**：Claude / Codex 弹出权限/审批选择时（Cursor 不触发审批闪烁；Claude
  的 `Notification`、Codex 的 `PermissionRequest` hook），设备整圈边框红色闪烁提醒你去
  确认；AUTO 模式还会自动切到那个待审批的角色。你在 CLI 里
  做出选择后（下一个工具调用/回合事件到达）自动停止闪烁，5 分钟无响应也会自动超时清除。
  Mac 弹窗镜像同步显示红色边框闪烁。

## 4. 自定义桌宠形象

两个入口，推荐桌面桥接程序（petdex 画廊 + 预览），设备网页作为兜底：

1. **macOS 菜单栏 / Windows 托盘 →「更换桌宠动画…」**：从 [petdex.dev](https://petdex.dev) 的公开
   manifest（`assets.petdex.dev/manifests/petdex-v1.json`，3300+ 开源桌宠）搜索选择。
   每个桌宠是一张 1536x1872 的 WebP 精灵图（8 列 x 9 行，每帧 192x208，每行一种动画：
   待机/左右跑/挥手/跳跃/失败/等待/原地跑/思考）。app 在本地裁出所选动画行、缩放到
   目标插槽尺寸、合成黑底循环 GIF，然后通过 USB 分块发送；WiFi 回退时 POST 到设备的 `/sprite/claude|codex`。
2. **设备网页** `http://<设备IP>/`：手动上传任意 `.gif`，适合用自己的图。

两条路最终都走同一条链路：设备收到 GIF 后**自己在板上解码并缩放**，立刻替换该角色的
动画，重启后也记得，**不需要重新编译或烧录固件**。

### USB 协议（macOS / Windows 默认）

- 串口：CH340，`460800 8N1`，应用独占打开，并清除 DTR/RTS 避免自动复位。macOS 自动扫描常见 `/dev/cu.*`，Windows 自动扫描 COM 口；实机上的 macOS CH340 驱动在 `921600` 会产生连续空字节，因此两端统一使用 `460800`。
- 帧格式：`A5 5A | version | type | seq(u16 LE) | length(u16 LE) | payload | CRC32 LE`；当前协议版本为 `1`，单帧负载最多 1024 字节。
- 控制/状态消息使用单行 JSON 负载；GIF 和镜像精灵使用 `RESOURCE_BEGIN / RESOURCE_CHUNK / RESOURCE_END` 二进制分块。
- 每个主机到设备的控制/资源块都等待 ACK，超时最多重试两次；设备按 offset 接受重复块，避免“已写入但 ACK 丢失”破坏传输。
- `HELLO/HELLO_ACK` 建链，之后每秒 `HEARTBEAT`；固件 5 秒未收到有效帧即认为 USB 断开。
- 主要消息类型：状态 `STATUS`、时钟 `CLOCK`、设备信息 `GET_INFO/DEVICE_INFO`、控制 `COMMAND`、资源读取 `GET_RESOURCE`。
- USB 物理连接即可信，不做密钥或加密；CRC 只负责传输检错。

### 设备 HTTP API（仅作 WiFi 回退）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/info` | 设备状态 JSON：ip/ssid/bridge/显示模式/当前显示/自定义精灵标记 |
| POST | `/api/display` | `mode=auto\|claude\|codex\|cursor\|clock` 切换屏幕显示（clock=时钟页）|
| POST | `/api/bridge` | `host=ip:port` 设置桥接地址 |
| POST | `/sprite/claude`、`/sprite/codex` | multipart 上传 GIF 并板上解码替换 |
| POST | `/sprite/claude/reset`、`/sprite/codex/reset` | 删除自定义动画，恢复内置形象 |
| GET | `/sprite/claude/raw`、`/sprite/codex/raw` | 当前生效动画的原始帧流 `[1B帧数][RGB565大端帧...]`（镜像窗口用）|

`/api/info` 里的 `sprite_rev` 在每次上传/重置动画后自增，镜像端据此决定是否重新拉帧。

## 5. 时钟页（桌面端 + 设备同步显示）

显示模式切到「时钟」后，macOS / Windows 使用电脑本地时区生成 `HH:mm:ss`、
`YYYY-MM-DD` 和英文星期缩写。USB 模式每秒推送一个独立的 `CLOCK` 帧（消息类型 `0x13`）；
WiFi 回退模式由设备每秒请求 `GET /clock`。不依赖设备 NTP，也不采集 SSID 或网卡流量。

设备和桌面镜像使用同一布局：顶部 `LOCAL TIME`，中间大号时间，底部依次显示日期和星期。
固件只局部重绘发生变化的文本区域，避免每秒整屏闪烁。

若自行配置 LaunchAgent，目标应指向 `dist/AIClockBridge.app/Contents/MacOS/AIClockBridge`。
改代码后重新运行 `mac-app/package-macos.sh`，再替换已安装的 App，避免旧进程和新版本
同时抢占 8765 端口或 USB 串口。

### GitHub Release CI

`.github/workflows/release.yml` 支持手动预检和正式发布。手动运行 workflow 只生成
Actions Artifacts；推送与根目录 `VERSION` 一致的 `vX.Y.Z` 标签后，才会构建并公开
GitHub Release。发布前先在本地检查所有版本字段：

```bash
python3 tools/check_release_version.py
git tag "v$(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

正式 Release 固定包含 Apple Silicon DMG、Windows x64 单文件程序、ESP8266 固件和
`SHA256SUMS.txt`。macOS 包当前只做 ad-hoc 签名，未接入 Developer ID 与 Apple 公证。

## 6. Hooks 实时状态（秒级，参考 clawd-on-desk 的做法）

除了日志 mtime 轮询（保留为兜底），bridge 还接收 Claude/Codex hooks 的事件推送，
状态切换从"最多迟滞 20 秒"变成"毫秒级"：

- bridge 的 `POST /event` 接受 Claude/Codex 标准 body：`{"agent":"claude|codex","event":"PreToolUse"}`
- `~/.claude/settings.json` 已注册 8 个事件的 curl hook（UserPromptSubmit/PreToolUse/
  PostToolUse/Stop/SessionEnd/Notification/PreCompact/SubagentStop，每条 `-m 1` 超时，
  不会拖慢 Claude Code；与已有 hooks 共存，靠命令里的 `8765/event` 标记幂等）
- 映射：UserPromptSubmit/Pre/PostToolUse 等 → working（TTL 10 分钟，覆盖长工具调用）；
  Stop/Notification 等 → idle（TTL 60 秒，只用来立刻压掉 mtime 的"工作尾巴"）
- Codex 侧已写入 `~/.codex/hooks.json` + `config.toml [features] hooks = true`，
  但 Codex 要求在 TUI 里跑一次 `/hooks` 信任新命令后才生效；未信任前走 mtime 兜底。
- 局限：事件是全局的不分会话——A 会话 Stop 会把还在干活的 B 会话压成 idle 最多 60 秒
  （B 的下一个工具调用事件会立刻翻回 working）。

### GIF 上传架构

架构：GIF 通过 `ESP8266WebServer` 的 multipart 文件上传（`HTTPUpload` 回调）边收边流式
写进 LittleFS 的临时文件（`/c.gif` / `/x.gif`），然后固件用
[AnimatedGIF](https://github.com/bitbank2/AnimatedGIF) 库**逐行解码**成设备要的 RGB565
帧，写入 `/c.bin` / `/x.bin`（格式 `[1字节帧数][各帧像素...]`），最后删掉临时 GIF。

ESP8266 总共只有 ~80KB RAM，一帧 120x120 的 RGB565 就 ~28KB，AnimatedGIF 自己也要
~24KB，两个大缓冲塞不下，所以整条链路都是**逐行流式、不常驻整帧**：

- 上传：multipart 分块写文件，不把整个 body 攒进一个 `String`（那样体积必炸内存）。
- 解码：AnimatedGIF 逐行回调，只用两条「一行」缓冲把源行最近邻缩放到目标尺寸，直接
  逐行写进 `.bin`；不覆盖到的区域用**上一帧**补齐（读回刚写进 `.bin` 的上一帧），
  这样被优化器裁成小矩形的 GIF（disposal method 1）也能拼对。解码期间才在堆上
  临时 `new` 出 AnimatedGIF，用完就 `delete`。
- 显示：每次也只把「当前要画的一帧」从 LittleFS 逐行读出来 `pushImage`，不整帧驻留内存。
- 没有自定义素材时，退回固件里编译好的默认动画（`firmware/include/img/*.h`）。

**注意事项 / 局限**：

- GIF 太大（尺寸很大、颜色/帧很多）可能因内存不足解码失败，页面会报错，换小一点的即可。
- 目标插槽尺寸固定：Claude 111x120、Codex 120x120，板上会最近邻缩放匹配（质量不如
  PIL 的 LANCZOS，像素风 GIF 通常没问题）。
- 最多取 GIF 的**前 8 帧**（没有整体帧数信息，就不做均匀抽帧了）。
- disposal method 2（"恢复到背景色"）没有单独区分，未覆盖像素保留上一帧而不是清空；
  对循环角色动画来说无所谓。
- WiFi 上传大文件偶尔会瞬时掉线（broken pipe 之类），失败重新上传一次即可。

## 已知限制 / TODO

- 参考项目里的“黄色闪烁-需要处理”“红色闪烁-需要批准”这类更细的状态，目前本地日志
  拿不到可靠信号，没有实现，只做了 working/idle-离线/桥接离线 三档。
- Mac 端 app 无鉴权，HTTP `/status` 监听 `0.0.0.0:8765`，仅建议在可信局域网使用；
  设备的 HTTP API 同样无鉴权。
- Claude 用量接口有较严格的服务端限流（429），app 已做 60s 节流 + 429 后 5 分钟退避 +
  沿用旧值，偶尔菜单里额度会显示为几分钟前的数据。
- Cursor 额度依赖客户端内部接口而非公开 API；兼容性由当前 Cursor 客户端实测保证，后续客户端升级可能需要同步更新解析字段。
- 未做开机自启 LaunchAgent，需要的话可以再加（见第 1 节）。
- 改**默认**编译进固件的动画（`firmware/include/img/claude_sprite.h` /
  `codex_sprite.h`）仍可用 `tools/convert_sprites.py` 生成新的 `.h` 后 `pio run -t upload`；
  日常换形象用菜单栏 petdex 选择器或设备网页即可，无需烧录。
