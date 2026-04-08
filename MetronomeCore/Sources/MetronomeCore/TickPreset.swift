import Foundation

/// Built-in metronome click sounds (synthesized on each platform).
public enum TickPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case mechanicalTock
    case woodKnock
    case softTap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mechanicalTock: return "Mechanical tock"
        case .woodKnock: return "Wood knock"
        case .softTap: return "Soft tap"
        }
    }
}
