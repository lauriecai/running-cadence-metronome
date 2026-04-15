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
    private var currentEmphasis: BeatEmphasisPattern = .none
    private var beatPhase: Int = 0
    /// True while the user has started the metronome (until `stopTicking` or an audio-session interruption suspends playback).
    private var metronomeRunning = false
    private let schedulerQueue = DispatchQueue(label: "com.cadence.metronome.watch.audio-scheduler", qos: .userInteractive)
    private let notificationCenter: NotificationCenter
    private var notificationObservers: [NSObjectProtocol] = []

    private let hapticsSettings: WatchHapticsSettings
    private let scheduledBeatsAhead = 24
    private let schedulerInterval: TimeInterval = 0.015
    private let startupLeadTime: TimeInterval = 0.050
    /// Estimated haptic trigger latency; used to fire slightly before target.
    private let hapticSystemLatencyEstimate: TimeInterval = 0.024

    init(
        hapticsSettings: WatchHapticsSettings,
        notificationCenter: NotificationCenter = .default
    ) {
        self.hapticsSettings = hapticsSettings
        self.notificationCenter = notificationCenter
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
        registerForAudioNotifications()
    }

    deinit {
        for observer in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Call at launch; full activation (Bluetooth route) happens when playback starts.
    func prepareSession() {
        configureAudioSessionCategory()
    }

    private func configureAudioSessionCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            assertionFailure("Failed to configure watch audio session category: \(error)")
        }
    }

    private func activateAudioSession(completion: @escaping () -> Void) {
        configureAudioSessionCategory()
        AVAudioSession.sharedInstance().activate(options: []) { _, _ in
            self.schedulerQueue.async(execute: completion)
        }
    }

    // MARK: - MetronomeTickPlayback

    func startTicking(bpm: Int, preset: TickPreset, emphasis: BeatEmphasisPattern) {
        schedulerQueue.async {
            self.metronomeRunning = true
            self.currentBPM = bpm
            self.currentPreset = preset
            self.currentEmphasis = emphasis
            self.beatPhase = 0
            self.startScheduling()
        }
    }

    func stopTicking() {
        schedulerQueue.async {
            self.metronomeRunning = false
            self.stopScheduling()
        }
    }

    func updateBPM(_ bpm: Int) {
        schedulerQueue.async {
            self.currentBPM = bpm
            if self.schedulingTimer != nil {
                self.rebuildSchedule(resetBeatPhase: false)
            }
        }
    }

    func updatePreset(_ preset: TickPreset) {
        schedulerQueue.async {
            self.currentPreset = preset
            if self.schedulingTimer != nil {
                self.rebuildSchedule(resetBeatPhase: false)
            }
        }
    }

    func updateEmphasis(_ emphasis: BeatEmphasisPattern) {
        schedulerQueue.async {
            self.currentEmphasis = emphasis
            self.beatPhase = 0
            if self.schedulingTimer != nil {
                self.rebuildSchedule(resetBeatPhase: true)
            }
        }
    }

    func setVolume(_ volume: Float) {
        schedulerQueue.async {
            self.player.volume = max(0.0, min(1.0, volume))
        }
    }

    // MARK: - Audio-clock beat scheduling

    private func startScheduling() {
        schedulingGeneration &+= 1
        let generation = schedulingGeneration
        invalidateSchedulingTimer()
        nextBeatSampleTime = nil
        beatPhase = 0

        player.stop()
        player.reset()

        activateAudioSession { [weak self] in
            guard let self else { return }
            guard generation == self.schedulingGeneration else { return }
            self.startEngineIfNeeded()
            if !self.player.isPlaying {
                self.player.play()
            }
            self.startSchedulingTimer()
            self.scheduleBeatsIfNeeded()
        }
    }

    private func stopScheduling() {
        schedulingGeneration &+= 1
        invalidateSchedulingTimer()
        nextBeatSampleTime = nil
        player.stop()
        player.reset()
        engine.stop()
    }

    /// Stops scheduling, invalidates pending haptics (`schedulingGeneration`), and tears down audio until resumed (e.g. after session interruption ends).
    private func suspendPlaybackForInterruption() {
        guard metronomeRunning else { return }
        schedulingGeneration &+= 1
        invalidateSchedulingTimer()
        nextBeatSampleTime = nil
        player.stop()
        player.reset()
        engine.stop()
    }

    /// Restarts engine/timer after playback was suspended (interruption or route change recovery).
    private func resumePlaybackAfterExternalResumeIfNeeded() {
        guard metronomeRunning else { return }
        guard schedulingTimer == nil else { return }

        schedulingGeneration &+= 1
        let generation = schedulingGeneration
        nextBeatSampleTime = nil
        player.stop()
        player.reset()

        activateAudioSession { [weak self] in
            guard let self else { return }
            guard generation == self.schedulingGeneration else { return }
            guard self.metronomeRunning else { return }
            self.startEngineIfNeeded()
            if !self.player.isPlaying {
                self.player.play()
            }
            self.startSchedulingTimer()
            self.scheduleBeatsIfNeeded()
        }
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
        let timer = DispatchSource.makeTimerSource(queue: schedulerQueue)
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
            let shouldTrigger = self.schedulerQueue.sync {
                generation == self.schedulingGeneration && self.shouldPlayHaptic(isAccent: isAccent)
            }
            guard shouldTrigger else { return }
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

    private func registerForAudioNotifications() {
        let interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.schedulerQueue.async {
                self?.handleSessionInterruption(notification)
            }
        }

        let routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.schedulerQueue.async {
                self?.handleRouteChange(notification)
            }
        }

        let engineChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.schedulerQueue.async {
                self?.recoverPlaybackIfNeeded()
            }
        }

        notificationObservers = [interruptionObserver, routeChangeObserver, engineChangeObserver]
    }

    private func handleSessionInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeRawValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRawValue)
        else { return }

        switch type {
        case .began:
            suspendPlaybackForInterruption()
        case .ended:
            var shouldResume = true
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                shouldResume = options.contains(.shouldResume)
            }
            if shouldResume {
                recoverPlaybackIfNeeded()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let reasonRawValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue)
        else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .routeConfigurationChange:
            recoverPlaybackIfNeeded()
        default:
            break
        }
    }

    private func recoverPlaybackIfNeeded() {
        guard metronomeRunning else { return }
        if schedulingTimer == nil {
            resumePlaybackAfterExternalResumeIfNeeded()
            return
        }
        activateAudioSession { [weak self] in
            guard let self else { return }
            guard self.metronomeRunning else { return }
            guard self.schedulingTimer != nil else { return }
            self.rebuildSchedule(resetBeatPhase: false)
        }
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
