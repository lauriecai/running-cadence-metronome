import AVFoundation
import Foundation
import WatchKit

/// Click sounds with optional haptics for the watch.
/// Schedules beats against the audio clock to reduce drift/jitter.
final class WatchMetronomeAudioService: NSObject, MetronomeTickPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [TickPreset: AVAudioPCMBuffer] = [:]
    private var accentBuffers: [TickPreset: AVAudioPCMBuffer] = [:]

    private var schedulingTimer: DispatchSourceTimer?
    private var nextBeatSampleTime: AVAudioFramePosition?
    private var schedulingGeneration: UInt64 = 0
    private var currentBPM: Int = 180
    private var currentPreset: TickPreset = .mechanicalTock
    private var currentEmphasis: BeatEmphasisPattern = .every2
    private var beatPhase: Int = 0

    private let hapticsSettings: WatchHapticsSettings
    private let scheduledBeatsAhead = 6
    private let schedulerInterval: TimeInterval = 0.015
    private let startupLeadTime: TimeInterval = 0.050
    /// Estimated haptic trigger latency; used to fire slightly before target.
    private let hapticSystemLatencyEstimate: TimeInterval = 0.024

    init(hapticsSettings: WatchHapticsSettings) {
        self.hapticsSettings = hapticsSettings
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for preset in TickPreset.allCases {
            let p = Self.synthesisParameters(for: preset)
            buffers[preset] = Self.makeBuffer(
                frequency: p.frequency,
                format: format,
                brightness: p.brightness,
                decay: p.decay,
                amplitudeScale: 1.0
            )
            accentBuffers[preset] = Self.makeBuffer(
                frequency: p.frequency * 1.45,
                format: format,
                brightness: min(1.0, p.brightness * 1.65),
                decay: p.decay * 1.08,
                amplitudeScale: 1.18
            )
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: - MetronomeTickPlayback

    func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern) {
        currentBPM = bpm
        currentPreset = preset
        currentEmphasis = emphasis
        beatPhase = 0
        startScheduling()
    }

    func stopTicking() {
        stopScheduling()
    }

    func updateBPM(_ bpm: Int) {
        currentBPM = bpm
        if schedulingTimer != nil {
            rebuildSchedule(resetBeatPhase: false)
        }
    }

    func updatePreset(_ preset: TickPreset) {
        currentPreset = preset
        if schedulingTimer != nil {
            rebuildSchedule(resetBeatPhase: false)
        }
    }

    func updateEmphasis(_ emphasis: BeatEmphasisPattern) {
        currentEmphasis = emphasis
        beatPhase = 0
        if schedulingTimer != nil {
            rebuildSchedule(resetBeatPhase: true)
        }
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0.0, min(1.0, volume))
    }

    // MARK: - Audio-clock beat scheduling

    private func startScheduling() {
        schedulingGeneration &+= 1
        invalidateSchedulingTimer()
        nextBeatSampleTime = nil
        beatPhase = 0

        player.stop()
        player.reset()
        startEngineIfNeeded()
        if !player.isPlaying {
            player.play()
        }
        startSchedulingTimer()
        scheduleBeatsIfNeeded()
    }

    private func stopScheduling() {
        schedulingGeneration &+= 1
        invalidateSchedulingTimer()
        nextBeatSampleTime = nil
        player.stop()
        player.reset()
    }

    private func rebuildSchedule(resetBeatPhase: Bool) {
        schedulingGeneration &+= 1
        if resetBeatPhase {
            beatPhase = 0
        }
        nextBeatSampleTime = nil
        player.stop()
        player.reset()
        startEngineIfNeeded()
        if !player.isPlaying {
            player.play()
        }
        scheduleBeatsIfNeeded()
    }

    private func startSchedulingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: schedulerInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.scheduleBeatsIfNeeded()
        }
        schedulingTimer = timer
        timer.resume()
    }

    private func invalidateSchedulingTimer() {
        schedulingTimer?.setEventHandler {}
        schedulingTimer?.cancel()
        schedulingTimer = nil
    }

    private func scheduleBeatsIfNeeded() {
        guard schedulingTimer != nil else { return }
        guard let normalBuffer = buffers[currentPreset] else { return }
        let accentBuffer = accentBuffers[currentPreset] ?? normalBuffer
        guard let render = currentRenderState() else { return }

        let framesPerBeat = currentFramesPerBeat(sampleRate: render.sampleRate)
        guard framesPerBeat > 0 else { return }

        if nextBeatSampleTime == nil {
            let startupFrames = AVAudioFramePosition(startupLeadTime * render.sampleRate)
            nextBeatSampleTime = render.sampleTime + startupFrames
        }

        let targetAheadFrames = AVAudioFramePosition(scheduledBeatsAhead) * framesPerBeat
        while let nextSample = nextBeatSampleTime, nextSample - render.sampleTime <= targetAheadFrames {
            scheduleBeat(
                atSampleTime: nextSample,
                sampleRate: render.sampleRate,
                normalBuffer: normalBuffer,
                accentBuffer: accentBuffer
            )
            nextBeatSampleTime = nextSample + framesPerBeat
        }
    }

    private func scheduleBeat(
        atSampleTime sampleTime: AVAudioFramePosition,
        sampleRate: Double,
        normalBuffer: AVAudioPCMBuffer,
        accentBuffer: AVAudioPCMBuffer
    ) {
        let isAccent = currentEmphasis.isAccent(forBeatIndex: beatPhase)
        let source = isAccent ? accentBuffer : normalBuffer
        let beatTime = AVAudioTime(sampleTime: sampleTime, atRate: sampleRate)
        player.scheduleBuffer(source, at: beatTime, options: [], completionHandler: nil)

        if shouldPlayHaptic(isAccent: isAccent) {
            scheduleHaptic(forBeatAtSampleTime: sampleTime, isAccent: isAccent)
        }
        beatPhase += 1
    }

    private func scheduleHaptic(forBeatAtSampleTime sampleTime: AVAudioFramePosition, isAccent: Bool) {
        guard let render = currentRenderState() else { return }
        let samplesUntilBeat = max(0, sampleTime - render.sampleTime)
        let secondsUntilBeat = Double(samplesUntilBeat) / render.sampleRate
        let perceivedAudioDelay = estimatedPerceivedAudioDelay()
        let fireDelay = max(0, secondsUntilBeat + perceivedAudioDelay - hapticSystemLatencyEstimate)
        let generation = schedulingGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + fireDelay) { [weak self] in
            guard let self else { return }
            guard generation == self.schedulingGeneration else { return }
            guard self.shouldPlayHaptic(isAccent: isAccent) else { return }
            WKInterfaceDevice.current().play(.start)
        }
    }

    private func currentFramesPerBeat(sampleRate: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((60.0 / Double(currentBPM)) * sampleRate)
    }

    private func currentRenderState() -> (sampleTime: AVAudioFramePosition, sampleRate: Double)? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return (sampleTime: playerTime.sampleTime, sampleRate: playerTime.sampleRate)
    }

    private func estimatedPerceivedAudioDelay() -> TimeInterval {
        let session = AVAudioSession.sharedInstance()
        // Route/output buffering delay before scheduled samples are actually heard.
        let outputPathDelay = session.outputLatency + session.ioBufferDuration
        return max(0, outputPathDelay)
    }

    private func shouldPlayHaptic(isAccent: Bool) -> Bool {
        guard hapticsSettings.hapticsEnabled else { return false }
        switch hapticsSettings.hapticsMode {
        case .everyBeat:
            return true
        case .emphasizedOnly:
            return isAccent
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    // MARK: - Buffer synthesis

    private static func synthesisParameters(for preset: TickPreset) -> (frequency: Double, brightness: Double, decay: Double) {
        switch preset {
        case .mechanicalTock: return (550, 0.6, 105)
        case .woodKnock: return (420, 0.35, 95)
        case .softTap: return (260, 0.15, 70)
        }
    }

    private static func makeBuffer(
        frequency: Double,
        format: AVAudioFormat,
        brightness: Double = 1.0,
        decay: Double = 95,
        amplitudeScale: Double = 1.0
    ) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let duration = 0.055
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        guard let ptr = buffer.floatChannelData?.pointee else { return buffer }
        for i in 0 ..< Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * decay)
            let fundamental = sin(2 * Double.pi * frequency * t)
            let partial = 0.35 * sin(2 * Double.pi * frequency * 1.5 * t)
            ptr[i] = Float((fundamental + partial * brightness) * envelope * 0.85 * amplitudeScale)
        }
        return buffer
    }
}
