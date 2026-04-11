import SwiftUI

struct WatchContentView: View {
    @ObservedObject var metronome: MetronomeController

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // BPM display
                Text("\(metronome.bpm)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // BPM slider
                Slider(
                    value: Binding(
                        get: { Double(metronome.bpm) },
                        set: { metronome.setBPM(Int($0.rounded())) }
                    ),
                    in: 40 ... 240,
                    step: 1
                )

                // ±10 buttons
                HStack(spacing: 8) {
                    Button("−10") { metronome.setBPM(metronome.bpm - 10) }
                        .font(.caption2)
                    Button("+10") { metronome.setBPM(metronome.bpm + 10) }
                        .font(.caption2)
                }
                .buttonStyle(.bordered)

                // Tick sound picker
                Picker("Sound", selection: Binding(
                    get: { metronome.preset },
                    set: { metronome.setPreset($0) }
                )) {
                    ForEach(TickPreset.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 50)

                Text("Accent: \(metronome.emphasis.patternDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Accent", selection: Binding(
                    get: { metronome.emphasis },
                    set: { metronome.setEmphasis($0) }
                )) {
                    ForEach(BeatEmphasisPattern.allCases) { e in
                        Text("\(e.shortLabel) — \(e.title)").tag(e)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 44)

                // Volume
                HStack(spacing: 4) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(metronome.volume) },
                            set: { metronome.setVolume(Float($0)) }
                        ),
                        in: 0 ... 1
                    )
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Play/Stop
                Button {
                    metronome.toggle()
                } label: {
                    Image(systemName: metronome.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .tint(metronome.isPlaying ? .red : .green)
            }
            .padding(.horizontal, 4)
        }
    }
}
