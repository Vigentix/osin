import Foundation
import OsinCore

/// Locking the screen and turning the display off, without extra permissions.
enum ScreenLock {
    /// Locks the screen and turns the display off. Returns false when locking was not possible and
    /// only the display was turned off (whether that locks depends on the user's setting).
    @discardableResult
    static func lockAndTurnOffDisplay() -> Bool {
        let locked = lockNow()
        // Give the lock screen a moment, then turn the display off to save power.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(800))
            _ = try? await run("/usr/bin/pmset", ["displaysleepnow"])
        }
        return locked
    }

    /// `SACLockScreenImmediate` from the private login framework: locks at once, no permission
    /// needed (Hammerspoon uses it). Loaded at run time so a future macOS without it falls back.
    static func lockNow() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        return lock() == 0
    }

    static func readSetting() async -> ScreenLockSetting {
        guard let output = try? await run("/usr/sbin/sysadminctl", ["-screenLock", "status"], includeErrors: true) else {
            return .unknown
        }
        return ScreenLockSetting(sysadminctlOutput: output)
    }

    /// Runs a fixed system tool and returns its output (stdout, plus stderr when asked).
    private static func run(_ executable: String, _ arguments: [String], includeErrors: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = includeErrors ? pipe : FileHandle.nullDevice
            process.terminationHandler = { @Sendable _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(bytes: data, encoding: .utf8) ?? "")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
