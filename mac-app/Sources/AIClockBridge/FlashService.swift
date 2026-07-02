import Foundation

// One-click firmware flashing over USB, from the menu bar. Shells out to the
// repo's own PlatformIO venv (`pio run -t upload`), auto-detecting the serial
// port — the CH340's /dev/cu.usbserial-* suffix changes with the USB port it
// is plugged into, so it must never be hardcoded.
enum FlashService {
    struct FlashError: Error { let message: String }

    private(set) static var isRunning = false

    /// Where the PlatformIO project lives. Overridable via defaults key
    /// "firmware_dir" in case the repo ever moves.
    static var firmwareDir: String {
        UserDefaults.standard.string(forKey: "firmware_dir")
            ?? ("~/Documents/esp8266-ai/firmware" as NSString).expandingTildeInPath
    }

    /// CH340/CP210x-style USB serial device, if one is plugged in.
    static func findSerialPort() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let patterns = ["cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART"]
        return names
            .filter { name in patterns.contains { name.hasPrefix($0) } }
            .sorted()
            .first
            .map { "/dev/\($0)" }
    }

    /// Compiles + uploads. Completion (on main): .success(portUsed) or error
    /// with the tail of pio's output for diagnosis.
    static func flash(completion: @escaping (Result<String, FlashError>) -> Void) {
        guard !isRunning else {
            completion(.failure(FlashError(message: "已有一次刷写在进行中")))
            return
        }
        let dir = firmwareDir
        let pio = dir + "/.pio-venv/bin/pio"
        guard FileManager.default.fileExists(atPath: pio) else {
            completion(.failure(FlashError(message: "找不到 PlatformIO：\(pio)")))
            return
        }
        guard let port = findSerialPort() else {
            completion(.failure(FlashError(message: "未检测到 USB 串口。请用数据线把时钟连到 Mac 后重试。")))
            return
        }

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pio)
            proc.arguments = ["run", "-t", "upload", "--upload-port", port]
            proc.currentDirectoryURL = URL(fileURLWithPath: dir)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            var output = Data()
            let reader = pipe.fileHandleForReading
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    isRunning = false
                    completion(.failure(FlashError(message: "启动 pio 失败：\(error.localizedDescription)")))
                }
                return
            }
            // drain as we go so the pipe never fills up and stalls pio
            while proc.isRunning {
                output.append(reader.availableData)
            }
            output.append(reader.readDataToEndOfFile())
            proc.waitUntilExit()

            let text = String(decoding: output, as: UTF8.self)
            DispatchQueue.main.async {
                isRunning = false
                if proc.terminationStatus == 0, text.contains("SUCCESS") {
                    completion(.success(port))
                } else {
                    let tail = text.split(separator: "\n").suffix(12).joined(separator: "\n")
                    completion(.failure(FlashError(message: "刷写失败（exit \(proc.terminationStatus)）：\n\(tail)")))
                }
            }
        }
    }
}
