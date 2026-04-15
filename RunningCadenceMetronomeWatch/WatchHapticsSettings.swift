import Combine
import Foundation

enum WatchHapticsMode: String, CaseIterable, Identifiable {
    case everyBeat
    case emphasizedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyBeat:
            return "Every beat"
        case .emphasizedOnly:
            return "Emphasized only"
        }
    }
}

final class WatchHapticsSettings: ObservableObject {
    private let userDefaults: UserDefaults

    @Published var hapticsEnabled: Bool {
        didSet {
            userDefaults.set(hapticsEnabled, forKey: Self.enabledKey)
        }
    }

    @Published var hapticsMode: WatchHapticsMode {
        didSet {
            userDefaults.set(hapticsMode.rawValue, forKey: Self.modeKey)
        }
    }

    private static let enabledKey = "running_cadence_watch_haptics_enabled"
    private static let modeKey = "running_cadence_watch_haptics_mode"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        hapticsEnabled = userDefaults.bool(forKey: Self.enabledKey)

        let storedMode = userDefaults.string(forKey: Self.modeKey)
        hapticsMode = storedMode.flatMap(WatchHapticsMode.init(rawValue:)) ?? .emphasizedOnly
    }
}
