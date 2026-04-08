import AVFoundation
import Foundation
import WatchKit

/// Click sounds plus light haptic on each tick for the watch.
/// Keeps its own Timer-based scheduling (watchOS background audio has
/// different constraints than iOS).
final class WatchMetronomeAudioService: NSObject, MetronomeTickPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [TickPreset: AVAudioPCMBuffer] = [:]

    private var timer: Timer?
    private var currentBPM: Int = 180
    private var currentPreset: TickPreset = .mechanicalTock

    private let gainLock = NSLock()
    private var gain: Float = 1.0

    override init() {
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
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
        currentBPM = bpm
        currentPreset = preset
        restartTimer()
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    func updateBPM(_ bpm: Int) {
        currentBPM = bpm
        if timer != nil {
            restartTimer()
        }
    }

    func updatePreset(_ preset: TickPreset) {
        currentPreset = preset
    }

    func setVolume(_ volume: Float) {
        gainLock.lock()
        gain = volume
        gainLock.unlock()
        engine.mainMixerNode.outputVolume = 1.0
    }

    // MARK: - Timer-based tick scheduling

    private func restartTimer() {
        timer?.invalidate()
        let interval = 60.0 / Double(currentBPM)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.playTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        playTick()
    }

    private func playTick() {
        WKInterfaceDevice.current().play(.click)
        startEngineIfNeeded()
        guard let buffer = buffers[currentPreset] else { return }
        gainLock.lock()
        let g = gain
        gainLock.unlock()
        let scaled = Self.bufferByApplyingGain(buffer, gain: g)
        player.scheduleBuffer(scaled, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    // MARK: - Buffer synthesis

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
