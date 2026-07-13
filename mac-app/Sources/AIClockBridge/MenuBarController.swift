import AppKit

// Menu-bar item: a retro Macintosh icon (drawn in code, template so it adapts
// to light/dark menu bars). Left click opens a live mirror of the ESP8266
// screen (MirrorPopover); right click opens the control menu with usage
// meters and device remote control. No quota text lives in the bar itself.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let service: StatusService
    private let usage: UsageFetcher
    private let port: UInt16
    private let serialLink: SerialLink
    private let controlMenu = NSMenu()
    private let mirrorPopover: MirrorPopoverController

    private let claudeUsageItem = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codexUsageItem = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let cursorUsageItem = NSMenuItem(title: "Cursor …", action: nil, keyEquivalent: "")
    private let deviceInfoItem = NSMenuItem(title: "设备：未设置", action: nil, keyEquivalent: "")
    private lazy var usbReleaseItem = makeItem("释放 USB 用于刷机", #selector(toggleUSBRelease))
    private var modeItems: [String: NSMenuItem] = [:]

    init(service: StatusService, usage: UsageFetcher, netMonitor: NetSpeedMonitor,
         serialLink: SerialLink, port: UInt16) {
        self.service = service
        self.usage = usage
        self.port = port
        self.serialLink = serialLink
        self.mirrorPopover = MirrorPopoverController(service: service, netMonitor: netMonitor)
        super.init()
        buildMenu()
        usage.onUpdate = { [weak self] in self?.refreshUsageLines() }
        if let button = statusItem.button {
            button.image = Self.retroMacIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// The packaged app loads the ICNS rendered from docs/images/logo.svg.
    /// `swift run` falls back to that same source-tree SVG.
    private static func retroMacIcon() -> NSImage {
        let packaged = Bundle.main.url(forResource: "AIClockBridge", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
        let sourceTree = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../docs/images/logo.svg").standardized
        guard let img = packaged ?? NSImage(contentsOf: sourceTree) else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    /// Left click -> mirror popover; right click -> control menu.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = controlMenu
            button.performClick(nil)
            statusItem.menu = nil // detach so left click keeps toggling the popover
        } else {
            mirrorPopover.toggle(relativeTo: button)
        }
    }

    // MARK: - menu construction

    private func buildMenu() {
        let menu = controlMenu
        menu.delegate = self

        claudeUsageItem.isEnabled = false
        codexUsageItem.isEnabled = false
        cursorUsageItem.isEnabled = false
        menu.addItem(claudeUsageItem)
        menu.addItem(codexUsageItem)
        menu.addItem(cursorUsageItem)
        let retryMenu = NSMenu()
        for (title, provider) in [("立即重试 Claude", "claude"), ("立即重试 Codex", "codex"),
                                  ("立即重试 Cursor", "cursor")] {
            let item = NSMenuItem(title: title, action: #selector(retryUsage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider
            retryMenu.addItem(item)
        }
        let retryItem = NSMenuItem(title: "手动重试额度", action: nil, keyEquivalent: "")
        retryItem.submenu = retryMenu
        menu.addItem(retryItem)
        menu.addItem(.separator())

        deviceInfoItem.isEnabled = false
        menu.addItem(deviceInfoItem)

        menu.addItem(usbReleaseItem)
        menu.addItem(makeItem("选择 USB 串口…", #selector(selectUSBPort)))

        let displayMenu = NSMenu()
        for (title, mode) in [("自动（谁在干活显示谁）", "auto"), ("固定 Claude", "claude"),
                              ("固定 Codex", "codex"), ("固定 Cursor", "cursor"), ("网速曲线", "net"),
                              ("CPU 占用率", "cpu")] {
            let item = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            modeItems[mode] = item
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "屏幕显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        // (屏幕亮度在左键弹出的镜像页底部，做成滑条了)

        menu.addItem(makeItem("更换桌宠动画…（petdex）", #selector(openPetPicker)))

        let resetMenu = NSMenu()
        for (title, slot) in [("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex")] {
            let item = NSMenuItem(title: title, action: #selector(resetSprite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot
            resetMenu.addItem(item)
        }
        let resetItem = NSMenuItem(title: "恢复默认动画", action: nil, keyEquivalent: "")
        resetItem.submenu = resetMenu
        menu.addItem(resetItem)

        let advanced = NSMenu()
        advanced.addItem(makeItem("自动查找 Wi-Fi 设备", #selector(autoPairAction)))
        advanced.addItem(makeItem("设置设备 IP…", #selector(setDeviceAddress)))
        advanced.addItem(makeItem("打开设备网页", #selector(openDevicePage)))
        advanced.addItem(makeItem("把本机设为设备桥接", #selector(pointBridgeHere)))
        advanced.addItem(makeItem("桥接服务地址", #selector(showAddress)))
        let advancedItem = NSMenuItem(title: "高级 · Wi-Fi 回退", action: nil, keyEquivalent: "")
        advancedItem.submenu = advanced
        menu.addItem(advancedItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("刷新", #selector(refreshAction), key: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - refresh

    func menuWillOpen(_ menu: NSMenu) {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    private func refreshUsageLines() {
        claudeUsageItem.title = Self.usageLine(name: "Claude", u: usage.claude, weeklyLabel: "7天")
        codexUsageItem.title = Self.usageLine(name: "Codex", u: usage.codex, weeklyLabel: "周")
        cursorUsageItem.title = Self.cursorUsageLine(usage.cursor)
        let providerStates = ["claude": usage.claude, "codex": usage.codex, "cursor": usage.cursor]
        for (mode, provider) in providerStates {
            modeItems[mode]?.isEnabled = provider.isEligible()
            modeItems[mode]?.title = "固定 \(mode == "claude" ? "Claude" : mode == "codex" ? "Codex" : "Cursor")"
                + (provider.isLoggedOut ? "（未登录）" : "")
        }
    }

    private static func usageLine(name: String, u: ProviderUsage, weeklyLabel: String) -> String {
        if u.isLoggedOut { return "\(name)：未登录" }
        if let err = u.error, !u.hasDisplayQuota { return "\(name)：\(err)" }
        var parts: [String] = []
        if let p = u.primaryPct {
            var s = "5h 剩余 \(Int(remainingPercent(fromUsed: p) ?? 0))%"
            if let m = u.primaryResetMin { s += "（\(fmtMin(m))后重置）" }
            parts.append(s)
        }
        if let p = u.weeklyPct {
            var s = "\(weeklyLabel) 剩余 \(Int(remainingPercent(fromUsed: p) ?? 0))%"
            if let m = u.weeklyResetMin { s += "（\(fmtMin(m))）" }
            parts.append(s)
        }
        let text = parts.isEmpty ? "\(name)：额度未知" : "\(name)　" + parts.joined(separator: "　")
        return appendFreshness(text, usage: u)
    }

    private static func cursorUsageLine(_ u: ProviderUsage) -> String {
        if u.isLoggedOut { return "Cursor：未登录" }
        guard u.totalPct != nil else {
            return "Cursor：\(u.error ?? "额度未知")"
        }
        var parts: [String] = []
        if let auto = remainingPercent(fromUsed: u.autoPct) { parts.append("Auto剩余\(Int(auto.rounded()))%") }
        if let api = remainingPercent(fromUsed: u.apiPct) { parts.append("API剩余\(Int(api.rounded()))%") }
        if let reset = u.billingResetMin { parts.append("（\(fmtMin(reset))）") }
        return appendFreshness("Cursor　" + parts.joined(separator: "　"), usage: u)
    }

    private static func appendFreshness(_ base: String, usage: ProviderUsage) -> String {
        guard let error = usage.error else { return usage.isStale() ? base + "　STALE" : base }
        let time = usage.fetchedAt.map {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: $0)
        } ?? "从未"
        return base + "　错误：\(error)　上次成功：\(time)"
    }

    private static func fmtMin(_ min: Int) -> String {
        if min >= 48 * 60 { return "\(min / (24 * 60))天" }
        if min >= 60 { return "\(min / 60)h\(min % 60 > 0 ? "\(min % 60)m" : "")" }
        return "\(min)m"
    }

    private func refreshDeviceSection() {
        usbReleaseItem.title = serialLink.connectionDescription.contains("已释放")
            ? "恢复 USB 连接" : "释放 USB 用于刷机"
        guard serialLink.isLinked || DeviceClient.baseURL != nil else {
            deviceInfoItem.title = "设备：\(DeviceClient.connectionDescription)"
            modeItems.values.forEach { $0.state = .off }
            return
        }
        deviceInfoItem.title = "设备：\(DeviceClient.connectionDescription)（读取中…）"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(info):
                let sprites = [info.claudeCustomSprite ? "C:自定义" : "C:默认",
                               info.codexCustomSprite ? "X:自定义" : "X:默认"]
                let showing = info.mode == "net" ? "网速"
                    : info.mode == "cpu" ? "CPU"
                    : info.showing == "claude" ? "Claude"
                    : info.showing == "codex" ? "Codex"
                    : info.showing == "cursor" ? "Cursor" : "无 AI 登录"
                self.deviceInfoItem.title =
                    "设备：\(DeviceClient.connectionDescription) · \(showing) · \(sprites.joined(separator: " "))"
                for (mode, item) in self.modeItems { item.state = mode == info.mode ? .on : .off }
            case .failure:
                self.deviceInfoItem.title = "设备：\(DeviceClient.connectionDescription)（无法读取）"
                self.modeItems.values.forEach { $0.state = .off }
                // self-heal: the device may have moved to a new DHCP address;
                // if it recently polled us from a different IP, adopt that.
                let seen = DeviceClient.lastSeenIP
                let host = DeviceClient.host
                if !self.serialLink.isLinked, !seen.isEmpty, !host.hasPrefix(seen) {
                    DeviceClient.verifyDevice(ip: seen) { ok in
                        if ok {
                            DeviceClient.host = seen
                            self.refreshDeviceSection()
                        }
                    }
                }
            }
        }
    }

    // MARK: - pairing

    @objc private func autoPairAction() {
        deviceInfoItem.title = "设备：正在查找…"
        DeviceClient.autoPair(progress: { [weak self] msg in
            self?.deviceInfoItem.title = "设备：\(msg)"
        }, completion: { [weak self] ip in
            if let ip = ip {
                Self.toast("配对成功", "已找到设备并配对：\(ip)")
                self?.refreshDeviceSection()
            } else {
                Self.toast("未找到设备", """
                局域网内没有发现 ESP8266 时钟。请确认：
                1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
                2. 路由器未开启"客户端隔离"
                """)
                self?.refreshDeviceSection()
            }
        })
    }

    // MARK: - actions

    @objc private func refreshAction() {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    @objc private func retryUsage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let provider: UsageProvider
        switch raw {
        case "claude": provider = .claude
        case "codex": provider = .codex
        case "cursor": provider = .cursor
        default: return
        }
        if !usage.retry(provider) {
            Self.toast("正在刷新", "\(sender.title.replacingOccurrences(of: "立即重试 ", with: "")) 的额度请求仍在进行中。")
        }
    }

    @objc private func setDeviceAddress() {
        let alert = NSAlert()
        alert.messageText = "设备地址"
        alert.informativeText = "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = DeviceClient.host
        input.placeholderString = "192.168.1.50"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceClient.host = input.stringValue.trimmingCharacters(in: .whitespaces)
            refreshDeviceSection()
        }
    }

    @objc private func openDevicePage() {
        guard let url = DeviceClient.baseURL else {
            setDeviceAddress()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DeviceClient.setDisplayMode(mode) { [weak self] error in
            if let error = error {
                Self.toast("切换失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func openPetPicker() {
        PetPickerWindowController.shared.show()
    }

    @objc private func toggleUSBRelease() {
        if serialLink.connectionDescription.contains("已释放") {
            serialLink.resumeAfterFlashing()
        } else {
            serialLink.releaseForFlashing()
            Self.toast("USB 已释放", "现在可以使用网页刷机或 PlatformIO；设备重新枚举后会自动恢复，或再次点击菜单手动恢复。")
        }
        refreshDeviceSection()
    }

    @objc private func selectUSBPort() {
        let ports = serialLink.availablePorts
        let alert = NSAlert()
        alert.messageText = "USB 串口"
        alert.informativeText = ports.isEmpty
            ? "未发现 CH340 串口。留空表示自动扫描。"
            : "留空表示自动扫描。当前发现：\n" + ports.joined(separator: "\n")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = serialLink.preferredPort
        input.placeholderString = "自动扫描"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            serialLink.preferredPort = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            serialLink.resumeAfterFlashing()
            refreshDeviceSection()
        }
    }

    @objc private func resetSprite(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? String else { return }
        DeviceClient.resetSprite(slot: slot) { [weak self] error in
            if let error = error {
                Self.toast("恢复失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func pointBridgeHere() {
        guard let ip = DeviceClient.localIPv4() else {
            Self.toast("失败", "获取本机局域网 IP 失败")
            return
        }
        let bridge = "\(ip):\(port)"
        DeviceClient.setBridgeHost(bridge) { error in
            if let error = error {
                Self.toast("设置失败", error.localizedDescription)
            } else {
                Self.toast("已设置", "设备将从 http://\(bridge)/status 拉取状态")
            }
        }
    }

    @objc private func showAddress() {
        let ip = DeviceClient.localIPv4() ?? "<本机局域网IP>"
        Self.toast("桥接服务地址", "http://\(ip):\(port)/status\n\n设备端 Bridge host 填：\(ip):\(port)")
    }

    private static func toast(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
