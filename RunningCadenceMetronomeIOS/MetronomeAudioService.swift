import AVFoundation
import Foundation

/// AVAudioEngine-based tick scheduling for iOS. Owns the timing loop
/// and pre-schedules buffers on the audio timeline so playback continues
/// even when the app is in the background.
final class MetronomeAudioService: NSObject, MetronomeTickPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var buffers: [TickPreset: AVAudioPCMBuffer] = [:]
    private var accentBuffers: [TickPreset: AVAudioPCMBuffer] = [:]

    // Scheduling state — accessed only on schedulingQueue
    private let schedulingQueue = DispatchQueue(label: "com.runningcadencemetronome.scheduling")
    private var nextSampleTime: AVAudioFramePosition = 0
    private var intervalInSamples: AVAudioFrameCount = 0
    private var currentPreset: TickPreset = .mechanicalTock
    private var currentEmphasis: BeatEmphasisPattern = .every2
    /// Increments for each scheduled tick (used to pick accent vs normal).
    private var beatPhase: Int = 0
    /// After `player.stop`/`play` or initial start, the first `scheduleAhead` must not
    /// advance `beatPhase` while catching the playhead up from `nextSampleTime == 0`, or
    /// the downbeat (high tick) is shifted to an offbeat (especially obvious for every 2).
    private var alignNextCatchUpToDownbeat = false
    private var isTicking = false

    /// How many beats to pre-schedule ahead of the player's current position.
    /// At 40 BPM this gives ~6 seconds of runway; plenty for background execution.
    private let lookAheadBeats = 4

    private let gainLock = NSLock()
    private var gain: Float = 1.0

    override init() {
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
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
        startEngineIfNeeded()

        schedulingQueue.async { [self] in
            isTicking = true
            currentPreset = preset
            currentEmphasis = emphasis
            beatPhase = 0
            intervalInSamples = AVAudioFrameCount(sampleRate * 60.0 / Double(bpm))
            nextSampleTime = 0

            // Reset the player to get a fresh timeline
            player.stop()
            player.play()

            alignNextCatchUpToDownbeat = true
            scheduleAhead()
        }
    }

    func stopTicking() {
        schedulingQueue.async { [self] in
            isTicking = false
            player.stop()
        }
    }

    func updateBPM(_ bpm: Int) {
        schedulingQueue.async { [self] in
            guard isTicking else { return }
            intervalInSamples = AVAudioFrameCount(sampleRate * 60.0 / Double(bpm))
            rescheduleFromNow()
        }
    }

    func updatePreset(_ preset: TickPreset) {
        schedulingQueue.async { [self] in
            currentPreset = preset
            guard isTicking else { return }
            // Flush pre-scheduled buffers and re-schedule with the new sound
            rescheduleFromNow()
        }
    }

    func updateEmphasis(_ emphasis: BeatEmphasisPattern) {
        schedulingQueue.async { [self] in
            currentEmphasis = emphasis
            guard isTicking else { return }
            rescheduleFromNow()
        }
    }

    func setVolume(_ volume: Float) {
        gainLock.lock()
        gain = volume
        gainLock.unlock()
        engine.mainMixerNode.outputVolume = 1.0
    }

    // MARK: - Scheduling loop

    /// Flushes all pre-scheduled buffers and re-schedules from the next beat
    /// at the current BPM/preset. Used when the user changes preset or BPM
    /// so the change takes effect immediately.
    private func rescheduleFromNow() {
        player.stop()
        player.play()
        // Reset timeline — next tick plays at sample 0 (i.e. now)
        nextSampleTime = 0
        beatPhase = 0
        alignNextCatchUpToDownbeat = true
        scheduleAhead()
    }

    /// Pre-schedules tick buffers ahead of the player's current position.
    /// Calls itself again after one beat interval to keep the schedule topped up.
    private func scheduleAhead() {
        guard isTicking else { return }
        guard let normalBuffer = buffers[currentPreset] else { return }
        let accentBuffer = accentBuffers[currentPreset] ?? normalBuffer

        // Determine "now" on the player's sample timeline
        let playerNow: AVAudioFramePosition
        if let lastRender = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: lastRender) {
            playerNow = playerTime.sampleTime
        } else {
            playerNow = 0
        }

        let intervalPos = AVAudioFramePosition(intervalInSamples)
        guard intervalPos > 0 else { return }

        let snapDownbeat = alignNextCatchUpToDownbeat
        alignNextCatchUpToDownbeat = false

        // If the playhead is already past `nextSampleTime`, jump forward to the next beat
        // instant without (on a fresh timeline) advancing the pattern — first heard tick
        // stays the downbeat / “high” for every-2 and other patterns.
        if nextSampleTime < playerNow {
            let delta = playerNow - nextSampleTime
            let skippedBeats = (delta + intervalPos - 1) / intervalPos
            if skippedBeats > 0 {
                nextSampleTime += skippedBeats * intervalPos
                if !snapDownbeat {
                    beatPhase += Int(skippedBeats)
                }
            }
        }

        let horizon = playerNow + AVAudioFramePosition(lookAheadBeats) * intervalPos

        // Schedule buffers from nextSampleTime up to the horizon
        gainLock.lock()
        let g = gain
        gainLock.unlock()

        while nextSampleTime < horizon {
            let time = AVAudioTime(sampleTime: nextSampleTime, atRate: sampleRate)
            let source = currentEmphasis.isAccent(forBeatIndex: beatPhase) ? accentBuffer : normalBuffer
            let toSchedule = Self.bufferByApplyingGain(source, gain: g)
            player.scheduleBuffer(toSchedule, at: time, options: [], completionHandler: nil)
            beatPhase += 1
            nextSampleTime += intervalPos
        }

        // Re-invoke after one beat to keep the schedule topped up
        let delaySeconds = Double(intervalInSamples) / sampleRate
        schedulingQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            self?.scheduleAhead()
        }
    }

    // MARK: - Engine management

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

    /// Applies linear gain; clamps samples to ±1 to limit harsh clipping when gain > 1.
    private static func bufferByApplyingGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer {
        if abs(Double(gain) - 1.0) < 0.000_001 {
            return buffer
        }
        let format = buffer.format
        let frameCount = buffer.frameLength
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        out.frameLength = frameCount
        guard let inPtr = buffer.floatChannelData?.pointee,
              let outPtr = out.floatChannelData?.pointee else { return buffer }
        let g = gain
        for i in 0 ..< Int(frameCount) {
            let s = inPtr[i] * g
            outPtr[i] = max(-1, min(1, s))
        }
        return out
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
