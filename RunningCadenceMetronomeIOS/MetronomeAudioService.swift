import AVFoundation
import Foundation
import UIKit

/// AVAudioEngine-based tick scheduling for iOS. Owns the timing loop
/// and pre-schedules buffers on the audio timeline so playback continues
/// even when the app is in the background.
final class MetronomeAudioService: NSObject, MetronomeTickPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var buffers: [TickPreset: AVAudioPCMBuffer] = [:]
    private var accentBuffers: [TickPreset: AVAudioPCMBuffer] = [:]

    private let notificationCenter: NotificationCenter
    private var notificationObservers: [NSObjectProtocol] = []

    // Scheduling state — accessed only on schedulingQueue
    private let schedulingQueue = DispatchQueue(label: "com.runningcadencemetronome.scheduling")
    private var nextSampleTime: AVAudioFramePosition = 0
    private var intervalInSamples: AVAudioFrameCount = 0
    private var currentPreset: TickPreset = .mechanicalTock
    private var currentEmphasis: BeatEmphasisPattern = .none
    /// Increments for each scheduled tick (used to pick accent vs normal).
    private var beatPhase: Int = 0
    /// After `player.stop`/`play` or initial start, the first `scheduleAhead` must not
    /// advance `beatPhase` while catching the playhead up from `nextSampleTime == 0`, or
    /// the downbeat (high tick) is shifted to an offbeat (especially obvious for every 2).
    private var alignNextCatchUpToDownbeat = false
    private var isTicking = false
    /// When true, `scheduleAhead` stops scheduling until an interruption ends.
    private var suspendedForInterruption = false

    /// How many beats to pre-schedule ahead of the player's current position.
    /// At 40 BPM this gives ~6 seconds of runway; plenty for background execution.
    private let lookAheadBeats = 4

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
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

        registerForAudioNotifications()
    }

    deinit {
        for observer in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: - MetronomeTickPlayback

    func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern) {
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            self.suspendedForInterruption = false
            self.startEngineIfNeeded()
            self.isTicking = true
            self.currentPreset = preset
            self.currentEmphasis = emphasis
            self.beatPhase = 0
            self.intervalInSamples = AVAudioFrameCount(self.sampleRate * 60.0 / Double(bpm))
            self.nextSampleTime = 0

            // Reset the player to get a fresh timeline
            self.player.stop()
            self.player.play()

            self.alignNextCatchUpToDownbeat = true
            self.scheduleAhead()
        }
    }

    func stopTicking() {
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            self.isTicking = false
            self.suspendedForInterruption = false
            self.player.stop()
        }
    }

    func updateBPM(_ bpm: Int) {
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            guard self.isTicking else { return }
            self.intervalInSamples = AVAudioFrameCount(self.sampleRate * 60.0 / Double(bpm))
            self.rescheduleFromNow()
        }
    }

    func updatePreset(_ preset: TickPreset) {
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            self.currentPreset = preset
            guard self.isTicking else { return }
            // Flush pre-scheduled buffers and re-schedule with the new sound
            self.rescheduleFromNow()
        }
    }

    func updateEmphasis(_ emphasis: BeatEmphasisPattern) {
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            self.currentEmphasis = emphasis
            guard self.isTicking else { return }
            self.rescheduleFromNow()
        }
    }

    func setVolume(_ volume: Float) {
        let v = max(0.0, min(1.0, volume))
        schedulingQueue.async { [weak self] in
            self?.player.volume = v
        }
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
        guard isTicking, !suspendedForInterruption else { return }
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

        // Schedule buffers from nextSampleTime up to the horizon.
        while nextSampleTime < horizon {
            let time = AVAudioTime(sampleTime: nextSampleTime, atRate: sampleRate)
            let source = currentEmphasis.isAccent(forBeatIndex: beatPhase) ? accentBuffer : normalBuffer
            player.scheduleBuffer(source, at: time, options: [], completionHandler: nil)
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

    // MARK: - Session / route recovery

    private func registerForAudioNotifications() {
        let interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.schedulingQueue.async {
                self?.handleSessionInterruption(notification)
            }
        }

        let routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.schedulingQueue.async {
                self?.handleRouteChange(notification)
            }
        }

        let engineChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.schedulingQueue.async {
                self?.recoverPlaybackAfterEngineOrRouteChange()
            }
        }

        let becameActiveObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.schedulingQueue.async {
                self?.recoverPlaybackAfterEngineOrRouteChange()
            }
        }

        notificationObservers = [
            interruptionObserver,
            routeChangeObserver,
            engineChangeObserver,
            becameActiveObserver,
        ]
    }

    /// Caller: `schedulingQueue` only.
    private func handleSessionInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeRawValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRawValue)
        else { return }

        switch type {
        case .began:
            guard isTicking else { return }
            suspendedForInterruption = true
            player.stop()
        case .ended:
            suspendedForInterruption = false
            guard isTicking else { return }
            recoverPlaybackAfterInterruptionEnded()
        @unknown default:
            break
        }
    }

    /// Caller: `schedulingQueue` only.
    private func handleRouteChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let reasonRawValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue)
        else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
            recoverPlaybackAfterEngineOrRouteChange()
        default:
            break
        }
    }

    /// Caller: `schedulingQueue` only.
    private func recoverPlaybackAfterInterruptionEnded() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        startEngineIfNeeded()
        rescheduleFromNow()
    }

    /// Caller: `schedulingQueue` only.
    private func recoverPlaybackAfterEngineOrRouteChange() {
        guard isTicking, !suspendedForInterruption else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if engine.isRunning {
            try? engine.stop()
        }
        engine.prepare()
        try? engine.start()
        rescheduleFromNow()
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
