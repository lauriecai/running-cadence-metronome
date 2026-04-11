import SwiftUI

struct ContentView: View {
    @ObservedObject var metronome: MetronomeController

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width > 700
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 24) {
                        phonePanel
//                        watchPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            phonePanel
//                            watchPanel
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
        }
    }

    private var phonePanel: some View {
        DeviceChrome(title: "iPhone", systemImage: "iphone") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Running Cadence")
                    .font(.title2.weight(.semibold))
                bpmControls
                presetPicker
                emphasisPicker
                volumeControl
                playStopRow
            }
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
    }

    private var watchPanel: some View {
        DeviceChrome(title: "Apple Watch", systemImage: "applewatch") {
            VStack(spacing: 8) {
                Text("\(metronome.bpm)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(metronome.bpm) },
                        set: { metronome.setBPM(Int($0.rounded())) }
                    ),
                    in: 40 ... 240,
                    step: 1
                )

                HStack(spacing: 6) {
                    Button("−10") { metronome.setBPM(metronome.bpm - 10) }
                        .font(.caption2)
                    Button("+10") { metronome.setBPM(metronome.bpm + 10) }
                        .font(.caption2)
                }
                .buttonStyle(.bordered)

                Text(metronome.preset.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(metronome.volume) },
                            set: { metronome.setVolume(Float($0)) }
                        ),
                        in: 0 ... 1
                    )
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                Button {
                    metronome.toggle()
                } label: {
                    Label(metronome.isPlaying ? "Stop" : "Play", systemImage: metronome.isPlaying ? "stop.fill" : "play.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(metronome.isPlaying ? .red : .green)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: 200, height: 340)
    }

    private var bpmControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tempo")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(metronome.bpm) BPM")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(metronome.bpm) },
                    set: { metronome.setBPM(Int($0.rounded())) }
                ),
                in: 40 ... 240,
                step: 1
            )
            HStack(spacing: 12) {
                Button("−10") { metronome.setBPM(metronome.bpm - 10) }
                Button("+10") { metronome.setBPM(metronome.bpm + 10) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tick sound")
                .font(.subheadline.weight(.medium))
            Picker("Sound", selection: Binding(
                get: { metronome.preset },
                set: { metronome.setPreset($0) }
            )) {
                ForEach(TickPreset.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var emphasisPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Beat emphasis")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(metronome.emphasis.patternDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Accent", selection: Binding(
                get: { metronome.emphasis },
                set: { metronome.setEmphasis($0) }
            )) {
                ForEach(BeatEmphasisPattern.allCases) { e in
                    Text(e.shortLabel).tag(e)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Beats per accented cycle")
        }
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metronome volume")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(metronome.volume) },
                        set: { metronome.setVolume(Float($0)) }
                    ),
                    in: 0 ... 1
                )
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playStopRow: some View {
        HStack(spacing: 12) {
            Button {
                if metronome.isPlaying {
                    metronome.stop()
                } else {
                    metronome.start()
                }
            } label: {
                Label(metronome.isPlaying ? "Stop" : "Play", systemImage: metronome.isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(metronome.isPlaying ? .red : .green)
        }
    }
}

private struct DeviceChrome<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
//            Label(title, systemImage: systemImage)
//                .font(.headline)
//                .foregroundStyle(.secondary)
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

#Preview {
	final class PreviewPlayback: MetronomeTickPlayback {
		func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern) {}
		func stopTicking() {}
		func updateBPM(_ bpm: Int) {}
		func updatePreset(_ preset: TickPreset) {}
		func updateEmphasis(_ emphasis: BeatEmphasisPattern) {}
		func setVolume(_ volume: Float) {}
	}

	let metronome = MetronomeController(
		bpm: 180,
		preset: .mechanicalTock,
		playback: PreviewPlayback()
	)

	return ContentView(metronome: metronome)
}
