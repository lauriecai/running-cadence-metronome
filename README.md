# Running Cadence Metronome (prototype)

Project root: `~/Developer/projects/Running Cadence Metronome`.

A small **iOS** metronome for testing cadence while running.

## What’s included

- **Shared logic** in [`MetronomeCore`](MetronomeCore/Package.swift) (compiled into the app target): BPM (40–240), synthesized tick presets, beat emphasis, play/stop.
- **iPhone UI** ([`RunningCadenceMetronomeIOS`](RunningCadenceMetronomeIOS/ContentView.swift)): tempo, sound, emphasis, volume, and play/stop.
