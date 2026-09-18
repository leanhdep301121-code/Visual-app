import AVFoundation
import Observation

/// Unified TTS façade.
///
/// - Prefers ElevenLabs cloud voice when an API key is configured. Falls
///   back to AVSpeech (system voice) for individual chunks on cloud failure.
/// - Audio session is acquired **only while speaking** so that when there's
///   no coach message, other apps (Spotify / Apple Music) retain full volume.
///   The session uses `.duckOthers` so background music drops temporarily
///   during a cue, then we deactivate to restore full volume.
@Observable
final class TTSService: NSObject, @unchecked Sendable {
    private(set) var isSpeaking: Bool = false
    private(set) var backendName: String = "AVSpeech"
    /// User-controlled mute. When true, every `speak()` / `speakStreaming()`
    /// call is a no-op: nothing is queued, nothing is enqueued to ElevenLabs,
    /// and the audio session is never acquired. Persisted across launches via
    /// UserDefaults so the user doesn't have to re-mute every session.
    /// Backed by a stored property (not a computed UserDefaults read) so the
    /// @Observable machinery actually tracks toggles for UI refresh.
    private static let mutedKey = "tts.muted"
    var isMuted: Bool = UserDefaults.standard.bool(forKey: TTSService.mutedKey) {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
            if isMuted { stop() }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let elevenLabs: ElevenLabsTTS?
    private var pendingChunks: [String] = []
    private let chunkLock = NSLock()
    private var sessionActive: Bool = false
    /// Dedicated queue for `AVAudioSession.setCategory` / `setActive` —
    /// both are synchronous audio-system calls that block the caller for
    /// 100ms–1s (worse when another app holds the session). Calling them
    /// on main froze the UI for ~half a second right after Start Session.
    private let sessionQueue = DispatchQueue(label: "tts.session", qos: .userInitiated)
    /// Increments every time we begin a speech burst; lets us detect "the
    /// last chunk finished" robustly even when sentence chunks queue back-to-back.
    private var activeBurstID: Int = 0

    override init() {
        if let cfg = SwinConfig.elevenLabs {
            self.elevenLabs = ElevenLabsTTS(config: cfg)
            super.init()
            self.backendName = "ElevenLabs"
            elevenLabs?.onStarted = { [weak self] in
                DispatchQueue.main.async { self?.isSpeaking = true }
            }
            elevenLabs?.onFinished = { [weak self] in
                guard let self else { return }
                self.playNextChunkIfAny()
            }
            elevenLabs?.onError = { [weak self] err in
                guard let self else { return }
                dbg(.warn, tag: "tts", "ElevenLabs failed → AVSpeech fallback: \(err.localizedDescription)")
                // Take what's in the queue (plus any chunk that was about to play)
                // and run them through AVSpeech.
                self.chunkLock.lock()
                let chunks = self.pendingChunks
                self.pendingChunks = []
                self.chunkLock.unlock()
                if !chunks.isEmpty {
                    for c in chunks { self.speakViaAVSpeech(c) }
                } else {
                    // No queued chunks — last chunk failed; ensure session is released.
                    self.tryRelease()
                }
            }
            dbg(tag: "tts", "backend=ElevenLabs (voice \(cfg.voiceID))")
        } else {
            self.elevenLabs = nil
            super.init()
            dbg(.warn, tag: "tts", "backend=AVSpeech (no ELEVENLABS_API_KEY)")
        }
        synthesizer.delegate = self
    }

    // MARK: - voice selection

    /// Whether a cloud voice is available (API key present). When false the
    /// picker is informational only — playback uses the system voice.
    var cloudVoiceAvailable: Bool { elevenLabs != nil }

    /// The currently-selected coach voice (persisted).
    var currentVoice: CoachVoice { CoachVoice.selected }

    /// Persist + apply a new coach voice and immediately speak a short preview
    /// so the user hears the change. Takes effect on the next coaching line too.
    func selectVoice(_ voice: CoachVoice) {
        CoachVoice.select(voice)
        if let cfg = SwinConfig.elevenLabs { elevenLabs?.updateConfig(cfg) }
        // Preview line. Speak even when muted is OFF only — respect the mute.
        let sample = "Hey, I'm \(voice.name). Let's work on your swing."
        stop()
        speak(sample)
    }

    // MARK: - public API

    /// Speak the whole text as one utterance. Audio-session acquisition runs
    /// on a background queue so the caller (typically main) doesn't block on
    /// `AVAudioSession.setActive`.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isMuted { dbg(tag: "tts", "muted — skip: \(trimmed)"); return }
        dbg(tag: "tts", "speak: \(trimmed)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.acquireSession()
            DispatchQueue.main.async {
                if let el = self.elevenLabs {
                    self.chunkLock.lock(); self.pendingChunks = []; self.chunkLock.unlock()
                    el.speak(trimmed)
                } else {
                    self.speakViaAVSpeech(trimmed)
                }
            }
        }
    }

    /// Stream-friendly: split into sentences and play them in order. Audio-session
    /// setup runs off the main thread for the same reason as `speak()`.
    func speakStreaming(_ text: String) {
        let chunks = splitIntoSentences(text)
        guard !chunks.isEmpty else { return }
        if isMuted { dbg(tag: "tts", "muted — skip streaming (\(chunks.count) chunks)"); return }
        dbg(tag: "tts", "speakStreaming: \(chunks.count) chunk(s)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.acquireSession()
            DispatchQueue.main.async {
                if let el = self.elevenLabs {
                    self.chunkLock.lock()
                    self.pendingChunks.append(contentsOf: chunks)
                    let first = self.pendingChunks.removeFirst()
                    self.chunkLock.unlock()
                    el.speak(first)
                } else {
                    for c in chunks { self.speakViaAVSpeech(c) }
                }
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        elevenLabs?.stop()
        chunkLock.lock(); pendingChunks = []; chunkLock.unlock()
        isSpeaking = false
        releaseSession()
    }

    /// Force-resync internal flags with reality. Called when a new session
    /// starts after the app was backgrounded — iOS may have deactivated
    /// our AVAudioSession behind our back, but `sessionActive` would still
    /// be `true`, so the next `acquireSession()` would early-return and
    /// speech would route through an inactive session (or silently fail
    /// to fire `onFinished`, leaving `isSpeaking` stuck and gating swing
    /// detection forever).
    func resetForNewSession() {
        synthesizer.stopSpeaking(at: .immediate)
        elevenLabs?.stop()
        chunkLock.lock(); pendingChunks = []; chunkLock.unlock()
        DispatchQueue.main.async { self.isSpeaking = false }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Don't bother calling `releaseSession()` here — if iOS already
            // tore it down, `setActive(false)` would throw. Just zero our
            // flag so the next `acquireSession()` re-runs the activation.
            self.sessionActive = false
        }
    }

    // MARK: - audio session lifecycle
    // Audio session is acquired right before speaking and released after.
    // While inactive, other apps retain full audio.

    private func acquireSession() {
        guard !sessionActive else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            // Camera doesn't claim the mic anymore, so we can use plain
            // `.playback` (no record permission needed, no music interruption
            // when nothing is being said). `.duckOthers` softly lowers any
            // background music while the coach talks; `.mixWithOthers` keeps
            // the music app alive in the background.
            try s.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .mixWithOthers]
            )
            try s.setActive(true, options: [])
            sessionActive = true
            dbg(tag: "tts", "session acquired (.playback duck)")
        } catch {
            dbg(.error, tag: "tts", "session acquire failed: \(error.localizedDescription)")
        }
    }

    private func releaseSession() {
        guard sessionActive else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActive = false
            dbg(tag: "tts", "session released")
        } catch {
            dbg(.error, tag: "tts", "session release failed: \(error.localizedDescription)")
        }
    }

    /// Release the session only if no chunks are queued, nothing is playing.
    /// `setActive(false)` blocks too — dispatch it off main so TTS finishing
    /// doesn't drop a frame on the UI thread.
    private func tryRelease() {
        chunkLock.lock(); let queued = pendingChunks.count; chunkLock.unlock()
        guard queued == 0, !synthesizer.isSpeaking else { return }
        DispatchQueue.main.async { self.isSpeaking = false }
        sessionQueue.async { [weak self] in self?.releaseSession() }
    }

    // MARK: - chunked playback (ElevenLabs path)

    private func playNextChunkIfAny() {
        chunkLock.lock()
        let next = pendingChunks.isEmpty ? nil : pendingChunks.removeFirst()
        chunkLock.unlock()
        if let next, let el = elevenLabs {
            el.speak(next)
        } else {
            tryRelease()
        }
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
        var chunks: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if terminators.contains(ch) {
                let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { chunks.append(s) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    // MARK: - AVSpeech fallback

    private func speakViaAVSpeech(_ text: String) {
        acquireSession()
        synthesizer.speak(makeUtterance(text))
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.pitchMultiplier = 1.0
        u.volume = 1.0
        return u
    }

    private var bestVoice: AVSpeechSynthesisVoice? {
        // Prefer an enhanced en-US voice; otherwise system default.
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-US") }
        return en.first(where: { $0.quality == .enhanced })
            ?? en.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = synthesizer.isSpeaking }
        tryRelease()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
        tryRelease()
    }
}
