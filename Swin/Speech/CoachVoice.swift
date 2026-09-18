import Foundation

/// A selectable coaching voice, curated on ElevenLabs by the coaching expert.
///
/// Each entry carries everything the cloud TTS request needs to reproduce that
/// voice — `id` (ElevenLabs voice ID), `modelID`, and the per-voice `style` /
/// `speed` tuned alongside it. The set + the active selection drive the in-app
/// voice picker; the choice is persisted so it survives relaunches.
struct CoachVoice: Identifiable, Sendable, Equatable {
    enum Gender: String, Sendable { case male = "M", female = "F" }

    let id: String          // ElevenLabs voice ID
    let name: String
    let gender: Gender
    let modelID: String
    let style: Double
    let speed: Double
    /// One-line character note (shown in the picker) from the curation pass.
    let note: String

    /// The curated catalog. Order = display order in the picker.
    static let all: [CoachVoice] = [
        // ---- Calm mentor / encouraging (best fit for the coaching tone) ----
        CoachVoice(id: "1fz2mW1imKTf5Ryjk5su", name: "Kevin", gender: .male,
                   modelID: "eleven_flash_v2_5", style: 0.05, speed: 0.90,
                   note: String(localized: "沉稳导师——平稳，从不严厉")),
        CoachVoice(id: "Wq15xSaY3gWvazBRaGEU", name: "Nathaniel", gender: .male,
                   modelID: "eleven_flash_v2_5", style: 0.10, speed: 0.95,
                   note: String(localized: "踏实、让人安心")),
        CoachVoice(id: "cNYrMw9glwJZXR8RwbuR", name: "Belle", gender: .female,
                   modelID: "eleven_flash_v2_5", style: 0.0, speed: 1.10,
                   note: String(localized: "明快、鼓励型")),
        CoachVoice(id: "h2sm0NbeIZXHBzJOMYcQ", name: "Natasha", gender: .female,
                   modelID: "eleven_flash_v2_5", style: 0.30, speed: 0.90,
                   note: String(localized: "资深老师的语气")),
        // ---- Other curated options ----
        CoachVoice(id: "lcMyyd2HUfFzxdCaC4Ta", name: "Lucy", gender: .female,
                   modelID: "eleven_flash_v2_5", style: 0.15, speed: 0.90,
                   note: String(localized: "沉着专业，带点温度")),
        CoachVoice(id: "kdmDKE6EkgrWrrykO9Qt", name: "Alexandra", gender: .female,
                   modelID: "eleven_flash_v2_5", style: 0.20, speed: 0.95,
                   note: String(localized: "稳重、可信")),
        CoachVoice(id: "ljX1ZrXuDIIRVcmiVSyR", name: "Michael", gender: .male,
                   modelID: "eleven_flash_v2_5", style: 0.30, speed: 0.90,
                   note: String(localized: "教学型，带些温度")),
        CoachVoice(id: "f5HLTX707KIM4SzJYzSz", name: "Brad", gender: .male,
                   modelID: "eleven_flash_v2_5", style: 0.05, speed: 0.85,
                   note: String(localized: "随和、口语化")),
    ]

    /// Default when the user hasn't picked yet — Kevin, the calm mentor voice
    /// that best matches the "encouraging, never harsh" coaching requirement.
    static var defaultVoice: CoachVoice { all[0] }

    static func voice(forID id: String) -> CoachVoice? {
        all.first { $0.id == id }
    }

    // MARK: - persisted selection

    private static let selectedKey = "tts.voiceID"

    /// The user's currently-selected coach voice (or the default).
    static var selected: CoachVoice {
        let id = UserDefaults.standard.string(forKey: selectedKey)
        return id.flatMap(voice(forID:)) ?? defaultVoice
    }

    /// Persist a new selection. The live TTS backend should be refreshed
    /// afterwards (see `TTSService.applySelectedVoice`).
    static func select(_ voice: CoachVoice) {
        UserDefaults.standard.set(voice.id, forKey: selectedKey)
    }
}
