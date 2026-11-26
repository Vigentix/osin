import Foundation

/// The "Require password after screen saver begins or display is turned off" setting.
public enum ScreenLockSetting: Sendable, Equatable {
    case unknown
    case off
    case immediate
    case after(seconds: Int)

    /// Parses `sysadminctl -screenLock status`, e.g. "screenLock delay is immediate",
    /// "screenLock delay is 300 seconds" or "screenLock is off".
    public init(sysadminctlOutput output: String) {
        let text = output.lowercased()
        if text.contains("screenlock is off") {
            self = .off
        } else if text.contains("immediate") {
            self = .immediate
        } else if let range = text.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            self = Int(digits).map { .after(seconds: $0) } ?? .unknown
        } else {
            self = .unknown
        }
    }
}
