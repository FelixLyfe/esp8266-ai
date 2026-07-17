import Darwin
import Foundation

/// USB-first transport for the SD2 clock. The board exposes the ESP8266 UART
/// through CH340; this class owns that serial port exclusively and carries the
/// same device operations that HTTP provides as a Wi-Fi fallback.
final class SerialLink {
    static let didChangeNotification = Notification.Name("AIClockUSBLinkDidChange")
    private static let preferredPortKey = "usb_preferred_port"

    private let service: StatusService

    private(set) var portPath = ""
    private(set) var isLinked = false
    private(set) var legacyFirmwareDetected = false
    private var fd: Int32 = -1
    private var timer: Timer?
    private var openedAt = Date.distantPast
    private var lastHelloAt = Date.distantPast
    private var lastHeartbeatAt = Date.distantPast
    private var lastDeviceFrameAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var lastClockAt = Date.distantPast
    private var legacyProbe = false
    private var rxBuffer = Data()
    private var txBuffer = Data()
    private var nextSequence: UInt16 = 1
    private var portCooldown: [String: Date] = [:]

    private struct Pending {
        let deadline: Date
        let handle: (USBFrame) -> Bool
        let timeout: () -> Void
    }
    private var pending: [UInt16: Pending] = [:]

    private var outgoingTransferBusy = false
    private var incomingResource: USBResource?
    private var incomingExpected = 0
    private var incomingData = Data()
    private var incomingCompletion: ((Result<Data, Error>) -> Void)?

    private var releasedUntil: Date?
    private var releasedPort = ""
    private var releasedPortDisappeared = false

    init(service: StatusService) {
        self.service = service
    }

    func start() {
        timer?.invalidate()
        timer = Self.scheduleLoopTimer { [weak self] in self?.tick() }
    }

    @discardableResult
    static func scheduleLoopTimer(interval: TimeInterval = 0.02,
                                  handler: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in handler() }
        // NSMenu tracks in NSEventTrackingRunLoopMode. A default-mode timer
        // pauses while the status-item menu is open, starving the USB heartbeat
        // until both sides hit their five-second disconnect timeout.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    var connectionDescription: String {
        if legacyFirmwareDetected { return "USB 检测到旧固件，需要升级到 0.5.0" }
        if releasedUntil != nil { return "USB 已释放用于刷机" }
        if isLinked { return "USB 已连接 · \(portPath)" }
        if DeviceClient.baseURL != nil { return "Wi-Fi 回退" }
        return "未连接"
    }

    var preferredPort: String {
        get { UserDefaults.standard.string(forKey: Self.preferredPortKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferredPortKey)
            closePort(notify: false)
        }
    }

    var availablePorts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
                || $0.hasPrefix("cu.SLAB_USBtoUART") || $0.hasPrefix("cu.usbmodem")
        }.map { "/dev/" + $0 }.sorted()
    }

    func releaseForFlashing() {
        releasedPort = portPath.isEmpty ? preferredPort : portPath
        releasedPortDisappeared = false
        releasedUntil = Date().addingTimeInterval(120)
        legacyFirmwareDetected = false
        closePort()
    }

    func resumeAfterFlashing() {
        releasedUntil = nil
        releasedPortDisappeared = false
        legacyFirmwareDetected = false
        notifyChange()
    }

    // MARK: - Device operations

    func fetchInfo(completion: @escaping (Result<Data, Error>) -> Void) {
        guard isLinked else { completion(.failure(Self.disconnectedError)); return }
        sendRequest(type: .getInfo, timeout: 3, handler: { frame in
            guard frame.type == .deviceInfo else { return false }
            completion(.success(frame.payload))
            return true
        }, onTimeout: { completion(.failure(Self.timeoutError)) })
    }

    func sendCommand(_ object: [String: Any], completion: @escaping (Error?) -> Void) {
        guard isLinked else { completion(Self.disconnectedError); return }
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= USBFrame.maxPayload else {
            completion(Self.badPayloadError); return
        }
        sendAcked(type: .command, payload: data, timeout: 8, completion: completion)
    }

    func uploadGif(_ data: Data, slot: String, completion: @escaping (Error?) -> Void) {
        let resource: USBResource
        switch slot {
        case "claude": resource = .claudeGif
        case "codex": resource = .codexGif
        case "cursor": resource = .cursorGif
        default: completion(Self.badPayloadError); return
        }
        sendTransfer(resource: resource, data: data, endTimeout: 60, completion: completion)
    }

    func fetchSprite(slot: String, completion: @escaping (Result<Data, Error>) -> Void) {
        fetchSprite(slot: slot, attemptsRemaining: 2, completion: completion)
    }

    private func fetchSprite(slot: String, attemptsRemaining: Int,
                             completion: @escaping (Result<Data, Error>) -> Void) {
        guard isLinked else { completion(.failure(Self.disconnectedError)); return }
        guard incomingCompletion == nil else {
            completion(.failure(Self.busyError)); return
        }
        let resource: USBResource
        switch slot {
        case "claude": resource = .claudeSprite
        case "codex": resource = .codexSprite
        case "cursor": resource = .cursorSprite
        default: completion(.failure(Self.badPayloadError)); return
        }
        incomingResource = resource
        incomingExpected = 0
        incomingData.removeAll(keepingCapacity: true)
        incomingCompletion = { [weak self] result in
            if case .failure = result, attemptsRemaining > 1, self?.isLinked == true {
                self?.fetchSprite(slot: slot, attemptsRemaining: attemptsRemaining - 1, completion: completion)
            } else {
                completion(result)
            }
        }
        enqueue(USBFrame(type: .getResource, sequence: takeSequence(), payload: Data([resource.rawValue])))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.incomingResource == resource, let done = self.incomingCompletion else { return }
            self.clearIncoming()
            done(.failure(Self.timeoutError))
        }
    }

    // MARK: - Loop

    private func tick() {
        serviceReleaseState()
        guard releasedUntil == nil else { return }
        expirePending()
        if fd < 0 {
            scanAndOpen()
            return
        }
        readPending()
        flushWrites()

        let now = Date()
        if !isLinked {
            if !legacyProbe, now.timeIntervalSince(openedAt) > 3 {
                legacyProbe = true
                setSpeed(speed_t(B115200))
                txBuffer.append(Data("#HELLO\n".utf8))
            }
            if now.timeIntervalSince(openedAt) > 5 {
                portCooldown[portPath] = now.addingTimeInterval(3)
                closePort()
                return
            }
            if !legacyProbe, now.timeIntervalSince(lastHelloAt) >= 0.5 {
                lastHelloAt = now
                enqueue(USBFrame(type: .hello, sequence: takeSequence(),
                                 payload: Data("{\"protocol\":1,\"host\":\"macOS\"}".utf8)))
            }
            return
        }

        if now.timeIntervalSince(lastDeviceFrameAt) > 5 {
            closePort()
            return
        }
        if now.timeIntervalSince(lastHeartbeatAt) >= 1 {
            lastHeartbeatAt = now
            enqueue(USBFrame(type: .heartbeat, sequence: takeSequence(), payload: Data()))
        }
        if now.timeIntervalSince(lastStatusAt) >= 5 {
            lastStatusAt = now
            enqueue(USBFrame(type: .status, sequence: takeSequence(), payload: service.snapshot().jsonData()))
        }
        if now.timeIntervalSince(lastClockAt) >= 1 {
            lastClockAt = now
            enqueue(USBFrame(type: .clock, sequence: takeSequence(),
                             payload: ClockSnapshot.current().jsonData()))
        }
    }

    private func serviceReleaseState() {
        guard let deadline = releasedUntil else { return }
        let exists = !releasedPort.isEmpty && FileManager.default.fileExists(atPath: releasedPort)
        if !exists { releasedPortDisappeared = true }
        if Date() >= deadline || (releasedPortDisappeared && exists) {
            resumeAfterFlashing()
        }
    }

    // MARK: - Request and transfer helpers

    @discardableResult
    private func sendRequest(type: USBMessage, payload: Data = Data(), timeout: TimeInterval,
                             handler: @escaping (USBFrame) -> Bool,
                             onTimeout: @escaping () -> Void) -> UInt16 {
        let sequence = takeSequence()
        pending[sequence] = Pending(deadline: Date().addingTimeInterval(timeout),
                                    handle: handler, timeout: onTimeout)
        enqueue(USBFrame(type: type, sequence: sequence, payload: payload))
        return sequence
    }

    private func sendAcked(type: USBMessage, payload: Data, timeout: TimeInterval,
                           completion: @escaping (Error?) -> Void) {
        sendAckedAttempt(type: type, payload: payload, timeout: timeout,
                         attemptsRemaining: 3, completion: completion)
    }

    private func sendAckedAttempt(type: USBMessage, payload: Data, timeout: TimeInterval,
                                  attemptsRemaining: Int, completion: @escaping (Error?) -> Void) {
        sendRequest(type: type, payload: payload, timeout: timeout, handler: { frame in
            guard frame.type == .ack, frame.payload.count >= 3 else { return false }
            completion(frame.payload[2] == 0 ? nil : Self.deviceError)
            return true
        }, onTimeout: { [weak self] in
            guard let self, attemptsRemaining > 1, self.isLinked else {
                completion(Self.timeoutError)
                return
            }
            self.sendAckedAttempt(type: type, payload: payload, timeout: timeout,
                                  attemptsRemaining: attemptsRemaining - 1, completion: completion)
        })
    }

    private func sendTransfer(resource: USBResource, data: Data, endTimeout: TimeInterval,
                              completion: @escaping (Error?) -> Void) {
        guard isLinked else { completion(Self.disconnectedError); return }
        guard !outgoingTransferBusy else { completion(Self.busyError); return }
        outgoingTransferBusy = true
        var begin = Data([resource.rawValue])
        begin.appendLE(UInt32(data.count))
        sendAcked(type: .resourceBegin, payload: begin, timeout: 8) { [weak self] error in
            guard let self else { return }
            if let error { self.outgoingTransferBusy = false; completion(error); return }
            self.sendTransferChunk(resource: resource, data: data, offset: 0,
                                   endTimeout: endTimeout, completion: completion)
        }
    }

    private func sendTransferChunk(resource: USBResource, data: Data, offset: Int,
                                   endTimeout: TimeInterval, completion: @escaping (Error?) -> Void) {
        if offset >= data.count {
            sendAcked(type: .resourceEnd, payload: Data([resource.rawValue]), timeout: endTimeout) { [weak self] error in
                self?.outgoingTransferBusy = false
                completion(error)
            }
            return
        }
        let count = min(USBFrame.maxPayload - 5, data.count - offset)
        var payload = Data([resource.rawValue])
        payload.appendLE(UInt32(offset))
        payload.append(data[offset..<(offset + count)])
        sendAcked(type: .resourceChunk, payload: payload, timeout: 8) { [weak self] error in
            guard let self else { return }
            if let error { self.outgoingTransferBusy = false; completion(error); return }
            self.sendTransferChunk(resource: resource, data: data, offset: offset + count,
                                   endTimeout: endTimeout, completion: completion)
        }
    }

    private func expirePending() {
        let now = Date()
        let expired = pending.filter { $0.value.deadline <= now }.map(\.key)
        for sequence in expired {
            guard let item = pending.removeValue(forKey: sequence) else { continue }
            item.timeout()
        }
    }

    // MARK: - Port lifecycle

    private func scanAndOpen() {
        let candidates = preferredPort.isEmpty ? availablePorts : [preferredPort]
        let now = Date()
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let until = portCooldown[path], until > now { continue }
            if openPort(path) { return }
            portCooldown[path] = now.addingTimeInterval(3)
        }
    }

    private func openPort(_ path: String) -> Bool {
        let handle = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { return false }
        _ = ioctl(handle, TIOCEXCL)
        fd = handle
        setSpeed(speed_t(460800))
        var bits = Int32(TIOCM_DTR | TIOCM_RTS)
        _ = ioctl(handle, TIOCMBIC, &bits)
        portPath = path
        openedAt = Date()
        lastHelloAt = .distantPast
        legacyProbe = false
        legacyFirmwareDetected = false
        rxBuffer.removeAll(keepingCapacity: true)
        txBuffer.removeAll(keepingCapacity: true)
        FileHandle.standardError.write(Data("[usb] probing \(path) at 460800\n".utf8))
        notifyChange()
        return true
    }

    private func setSpeed(_ speed: speed_t) {
        guard fd >= 0 else { return }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { return }
        cfmakeraw(&options)
        // Darwin's termios table stops below 460800. Set a legal placeholder,
        // then use IOSSIOSPEED (_IOW('T', 2, speed_t)) for the CH340 rate.
        cfsetspeed(&options, speed == 460800 ? speed_t(B9600) : speed)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(HUPCL)
        tcsetattr(fd, TCSANOW, &options)
        if speed == 460800 {
            var customSpeed = speed
            _ = ioctl(fd, UInt(0x8008_5402), &customSpeed)
        }
    }

    private func closePort(notify: Bool = true) {
        if fd >= 0 { close(fd) }
        fd = -1
        let wasLinked = isLinked
        isLinked = false
        portPath = ""
        rxBuffer.removeAll(keepingCapacity: true)
        txBuffer.removeAll(keepingCapacity: true)
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0.timeout() }
        if let done = incomingCompletion {
            clearIncoming()
            done(.failure(Self.disconnectedError))
        }
        outgoingTransferBusy = false
        if wasLinked { FileHandle.standardError.write(Data("[usb] disconnected\n".utf8)) }
        if notify { notifyChange() }
    }

    // MARK: - I/O and frame handling

    private func enqueue(_ frame: USBFrame) {
        txBuffer.append(frame.encoded())
        flushWrites()
    }

    private func flushWrites() {
        guard fd >= 0, !txBuffer.isEmpty else { return }
        let written = txBuffer.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, txBuffer.count)
        }
        if written > 0 {
            txBuffer.removeFirst(written)
        } else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
            closePort()
        }
    }

    private func readPending() {
        guard fd >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                rxBuffer.append(contentsOf: bytes[0..<count])
                if legacyProbe, rxBuffer.range(of: Data("#DEVICE".utf8)) != nil {
                    legacyFirmwareDetected = true
                    releasedUntil = .distantFuture
                    FileHandle.standardError.write(Data("[usb] legacy firmware detected on \(portPath)\n".utf8))
                    closePort()
                    return
                }
                if rxBuffer.count > 128 * 1024 { rxBuffer.removeFirst(rxBuffer.count - 4096) }
                continue
            }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                closePort()
            }
            break
        }
        guard !legacyProbe else { return }
        while let frame = USBFrame.decode(from: &rxBuffer) { handle(frame) }
    }

    private func handle(_ frame: USBFrame) {
        lastDeviceFrameAt = Date()
        if frame.type == .helloAck {
            if !isLinked {
                isLinked = true
                lastStatusAt = .distantPast
                lastClockAt = .distantPast
                FileHandle.standardError.write(Data("[usb] linked \(portPath)\n".utf8))
                notifyChange()
            }
            return
        }
        if frame.type == .heartbeatAck { return }
        if frame.type == .ack, frame.payload.count >= 2 {
            let sequence = UInt16(frame.payload[0]) | (UInt16(frame.payload[1]) << 8)
            if let item = pending[sequence], item.handle(frame) { pending.removeValue(forKey: sequence) }
            return
        }
        if let item = pending[frame.sequence], item.handle(frame) {
            pending.removeValue(forKey: frame.sequence)
            return
        }
        switch frame.type {
        case .resourceBegin: handleResourceBegin(frame.payload)
        case .resourceChunk: handleResourceChunk(frame.payload)
        case .resourceEnd: handleResourceEnd(frame.payload)
        default: break
        }
    }

    private func handleResourceBegin(_ payload: Data) {
        guard payload.count >= 5, let resource = USBResource(rawValue: payload[0]),
              resource == incomingResource, let total = payload.uint32LE(at: 1) else { return }
        incomingExpected = Int(total)
        incomingData.removeAll(keepingCapacity: true)
        incomingData.reserveCapacity(incomingExpected)
    }

    private func handleResourceChunk(_ payload: Data) {
        guard payload.count >= 5, USBResource(rawValue: payload[0]) == incomingResource,
              let offset = payload.uint32LE(at: 1), Int(offset) == incomingData.count else { return }
        incomingData.append(payload.dropFirst(5))
    }

    private func handleResourceEnd(_ payload: Data) {
        guard let resource = incomingResource, payload.first == resource.rawValue,
              let done = incomingCompletion else { return }
        let data = incomingData
        let valid = data.count == incomingExpected && data.count > 1
        clearIncoming()
        done(valid ? .success(data) : .failure(Self.badPayloadError))
    }

    private func clearIncoming() {
        incomingResource = nil
        incomingExpected = 0
        incomingData.removeAll(keepingCapacity: true)
        incomingCompletion = nil
    }

    private func takeSequence() -> UInt16 {
        let value = nextSequence
        nextSequence &+= 1
        if nextSequence == 0 { nextSequence = 1 }
        return value
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static let disconnectedError = NSError(domain: "USBLink", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "USB 设备未连接"])
    private static let timeoutError = NSError(domain: "USBLink", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "USB 设备响应超时"])
    private static let badPayloadError = NSError(domain: "USBLink", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "USB 数据格式错误"])
    private static let deviceError = NSError(domain: "USBLink", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "设备拒绝了 USB 请求"])
    private static let busyError = NSError(domain: "USBLink", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "USB 正在传输其他资源，请稍后重试"])
}
