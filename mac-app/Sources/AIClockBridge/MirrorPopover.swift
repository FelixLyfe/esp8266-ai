import AppKit

// Live "mirror" of the ESP8266 screen, shown in a popover from the menu-bar
// icon. Not a video stream: the Mac re-renders the same scene from the same
// data — /api/info says which app the device is showing (and a sprite_rev
// that bumps when animations change), /sprite/<app>/raw provides the exact
// Claude/Codex frames, Cursor uses the same bundled RGB565 frames as firmware,
// and the local StatusService supplies the quota numbers the device gets from
// /status. Claude/Codex animate while working; Cursor loops its quota-only pet.

// MARK: - RGB565 frame decoding

private func decodeSpriteFrames(_ data: Data, w: Int, h: Int) -> [CGImage] {
    guard data.count >= 1 else { return [] }
    let count = Int(data[data.startIndex])
    let frameBytes = w * h * 2
    guard count > 0, data.count >= 1 + count * frameBytes else { return [] }
    var frames: [CGImage] = []
    let bytes = [UInt8](data)
    for f in 0..<count {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var src = 1 + f * frameBytes
        for p in 0..<(w * h) {
            // wire order is big-endian RGB565 (see tools/convert_sprites.py)
            let v = (UInt16(bytes[src]) << 8) | UInt16(bytes[src + 1])
            src += 2
            rgba[p * 4 + 0] = UInt8((v >> 11) & 0x1F) << 3
            rgba[p * 4 + 1] = UInt8((v >> 5) & 0x3F) << 2
            rgba[p * 4 + 2] = UInt8(v & 0x1F) << 3
        }
        let data = CFDataCreate(nil, rgba, rgba.count)!
        if let provider = CGDataProvider(data: data),
           let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent) {
            frames.append(img)
        }
    }
    return frames
}

// MARK: - the 240x240 replica view

final class MirrorView: NSView {
    // scene state, all in the device's 240x240 logical coordinates
    var frames: [CGImage] = []
    var frameIdx = 0
    var spriteW = 120, spriteH = 120
    var ringPct: Double = 0
    var needsInput = false // shown app waiting on approval -> red border flash
    var flashOn = false
    var line1 = "5h -"
    var line2 = "Weekly -"
    var showingProvider = "claude"
    var stale = false
    var deviceOK = false
    var clockMode = false

    private static let claudeLogo = Bundle.appResources.image(forResource: "claude-logo")
    private static let codexLogo = Bundle.appResources.image(forResource: "codex-logo")
    override var isFlipped: Bool { true } // draw in the panel's top-left origin

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / 240.0
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        // panel background
        let panel = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 240, height: 240),
                                 xRadius: 10, yRadius: 10)
        NSColor.black.setFill()
        panel.fill()
        panel.addClip()

        if clockMode {
            drawClockScene()
            ctx.restoreGState()
            return
        }
        if showingProvider == "none" || showingProvider == "checking" {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = showingProvider == "checking" ? "CHECKING ACCOUNTS..." : "NO AI LOGIN"
            (text as NSString).draw(in: NSRect(x: 0, y: 105, width: 240, height: 24), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: showingProvider == "checking" ? NSColor.systemCyan : NSColor.systemOrange,
                .paragraphStyle: style,
            ])
            ctx.restoreGState()
            return
        }

        // square quota ring: margin 1, thickness 6, clockwise from top-left
        let m: CGFloat = 1, t: CGFloat = 6
        let side: CGFloat = 240 - 2 * m
        let color = showingProvider == "cursor" && ringPct <= 0 ? NSColor.systemRed
            : deviceOK ? NSColor(calibratedRed: 0, green: 0.85, blue: 0.2, alpha: 1)
                             : NSColor.darkGray
        color.setFill()
        var remaining = side * 4 * CGFloat(max(0, min(ringPct, 100)) / 100)
        let x0 = m, y0 = m, x1 = 240 - m
        var seg = min(remaining, side)
        if seg > 0 { NSRect(x: x0, y: y0, width: seg, height: t).fill() }          // top
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x1 - t, y: y0, width: t, height: seg).fill() }      // right
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x1 - seg, y: 240 - m - t, width: seg, height: t).fill() } // bottom
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x0, y: 240 - m - seg, width: t, height: seg).fill() }     // left

        // sprite, centered, pixel-crisp
        if !frames.isEmpty {
            let img = frames[min(frameIdx, frames.count - 1)]
            let rect = CGRect(x: 120 - spriteW / 2, y: 120 - spriteH / 2,
                              width: spriteW, height: spriteH)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // CGContext draws images bottom-up; flip locally around the rect
            ctx.translateBy(x: 0, y: rect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -rect.midY)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }

        // App logo, top-left inside the ring (firmware draws it at 14,18 @40px).
        if showingProvider == "cursor" {
            drawCursorMark(ctx, center: CGPoint(x: 34, y: 38), size: 40)
        } else if let logo = Self.claudeLogo, let logo2 = Self.codexLogo {
            (showingProvider == "claude" ? logo : logo2).draw(in: NSRect(x: 14, y: 18, width: 40, height: 40))
        }

        // quota text
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        if showingProvider == "cursor" {
            (line1 as NSString).draw(in: NSRect(x: 14, y: 188, width: 100, height: 36), withAttributes: attrs)
            (line2 as NSString).draw(in: NSRect(x: 126, y: 188, width: 100, height: 36), withAttributes: attrs)
        } else {
            (line1 as NSString).draw(in: NSRect(x: 0, y: 188, width: 240, height: 18), withAttributes: attrs)
            (line2 as NSString).draw(in: NSRect(x: 0, y: 206, width: 240, height: 18), withAttributes: attrs)
        }

        if stale {
            let staleStyle = NSMutableParagraphStyle()
            staleStyle.alignment = .right
            ("STALE" as NSString).draw(in: NSRect(x: 174, y: 17, width: 50, height: 14), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: staleStyle,
            ])
        }

        if !deviceOK {
            let overlay: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: style,
            ]
            ("设备离线" as NSString).draw(in: NSRect(x: 0, y: 60, width: 240, height: 20),
                                          withAttributes: overlay)
        }

        // approval pending: blink the whole border red over everything else
        if needsInput && flashOn {
            let m: CGFloat = 4, t: CGFloat = 10, side: CGFloat = 240 - 2 * m
            NSColor.systemRed.setFill()
            NSRect(x: m, y: m, width: side, height: t).fill()
            NSRect(x: m, y: 240 - m - t, width: side, height: t).fill()
            NSRect(x: m, y: m, width: t, height: side).fill()
            NSRect(x: 240 - m - t, y: m, width: t, height: side).fill()
        }
        ctx.restoreGState()
    }

    private func drawCursorMark(_ ctx: CGContext, center: CGPoint, size: CGFloat) {
        // Cursor's official 49x56 SVG path, scaled into the same square slot
        // as the Claude/Codex logo while preserving its native aspect ratio.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 48.0226, y: 13.2547))
        path.addLine(to: CGPoint(x: 25.6601, y: 0.311786))
        path.addCurve(to: CGPoint(x: 23.3378, y: 0.311786),
                      control1: CGPoint(x: 24.942, y: -0.103929),
                      control2: CGPoint(x: 24.0559, y: -0.103929))
        path.addLine(to: CGPoint(x: 0.976347, y: 13.2547))
        path.addCurve(to: CGPoint(x: 0, y: 14.9502),
                      control1: CGPoint(x: 0.372691, y: 13.6041),
                      control2: CGPoint(x: 0, y: 14.2503))
        path.addLine(to: CGPoint(x: 0, y: 41.0498))
        path.addCurve(to: CGPoint(x: 0.976347, y: 42.7453),
                      control1: CGPoint(x: 0, y: 41.7496),
                      control2: CGPoint(x: 0.372691, y: 42.3958))
        path.addLine(to: CGPoint(x: 23.3389, y: 55.6882))
        path.addCurve(to: CGPoint(x: 25.6611, y: 55.6882),
                      control1: CGPoint(x: 24.057, y: 56.1039),
                      control2: CGPoint(x: 24.943, y: 56.1039))
        path.addLine(to: CGPoint(x: 48.0237, y: 42.7453))
        path.addCurve(to: CGPoint(x: 49, y: 41.0498),
                      control1: CGPoint(x: 48.6273, y: 42.3958),
                      control2: CGPoint(x: 49, y: 41.7496))
        path.addLine(to: CGPoint(x: 49, y: 14.9502))
        path.addCurve(to: CGPoint(x: 48.0226, y: 13.2547),
                      control1: CGPoint(x: 49, y: 14.2503),
                      control2: CGPoint(x: 48.6273, y: 13.6041))
        path.closeSubpath()

        path.move(to: CGPoint(x: 46.6179, y: 15.9964))
        path.addLine(to: CGPoint(x: 25.0302, y: 53.4802))
        path.addCurve(to: CGPoint(x: 24.4989, y: 53.337),
                      control1: CGPoint(x: 24.8842, y: 53.7328),
                      control2: CGPoint(x: 24.4989, y: 53.6296))
        path.addLine(to: CGPoint(x: 24.4989, y: 28.793))
        path.addCurve(to: CGPoint(x: 23.8134, y: 27.6027),
                      control1: CGPoint(x: 24.4989, y: 28.3026),
                      control2: CGPoint(x: 24.2375, y: 27.849))
        path.addLine(to: CGPoint(x: 2.61094, y: 15.3312))
        path.addCurve(to: CGPoint(x: 2.75372, y: 14.7987),
                      control1: CGPoint(x: 2.35898, y: 15.1849),
                      control2: CGPoint(x: 2.46186, y: 14.7987))
        path.addLine(to: CGPoint(x: 45.9292, y: 14.7987))
        path.addCurve(to: CGPoint(x: 46.6179, y: 15.9964),
                      control1: CGPoint(x: 46.5423, y: 14.7987),
                      control2: CGPoint(x: 46.9255, y: 15.4649))
        path.closeSubpath()

        let scale = size / 56
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: center.x - 49 * scale / 2,
                                          ty: center.y - size / 2)
        guard let fitted = path.copy(using: &transform) else { return }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(fitted)
        ctx.drawPath(using: .eoFill)
    }

    private func drawClockScene() {
        let snapshot = ClockSnapshot.current()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        ("LOCAL TIME" as NSString).draw(in: NSRect(x: 0, y: 30, width: 240, height: 20), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.lightGray,
            .paragraphStyle: center,
        ])
        (snapshot.time as NSString).draw(in: NSRect(x: 0, y: 70, width: 240, height: 58), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.systemCyan,
            .paragraphStyle: center,
        ])
        (snapshot.date as NSString).draw(in: NSRect(x: 0, y: 148, width: 240, height: 26), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: center,
        ])
        (snapshot.weekday as NSString).draw(in: NSRect(x: 0, y: 188, width: 240, height: 22), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
            .paragraphStyle: center,
        ])
    }
}

// MARK: - popover controller

final class MirrorPopoverController: NSObject, NSPopoverDelegate {
    private static let cursorSpriteW = 96
    private static let cursorSpriteH = 104
    private static let cursorSpriteFrames: [CGImage] = {
        guard let url = Bundle.appResources.url(forResource: "cursor-sprite", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decodeSpriteFrames(data, w: cursorSpriteW, h: cursorSpriteH)
    }()

    private let service: StatusService
    private let popover = NSPopover()
    private let mirror = MirrorView()
    private let modeControl = NSSegmentedControl(labels: ["自动", "Claude", "Codex", "Cursor", "时钟"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "连接设备中…")
    private let brightnessSlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                            target: nil, action: nil)
    private let brightnessValueLabel = NSTextField(labelWithString: "100%")
    // Drag streams many slider events; posts to the single-threaded ESP8266 web
    // server are throttled mid-drag and the final value always flushes on mouse-up.
    private var pendingBrightness: Int?
    private var lastBrightnessSentAt = Date.distantPast

    private var pollTimer: Timer?
    private var animTimer: Timer?
    private var spriteCache: [String: (rev: Int, frames: [CGImage], w: Int, h: Int)] = [:]
    private var lastInfo: DeviceInfo?
    private var fetchingSlot: String?

    init(service: StatusService) {
        self.service = service
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = makeContent()
    }

    private func makeContent() -> NSViewController {
        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 316, height: 424))

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        brightnessValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        brightnessValueLabel.textColor = .secondaryLabelColor
        brightnessValueLabel.alignment = .right
        let brightnessIcon = NSImageView(image: NSImage(systemSymbolName: "sun.max.fill",
                                                        accessibilityDescription: "亮度") ?? NSImage())
        brightnessIcon.contentTintColor = .secondaryLabelColor

        for v in [mirror, modeControl, brightnessIcon, brightnessSlider, brightnessValueLabel, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            mirror.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            mirror.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            mirror.widthAnchor.constraint(equalToConstant: 288),
            mirror.heightAnchor.constraint(equalToConstant: 288),
            modeControl.topAnchor.constraint(equalTo: mirror.bottomAnchor, constant: 12),
            modeControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            brightnessIcon.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            brightnessSlider.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            brightnessSlider.leadingAnchor.constraint(equalTo: brightnessIcon.trailingAnchor, constant: 8),
            brightnessSlider.trailingAnchor.constraint(equalTo: brightnessValueLabel.leadingAnchor, constant: -8),
            brightnessValueLabel.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            brightnessValueLabel.widthAnchor.constraint(equalToConstant: 40),
            statusLabel.topAnchor.constraint(equalTo: brightnessSlider.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        vc.view = container
        return vc
    }

    // MARK: - brightness slider

    @objc private func brightnessChanged() {
        let level = Int(brightnessSlider.doubleValue.rounded())
        brightnessValueLabel.stringValue = "\(level)%"
        let isFinal = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
        pendingBrightness = level
        if !isFinal && Date().timeIntervalSince(lastBrightnessSentAt) < 0.25 { return }
        flushBrightness()
    }

    private func flushBrightness() {
        guard let level = pendingBrightness else { return }
        pendingBrightness = nil
        lastBrightnessSentAt = Date()
        DeviceClient.setBrightness(level) { _ in }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startTimers()
            tick()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        animTimer?.invalidate()
        pollTimer = nil
        animTimer = nil
    }

    private func startTimers() {
        pollTimer?.invalidate()
        animTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // same cadence as the firmware's ANIM_INTERVAL_MS
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.animTick()
        }
    }

    private func tick() {
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self, self.popover.isShown else { return }
            switch result {
            case let .success(info):
                self.lastInfo = info
                self.mirror.deviceOK = true
                self.applyScene(info)
                self.ensureSprite(info)
                self.syncBrightness(info)
                let modeIdx = ["auto": 0, "claude": 1, "codex": 2, "cursor": 3,
                               "clock": 4][info.mode] ?? 0
                self.modeControl.selectedSegment = modeIdx
                let modeText = info.mode == "auto" ? "自动切换"
                    : info.mode == "clock" ? "时钟" : "固定显示"
                self.statusLabel.stringValue = "\(DeviceClient.connectionDescription) · \(modeText)"
            case .failure:
                self.mirror.deviceOK = false
                self.mirror.needsDisplay = true
                self.statusLabel.stringValue = DeviceClient.connectionDescription
            }
        }
    }

    /// Follow the device's reported brightness (changed via its web page or
    /// another client) — but never while the user is mid-adjustment here.
    private func syncBrightness(_ info: DeviceInfo) {
        guard pendingBrightness == nil,
              Date().timeIntervalSince(lastBrightnessSentAt) > 2 else { return }
        brightnessSlider.doubleValue = Double(info.brightness)
        brightnessValueLabel.stringValue = "\(info.brightness)%"
    }

    /// Quota lines & ring exactly as the firmware computes them from /status.
    private func applyScene(_ info: DeviceInfo) {
        mirror.clockMode = info.effective == "clock"
        if mirror.clockMode {
            mirror.needsDisplay = true
            return
        }
        let snap = service.snapshot()
        modeControl.setEnabled(snap.claude.eligible, forSegment: 1)
        modeControl.setEnabled(snap.codex.eligible, forSegment: 2)
        modeControl.setEnabled(snap.cursor.eligible, forSegment: 3)
        mirror.showingProvider = info.showing
        if info.showing == "checking" || info.showing == "none" {
            mirror.frames = []
            mirror.needsInput = false
            mirror.stale = false
            mirror.needsDisplay = true
            return
        }
        if info.showing == "claude" {
            let usedPct = snap.claude.fiveHourPct
                ?? (snap.claude.sessionWindowMin > 0
                    ? 100.0 * Double(snap.claude.sessionMin) / Double(snap.claude.sessionWindowMin) : 0)
            let leftPct = remainingPercent(fromUsed: usedPct)
            mirror.ringPct = leftPct ?? 0
            let weekly = remainingPercent(fromUsed: snap.claude.sevenDayPct)
            mirror.line1 = leftPct == nil ? "" : "5h LEFT " + Self.pctText(leftPct)
            mirror.line2 = weekly == nil ? "" : "Weekly LEFT " + Self.pctText(weekly)
            mirror.needsInput = snap.claude.needsInput
            mirror.stale = snap.claude.stale
        } else if info.showing == "codex" {
            let ringUsedPct = snap.codex.primaryPct ?? snap.codex.weeklyPct
            mirror.ringPct = remainingPercent(fromUsed: ringUsedPct) ?? 0
            let primary = remainingPercent(fromUsed: snap.codex.primaryPct)
            let weekly = remainingPercent(fromUsed: snap.codex.weeklyPct)
            mirror.line1 = primary == nil ? "" : "5h LEFT " + Self.pctText(primary)
            mirror.line2 = weekly == nil ? "" : "Weekly LEFT " + Self.pctText(weekly)
            mirror.needsInput = snap.codex.needsInput
            mirror.stale = snap.codex.stale
        } else {
            mirror.ringPct = remainingPercent(fromUsed: snap.cursor.totalPct) ?? 0
            let auto = remainingPercent(fromUsed: snap.cursor.autoPct)
            let api = remainingPercent(fromUsed: snap.cursor.apiPct)
            mirror.line1 = auto == nil ? "" : "AUTO LEFT\n" + Self.pctText(auto)
            mirror.line2 = api == nil ? "" : "API LEFT\n" + Self.pctText(api)
            mirror.needsInput = false
            mirror.stale = snap.cursor.stale
        }
        mirror.needsDisplay = true
    }

    private static func pctText(_ pct: Double?) -> String {
        guard let p = pct, p >= 0 else { return "-" }
        return "\(Int(p.rounded()))%"
    }

    private func ensureSprite(_ info: DeviceInfo) {
        if info.showing == "cursor", !info.cursorCustomSprite {
            mirror.frames = Self.cursorSpriteFrames
            mirror.spriteW = Self.cursorSpriteW
            mirror.spriteH = Self.cursorSpriteH
            return
        }
        guard info.showing == "claude" || info.showing == "codex" || info.showing == "cursor" else {
            mirror.frames = []
            return
        }
        let slot = info.showing
        let w = slot == "claude" ? info.claudeW : slot == "codex" ? info.codexW : info.cursorW
        let h = slot == "claude" ? info.claudeH : slot == "codex" ? info.codexH : info.cursorH
        if let cached = spriteCache[slot], cached.rev == info.spriteRev {
            mirror.frames = cached.frames
            mirror.spriteW = cached.w
            mirror.spriteH = cached.h
            return
        }
        guard fetchingSlot != slot else { return }
        fetchingSlot = slot
        DeviceClient.fetchSpriteRaw(slot: slot) { [weak self] result in
            guard let self = self else { return }
            self.fetchingSlot = nil
            if case let .success(data) = result {
                let frames = decodeSpriteFrames(data, w: w, h: h)
                guard !frames.isEmpty else { return }
                self.spriteCache[slot] = (info.spriteRev, frames, w, h)
                if self.lastInfo?.showing == slot {
                    self.mirror.frames = frames
                    self.mirror.spriteW = w
                    self.mirror.spriteH = h
                    self.mirror.needsDisplay = true
                }
            }
        }
    }

    private var flashCounter = 0

    private func animTick() {
        guard let info = lastInfo, !mirror.clockMode else { return }

        // ~400ms red-border flash while an approval is pending (device cadence)
        if mirror.needsInput {
            flashCounter += 1
            if flashCounter >= 3 { // 3 * 0.12s ≈ 0.36s
                flashCounter = 0
                mirror.flashOn.toggle()
                mirror.needsDisplay = true
            }
        } else if mirror.flashOn {
            mirror.flashOn = false
            mirror.needsDisplay = true
        }

        guard !mirror.frames.isEmpty else { return }
        let snap = service.snapshot()
        let working = info.showing == "cursor" || (info.showing == "codex"
            ? snap.codex.status == "working" : snap.claude.status == "working")
        if working {
            mirror.frameIdx = (mirror.frameIdx + 1) % mirror.frames.count
        } else if mirror.frameIdx != 0 {
            mirror.frameIdx = 0
        }
        mirror.needsDisplay = true
    }

    @objc private func modeChanged() {
        let mode = ["auto", "claude", "codex", "cursor", "clock"][max(0, modeControl.selectedSegment)]
        DeviceClient.setDisplayMode(mode) { [weak self] _ in self?.tick() }
    }
}
