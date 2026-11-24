import Darwin
import Foundation

/// Typed wrappers around `sysctlbyname`.
enum Sysctl {
    /// Reads a fixed-size value. Returns `nil` when the name does not exist on this machine.
    static func value<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    static func int32(_ name: String) -> Int32? {
        value(name, initial: Int32(0))
    }

    static func uint64(_ name: String) -> UInt64? {
        value(name, initial: UInt64(0))
    }
}

extension String {
    /// Decodes a NUL-terminated C buffer.
    init(cBuffer buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

/// Mach helpers that avoid the global `mach_task_self_`, which Swift 6 flags as shared mutable state.
enum Mach {
    static let host: mach_port_t = mach_host_self()

    static var task: mach_port_t {
        task_self_trap()
    }

    /// Multiplier from `mach_absolute_time` units to nanoseconds.
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()
}
