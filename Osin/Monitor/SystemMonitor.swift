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
    private(set) var cpuHistory = RollingWindow<Double>(capacity: historyLength)
    private(set) var memoryHistory = RollingWindow<Double>(capacity: historyLength)

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visibleSurfaces: Set<Surface> = []

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

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                let interval = isForeground ? Self.foregroundInterval : Self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refresh() async {
        let next = await sampler.sample()
        guard !Task.isCancelled else { return }
        snapshot = next
        cpuHistory.append(next.cpu.total)
        let memory = next.memory
        memoryHistory.append(memory.physicalBytes == 0 ? 0 : Double(memory.usedBytes) / Double(memory.physicalBytes))
    }
}
