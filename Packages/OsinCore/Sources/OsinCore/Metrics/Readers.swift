import Darwin
import Foundation
import IOKit
import IOKit.ps

// Thin readers over system APIs. Each returns raw counters; `SystemSampler` turns them into rates.

enum CPUReader {
    static func readTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Mach.host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(Mach.task, vm_address_t(UInt(bitPattern: info)), size)
        }
        return (0 ..< Int(cpuCount)).map { index in
            let base = index * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}

public extension CoreTopology {
    /// P/E layout of this Mac, or `nil` on Intel and single-cluster chips.
    static func current() -> CoreTopology? {
        guard Sysctl.int32("hw.nperflevels") == 2,
              let cpus = Sysctl.int32("hw.ncpu"),
              let performance = Sysctl.int32("hw.perflevel0.logicalcpu"),
              let efficiency = Sysctl.int32("hw.perflevel1.logicalcpu")
        else { return nil }
        return CoreTopology(logicalCPUs: Int(cpus), performanceCPUs: Int(performance), efficiencyCPUs: Int(efficiency))
    }
}

enum MemoryReader {
    static func read() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Mach.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(Mach.host, &pageSize) == KERN_SUCCESS else { return nil }

        let swap = Sysctl.value("vm.swapusage", initial: xsw_usage())
        let pages = VMPageCounts(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count),
            internalPages: UInt64(stats.internal_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count)
        )
        return MemoryStats(
            pages: pages,
            pageSize: UInt64(pageSize),
            physicalBytes: Sysctl.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: swap?.xsu_used ?? 0,
            swapTotalBytes: swap?.xsu_total ?? 0,
            pressure: MemoryPressure(kernelLevel: Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1)
        )
    }
}

enum DiskReader {
    /// Capacity of the volume holding `path`. "Available" includes purgeable space, as Finder shows it.
    static func capacity(at path: String = "/") -> (total: UInt64, available: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return (UInt64(total), UInt64(max(0, min(Int64(total), available))))
    }

    /// Cumulative bytes read and written across all block storage drivers.
    static func ioCounters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (read, written)
    }
}

public enum BatteryReader {
    /// Internal battery state, or `nil` on Macs without one.
    public static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let registry = smartBatteryProperties()
            return BatterySnapshot(
                chargeFraction: min(1, max(0, Double(current) / Double(maximum))),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnACPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                health: BatteryHealth.fraction(fromRegistry: registry),
                cycleCount: registry["CycleCount"] as? Int
            )
        }
        return nil
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        let keys = ["DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity", "MaxCapacity", "CycleCount"]
        var result: [String: Any] = [:]
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                result[key] = value
            }
        }
        return result
    }
}

enum NetworkReader {
    /// Cumulative bytes received and sent on physical (`en*`) interfaces, using 64-bit counters.
    static func counters() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if interfaceName(index: info.ifm_index).hasPrefix("en") {
                        received += info.ifm_data.ifi_ibytes
                        sent += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    private static func interfaceName(index: UInt16) -> String {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return "" }
        return String(cBuffer: name)
    }
}

/// A process with cumulative CPU time. Only processes owned by the current user are readable.
struct RawProcess: Sendable {
    let pid: Int32
    let name: String
    let executablePath: String?
    let footprintBytes: UInt64
    let cpuNanoseconds: UInt64
}

enum ProcessReader {
    static func readAll() -> [RawProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { return nil }
            let ticks = Double(usage.ri_user_time + usage.ri_system_time)
            return RawProcess(
                pid: pid,
                name: name(of: pid),
                executablePath: path(of: pid),
                footprintBytes: usage.ri_phys_footprint,
                cpuNanoseconds: UInt64(ticks * Mach.nanosecondsPerTick)
            )
        }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cBuffer: buffer)
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }
}
