import Foundation

/// Collects a `SystemSnapshot` on demand. Keeps the previous counters so rates and CPU usage
/// are computed over the interval between two calls; the first call reports zero rates.
public actor SystemSampler {
    /// How far back "sustained" CPU load looks for the health score.
    public static let sustainedCPUWindow: Duration = .seconds(300)

    private struct CPUPoint {
        let instant: ContinuousClock.Instant
        let value: Double
    }

    private let config: HealthConfig
    private let topology = CoreTopology.current()
    private let clock = ContinuousClock()
    private let topCount: Int

    private var lastInstant: ContinuousClock.Instant?
    private var lastTicks: [CPUTicks] = []
    private var lastNetwork: (received: UInt64, sent: UInt64)?
    private var lastDiskIO: (read: UInt64, written: UInt64)?
    private var lastCPUTime: [Int32: UInt64] = [:]
    private var cpuHistory = RollingWindow<CPUPoint>(capacity: 600)
    private let minimumInterval: Duration
    private var lastSnapshot: SystemSnapshot?
    private var diskCapacity: (value: (total: UInt64, available: UInt64), at: ContinuousClock.Instant)?
    private var reportedBatteryHealth: (value: Double?, at: ContinuousClock.Instant)?

    /// - Parameter minimumInterval: calls closer together than this return the previous snapshot, so
    ///   rates and per-core CPU are never computed over a few milliseconds.
    public init(config: HealthConfig = HealthConfig(), topCount: Int = 5, minimumInterval: Duration = .milliseconds(900)) {
        self.config = config
        self.topCount = topCount
        self.minimumInterval = minimumInterval
    }

    public func sample() async -> SystemSnapshot {
        if let lastSnapshot, let lastInstant, clock.now - lastInstant < minimumInterval {
            return lastSnapshot
        }
        await refreshBatteryHealthIfNeeded()
        // Another call may have sampled while this one waited for system_profiler.
        if let lastSnapshot, let lastInstant, clock.now - lastInstant < minimumInterval {
            return lastSnapshot
        }
        let snapshot = takeSample()
        lastSnapshot = snapshot
        return snapshot
    }

    /// Makes the next `sample()` measure everything afresh, e.g. right after a cleanup.
    public func invalidate() {
        lastSnapshot = nil
        diskCapacity = nil
    }

    /// Reads "Maximum Capacity" as macOS reports it, at most every 6 hours and only on Macs with a battery.
    private func refreshBatteryHealthIfNeeded() async {
        if let reportedBatteryHealth, clock.now - reportedBatteryHealth.at < .seconds(6 * 3600) {
            return
        }
        reportedBatteryHealth = (nil, clock.now) // also stops concurrent refreshes
        guard BatteryReader.read() != nil else { return }
        reportedBatteryHealth = await (BatteryHealth.systemReported(), clock.now)
    }

    private func takeSample() -> SystemSnapshot {
        let now = clock.now
        let seconds = lastInstant.map { (now - $0) / .seconds(1) } ?? 0

        let cpu = sampleCPU()
        cpuHistory.append(CPUPoint(instant: now, value: cpu.total))
        let memory = MemoryReader.read() ?? MemoryStats(
            pages: VMPageCounts(
                free: 0,
                active: 0,
                inactive: 0,
                speculative: 0,
                wired: 0,
                compressed: 0,
                internalPages: 0,
                purgeable: 0,
                external: 0
            ),
            pageSize: 0, physicalBytes: ProcessInfo.processInfo.physicalMemory, swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal
        )
        let disk = sampleDisk(seconds: seconds)
        let network = sampleNetwork(seconds: seconds)
        let battery = BatteryReader.read().map { reading in
            BatterySnapshot(
                chargeFraction: reading.chargeFraction,
                isCharging: reading.isCharging,
                isOnACPower: reading.isOnACPower,
                health: reportedBatteryHealth?.value ?? reading.health,
                cycleCount: reading.cycleCount
            )
        }
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let groups = ProcessGrouping.group(sampleProcesses(seconds: seconds))
        let byMemory = ProcessGrouping.top(groups, by: .memory, limit: groups.count)

        let health = HealthScore.evaluate(
            HealthInputs(
                diskFreeFraction: 1 - disk.usedFraction,
                memoryPressure: memory.pressure,
                swapUsedBytes: memory.swapUsedBytes,
                physicalMemoryBytes: memory.physicalBytes,
                sustainedCPU: sustainedCPU(now: now),
                thermal: thermal,
                batteryHealth: battery?.health
            ),
            config: config
        )

        lastInstant = now
        return SystemSnapshot(
            date: Date(),
            cpu: cpu,
            memory: memory,
            disk: disk,
            battery: battery,
            network: network,
            thermal: thermal,
            processes: byMemory,
            topByMemory: Array(byMemory.prefix(topCount)),
            topByCPU: ProcessGrouping.top(groups, by: .cpu, limit: topCount),
            health: health
        )
    }

    private func sampleCPU() -> CPUSnapshot {
        let ticks = CPUReader.readTicks()
        let hasPrevious = lastTicks.count == ticks.count
        let perCore = hasPrevious ? CPUUsage.perCore(previous: lastTicks, current: ticks) : Array(repeating: 0, count: ticks.count)
        let total = hasPrevious ? CPUUsage.total(previous: lastTicks, current: ticks) ?? 0 : 0
        lastTicks = ticks
        return CPUSnapshot(
            total: total,
            perCore: perCore,
            performance: topology?.averagePerformance(perCore),
            efficiency: topology?.averageEfficiency(perCore),
            loadAverage: CPUReader.loadAverage()
        )
    }

    private func sampleDisk(seconds: Double) -> DiskSnapshot {
        // "Available for important usage" costs ~10 ms per call; free space moves slowly.
        let now = clock.now
        if (diskCapacity.map { now - $0.at > .seconds(60) } ?? true), let fresh = DiskReader.capacity() {
            diskCapacity = (fresh, now)
        }
        let capacity: (total: UInt64, available: UInt64) = diskCapacity?.value ?? (0, 0)
        let counters = DiskReader.ioCounters()
        defer { lastDiskIO = counters }
        return DiskSnapshot(
            totalBytes: capacity.total,
            availableBytes: capacity.available,
            readBytesPerSecond: lastDiskIO.map { Throughput.rate(previous: $0.read, current: counters.read, seconds: seconds) } ?? 0,
            writeBytesPerSecond: lastDiskIO.map { Throughput.rate(previous: $0.written, current: counters.written, seconds: seconds) } ?? 0
        )
    }

    private func sampleNetwork(seconds: Double) -> NetworkSnapshot {
        let counters = NetworkReader.counters()
        defer { lastNetwork = counters }
        return NetworkSnapshot(
            receiveBytesPerSecond: lastNetwork
                .map { Throughput.rate(previous: $0.received, current: counters.received, seconds: seconds) } ?? 0,
            sendBytesPerSecond: lastNetwork.map { Throughput.rate(previous: $0.sent, current: counters.sent, seconds: seconds) } ?? 0
        )
    }

    private func sampleProcesses(seconds: Double) -> [ProcessRecord] {
        let raw = ProcessReader.readAll()
        let elapsedNanoseconds = seconds * 1_000_000_000
        var cpuTimes: [Int32: UInt64] = [:]
        let records = raw.map { process in
            cpuTimes[process.pid] = process.cpuNanoseconds
            var fraction = 0.0
            if elapsedNanoseconds > 0, let previous = lastCPUTime[process.pid], process.cpuNanoseconds >= previous {
                fraction = Double(process.cpuNanoseconds - previous) / elapsedNanoseconds
            }
            return ProcessRecord(
                pid: process.pid,
                name: process.name,
                executablePath: process.executablePath,
                footprintBytes: process.footprintBytes,
                cpuFraction: fraction
            )
        }
        lastCPUTime = cpuTimes
        return records
    }

    private func sustainedCPU(now: ContinuousClock.Instant) -> Double {
        let recent = cpuHistory.values.filter { now - $0.instant <= Self.sustainedCPUWindow }
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0) { $0 + $1.value } / Double(recent.count)
    }
}
