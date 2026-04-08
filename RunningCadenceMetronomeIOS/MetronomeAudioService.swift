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

    // Scheduling state — accessed only on schedulingQueue
    private let schedulingQueue = DispatchQueue(label: "com.runningcadencemetronome.scheduling")
    private var nextSampleTime: AVAudioFramePosition = 0
    private var intervalInSamples: AVAudioFrameCount = 0
    private var currentPreset: TickPreset = .mechanicalTock
    private var isTicking = false

    /// How many beats to pre-schedule ahead of the player's current position.
    /// At 40 BPM this gives ~6 seconds of runway; plenty for background execution.
    private let lookAheadBeats = 4

    private let gainLock = NSLock()
    private var gain: Float = 1.0

    override init() {
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        buffers[.mechanicalTock] = Self.makeBuffer(frequency: 550, format: format, brightness: 0.6, decay: 105)
        buffers[.woodKnock] = Self.makeBuffer(frequency: 420, format: format, brightness: 0.35)
        buffers[.softTap] = Self.makeBuffer(frequency: 260, format: format, brightness: 0.15, decay: 70)

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

    func startTicking(bpm: Int, preset: TickPreset) {
        startEngineIfNeeded()

        schedulingQueue.async { [self] in
            isTicking = true
            currentPreset = preset
            intervalInSamples = AVAudioFrameCount(sampleRate * 60.0 / Double(bpm))
            nextSampleTime = 0

            // Reset the player to get a fresh timeline
            player.stop()
            player.play()

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
        scheduleAhead()
    }

    /// Pre-schedules tick buffers ahead of the player's current position.
    /// Calls itself again after one beat interval to keep the schedule topped up.
    private func scheduleAhead() {
        guard isTicking else { return }
        guard let buffer = buffers[currentPreset] else { return }

        // Determine "now" on the player's sample timeline
        let playerNow: AVAudioFramePosition
        if let lastRender = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: lastRender) {
            playerNow = playerTime.sampleTime
        } else {
            playerNow = 0
        }

        let horizon = playerNow + AVAudioFramePosition(lookAheadBeats) * AVAudioFramePosition(intervalInSamples)

        // Schedule buffers from nextSampleTime up to the horizon
        gainLock.lock()
        let g = gain
        gainLock.unlock()

        while nextSampleTime < horizon {
            let time = AVAudioTime(sampleTime: nextSampleTime, atRate: sampleRate)
            let toSchedule = Self.bufferByApplyingGain(buffer, gain: g)
            player.scheduleBuffer(toSchedule, at: time, options: [], completionHandler: nil)
            nextSampleTime += AVAudioFramePosition(intervalInSamples)
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
        decay: Double = 95
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
            ptr[i] = Float((fundamental + partial * brightness) * envelope * 0.85)
        }
        return buffer
    }
}
