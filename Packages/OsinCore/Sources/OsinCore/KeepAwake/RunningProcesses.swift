import Darwin
import Foundation

/// A process the user can pick for "keep awake until it finishes".
public struct RunningProcess: Sendable, Identifiable, Equatable {
    public var id: Int32 {
        pid
    }

    public let pid: Int32
    /// Short, recognisable name: the app's name, or the command (plus the script for interpreters).
    public let name: String
    /// The full command line, or the name when arguments cannot be read.
    public let commandLine: String
    public let startTime: Date
    /// The `.app` bundle, set only for an app's own executable (helpers and bundled tools are commands).
    public let bundlePath: String?
    public let executablePath: String?
    /// Total CPU time used so far; two readings give a CPU share.
    public let cpuNanoseconds: UInt64
    /// Started from a terminal (has a controlling tty): the commands people usually wait for.
    public let hasTerminal: Bool
    /// An interactive shell with nothing else to run (`zsh`, `-zsh`, `bash`…), not worth offering.
    public var isIdleShell: Bool {
        !isApp && RunningProcesses.shells.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
    }

    public var isApp: Bool {
        bundlePath != nil
    }

    /// The app's own executable (`Foo.app/Contents/MacOS/…`); helpers and bundled tools have no bundle.
    public var isMainAppProcess: Bool {
        bundlePath != nil
    }

    public var watched: WatchedProcess {
        WatchedProcess(pid: pid, name: name, startTime: startTime)
    }
}

/// Lists the user's processes and tells when a watched one has ended. Uses `sysctl` and libproc,
/// which need no permission for the user's own processes.
public enum RunningProcesses {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen"]

    private static let interpreters: Set<String> = [
        "python", "python3", "node", "ruby", "perl", "bash", "sh", "zsh", "fish", "deno", "bun", "php", "java", "swift"
    ]

    /// The current user's processes, apps first, excluding Osin itself.
    public static func list() -> [RunningProcess] {
        let currentUser = getuid()
        let ownPID = getpid()
        return ProcessReader.readAll().compactMap { raw -> RunningProcess? in
            guard raw.pid > 1, raw.pid != ownPID, let info = kinfo(raw.pid), info.kp_eproc.e_ucred.cr_uid == currentUser else { return nil }
            let arguments = arguments(of: raw.pid) ?? []
            let bundle = mainAppBundle(forExecutable: raw.executablePath)
            let name = displayName(bundlePath: bundle, executablePath: raw.executablePath, arguments: arguments, fallback: raw.name)
            let commandLine = arguments.isEmpty ? name : arguments.map(shortened).joined(separator: " ")
            return RunningProcess(
                pid: raw.pid, name: name, commandLine: commandLine, startTime: startTime(info),
                bundlePath: bundle, executablePath: raw.executablePath, cpuNanoseconds: raw.cpuNanoseconds,
                hasTerminal: info.kp_eproc.e_tdev != -1
            )
        }
    }

    /// The identity to watch for `pid`, or `nil` when no such process exists.
    public static func watched(pid: Int32) -> WatchedProcess? {
        guard let info = kinfo(pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            ? String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            : nil
        let fallback = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "pid \(pid)"
        }
        let name = displayName(
            bundlePath: mainAppBundle(forExecutable: path),
            executablePath: path,
            arguments: arguments(of: pid) ?? [],
            fallback: fallback
        )
        return WatchedProcess(pid: pid, name: name, startTime: startTime(info))
    }

    /// True while the exact process (same PID and start time) is still running.
    public static func isAlive(_ process: WatchedProcess) -> Bool {
        guard let info = kinfo(process.pid), info.kp_proc.p_stat != SZOMB else { return false }
        return abs(startTime(info).timeIntervalSince(process.startTime)) < 0.001
    }

    /// Returns once the process has ended (or is cancelled). Checks once a second.
    public static func waitForExit(of process: WatchedProcess) async {
        while !Task.isCancelled, isAlive(process) {
            try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
        }
    }

    // MARK: - Helpers

    /// The `.app` bundle when `path` is the app's own executable (`Foo.app/Contents/MacOS/…`), not a
    /// helper or a command-line tool shipped inside it (like `xcodebuild` inside Xcode).
    static func mainAppBundle(forExecutable path: String?) -> String? {
        guard let bundle = ProcessGrouping.appBundlePath(forExecutable: path), let path,
              path.hasPrefix(bundle + "/Contents/MacOS/")
        else { return nil }
        return bundle
    }

    /// A short, safe name: the app name, the command, or "interpreter script". Inline code passed with
    /// `-c`/`-e` is never used, since it can hold secrets and the name appears in notifications.
    static func displayName(bundlePath: String?, executablePath: String?, arguments: [String], fallback: String) -> String {
        if let bundlePath {
            return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        }
        let command = (arguments.first ?? executablePath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallback
        let base = command.isEmpty ? fallback : command
        let interpreter = base.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
        guard interpreters.contains(interpreter) || interpreters.contains(base) else { return base }
        var remaining = arguments.dropFirst().makeIterator()
        while let argument = remaining.next() {
            if inlineCodeFlags.contains(argument) || isShortFlagCluster(withInlineCode: argument) {
                return base
            }
            if argument == "-m", let module = remaining.next() {
                return "\(base) -m \(module)"
            }
            if !argument.hasPrefix("-") {
                return "\(base) \(URL(fileURLWithPath: argument).lastPathComponent)"
            }
        }
        return base
    }

    private static let inlineCodeFlags: Set<String> = ["-c", "-e", "-E", "--eval", "-p", "--print", "-r"]

    /// `-lc`, `-ec`, `-uc`, `-ne`: combined short flags where one of them takes inline code.
    private static func isShortFlagCluster(withInlineCode argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 else { return false }
        return argument.dropFirst().contains { "ceE".contains($0) }
    }

    private static func shortened(_ argument: String) -> String {
        argument.hasPrefix("/") ? URL(fileURLWithPath: argument).lastPathComponent : argument
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    private static func startTime(_ info: kinfo_proc) -> Date {
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// `argv` from `KERN_PROCARGS2` (the user's own processes only).
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 {
                index += 1
            }
            arguments.append(String(bytes: buffer[start ..< index], encoding: .utf8) ?? "")
            index += 1
        }
        return arguments
    }
}
