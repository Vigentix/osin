import Foundation

/// What the Overview's "Recommended" section is built from.
public struct RecommendationContext: Sendable {
    /// Safe-tier bytes from the last scan, or `nil` when there has been no scan yet.
    public var safeReclaimableBytes: UInt64?
    public var reviewBytes: UInt64
    public var memoryPressure: MemoryPressure
    public var swapUsedBytes: UInt64
    public var physicalMemoryBytes: UInt64
    /// The regular app using the most memory, if any.
    public var heaviestApp: ProcessGroup?
    public var batteryHealth: Double?

    public init(
        safeReclaimableBytes: UInt64?,
        reviewBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        physicalMemoryBytes: UInt64,
        heaviestApp: ProcessGroup?,
        batteryHealth: Double?
    ) {
        self.safeReclaimableBytes = safeReclaimableBytes
        self.reviewBytes = reviewBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.heaviestApp = heaviestApp
        self.batteryHealth = batteryHealth
    }
}

public struct Recommendation: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case scan
        case cleanSafe(bytes: UInt64)
        case quitApp(ProcessGroup)
        case review(bytes: UInt64)
        case battery(health: Double)
    }

    public let kind: Kind

    public var id: String {
        switch kind {
        case .scan: "scan"
        case .cleanSafe: "clean"
        case let .quitApp(group): "quit-\(group.id)"
        case .review: "review"
        case .battery: "battery"
        }
    }
}

/// Picks at most three actions, most useful first.
public enum Recommendations {
    /// Reclaimable space below this is not worth headlining.
    public static let minimumCleanBytes: UInt64 = 500 * 1024 * 1024
    public static let batteryThreshold = 0.85

    public static func make(_ context: RecommendationContext) -> [Recommendation] {
        var list: [Recommendation] = []
        if let safe = context.safeReclaimableBytes {
            if safe >= minimumCleanBytes {
                list.append(Recommendation(kind: .cleanSafe(bytes: safe)))
            }
        } else {
            list.append(Recommendation(kind: .scan))
        }

        let swapRatio = context.physicalMemoryBytes == 0 ? 0 : Double(context.swapUsedBytes) / Double(context.physicalMemoryBytes)
        if let app = context.heaviestApp, context.memoryPressure >= .warning || swapRatio > 0.25 {
            list.append(Recommendation(kind: .quitApp(app)))
        }
        if context.reviewBytes >= minimumCleanBytes {
            list.append(Recommendation(kind: .review(bytes: context.reviewBytes)))
        }
        if let health = context.batteryHealth, health < batteryThreshold {
            list.append(Recommendation(kind: .battery(health: health)))
        }
        return Array(list.prefix(3))
    }
}
