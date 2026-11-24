/// System memory pressure, the primary memory health signal (see ADR 0005).
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    /// Maps `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical).
    public init(kernelLevel: Int32) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Raw page counters from `host_statistics64(HOST_VM_INFO64)`.
public struct VMPageCounts: Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var internalPages: UInt64
    public var purgeable: UInt64
    public var external: UInt64

    public init(
        free: UInt64,
        active: UInt64,
        inactive: UInt64,
        speculative: UInt64,
        wired: UInt64,
        compressed: UInt64,
        internalPages: UInt64,
        purgeable: UInt64,
        external: UInt64
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.internalPages = internalPages
        self.purgeable = purgeable
        self.external = external
    }
}

/// Memory figures computed the way Activity Monitor presents them.
public struct MemoryStats: Sendable, Equatable {
    public let physicalBytes: UInt64
    /// Anonymous memory used by apps: internal minus purgeable pages.
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    /// File-backed and purgeable pages the system can reclaim.
    public let cachedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pressure: MemoryPressure

    /// App + wired + compressed, the "Memory Used" figure.
    public var usedBytes: UInt64 {
        appBytes + wiredBytes + compressedBytes
    }

    public init(
        pages: VMPageCounts,
        pageSize: UInt64,
        physicalBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pressure: MemoryPressure
    ) {
        let appPages = pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0
        self.physicalBytes = physicalBytes
        appBytes = appPages * pageSize
        wiredBytes = pages.wired * pageSize
        compressedBytes = pages.compressed * pageSize
        cachedBytes = (pages.external + pages.purgeable) * pageSize
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }
}
