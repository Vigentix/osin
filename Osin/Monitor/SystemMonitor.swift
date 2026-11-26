import Observation
import OsinCore
import SwiftUI

/// Drives sampling for the whole app and keeps short histories for sparklines.
///
/// Samples every 2 s while any Osin surface is visible and every 30 s otherwise (PRD §6.1).
@MainActor
@Observable
final class SystemMonitor {
    enum Surface: Hashable {
        case popover
        case dashboard
    }

    static let foregroundInterval: Duration = .seconds(2)
    static let backgroundInterval: Duration = .seconds(30)
    static let historyLength = 60

    private(set) var snapshot: SystemSnapshot?
    /// Health level, updated only when it changes, so the menu bar label is not redrawn every sample.
    private(set) var healthLevel: HealthLevel?
    private(set) var cpuHistory = RollingWindow<Double>(capacity: historyLength)
    private(set) var memoryHistory = RollingWindow<Double>(capacity: historyLength)
    private(set) var networkHistory = RollingWindow<Double>(capacity: historyLength)
    /// Recent memory footprint per process group, for the Activity inspector.
    private(set) var groupMemoryHistory: [String: RollingWindow<Double>] = [:]
    /// Disk usage by category, measured at most once a day (cached across launches).
    private(set) var storage: StorageBreakdown? = SystemMonitor.loadStorage()

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let history: HistoryStore? = try? HistoryStore(url: HistoryStore.defaultURL())
    @ObservationIgnored private var lastCompaction = Date.distantPast
    @ObservationIgnored private var lastPersisted: Date?
    /// A storage measurement in progress; later requests only update the reclaimable figure.
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReclaimable: UInt64?
    /// A forced re-measure (after a cleanup) asked for while another measurement was running.
    @ObservationIgnored private var pendingForce = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visibleSurfaces: Set<Surface> = []
    /// Debug-only: fixed demo data instead of sampling (README screenshots).
    @ObservationIgnored private var isDemo = false
    /// Called after every sample (used for notifications).
    @ObservationIgnored var onSnapshot: ((SystemSnapshot) -> Void)?

    var isForeground: Bool {
        !visibleSurfaces.isEmpty
    }

    func start() {
        guard loop == nil else { return }
        restartLoop()
    }

    func setVisible(_ surface: Surface, _ visible: Bool) {
        let wasForeground = isForeground
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        // Becoming visible should show fresh numbers immediately, not after a 30 s sleep.
        if !wasForeground, isForeground {
            restartLoop()
        }
    }

    /// Samples immediately and afresh (after a cleanup, for example) without waiting for the next tick.
    func refreshNow() {
        restartLoop(invalidating: true)
    }

    private func restartLoop(invalidating: Bool = false) {
        guard !isDemo else { return }
        loop?.cancel()
        loop = Task { [weak self, sampler] in
            if invalidating {
                await sampler.invalidate()
            }
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                let interval = isForeground ? Self.foregroundInterval : Self.backgroundInterval
                // Tolerance lets macOS coalesce wake-ups with other timers.
                try? await Task.sleep(for: interval, tolerance: isForeground ? .milliseconds(200) : .seconds(5))
            }
        }
    }

    private func refresh() async {
        let next = await sampler.sample()
        guard !Task.isCancelled else { return }
        snapshot = next
        if healthLevel != next.health.level {
            healthLevel = next.health.level
        }
        onSnapshot?(next)
        cpuHistory.append(next.cpu.total)
        let memory = next.memory
        memoryHistory.append(memory.physicalBytes == 0 ? 0 : Double(memory.usedBytes) / Double(memory.physicalBytes))
        networkHistory.append(next.network.receiveBytesPerSecond + next.network.sendBytesPerSecond)
        var groups: [String: RollingWindow<Double>] = [:]
        for group in next.processes.prefix(30) {
            var window = groupMemoryHistory[group.id] ?? RollingWindow<Double>(capacity: Self.historyLength)
            window.append(Double(group.footprintBytes))
            groups[group.id] = window
        }
        groupMemoryHistory = groups
        await persist(next)
    }

    // MARK: Storage

    private static let storageKey = "storageBreakdown"

    private static func loadStorage() -> StorageBreakdown? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(StorageBreakdown.self, from: data)
    }

    /// Re-measures categories when the cached value is older than a day, or always when `force` is set.
    func refreshStorage(reclaimable: UInt64, force: Bool = false) {
        #if DEBUG
            if isDemo {
                storage = DemoData.storage(reclaimable: reclaimable)
                return
            }
        #endif
        guard let disk = snapshot?.disk else { return }
        // A measurement is already walking the disk: don't start a second, overlapping one.
        if storageTask != nil {
            pendingReclaimable = reclaimable
            pendingForce = pendingForce || force
            return
        }
        if !force, let storage, Date().timeIntervalSince(storage.measuredAt) < 86400 {
            self.storage = StorageBreakdown(
                apps: storage.apps, developer: storage.developer, caches: storage.caches, reclaimable: reclaimable,
                other: storage.other, free: disk.availableBytes, total: disk.totalBytes, measuredAt: storage.measuredAt
            )
            return
        }
        storageTask = Task {
            let measured = try? await StorageBreakdown.measure(
                totalBytes: disk.totalBytes, availableBytes: disk.availableBytes, reclaimableBytes: reclaimable
            )
            // Requests that arrived meanwhile: the newest reclaimable figure, and whether a cleanup
            // finished (then measure again, with that newest figure).
            let latest = pendingReclaimable
            let rerun = pendingForce
            pendingReclaimable = nil
            pendingForce = false
            storageTask = nil
            if let measured {
                let current = latest.map {
                    StorageBreakdown(
                        apps: measured.apps, developer: measured.developer, caches: measured.caches, reclaimable: $0,
                        other: measured.other, free: measured.free, total: measured.total, measuredAt: measured.measuredAt
                    )
                } ?? measured
                storage = current
                if let data = try? JSONEncoder().encode(current) {
                    UserDefaults.standard.set(data, forKey: Self.storageKey)
                }
            }
            if rerun {
                refreshStorage(reclaimable: latest ?? reclaimable, force: true)
            }
        }
    }

    // MARK: History

    enum HistoryRange: String, CaseIterable, Identifiable {
        case hour
        case day
        case week

        var id: Self {
            self
        }

        var duration: TimeInterval {
            switch self {
            case .hour: 3600
            case .day: 86400
            case .week: 7 * 86400
            }
        }

        /// Bucket size giving roughly 120–170 points per chart.
        var bucketSeconds: Int {
            switch self {
            case .hour: 30
            case .day: 600
            case .week: 3600
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .hour: "1 hour"
            case .day: "24 hours"
            case .week: "7 days"
            }
        }
    }

    func historyPoints(_ range: HistoryRange) async -> [HistoryPoint] {
        let since = Date().addingTimeInterval(-range.duration)
        #if DEBUG
            if isDemo {
                return DemoData.historyPoints(since: since, bucket: range.bucketSeconds)
            }
        #endif
        guard let history else { return [] }
        return await (try? history.points(since: since, bucket: range.bucketSeconds)) ?? []
    }

    private func persist(_ snapshot: SystemSnapshot) async {
        guard let history else { return }
        // The first sample after launch has no interval yet (zero CPU and rates), and a sample reused
        // because it was requested too soon is already stored.
        guard let previous = lastPersisted else {
            lastPersisted = snapshot.date
            return
        }
        let seconds = snapshot.date.timeIntervalSince(previous)
        guard seconds > 0 else { return }
        lastPersisted = snapshot.date
        try? await history.record(HistoryPoint(snapshot: snapshot), seconds: min(seconds, Self.backgroundInterval / .seconds(1) * 2))
        if Date().timeIntervalSince(lastCompaction) > 600 {
            lastCompaction = Date()
            try? await history.compact()
        }
    }
}

#if DEBUG
    extension SystemMonitor {
        /// Stops sampling and shows `DemoData` instead (README screenshots).
        func loadDemo() {
            isDemo = true
            loop?.cancel()
            loop = nil
            let demo = DemoData.snapshot()
            snapshot = demo
            let count = Self.historyLength
            cpuHistory = Self.window(DemoData.series(count: count, base: demo.cpu.total, swing: 0.12))
            memoryHistory = Self.window(DemoData.series(count: count, base: 0.64, swing: 0.03, phase: 2))
            networkHistory = Self.window(DemoData.series(count: count, base: 1_100_000, swing: 700_000, phase: 4))
            var groups: [String: RollingWindow<Double>] = [:]
            for (index, group) in demo.processes.enumerated() {
                let base = Double(group.footprintBytes)
                groups[group.id] = Self.window(DemoData.series(count: count, base: base * 0.92, swing: base * 0.08, phase: Double(index)))
            }
            groupMemoryHistory = groups
        }

        private static func window(_ values: [Double]) -> RollingWindow<Double> {
            var window = RollingWindow<Double>(capacity: historyLength)
            values.forEach { window.append($0) }
            return window
        }
    }
#endif
