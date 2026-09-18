import Foundation

/// Which OpenAI-compatible chat-completions provider to call. Both expose the
/// same Bearer-auth + `chat/completions` shape, just different base URL + model.
enum LLMProvider: Sendable {
    case deepSeek
    case kimi

    var baseURL: URL {
        switch self {
        case .deepSeek: return URL(string: "https://api.deepseek.com/v1")!
        case .kimi:     return URL(string: "https://api.moonshot.cn/v1")!
        }
    }

    var defaultModel: String {
        switch self {
        // `deepseek-chat` skips reasoning_content generation → 3-5 s end-to-end
        // vs ~17 s for `deepseek-v4-flash` (which does reasoning before content).
        // Quality is fine for our prompt; reasoning isn't needed.
        case .deepSeek: return "deepseek-chat"
        case .kimi:     return "kimi-latest"
        }
    }

    var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .kimi:     return "Kimi"
        }
    }
}

struct LLMCredentials: Sendable {
    let provider: LLMProvider
    let apiKey: String
}

/// Centralized config + secret access. Picks a working provider in priority
/// order (DeepSeek → Kimi) based on which key is filled in `Secrets.plist`.
enum SwinConfig {
    static var llmCredentials: LLMCredentials? {
        let dict = bundledSecretsDict()

        if let key = dict["DEEPSEEK_API_KEY"] as? String,
           !key.isEmpty, !key.hasPrefix("PASTE")
        {
            return LLMCredentials(provider: .deepSeek, apiKey: key)
        }
        if let key = dict["KIMI_API_KEY"] as? String,
           !key.isEmpty, !key.hasPrefix("PASTE")
        {
            return LLMCredentials(provider: .kimi, apiKey: key)
        }

        // Fallback: maybe the key is set as an Info.plist key (xcconfig)
        if let key = Bundle.main.object(forInfoDictionaryKey: "DEEPSEEK_API_KEY") as? String,
           !key.isEmpty, key != "$(DEEPSEEK_API_KEY)"
        {
            return LLMCredentials(provider: .deepSeek, apiKey: key)
        }
        if let key = Bundle.main.object(forInfoDictionaryKey: "KIMI_API_KEY") as? String,
           !key.isEmpty, key != "$(KIMI_API_KEY)"
        {
            return LLMCredentials(provider: .kimi, apiKey: key)
        }

        if dict.isEmpty {
            print("[SwinConfig] Secrets.plist NOT in bundle. Bundle: \(Bundle.main.bundlePath)")
            let plists = Bundle.main.paths(forResourcesOfType: "plist", inDirectory: nil)
            print("[SwinConfig] .plist files actually in bundle: \(plists.map { ($0 as NSString).lastPathComponent })")
        } else {
            print("[SwinConfig] Secrets.plist found but no provider key set (DEEPSEEK_API_KEY / KIMI_API_KEY both empty)")
        }
        return nil
    }

    /// DeepSeek v4 flash with reasoning + JSON mode + our per-event payload
    /// can take 15–30 s. 60 is comfortable headroom.
    static let timeout: TimeInterval = 60

    // MARK: - ElevenLabs TTS

    struct ElevenLabsConfig: Sendable {
        let apiKey: String
        let voiceID: String
        let modelID: String
        /// Per-voice expressiveness + pacing from the curated voice list.
        var style: Double = 0.0
        var speed: Double = 1.0
    }

    /// Builds the ElevenLabs config from: API key (Secrets.plist) + the user's
    /// chosen coach voice (`CoachVoice.selected`, persisted in UserDefaults).
    /// Returns nil only when no API key is set — then TTS falls back to AVSpeech.
    static var elevenLabs: ElevenLabsConfig? {
        let dict = bundledSecretsDict()
        guard let key = dict["ELEVENLABS_API_KEY"] as? String,
              !key.isEmpty, !key.hasPrefix("PASTE")
        else { return nil }
        // The user-selected coach voice (or the catalog default, Kevin, when
        // they haven't picked one yet) fully defines voice/model/style/speed.
        let v = CoachVoice.selected
        return ElevenLabsConfig(apiKey: key, voiceID: v.id, modelID: v.modelID,
                                style: v.style, speed: v.speed)
    }

    private static func bundledSecretsDict() -> [AnyHashable: Any] {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [AnyHashable: Any]
        else { return [:] }
        return dict
    }
}
