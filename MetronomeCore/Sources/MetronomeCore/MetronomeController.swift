import Foundation

/// Drives tempo state and delegates tick scheduling to the platform audio service.
@MainActor
public final class MetronomeController: ObservableObject {
    private static let volumeDefaultsKey = "running_cadence_volume"

    @Published public private(set) var bpm: Int
    @Published public private(set) var preset: TickPreset
    @Published public private(set) var emphasis: BeatEmphasisPattern
    @Published public private(set) var isPlaying: Bool
    /// User level `0...1` (slider); forwarded directly to playback.
    @Published public private(set) var volume: Float

    private let playback: MetronomeTickPlayback

    public init(
        bpm: Int = 180,
        preset: TickPreset = .mechanicalTock,
        emphasis: BeatEmphasisPattern = .none,
        playback: MetronomeTickPlayback
    ) {
        self.bpm = max(40, min(240, bpm))
        self.preset = preset
        self.emphasis = emphasis
        self.isPlaying = false
        let loadedVolume = Self.loadSavedVolume()
        self.volume = loadedVolume
        self.playback = playback
        playback.setVolume(loadedVolume)
    }

    public func setBPM(_ value: Int) {
        let clamped = max(40, min(240, value))
        guard clamped != bpm else { return }
        bpm = clamped
        if isPlaying {
            playback.updateBPM(clamped)
        }
        UserDefaults.standard.set(clamped, forKey: "running_cadence_bpm")
    }

    public func setVolume(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        guard clamped != volume else { return }
        volume = clamped
        playback.setVolume(clamped)
        UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
    }

    public func setPreset(_ value: TickPreset) {
        guard value != preset else { return }
        preset = value
        if isPlaying {
            playback.updatePreset(value)
        }
        UserDefaults.standard.set(value.rawValue, forKey: "running_cadence_preset")
    }

    public func setEmphasis(_ value: BeatEmphasisPattern) {
        guard value != emphasis else { return }
        emphasis = value
        if isPlaying {
            playback.updateEmphasis(value)
        }
        UserDefaults.standard.set(value.rawValue, forKey: "running_cadence_emphasis")
    }

    public func start() {
        guard !isPlaying else { return }
        isPlaying = true
        playback.startTicking(bpm: bpm, preset: preset, emphasis: emphasis)
    }

    public func stop() {
        guard isPlaying else { return }
        isPlaying = false
        playback.stopTicking()
    }

    public func toggle() {
        if isPlaying { stop() } else { start() }
    }

    private static func loadSavedVolume() -> Float {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: volumeDefaultsKey) != nil else { return 1.0 }
        let v = defaults.float(forKey: volumeDefaultsKey)
        return max(0.0, min(1.0, v))
    }
}
