# Running Cadence Metronome (prototype)

Project root: `~/Developer/projects/Running Cadence Metronome`.

A small **iOS + watchOS** metronome for testing cadence while running.

## What’s included

- **Shared logic** in [`MetronomeCore`](MetronomeCore/Package.swift) (also compiled into both app targets): BPM (40–240), three synthesized tick presets, play/stop.
- **iPhone UI** ([`RunningCadenceMetronomeIOS`](RunningCadenceMetronomeIOS/ContentView.swift)): side-by-side **phone** and **watch-style** panels in one window, both bound to the same `MetronomeController` so you can demo the “paired” feel in the simulator.
- **Real Watch app** ([`RunningCadenceMetronomeWatch`](RunningCadenceMetronomeWatch/WatchContentView.swift)): wheel picker for sound, slider for BPM, play/stop; ticks use audio + a light haptic.

## Open in Xcode

1. Open `Running Cadence Metronome.xcodeproj`.
2. Pick the **Running Cadence Metronome** scheme and an **iPhone** simulator → Run. You’ll see the side-by-side layout; use **Play** / **Stop**, the **BPM** slider and ±10, and the **tick sound** segmented control.
3. To run the **watch app** alone: select the **Running Cadence Metronome Watch** target (or install the embedded watch app from the phone run by pairing a watch simulator in Xcode).

## Standalone Swift package

From `MetronomeCore/`:

```bash
swift build
```

(The apps use the same sources via the Xcode project, not `import MetronomeCore`, so the module stays simple for the prototype.)

## Notes

- Timing uses `Timer` on the main run loop—fine for a prototype; a shipping app would likely move to audio-clock scheduling for tighter accuracy.
- No WatchConnectivity yet; phone and watch builds are independent at runtime.
