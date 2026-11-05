@preconcurrency import AVFoundation
import Foundation

/// Zet tekst om naar een WAV-bestand (dat kunnen Mac én Sonos afspelen).
@MainActor
protocol Voice {
    var name: String { get }
    func render(_ text: String) async throws -> URL
}

enum AudioFiles {
    /// Map met de DJ-audio; de HTTP-server voor de Sonos serveert later precies deze map.
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dj-agenda", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @MainActor private static var counter = 0

    @MainActor
    static func next() -> URL {
        counter += 1
        return directory.appendingPathComponent("dj-\(counter)-\(Int(Date().timeIntervalSince1970)).wav")
    }

    /// Oude bestanden opruimen.
    static func cleanUp(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date.timeIntervalSinceNow < -age { try? fm.removeItem(at: f) }
        }
    }
}

/// Alle DJ-audio even hard: naar een vast gemiddeld niveau (RMS), met een plafond voor de pieken.
/// (De Engelse Voxtral-stemmen zijn van zichzelf zo'n 18 dB zachter dan de Nederlandse.)
enum Loudness {
    static let targetRMS: Float = -20   // dBFS
    static let ceiling: Float = -1      // dBFS

    static func gain(rms: Float, peak: Float) -> Float {
        guard rms > 0, peak > 0 else { return 1 }
        let wanted = pow(10, targetRMS / 20) / rms
        let maxGain = pow(10, ceiling / 20) / peak
        return min(wanted, maxGain, 30)   // hoogstens ~30 dB erbij, anders blaas je ruis op
    }

    /// Normaliseert een WAV-bestand op zijn plek (16-bit PCM).
    static func normalize(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try file.read(into: buf)
        let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
        guard n > 0, let data = buf.floatChannelData else { return }
        var sum: Float = 0, peak: Float = 0
        for c in 0..<channels {
            for i in 0..<n { let v = data[c][i]; sum += v * v; peak = max(peak, abs(v)) }
        }
        let rms = sqrt(sum / Float(n * channels))
        let g = gain(rms: rms, peak: peak)
        guard abs(g - 1) > 0.05 else { return }
        for c in 0..<channels { for i in 0..<n { data[c][i] *= g } }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: buf.format.sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buf)
    }
}

/// De ingebouwde macOS-stem, via `AVSpeechSynthesizer`.
@MainActor
final class SystemVoice: Voice {
    var language: Language = .nl {
        didSet { voice = Self.bestVoice(language) }
    }
    private(set) var voice: AVSpeechSynthesisVoice?
    private var synthesizers: [AVSpeechSynthesizer] = []

    init() {
        voice = Self.bestVoice(.nl)
    }

    var name: String {
        guard let v = voice else { return "standaardstem" }
        let q = switch v.quality {
        case .premium: " (premium)"
        case .enhanced: " (verbeterd)"
        default: ""
        }
        return v.name + q
    }

    /// Nederlands: Xander of Claire; Engels: Brits of Amerikaans. Liefst de verbeterde of premium-versie.
    static func bestVoice(_ lang: Language) -> AVSpeechSynthesisVoice? {
        let dutch = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang.rawValue) }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 10
            if ["nl-NL", "en-GB", "en-US"].contains(v.language) { s += 4 }
            if ["Xander", "Claire", "Daniel", "Samantha"].contains(v.name) { s += 2 }
            if v.identifier.contains("super-compact") { s -= 1 }
            return s
        }
        return dutch.max { score($0) < score($1) }
    }

    func render(_ text: String) async throws -> URL {
        let url = AudioFiles.next()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synth = AVSpeechSynthesizer()
        synthesizers.append(synth)   // vasthouden tot hij klaar is
        defer { synthesizers.removeAll { $0 === synth } }

        let writer = BufferWriter(url: url)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.onDone = { cont.resume(with: $0) }
            synth.write(utterance) { writer.append($0) }
        }
        return url
    }
}

/// Schrijft de buffers van `AVSpeechSynthesizer.write` naar een WAV-bestand.
private final class BufferWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var finished = false
    private let lock = NSLock()
    var onDone: ((Result<Void, Error>) -> Void)?

    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            finish(file == nil ? .failure(CocoaError(.fileWriteUnknown)) : .success(()))
            return
        }
        do {
            if file == nil {
                var settings = pcm.format.settings
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                // 16-bit integer: dat speelt elke Sonos af.
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = false
                settings[AVLinearPCMIsNonInterleaved] = false
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        finished = true
        file = nil   // sluit het bestand (schrijft de WAV-header)
        onDone?(result)
        onDone = nil
    }
}

/// Speelt audio af via de Mac-speakers en wacht tot het klaar is.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    func play(_ url: URL) async {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            log.error("Kan \(url.lastPathComponent, privacy: .public) niet afspelen")
            return
        }
        p.delegate = self
        player = p
        await withCheckedContinuation { cont in
            continuation = cont
            if !p.play() { finish() }
        }
    }

    func stop() {
        player?.stop()
        finish()
    }

    private func finish() {
        player = nil
        continuation?.resume()
        continuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated { finish() }
    }
}
