import SwiftUI

@main
struct RunningCadenceMetronomeApp: App {
    @StateObject private var metronome: MetronomeController

    init() {
        let audio = MetronomeAudioService()
        audio.prepareSession()

        let savedBPM = UserDefaults.standard.integer(forKey: "running_cadence_bpm")
        let legacyBPM = UserDefaults.standard.integer(forKey: "cadence_bpm")
        let bpm = savedBPM > 0 ? savedBPM : (legacyBPM > 0 ? legacyBPM : 180)

        let savedPresetRaw = UserDefaults.standard.string(forKey: "running_cadence_preset")
            ?? UserDefaults.standard.string(forKey: "cadence_preset")
        let preset = savedPresetRaw.flatMap(TickPreset.init(rawValue:)) ?? .mechanicalTock

        _metronome = StateObject(wrappedValue: MetronomeController(
            bpm: bpm,
            preset: preset,
            playback: audio
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(metronome: metronome)
        }
    }
}
