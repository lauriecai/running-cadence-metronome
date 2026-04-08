import Foundation

/// Platform-specific audio (and optional haptics). Implemented in the iOS / watchOS apps.
public protocol MetronomeTickPlayback: AnyObject {
    /// Begin continuously scheduling tick audio at the given BPM and preset.
    func startTicking(bpm: Int, preset: TickPreset)

    /// Stop all scheduled ticks.
    func stopTicking()

    /// Change the BPM while ticking continues. No-op if not currently ticking.
    func updateBPM(_ bpm: Int)

    /// Change the tick sound while ticking continues. No-op if not currently ticking.
    func updatePreset(_ preset: TickPreset)

    /// Linear output gain (0.0 … `MetronomeController.maxVolumeGain`).
    func setVolume(_ volume: Float)
}
