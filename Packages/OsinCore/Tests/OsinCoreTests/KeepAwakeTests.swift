import Foundation
import Testing
@testable import OsinCore

struct KeepAwakeSessionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ duration: KeepAwakeDuration, maxHours: Double? = nil) -> KeepAwakeSession {
        KeepAwakeSession(options: KeepAwakeOptions(duration: duration, maxHours: maxHours), startedAt: start)
    }

    @Test func deadlineFollowsTheChosenDuration() {
        #expect(session(.indefinite).deadline == nil)
        #expect(session(.minutes(90)).deadline == start.addingTimeInterval(5400))
        let morning = start.addingTimeInterval(8 * 3600)
        #expect(session(.until(morning)).deadline == morning)
    }

    @Test func maximumDurationCapsIndefiniteAndProcessSessions() {
        #expect(session(.indefinite, maxHours: 6).deadline == start.addingTimeInterval(6 * 3600))
        let watched = WatchedProcess(pid: 42, name: "rsync", startTime: start)
        #expect(session(.process(watched), maxHours: 2).deadline == start.addingTimeInterval(2 * 3600))
        // The cap never extends a shorter timer.
        #expect(session(.minutes(30), maxHours: 6).deadline == start.addingTimeInterval(1800))
    }

    @Test func remainingTimeCountsDown() {
        let timed = session(.minutes(60))
        #expect(timed.remaining(at: start.addingTimeInterval(600), elapsed: 600) == 3000)
        #expect(timed.remaining(at: start.addingTimeInterval(4000), elapsed: 4000) == 0)
        #expect(session(.indefinite).remaining(at: start, elapsed: 0) == nil)
    }

    @Test func reusedOptionsDropOneOffTargets() {
        let watched = WatchedProcess(pid: 42, name: "rsync", startTime: start)
        let processOptions = KeepAwakeOptions(mode: .lockScreen, duration: .process(watched))
        #expect(processOptions.forReuse(now: start).duration == .indefinite)
        #expect(processOptions.forReuse(now: start).mode == .lockScreen)
        let past = KeepAwakeOptions(duration: .until(start.addingTimeInterval(-60)))
        #expect(past.forReuse(now: start).duration == .indefinite)
        let timer = KeepAwakeOptions(duration: .minutes(120))
        #expect(timer.forReuse(now: start).duration == .minutes(120))
    }

    @Test func optionsSurviveACodableRoundTrip() throws {
        let options = KeepAwakeOptions(
            mode: .awake, keepDisplayOn: false,
            duration: .process(WatchedProcess(pid: 7, name: "python3 train.py", startTime: start)), maxHours: 4
        )
        let decoded = try JSONDecoder().decode(KeepAwakeOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }
}

struct KeepAwakeEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules = KeepAwakeRules()
    private let plugged = PowerReading(batteryFraction: 0.9, onACPower: true, thermal: .nominal)

    private func session(_ duration: KeepAwakeDuration = .indefinite, maxHours: Double? = nil) -> KeepAwakeSession {
        KeepAwakeSession(options: KeepAwakeOptions(duration: duration, maxHours: maxHours), startedAt: start)
    }

    private func reason(
        _ session: KeepAwakeSession, after seconds: TimeInterval = 60, power: PowerReading? = nil,
        processAlive: Bool = true, rules: KeepAwakeRules? = nil
    ) -> KeepAwakeStopReason? {
        KeepAwakeEvaluator.stopReason(
            for: session, at: start.addingTimeInterval(seconds), elapsed: seconds, power: power ?? plugged,
            processAlive: processAlive, rules: rules ?? self.rules
        )
    }

    @Test func keepsGoingWhileNothingCallsForAStop() {
        #expect(reason(session()) == nil)
        #expect(reason(session(.minutes(30)), after: 1799) == nil)
    }

    @Test func stopsWhenTheTimerEnds() {
        #expect(reason(session(.minutes(30)), after: 1800) == .timeUp)
        #expect(reason(session(.indefinite, maxHours: 1), after: 3600) == .reachedMaxDuration)
    }

    @Test func stopsWhenTheWatchedProcessEnds() {
        let watched = WatchedProcess(pid: 42, name: "rsync", startTime: start)
        #expect(reason(session(.process(watched)), after: 8040, processAlive: false) == .processEnded(name: "rsync"))
        #expect(reason(session(.process(watched)), processAlive: true) == nil)
    }

    @Test func stopsOnLowBatteryOnlyWhenNotCharging() {
        let low = PowerReading(batteryFraction: 0.19, onACPower: false, thermal: .nominal)
        #expect(reason(session(), power: low) == .lowBattery)
        let lowButCharging = PowerReading(batteryFraction: 0.19, onACPower: true, thermal: .nominal)
        #expect(reason(session(), power: lowButCharging) == nil)
        var off = rules
        off.stopOnLowBattery = false
        #expect(reason(session(), power: low, rules: off) == nil)
    }

    @Test func stopsWhenTheMacRunsHot() {
        let hot = PowerReading(batteryFraction: 0.9, onACPower: true, thermal: .serious)
        #expect(reason(session(), power: hot) == .tooHot)
        let warm = PowerReading(batteryFraction: 0.9, onACPower: true, thermal: .fair)
        #expect(reason(session(), power: warm) == nil)
    }

    @Test func unpluggingStopsOnlyWhenThatRuleIsOn() {
        let onBattery = PowerReading(batteryFraction: 0.8, onACPower: false, thermal: .nominal)
        #expect(reason(session(), power: onBattery) == nil)
        var strict = rules
        strict.stopWhenUnplugged = true
        #expect(reason(session(), power: onBattery, rules: strict) == .unplugged)
        // Desktop Macs have no battery: never "unplugged".
        let desktop = PowerReading(batteryFraction: nil, onACPower: true, thermal: .nominal)
        #expect(reason(session(), power: desktop, rules: strict) == nil)
    }

    @Test func aProcessThatEndedWinsOverATimerThatAlsoRanOut() {
        let watched = WatchedProcess(pid: 42, name: "make", startTime: start)
        #expect(reason(session(.process(watched), maxHours: 1), after: 7200, processAlive: false) == .processEnded(name: "make"))
    }
}

struct ScreenLockSettingTests {
    @Test func parsesSysadminctlOutput() {
        #expect(ScreenLockSetting(sysadminctlOutput: "2026-11-26 sysadminctl[1] screenLock delay is immediate") == .immediate)
        #expect(ScreenLockSetting(sysadminctlOutput: "screenLock delay is 300 seconds") == .after(seconds: 300))
        #expect(ScreenLockSetting(sysadminctlOutput: "screenLock is off") == .off)
        #expect(ScreenLockSetting(sysadminctlOutput: "something else") == .unknown)
    }
}

struct SoftwareUpdateStatusTests {
    @Test func findsAPendingMacOSUpdateAndAutomaticInstall() {
        let preferences: [String: Any] = [
            "AutomaticallyInstallMacOSUpdates": 1,
            "RecommendedUpdates": [
                ["Display Name": "Safari", "Display Version": "27.2", "Identifier": "Safari27.2"],
                ["Display Name": "macOS Tahoe 26.7.3", "Display Version": "26.7.3", "MobileSoftwareUpdate": 1]
            ]
        ]
        let status = SoftwareUpdateStatus(preferences: preferences)
        #expect(status.pendingMacOSUpdate == "macOS Tahoe 26.7.3")
        #expect(status.installsMacOSUpdatesAutomatically)
        #expect(status.mayRestartOnItsOwn)
    }

    @Test func nothingToReportWithoutAMacOSUpdate() {
        let status = SoftwareUpdateStatus(preferences: ["RecommendedUpdates": [["Display Name": "Safari"]]])
        #expect(status.pendingMacOSUpdate == nil)
        #expect(!status.mayRestartOnItsOwn)
        #expect(!SoftwareUpdateStatus(preferences: [:]).mayRestartOnItsOwn)
    }
}

@Suite(.serialized) struct ProcessWatchTests {
    private func spawnSleep(_ seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["\(seconds)"]
        try process.run()
        return process
    }

    @Test func identifiesALiveProcessAndNoticesWhenItEnds() throws {
        let child = try spawnSleep(30)
        defer {
            if child.isRunning {
                child.terminate()
            }
        }
        let watched = try #require(RunningProcesses.watched(pid: child.processIdentifier))
        #expect(watched.name == "sleep")
        #expect(RunningProcesses.isAlive(watched))
        child.terminate()
        child.waitUntilExit()
        #expect(!RunningProcesses.isAlive(watched))
    }

    @Test func aReusedProcessIDIsNotMistakenForTheWatchedProcess() throws {
        let child = try spawnSleep(30)
        defer { child.terminate() }
        let real = try #require(RunningProcesses.watched(pid: child.processIdentifier))
        let impostor = WatchedProcess(pid: real.pid, name: real.name, startTime: real.startTime.addingTimeInterval(-3600))
        #expect(!RunningProcesses.isAlive(impostor))
    }

    @Test func exitWatcherReportsTheEnd() async throws {
        let child = try spawnSleep(30)
        let watched = try #require(RunningProcesses.watched(pid: child.processIdentifier))
        let ended = Task { await RunningProcesses.waitForExit(of: watched) }
        try await Task.sleep(for: .milliseconds(200))
        child.terminate()
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ended.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result)
    }

    @Test func listsTheUsersCommandsWithTheirArguments() throws {
        let child = try spawnSleep(31)
        defer { child.terminate() }
        let listed = RunningProcesses.list()
        let entry = try #require(listed.first { $0.pid == child.processIdentifier })
        #expect(entry.commandLine.contains("sleep 31"))
        #expect(!entry.isApp)
    }
}

/// Review follow-ups: monotonic elapsed time, safe display names, commands inside app bundles.
struct KeepAwakeReviewTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let plugged = PowerReading(batteryFraction: 0.9, onACPower: true, thermal: .nominal)

    @Test func timersCountElapsedTimeNotTheWallClock() {
        let session = KeepAwakeSession(options: KeepAwakeOptions(duration: .minutes(30)), startedAt: start)
        // The wall clock jumped back an hour, but 31 minutes really passed.
        let reason = KeepAwakeEvaluator.stopReason(
            for: session, at: start.addingTimeInterval(-3600), elapsed: 31 * 60,
            power: plugged, processAlive: true, rules: KeepAwakeRules()
        )
        #expect(reason == .timeUp)
        #expect(session.remaining(at: start.addingTimeInterval(-3600), elapsed: 600) == 1200)
    }

    @Test func maximumDurationAlsoUsesElapsedTime() {
        let session = KeepAwakeSession(options: KeepAwakeOptions(duration: .indefinite, maxHours: 1), startedAt: start)
        let early = KeepAwakeEvaluator.stopReason(
            for: session, at: start.addingTimeInterval(7200), elapsed: 600, power: plugged, processAlive: true, rules: KeepAwakeRules()
        )
        #expect(early == nil) // the wall clock jumped forward; only 10 minutes passed
        let late = KeepAwakeEvaluator.stopReason(
            for: session, at: start, elapsed: 3600, power: plugged, processAlive: true, rules: KeepAwakeRules()
        )
        #expect(late == .reachedMaxDuration)
    }

    @Test func untilATimeFollowsTheWallClock() {
        let morning = start.addingTimeInterval(8 * 3600)
        let session = KeepAwakeSession(options: KeepAwakeOptions(duration: .until(morning)), startedAt: start)
        let reason = KeepAwakeEvaluator.stopReason(
            for: session, at: morning, elapsed: 60, power: plugged, processAlive: true, rules: KeepAwakeRules()
        )
        #expect(reason == .timeUp)
    }

    @Test func inlineCodeNeverBecomesTheDisplayName() {
        func name(_ arguments: [String]) -> String {
            RunningProcesses.displayName(
                bundlePath: nil,
                executablePath: "/usr/bin/\(arguments[0])",
                arguments: arguments,
                fallback: arguments[0]
            )
        }
        #expect(name(["python3", "-c", "token='secret'; run()"]) == "python3")
        #expect(name(["node", "-e", "console.log(process.env.KEY)"]) == "node")
        #expect(name(["ruby", "-e", "puts 1"]) == "ruby")
        #expect(name(["python3", "-m", "http.server"]) == "python3 -m http.server")
        #expect(name(["python3", "-u", "train.py", "--epochs", "3"]) == "python3 train.py")
        #expect(name(["/opt/homebrew/bin/python3.12", "/Users/x/proj/train.py"]) == "python3.12 train.py")
        #expect(name(["rsync", "-av", "src/", "dst/"]) == "rsync")
        // Combined short flags that include -c or -e still mean inline code.
        #expect(name(["bash", "-lc", "TOKEN=secret; sleep 60"]) == "bash")
        #expect(name(["sh", "-ec", "export KEY=1"]) == "sh")
        #expect(name(["python3", "-uc", "print(1)"]) == "python3")
        #expect(name(["perl", "-ne", "print"]) == "perl")
    }

    @Test func onlyTheAppsOwnExecutableCountsAsTheApp() {
        let xcode = "/Applications/Xcode.app"
        #expect(RunningProcesses.mainAppBundle(forExecutable: "\(xcode)/Contents/MacOS/Xcode") == xcode)
        #expect(RunningProcesses.mainAppBundle(forExecutable: "\(xcode)/Contents/Developer/usr/bin/xcodebuild") == nil)
        #expect(RunningProcesses.mainAppBundle(forExecutable: "/bin/sleep") == nil)
        let name = RunningProcesses.displayName(
            bundlePath: nil, executablePath: "\(xcode)/Contents/Developer/usr/bin/xcodebuild",
            arguments: ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "-scheme", "Osin"], fallback: "xcodebuild"
        )
        #expect(name == "xcodebuild")
    }
}
