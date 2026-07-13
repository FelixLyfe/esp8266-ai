import Foundation

extension Bundle {
    /// SwiftPM finds resources beside a command-line executable, while a
    /// signed macOS app must keep them under Contents/Resources. Prefer the
    /// standard app location and retain Bundle.module for swift run/tests.
    static let appResources: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("AIClockBridge_AIClockBridge.bundle")) {
            return bundle
        }
        return .module
    }()
}
