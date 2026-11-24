import Foundation
import Observation
import Sparkle

/// Sparkle updates from the GitHub-hosted appcast (PRD §6.11). Disabled when the build has no
/// public EdDSA key, so local and CI builds never check for updates.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("$(") else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller?.updater.automaticallyChecksForUpdates = UserDefaults.standard.bool(forKey: Preferences.Key.automaticUpdateChecks)
    }

    var isAvailable: Bool {
        controller != nil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
