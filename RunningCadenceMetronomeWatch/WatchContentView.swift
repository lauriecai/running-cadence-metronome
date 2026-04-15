import SwiftUI

struct WatchContentView: View {
    @ObservedObject var metronome: MetronomeController
    @ObservedObject var hapticsSettings: WatchHapticsSettings
    @State private var showBPMPicker = false
    @State private var pickerBPM = 180

    var body: some View {
        NavigationStack {
            List {
                Section {
					HStack(alignment: .center, spacing: 4) {
						Button { metronome.setBPM(metronome.bpm - 1) } label: {
							Image(systemName: "minus")
								.fontWeight(.bold)
						}
						.buttonStyle(.plain)
						
						Spacer()
						
						Text("\(metronome.bpm)")
							.font(.system(size: 32, weight: .bold, design: .rounded))
							.lineLimit(1)
							.onTapGesture {
								pickerBPM = metronome.bpm
								showBPMPicker = true
							}
							
						Spacer()
						
						Button { metronome.setBPM(metronome.bpm + 1) } label: {
							Image(systemName: "plus")
								.fontWeight(.bold)
						}
						.buttonStyle(.plain)
					}
					.frame(maxWidth: .infinity)
					
//					HStack(spacing: 12) {
//						Button("−10") { metronome.setBPM(metronome.bpm - 10) }
//							.font(.caption2)
//							.buttonStyle(.plain)
//							.frame(maxWidth: .infinity)
//							.padding(.vertical, 8)
//							.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
//
//						Button("+10") { metronome.setBPM(metronome.bpm + 10) }
//							.font(.caption2)
//							.buttonStyle(.plain)
//							.frame(maxWidth: .infinity)
//							.padding(.vertical, 8)
//							.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
//					}
//					.frame(maxWidth: .infinity)
//					.listRowBackground(Color.clear)
//					.listRowInsets(EdgeInsets(top: -8, leading: 0, bottom: 0, trailing: 0))

//                    Slider(
//                        value: Binding(
//                            get: { Double(metronome.bpm) },
//                            set: { metronome.setBPM(Int($0.rounded())) }
//                        ),
//                        in: 40 ... 240,
//                        step: 1
//                    )
                }

                Section {
					Picker("Sound", selection: Binding(
                        get: { metronome.preset },
                        set: { metronome.setPreset($0) }
                    )) {
                        ForEach(TickPreset.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Picker(selection: Binding(
                        get: { metronome.emphasis },
                        set: { metronome.setEmphasis($0) }
                    )) {
                        ForEach(BeatEmphasisPattern.allCases) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title)
                                Text(e.rhythmHyphenNotation)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(e)
                        }
                    } label: {
                        Text("Emphasis")
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
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
                }

                Section {
                    Toggle("Haptics", isOn: $hapticsSettings.hapticsEnabled)
                        .font(.caption)

                    if hapticsSettings.hapticsEnabled {
                        Picker("When", selection: $hapticsSettings.hapticsMode) {
                            ForEach(WatchHapticsMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                Section {
                    Button {
                        metronome.toggle()
                    } label: {
                        Image(systemName: metronome.isPlaying ? "stop.fill" : "play.fill")
                            .font(.title2)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(metronome.isPlaying ? .red : .green)
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 0, leading: -8, bottom: 0, trailing: -8))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showBPMPicker) {
                VStack {
                    Text("Set BPM")
                        .font(.headline)
                    Picker("BPM", selection: $pickerBPM) {
                        ForEach(40...240, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    Button("Done") {
                        metronome.setBPM(pickerBPM)
                        showBPMPicker = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

#Preview {
    WatchContentView(
        metronome: MetronomeController(playback: PreviewPlayback()),
        hapticsSettings: WatchHapticsSettings()
    )
}

private final class PreviewPlayback: MetronomeTickPlayback {
    func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern) {}
    func stopTicking() {}
    func updateBPM(_ bpm: Int) {}
    func updatePreset(_ preset: TickPreset) {}
    func updateEmphasis(_ emphasis: BeatEmphasisPattern) {}
    func setVolume(_ volume: Float) {}
}

private extension BeatEmphasisPattern {
    /// Leading label for the emphasis picker row (replaces “Pattern”).
    var everyBeatsPickerLabel: String {
        switch self {
        case .none: return "Even"
        case .every2: return "Every 2 beats"
        case .every3: return "Every 3 beats"
        case .every4: return "Every 4 beats"
        }
    }
}
