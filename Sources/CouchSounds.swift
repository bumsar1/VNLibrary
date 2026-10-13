import AVFoundation

/// Short UI sounds for couch mode, synthesised once at start-up so the app
/// ships no audio files: a soft tick for moving, a rising chime for
/// selecting, a falling one for going back.
final class CouchSounds {
    static let shared = CouchSounds()

    enum Sound { case move, row, select, back, error, add }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var started = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
        buffers[.move] = tones([(1760, 0.035)], gain: 0.25)
        buffers[.row] = tones([(1318, 0.045)], gain: 0.3)
        buffers[.select] = tones([(880, 0.06), (1318, 0.09)], gain: 0.35)
        buffers[.back] = tones([(1318, 0.06), (880, 0.09)], gain: 0.3)
        buffers[.error] = tones([(196, 0.12)], gain: 0.4, square: true)
        buffers[.add] = tones([(880, 0.05), (1108, 0.05), (1318, 0.1)], gain: 0.35)
    }

    func play(_ s: Sound) {
        guard UserDefaults.standard.object(forKey: "couchSounds") as? Bool ?? true, let buf = buffers[s] else { return }
        if !started {
            do { try engine.start(); started = true } catch { return }
        }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// A run of notes, each with a quick attack and an exponential fade.
    private func tones(_ notes: [(Double, Double)], gain: Float, square: Bool = false) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = notes.reduce(0) { $0 + Int(rate * $1.1) }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = buf.frameCapacity
        let out = buf.floatChannelData![0]
        var i = 0
        for (freq, dur) in notes {
            let n = Int(rate * dur)
            for k in 0..<n {
                let t = Double(k) / rate
                let attack = min(1, t / 0.004)
                let decay = exp(-t / (dur * 0.35))
                var v = sin(2 * .pi * freq * t)
                if square { v = v > 0 ? 0.6 : -0.6 }
                // A little octave overtone makes the tick less like a beep.
                v += 0.25 * sin(4 * .pi * freq * t)
                out[i] = Float(v * attack * decay) * gain
                i += 1
            }
        }
        return buf
    }
}
