import AppKit

// Native SVG -> PNG renderer used by package-macos.sh. Keeping this inside the
// already-built app avoids extra image-tool dependencies and makes
// docs/images/logo.svg the single source for both the App and menu-bar icons.
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--render-icon" {
    let source = CommandLine.arguments[2]
    let output = CommandLine.arguments[3]
    guard let pixels = Int(CommandLine.arguments[4]), pixels > 0,
          let image = NSImage(contentsOfFile: source),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        FileHandle.standardError.write(Data("Failed to render SVG icon\n".utf8))
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Failed to encode icon PNG\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed to write icon PNG: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Entry point. Runs as an "accessory" app (menu-bar only, no Dock icon, no main
// window) and starts the /status HTTP server that the ESP8266 clock polls.
// Headless smoke test for the petdex -> GIF -> device pipeline (same code the
// pet picker window uses): AIClockBridge --test-pet <slug> <claude|codex|cursor> <host>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--test-pet" {
    let slug = CommandLine.arguments[2]
    let slot = CommandLine.arguments[3]
    if CommandLine.arguments.count >= 5 { DeviceClient.host = CommandLine.arguments[4] }
    let size = slot == "claude" ? (w: 111, h: 120)
        : slot == "codex" ? (w: 120, h: 120) : (w: 96, h: 104)
    let state = PetdexService.states.first { $0.id == "running" }!
    PetdexService.loadManifest { result in
        guard case let .success(pets) = result, let pet = pets.first(where: { $0.slug == slug }) else {
            print("manifest load failed or slug not found"); exit(1)
        }
        print("pet: \(pet.displayName) \(pet.spritesheetUrl)")
        PetdexService.downloadSpritesheet(pet) { result in
            guard case let .success(sheet) = result else { print("sheet download failed"); exit(1) }
            print("sheet: \(sheet.width)x\(sheet.height)")
            guard let gif = PetdexService.buildGif(sheet: sheet, state: state,
                                                   targetW: size.w, targetH: size.h) else {
                print("gif build failed"); exit(1)
            }
            print("gif: \(gif.count) bytes, uploading to \(DeviceClient.host) slot \(slot)...")
            DeviceClient.uploadGif(gif, slot: slot) { error in
                print(error.map { "upload failed: \($0.localizedDescription)" } ?? "upload ok")
                exit(error == nil ? 0 : 1)
            }
        }
    }
    RunLoop.main.run() // completions land on the main queue; exit() above ends us
    exit(0)
}

// One-shot diagnostics used by release verification. Prints quota numbers and
// errors only; credentials are never included.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--usage-once" {
    let fetcher = UsageFetcher()
    let selected: UsageProvider? = CommandLine.arguments.count >= 3
        ? ["claude": .claude, "codex": .codex, "cursor": .cursor][CommandLine.arguments[2]] : nil
    fetcher.onUpdate = {
        let selectedUsage = selected.map {
            switch $0 { case .claude: return fetcher.claude; case .codex: return fetcher.codex; case .cursor: return fetcher.cursor }
        }
        guard selectedUsage?.checkCompleted ?? fetcher.initialChecksCompleted else { return }
        func value<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func row(_ usage: ProviderUsage) -> [String: Any] {
            ["eligible": usage.isEligible(), "error": value(usage.error),
             "primary": value(usage.primaryPct), "weekly": value(usage.weeklyPct),
             "total": value(usage.totalPct), "auto": value(usage.autoPct),
             "api": value(usage.apiPct)]
        }
        let output: [String: Any]
        if let selected, let selectedUsage {
            output = [String(describing: selected): row(selectedUsage)]
        } else {
            output = ["claude": row(fetcher.claude), "codex": row(fetcher.codex),
                      "cursor": row(fetcher.cursor)]
        }
        let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(data.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        exit(0)
    }
    if let selected { fetcher.refresh(selected) } else { fetcher.refresh() }
    RunLoop.main.run()
    exit(0)
}

let port: UInt16 = 8765
let service = StatusService()
let usage = UsageFetcher()
service.usage = usage

// USB is the default device transport. HTTP stays available only for the
// firmware's automatic Wi-Fi fallback after the cable/link disappears.
let serialLink = SerialLink(service: service)
DeviceClient.usbLink = serialLink
serialLink.start()

let server = HTTPServer(port: port, routes: [
    "/": { service.snapshot().jsonData() },
    "/status": { service.snapshot().jsonData() },
    "/clock": { ClockSnapshot.current().jsonData() },
], postRoutes: [
    // Claude Code / Codex hooks use the normalized shape.
    // curl -d '{"agent":"claude","event":"PreToolUse"}' http://127.0.0.1:8765/event
    "/event": { body in
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let agent = obj["agent"] as? String, let event = obj["event"] as? String {
                service.recordEvent(agent: agent, event: event, message: obj["message"] as? String)
                return Data("{\"ok\":true}".utf8)
            }
        }
        return Data("{\"ok\":false}".utf8)
    },
])
// Passive discovery: the clock polls us, so its source IP identifies it.
// Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
// outright when no device is configured yet.
server.onRequest = { path, ip in
    guard path == "/status" || path == "/clock",
          ip != "127.0.0.1", ip != "::1", !ip.isEmpty else { return }
    DeviceClient.devicePollAt = Date()
    DeviceClient.lastSeenIP = ip
    if DeviceClient.host.isEmpty { DeviceClient.host = ip }
}
// Active fallback for when the passive route can't fire at all (fresh /
// erased device knows no bridge host, so it never polls anyone): if the
// device stays silent, find it ourselves and hand it our address.
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    DeviceClient.healPairingIfNeeded(port: port)
}

do {
    try server.start()
    FileHandle.standardError.write(Data("[bridge] starting HTTP fallback on port \(port)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("[bridge] failed to bind port \(port): \(error)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBarController(service: service, usage: usage, serialLink: serialLink, port: port)
_ = menuBar // retain
usage.startAutoRefresh()
app.run()
