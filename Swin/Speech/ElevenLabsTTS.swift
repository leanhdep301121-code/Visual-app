import AVFoundation
import Foundation

/// ElevenLabs cloud TTS — POSTs text to /v1/text-to-speech/{voice}/stream,
/// receives MP3 audio bytes, decodes via AVAudioPlayer.
///
/// Use as a backend behind `TTSService`. If `SwinConfig.elevenLabs` is nil,
/// `TTSService` falls back to AVSpeech.
final class ElevenLabsTTS: NSObject, @unchecked Sendable {
    /// Mutable so the user can switch coach voice at runtime without rebuilding
    /// the whole TTS stack. Guarded by `configLock` since `speak()` reads it
    /// from a background Task.
    private var config: SwinConfig.ElevenLabsConfig
    private let configLock = NSLock()
    private let session: URLSession
    private var player: AVAudioPlayer?
    private var currentRequestID: UUID?

    /// Called on main when playback finishes (success or stopped).
    var onFinished: (() -> Void)?
    /// Called on main when playback starts.
    var onStarted: (() -> Void)?
    /// Called on main when an error occurs.
    var onError: ((Error) -> Void)?

    init(config: SwinConfig.ElevenLabsConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    /// Synthesize + play `text` end-to-end. Replaces any in-flight request.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dbg(tag: "el", "request: \(trimmed.prefix(40))")
        // IMPORTANT: stop() clears currentRequestID. We must call it BEFORE
        // installing the new requestID, otherwise the task we're about to
        // launch will see currentRequestID == nil and immediately drop its
        // result as "superseded". This was the silent-TTS bug.
        stop()
        let reqID = UUID()
        currentRequestID = reqID
        Task { [weak self] in
            guard let self else { return }
            do {
                let mp3 = try await self.synthesize(text: trimmed)
                guard self.currentRequestID == reqID else {
                    dbg(.warn, tag: "el", "superseded — drop result")
                    return
                }
                try self.play(data: mp3)
            } catch {
                dbg(.error, tag: "el", "\(error.localizedDescription)")
                await MainActor.run { self.onError?(error) }
            }
        }
    }

    func stop() {
        currentRequestID = nil
        player?.stop()
        player = nil
    }

    /// Swap the active voice (id / model / style / speed) live. Takes effect on
    /// the next `speak()`.
    func updateConfig(_ newConfig: SwinConfig.ElevenLabsConfig) {
        configLock.lock(); config = newConfig; configLock.unlock()
        dbg(tag: "el", "voice switched → \(newConfig.voiceID)")
    }

    private func snapshotConfig() -> SwinConfig.ElevenLabsConfig {
        configLock.lock(); defer { configLock.unlock() }
        return config
    }

    // MARK: - HTTP

    private func synthesize(text: String) async throws -> Data {
        let cfg = snapshotConfig()
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(cfg.voiceID)/stream?optimize_streaming_latency=3")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        // Per-voice expressiveness comes from the curated voice list via `style`.
        // NB: do NOT send `speed` here. Measured on-device, adding `speed` to
        // voice_settings makes the /stream endpoint ~3–4× slower (first byte
        // 2.8 s vs 0.8 s) — it defeats optimize_streaming_latency. For a
        // real-time post-swing cue that latency is the difference between
        // "instant" and "frozen", and the pacing tweak isn't worth it.
        let body: [String: Any] = [
            "text": text,
            "model_id": cfg.modelID,
            "voice_settings": [
                "stability": 0.45,
                "similarity_boost": 0.75,
                "style": cfg.style,
                "use_speaker_boost": true,
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw NSError(domain: "ElevenLabsTTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"])
        }
        return data
    }

    // MARK: - playback

    private func play(data: Data) throws {
        // IMPORTANT: do NOT re-set the audio session category here.
        // TTSService (our caller) has already acquired a `.playAndRecord`
        // session that's compatible with the AVCaptureSession running for
        // the camera. Switching to `.playback` here used to silently
        // deactivate playback when capture was holding a mic — that's why
        // TTS never made any sound on the live tab.
        dbg(tag: "el", "play \(data.count) bytes mp3")
        let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        p.delegate = self
        p.prepareToPlay()
        let ok = p.play()
        dbg(tag: "el", "AVAudioPlayer.play() returned \(ok)")
        DispatchQueue.main.async { self.onStarted?() }
        self.player = p
    }
}

extension ElevenLabsTTS: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinished?() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error { DispatchQueue.main.async { self.onError?(error) } }
    }
}
