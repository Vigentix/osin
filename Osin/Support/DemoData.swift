#if DEBUG
    import Foundation
    import OsinCore

    /// Debug-only fixed data for README screenshots (`Osin --render-snapshots <dir> --demo`).
    ///
    /// Live snapshots show the real machine: running apps, project folders, cache names. Demo data uses
    /// Apple's own apps and generic folder names, so screenshots never leak anything personal. Hardware
    /// figures (core count, memory) follow this Mac so views that read the topology stay consistent.
    enum DemoData {
        static let isActive = CommandLine.arguments.contains("--demo")

        private static let gigabyte: UInt64 = 1_000_000_000
        private static let now = Date()

        // MARK: Snapshot

        static func snapshot() -> SystemSnapshot {
            let physical = ProcessInfo.processInfo.physicalMemory
            let pageSize: UInt64 = 16384
            let pages = VMPageCounts(
                free: 0, active: 0, inactive: 0, speculative: 0,
                wired: physical / 8 / pageSize,
                compressed: physical / 14 / pageSize,
                internalPages: physical * 9 / 20 / pageSize,
                purgeable: 0,
                external: physical / 6 / pageSize
            )
            let memory = MemoryStats(
                pages: pages, pageSize: pageSize, physicalBytes: physical,
                swapUsedBytes: 640_000_000, swapTotalBytes: 2 * gigabyte, pressure: .normal
            )
            let disk = DiskSnapshot(
                totalBytes: 494_380_000_000, availableBytes: 47_200_000_000,
                readBytesPerSecond: 18_400_000, writeBytesPerSecond: 3_200_000
            )
            let battery = BatterySnapshot(chargeFraction: 0.76, isCharging: false, isOnACPower: false, health: 0.91, cycleCount: 143)
            let perCore = coreLoads()
            let topology = CoreTopology(
                logicalCPUs: perCore.count,
                performanceCPUs: perCore.count / 2,
                efficiencyCPUs: perCore.count - perCore.count / 2
            )
            let cpu = CPUSnapshot(
                total: perCore.reduce(0, +) / Double(max(perCore.count, 1)),
                perCore: perCore,
                performance: topology?.averagePerformance(perCore),
                efficiency: topology?.averageEfficiency(perCore),
                loadAverage: 2.41
            )
            let health = HealthScore.evaluate(HealthInputs(
                diskFreeFraction: Double(disk.availableBytes) / Double(disk.totalBytes),
                memoryPressure: memory.pressure,
                swapUsedBytes: memory.swapUsedBytes,
                physicalMemoryBytes: physical,
                sustainedCPU: cpu.total,
                thermal: .nominal,
                batteryHealth: battery.health
            ))
            let groups = processes()
            return SystemSnapshot(
                date: now,
                cpu: cpu,
                memory: memory,
                disk: disk,
                battery: battery,
                network: NetworkSnapshot(receiveBytesPerSecond: 1_240_000, sendBytesPerSecond: 186_000),
                thermal: .nominal,
                processes: groups,
                topByMemory: Array(groups.prefix(5)),
                topByCPU: Array(groups.sorted { $0.cpuFraction > $1.cpuFraction }.prefix(5)),
                health: health
            )
        }

        /// Efficiency cores (numbered first) lightly loaded, performance cores busier.
        private static func coreLoads() -> [Double] {
            let count = max(ProcessInfo.processInfo.processorCount, 2)
            let efficiency = count - count / 2
            return (0 ..< count).map { index in
                let wave = (sin(Double(index) * 1.7) + 1) / 2
                return index < efficiency ? 0.12 + wave * 0.18 : 0.22 + wave * 0.38
            }
        }

        private static func app(_ name: String, _ path: String, _ megabytes: Double, cpu: Double, helpers: [String] = []) -> ProcessGroup {
            let bytes = UInt64(megabytes * 1_000_000)
            let pid = Int32(400 + name.utf8.reduce(0) { ($0 * 31 + Int($1)) % 9000 })
            var members = [ProcessRecord(
                pid: pid, name: name, executablePath: "\(path)/Contents/MacOS/\(name)",
                footprintBytes: bytes * 3 / 5, cpuFraction: cpu * 0.6
            )]
            let weights = helpers.indices.map { 1 / Double($0 + 1) }
            let total = weights.reduce(0, +)
            for (offset, helper) in helpers.enumerated() {
                let share = UInt64(Double(bytes) * 0.4 * weights[offset] / total)
                members.append(ProcessRecord(
                    pid: pid + Int32(offset + 1), name: helper, executablePath: nil,
                    footprintBytes: share, cpuFraction: cpu * 0.4 * weights[offset] / total
                ))
            }
            return ProcessGroup(
                id: path, name: name, bundlePath: path, pids: members.map(\.pid),
                footprintBytes: bytes, cpuFraction: cpu, members: members
            )
        }

        private static func process(_ name: String, pid: Int32, _ megabytes: Double, cpu: Double) -> ProcessGroup {
            let bytes = UInt64(megabytes * 1_000_000)
            return ProcessGroup(
                id: "pid:\(pid)", name: name, bundlePath: nil, pids: [pid], footprintBytes: bytes, cpuFraction: cpu,
                members: [ProcessRecord(pid: pid, name: name, executablePath: nil, footprintBytes: bytes, cpuFraction: cpu)]
            )
        }

        static func processes() -> [ProcessGroup] {
            [
                app(
                    "Xcode",
                    "/Applications/Xcode.app",
                    4820,
                    cpu: 0.46,
                    helpers: ["SourceKitService", "XCBBuildService", "swift-frontend"]
                ),
                app("Safari", "/Applications/Safari.app", 2910, cpu: 0.18, helpers: ["Safari Web Content", "Safari Networking"]),
                app("Photos", "/System/Applications/Photos.app", 1240, cpu: 0.07, helpers: ["photoanalysisd"]),
                app("Music", "/System/Applications/Music.app", 612, cpu: 0.04),
                process("WindowServer", pid: 159, 588, cpu: 0.21),
                app("Mail", "/System/Applications/Mail.app", 431, cpu: 0.02, helpers: ["com.apple.WebKit.WebContent"]),
                app("Messages", "/System/Applications/Messages.app", 264, cpu: 0.01),
                process("mds_stores", pid: 412, 218, cpu: 0.09),
                app("Notes", "/System/Applications/Notes.app", 183, cpu: 0.01),
                app("Preview", "/System/Applications/Preview.app", 142, cpu: 0),
                app("Terminal", "/System/Applications/Utilities/Terminal.app", 121, cpu: 0.03),
                app("Calendar", "/System/Applications/Calendar.app", 96, cpu: 0),
                app("Maps", "/System/Applications/Maps.app", 84, cpu: 0)
            ]
        }

        // MARK: Short histories (sparklines)

        static func series(count: Int, base: Double, swing: Double, phase: Double = 0) -> [Double] {
            (0 ..< count).map { index in
                let x = Double(index) / 6 + phase
                return max(0, base + swing * (sin(x) * 0.5 + sin(x * 2.3 + 1) * 0.3 + noise(Double(index) * 0.7 + phase * 10) * 0.4))
            }
        }

        // MARK: Long history (charts)

        static func historyPoints(since: Date, bucket: Int) -> [HistoryPoint] {
            let step = TimeInterval(bucket)
            var points: [HistoryPoint] = []
            var date = since
            while date <= now {
                let hours = date.timeIntervalSince1970 / 3600
                let daytime = (sin((hours.truncatingRemainder(dividingBy: 24) - 9) / 24 * 2 * .pi) + 1) / 2
                let jitter = (sin(hours * 7.1) + sin(hours * 3.3 + 2)) / 4 + noise(hours * 120) * 0.35
                let cpu = min(0.95, max(0.03, 0.08 + daytime * 0.32 + jitter * 0.12))
                let memory = min(0.9, 0.55 + daytime * 0.18 + jitter * 0.05)
                let freeFraction = 0.094 + 0.008 * (sin(hours / 30) + 1)
                let charge = 0.35 + 0.6 * ((sin(hours / 5) + 1) / 2) + noise(hours * 40) * 0.01
                points.append(HistoryPoint(
                    date: date,
                    cpu: cpu,
                    memoryUsed: memory,
                    pressure: .normal,
                    diskFree: freeFraction,
                    networkReceive: max(0, 900_000 * daytime + 400_000 * jitter),
                    networkSend: max(0, 160_000 * daytime + 60000 * jitter),
                    batteryCharge: charge,
                    score: Int(86 + 4 * jitter - 3 * daytime),
                    diskRead: max(0, 12_000_000 * daytime + 6_000_000 * jitter),
                    diskWrite: max(0, 3_000_000 * daytime + 1_500_000 * jitter)
                ))
                date += step
            }
            return points
        }

        /// Deterministic value noise in -1...1, smooth between integer steps.
        private static func noise(_ x: Double) -> Double {
            func hash(_ seed: Double) -> Double {
                let value = sin(seed * 12.9898) * 43758.5453
                return (value - value.rounded(.down)) * 2 - 1
            }
            let base = x.rounded(.down)
            let fraction = x - base
            let smooth = fraction * fraction * (3 - 2 * fraction)
            return hash(base) * (1 - smooth) + hash(base + 1) * smooth
        }

        // MARK: Storage

        static func storage(reclaimable: UInt64) -> StorageBreakdown {
            let total: UInt64 = 494_380_000_000
            let free: UInt64 = 47_200_000_000
            let apps: UInt64 = 41_200_000_000
            let developer: UInt64 = 68_900_000_000
            let caches: UInt64 = 9_300_000_000
            return StorageBreakdown(
                apps: apps, developer: developer, caches: caches, reclaimable: reclaimable,
                other: total - free - apps - developer - caches, free: free, total: total,
                measuredAt: now.addingTimeInterval(-3 * 3600)
            )
        }

        // MARK: Smart Scan

        /// Rule results with generic folder names under the real home folder (shown as `~`).
        static func scanResults() -> [RuleScanResult] {
            let rules = ((try? CleanupRule.bundled()) ?? []).reduce(into: [String: CleanupRule]()) { $0[$1.id] = $1 }
            let home = FileManager.default.homeDirectoryForCurrentUser
            func items(_ entries: [(String, Double)], daysOld: Double = 9) -> [ScanItem] {
                entries.enumerated().map { index, entry in
                    ScanItem(
                        url: home.appendingPathComponent(entry.0),
                        bytes: UInt64(entry.1 * 1_000_000),
                        modified: now.addingTimeInterval(-(daysOld + Double(index) * 3) * 86400)
                    )
                }
            }
            let plan: [(String, [ScanItem])] = [
                ("xcode.derived-data", items([
                    ("Library/Developer/Xcode/DerivedData/Weather-bdqlmhvxzaefkr", 2840),
                    ("Library/Developer/Xcode/DerivedData/Recipes-gqpwnzaxtdlhsk", 1960),
                    ("Library/Developer/Xcode/DerivedData/Pomodoro-cxuyhfqkzbtvem", 1120),
                    ("Library/Developer/Xcode/DerivedData/ModuleCache.noindex", 412)
                ])),
                ("xcode.device-support", items([
                    ("Library/Developer/Xcode/iOS DeviceSupport/iPhone16,2 18.4 (22E240)", 1680),
                    ("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,3 17.6.1 (21G93)", 1410)
                ], daysOld: 120)),
                ("user.caches", items([
                    ("Library/Caches/Homebrew", 1240),
                    ("Library/Caches/org.swift.swiftpm", 682),
                    ("Library/Caches/ms-playwright", 455),
                    ("Library/Caches/pip", 318),
                    ("Library/Caches/go-build", 207),
                    ("Library/Caches/node-gyp", 96),
                    ("Library/Caches/Yarn", 74)
                ], daysOld: 2)),
                ("user.logs", items([
                    ("Library/Logs/DiagnosticReports", 96),
                    ("Library/Logs/CoreSimulator", 61)
                ])),
                ("dev.package-caches", items([
                    (".npm/_cacache", 1130),
                    (".gradle/caches", 742)
                ], daysOld: 4)),
                ("dev.node-modules", items([
                    ("Developer/weather-web/node_modules", 1260),
                    ("Developer/portfolio/node_modules", 840),
                    ("Developer/old-prototype/node_modules", 615)
                ], daysOld: 95)),
                ("downloads.installers", items([
                    ("Downloads/Xcode_26.1.xip", 3020),
                    ("Downloads/Blender-4.5-macos-arm64.dmg", 412)
                ], daysOld: 40))
            ]
            return plan.compactMap { id, items in
                rules[id].map { RuleScanResult(rule: $0, items: items, needsAccess: false) }
            }
        }

        /// Eight weeks of reports, the newest being the week that just ended.
        static func weeklySummaries() -> [WeeklySummary] {
            let thisWeek = UsageTracker.weekStart(containing: now)
            let scores = [71, 74, 69, 77, 80, 76, 79, 84]
            return scores.enumerated().map { index, score in
                let weeksAgo = scores.count - index
                let start = Calendar.current.date(byAdding: .day, value: -7 * weeksAgo, to: thisWeek) ?? thisWeek
                let latest = weeksAgo == 1
                return WeeklySummary(
                    weekStart: start, averageScore: score,
                    freedBytes: latest ? 3_420_000_000 : UInt64(800_000_000 + index * 150_000_000),
                    pressureMinutes: latest ? 75 : 30 + index * 5, lowDiskDays: latest ? 0 : index % 3,
                    hotMinutes: latest ? 20 : 5, keepAwakeHours: latest ? 6.5 : 2, choreRuns: latest ? 1 : 0,
                    topApps: latest ? [
                        UsageTracker.AppShare(name: "Xcode", bundlePath: "/Applications/Xcode.app", cpuHours: 7.4),
                        UsageTracker.AppShare(name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", cpuHours: 3.1),
                        UsageTracker.AppShare(name: "Figma", bundlePath: "/Applications/Figma.app", cpuHours: 1.8),
                        UsageTracker.AppShare(name: "Slack", bundlePath: "/Applications/Slack.app", cpuHours: 0.9)
                    ] : []
                )
            }
        }

        static let simulators = (count: 6, bytes: UInt64(4_310_000_000))
        static let trashBytes: UInt64 = 872_000_000
    }
#endif
