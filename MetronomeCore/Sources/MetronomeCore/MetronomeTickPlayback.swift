import Foundation

/// Platform-specific audio (and optional haptics). Implemented in the iOS / watchOS apps.
public protocol MetronomeTickPlayback: AnyObject {
    /// Begin continuously scheduling tick audio at the given BPM, preset, and accent pattern.
    func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern)

    /// Stop all scheduled ticks.
    func stopTicking()

    /// Change the BPM while ticking continues. No-op if not currently ticking.
    func updateBPM(_ bpm: Int)

    /// Change the tick sound while ticking continues. No-op if not currently ticking.
    func updatePreset(_ preset: TickPreset)

    /// Change accent grouping while ticking continues. No-op if not currently ticking.
    func updateEmphasis(_ emphasis: BeatEmphasisPattern)

    /// Linear output volume level (0.0 ... 1.0).
    func setVolume(_ volume: Float)
}
