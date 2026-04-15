import SwiftUI

@main
struct RunningCadenceMetronomeWatchApp: App {
    @StateObject private var metronome: MetronomeController
    @StateObject private var hapticsSettings: WatchHapticsSettings

    init() {
        let settings = WatchHapticsSettings()
        _hapticsSettings = StateObject(wrappedValue: settings)

        let audio = WatchMetronomeAudioService(hapticsSettings: settings)
        audio.prepareSession()

        let savedBPM = UserDefaults.standard.integer(forKey: "running_cadence_bpm")
        let legacyBPM = UserDefaults.standard.integer(forKey: "cadence_bpm")
        let bpm = savedBPM > 0 ? savedBPM : (legacyBPM > 0 ? legacyBPM : 180)

        let savedPresetRaw = UserDefaults.standard.string(forKey: "running_cadence_preset")
            ?? UserDefaults.standard.string(forKey: "cadence_preset")
        let preset = savedPresetRaw.flatMap(TickPreset.init(rawValue:)) ?? .mechanicalTock

        let savedEmphasisRaw = UserDefaults.standard.string(forKey: "running_cadence_emphasis")
        let emphasis = savedEmphasisRaw.flatMap(BeatEmphasisPattern.init(rawValue:)) ?? .every2

        _metronome = StateObject(wrappedValue: MetronomeController(
            bpm: bpm,
            preset: preset,
            emphasis: emphasis,
            playback: audio
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView(metronome: metronome, hapticsSettings: hapticsSettings)
        }
    }
}
