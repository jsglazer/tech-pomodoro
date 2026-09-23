// make-sounds.swift — synthesize the iOS app's bundled alert tones as 16-bit linear-PCM .caf files.
//
//   swift Scripts/make-sounds.swift [out-dir]
//
// iOS exposes no system sound folder an app can list or play by name, so the iOS app ships its own
// small set of original tones. Each is additive sine partials under an exponential decay, with a
// short attack ramp so nothing clicks. No randomness: rerunning the script regenerates identical
// files. Output defaults to Sources/TechPomodoroiOS/Resources/Sounds. Every tone is well under the
// 30 second limit iOS places on a notification sound.
import AVFoundation
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/TechPomodoroiOS/Resources/Sounds"
let sampleRate = 44_100.0

/// One sine partial: frequency in Hz, peak amplitude, decay time constant in seconds, onset delay.
struct Partial {
    let frequency: Double
    let amplitude: Double
    let decay: Double
    var delay: Double = 0
}

struct Tone {
    let name: String
    let length: Double
    let partials: [Partial]
}

/// A struck note: the fundamental plus its (possibly inharmonic) overtones, highs dying fastest.
func strike(_ base: Double, at delay: Double = 0, ratios: [(Double, Double)], decay: Double) -> [Partial] {
    ratios.enumerated().map { index, pair in
        Partial(
            frequency: base * pair.0,
            amplitude: pair.1,
            decay: decay / (1 + Double(index) * 0.6),
            delay: delay
        )
    }
}

/// A short enveloped beep, for the tick and pulse tones.
func blip(_ frequency: Double, at delay: Double, decay: Double = 0.035, amplitude: Double = 0.8) -> [Partial] {
    [
        Partial(frequency: frequency, amplitude: amplitude, decay: decay, delay: delay),
        Partial(frequency: frequency * 2, amplitude: amplitude * 0.25, decay: decay * 0.6, delay: delay)
    ]
}

let tones: [Tone] = [
    // The default. Named for the macOS sound it stands in for, so the shared `soundName` default of
    // "Glass" resolves on both platforms: a bright, high, glassy ping.
    Tone(name: "Glass", length: 1.6, partials: strike(1318.5, ratios: [(1, 0.6), (2.76, 0.28), (5.40, 0.14), (8.93, 0.06)], decay: 0.55)),
    // A rising two-note chime, C6 then G6.
    Tone(name: "Chime", length: 1.8, partials:
        strike(1046.5, ratios: [(1, 0.5), (2, 0.18), (3, 0.06)], decay: 0.5)
        + strike(1568.0, at: 0.22, ratios: [(1, 0.5), (2, 0.18), (3, 0.06)], decay: 0.6)),
    // A small bell with the inharmonic partials of a real one: hum, prime, tierce, quint, nominal.
    Tone(name: "Bell", length: 2.4, partials: strike(523.25, ratios: [(0.5, 0.25), (1, 0.5), (1.19, 0.3), (1.5, 0.22), (2, 0.28), (2.74, 0.12), (3.0, 0.08)], decay: 1.1)),
    // Two soft wooden ticks.
    Tone(name: "Tick", length: 0.5, partials: blip(1900, at: 0, decay: 0.012) + blip(1900, at: 0.16, decay: 0.012)),
    // Three short beeps.
    Tone(name: "Pulse", length: 0.8, partials: blip(880, at: 0) + blip(880, at: 0.18) + blip(880, at: 0.36))
]

func render(_ tone: Tone) -> [Float] {
    let count = Int(tone.length * sampleRate)
    let attack = 0.004
    var samples = [Double](repeating: 0, count: count)
    for partial in tone.partials {
        let start = Int(partial.delay * sampleRate)
        guard start < count else { continue }
        for i in start..<count {
            let t = Double(i - start) / sampleRate
            let envelope = min(1, t / attack) * exp(-t / partial.decay)
            samples[i] += partial.amplitude * envelope * sin(2 * .pi * partial.frequency * t)
        }
    }
    // Normalise to a fixed peak so every tone plays at the same loudness, then fade the last 30 ms.
    let peak = samples.map(abs).max() ?? 1
    let gain = peak > 0 ? 0.85 / peak : 0
    let fade = Int(0.03 * sampleRate)
    return samples.enumerated().map { i, value in
        let tail = i >= count - fade ? Double(count - i) / Double(fade) : 1
        return Float(value * gain * tail)
    }
}

func write(_ tone: Tone) throws {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(tone.name).caf")
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let samples = render(tone)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw NSError(domain: "make-sounds", code: 1)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
    print("wrote \(url.path) (\(String(format: "%.2f", tone.length)) s)")
}

do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    for tone in tones { try write(tone) }
} catch {
    FileHandle.standardError.write(Data("make-sounds failed: \(error)\n".utf8))
    exit(1)
}
