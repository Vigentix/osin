/// Where Smart Scan is in its scan → report → clean → result flow, and which actions each step allows.
///
/// Kept in the core so the rules are tested: nothing may start a scan, a second clean or a report view
/// while a clean is running, because that would replace its outcome (and its Undo).
public enum ScanPhase: Sendable, Equatable {
    case idle
    case scanning
    case report
    case cleaning
    case done

    /// A scan or a clean is running.
    public var isBusy: Bool {
        self == .scanning || self == .cleaning
    }

    /// A user-started scan may (re)start, except during a clean.
    public var canStartScan: Bool {
        self != .cleaning
    }

    /// A quiet background scan only runs when nothing is on screen that it would change.
    public var canStartBackgroundScan: Bool {
        self == .idle || self == .done
    }

    /// The one-click "clean safe items" action, from Overview or the menu bar.
    public var canCleanSafeNow: Bool {
        !isBusy
    }

    /// Going back to the report (from the result screen or the Overview).
    public var canShowReport: Bool {
        !isBusy
    }

    /// Cancel only stops a scan; a clean always finishes so its outcome and Undo are kept.
    public var canCancel: Bool {
        self == .scanning
    }
}
