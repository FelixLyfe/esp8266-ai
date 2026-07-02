import AppKit
import ImageIO
import UniformTypeIdentifiers

// Pet animation source: petdex.dev's public manifest (3300+ open-source
// "Codex pets"). Each pet is one 1536x1872 WebP spritesheet laid out on a
// fixed 8x9 grid of 192x208 frames; each row is one named animation (the
// row/frame-count table below mirrors petdex's own pet-states definition).
// We crop a row, composite the frames onto black at the device slot size,
// encode a looping GIF, and POST it to the clock, which re-decodes it
// on-device into its own format.

struct PetdexPet {
    let slug: String
    let displayName: String
    let kind: String
    let spritesheetUrl: String
}

struct PetdexAnimState {
    let id: String
    let label: String
    let row: Int
    let frames: Int
    let durationMs: Int
}

enum PetdexService {
    static let manifestURL = URL(string: "https://assets.petdex.dev/manifests/petdex-v1.json")!

    static let frameW = 192, frameH = 208
    /// Device firmware caps custom animations at 8 frames (MAX_CUSTOM_FRAMES).
    static let maxFrames = 8

    static let states: [PetdexAnimState] = [
        .init(id: "idle", label: "待机 Idle", row: 0, frames: 6, durationMs: 1100),
        .init(id: "running-right", label: "右跑 Run Right", row: 1, frames: 8, durationMs: 1060),
        .init(id: "running-left", label: "左跑 Run Left", row: 2, frames: 8, durationMs: 1060),
        .init(id: "waving", label: "挥手 Waving", row: 3, frames: 4, durationMs: 700),
        .init(id: "jumping", label: "跳跃 Jumping", row: 4, frames: 5, durationMs: 840),
        .init(id: "failed", label: "失败 Failed", row: 5, frames: 8, durationMs: 1220),
        .init(id: "waiting", label: "等待 Waiting", row: 6, frames: 6, durationMs: 1010),
        .init(id: "running", label: "原地跑 Running", row: 7, frames: 6, durationMs: 820),
        .init(id: "review", label: "思考 Review", row: 8, frames: 6, durationMs: 1030),
    ]

    private static var cachedPets: [PetdexPet]?

    static func loadManifest(completion: @escaping (Result<[PetdexPet], Error>) -> Void) {
        if let pets = cachedPets {
            completion(.success(pets))
            return
        }
        var req = URLRequest(url: manifestURL)
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, _, error in
            var result: Result<[PetdexPet], Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = obj["pets"] as? [[String: Any]] {
                let pets = items.compactMap { item -> PetdexPet? in
                    guard let slug = item["slug"] as? String,
                          let sheet = item["spritesheetUrl"] as? String else { return nil }
                    return PetdexPet(slug: slug,
                                     displayName: item["displayName"] as? String ?? slug,
                                     kind: item["kind"] as? String ?? "",
                                     spritesheetUrl: sheet)
                }
                result = .success(pets)
            } else {
                result = .failure(NSError(domain: "Petdex", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "petdex manifest 解析失败"]))
            }
            DispatchQueue.main.async {
                if case let .success(pets) = result { cachedPets = pets }
                completion(result)
            }
        }.resume()
    }

    static func downloadSpritesheet(_ pet: PetdexPet,
                                    completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard let url = URL(string: pet.spritesheetUrl) else {
            completion(.failure(NSError(domain: "Petdex", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "spritesheet 地址无效"])))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, _, error in
            var result: Result<CGImage, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data,
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                result = .success(img)
            } else {
                result = .failure(NSError(domain: "Petdex", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "spritesheet 解码失败（WebP）"]))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Crops `state`'s row out of the sheet and encodes a looping GIF at
    /// targetW x targetH: frames aspect-fit, composited onto black (matches
    /// the clock's black background and avoids GIF transparency compositing
    /// surprises in the on-device decoder).
    static func buildGif(sheet: CGImage, state: PetdexAnimState,
                         targetW: Int, targetH: Int) -> Data? {
        let frameCount = min(state.frames, maxFrames)
        guard frameCount > 0 else { return nil }
        let delay = Double(state.durationMs) / Double(state.frames) / 1000.0

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.gif.identifier as CFString, frameCount, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(delay, 0.05)],
        ] as CFDictionary

        // aspect-fit rect inside the target slot
        let scale = min(CGFloat(targetW) / CGFloat(frameW), CGFloat(targetH) / CGFloat(frameH))
        let drawW = CGFloat(frameW) * scale, drawH = CGFloat(frameH) * scale
        let drawRect = CGRect(x: (CGFloat(targetW) - drawW) / 2,
                              y: (CGFloat(targetH) - drawH) / 2, width: drawW, height: drawH)

        for i in 0..<frameCount {
            let crop = CGRect(x: i * frameW, y: state.row * frameH, width: frameW, height: frameH)
            guard let frame = sheet.cropping(to: crop),
                  let ctx = CGContext(data: nil, width: targetW, height: targetH,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: drawRect)
            guard let out = ctx.makeImage() else { return nil }
            CGImageDestinationAddImage(dest, out, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
