# Running Cadence Metronome (prototype)

Project root: `~/Developer/projects/Running Cadence Metronome`.

A small **iOS + watchOS** metronome for testing cadence while running.

## What’s included

- **Shared logic** in [`MetronomeCore`](MetronomeCore/Package.swift) (also compiled into both app targets): BPM (40–240), three synthesized tick presets, play/stop.
- **iPhone UI** ([`RunningCadenceMetronomeIOS`](RunningCadenceMetronomeIOS/ContentView.swift)): side-by-side **phone** and **watch-style** panels in one window, both bound to the same `MetronomeController` so you can demo the “paired” feel in the simulator.
- **Real Watch app** ([`RunningCadenceMetronomeWatch`](RunningCadenceMetronomeWatch/WatchContentView.swift)): wheel picker for sound, slider for BPM, play/stop; ticks use audio + a light haptic.
