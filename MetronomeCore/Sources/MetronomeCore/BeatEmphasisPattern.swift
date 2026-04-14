import Foundation

/// Which beats in a repeating cycle are accented (first beat of each cycle is the “high” tick).
public enum BeatEmphasisPattern: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Same volume/timbre on every beat (no downbeat accent).
    case none
    /// High–low (accent every 2 beats).
    case every2
    /// High–low–low (accent every 3 beats).
    case every3
    /// High–low–low–low (accent every 4 beats).
    case every4

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "No accent"
        case .every2: return "Every 2 beats"
        case .every3: return "Every 3 beats"
        case .every4: return "Every 4 beats"
        }
    }

    /// Short label for compact controls (segment title).
    public var shortLabel: String {
        switch self {
        case .none: return "None"
        case .every2: return "2"
        case .every3: return "3"
        case .every4: return "4"
        }
    }

    /// Human-readable accent shape (first beat is the strong tick).
    public var patternDescription: String {
        switch self {
        case .none: return "All beats equal"
        case .every2: return "High, low"
        case .every3: return "High, low, low"
        case .every4: return "High, low, low, low"
        }
    }

    /// Beats per repeating accent group (beat 0 of each group is accented).
    public var beatsPerPattern: Int {
        switch self {
        case .none: return 1
        case .every2: return 2
        case .every3: return 3
        case .every4: return 4
        }
    }

    public func isAccent(forBeatIndex beatIndex: Int) -> Bool {
        switch self {
        case .none: return false
        default: return beatIndex % beatsPerPattern == 0
        }
    }
}
