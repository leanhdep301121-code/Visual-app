import Foundation

/// Direct call to Kimi (Moonshot) chat-completions, OpenAI-compatible. No PC
/// server required — pure on-device + cloud LLM. The API key is read from a
/// gitignored `Resources/Secrets.plist` via `SwinConfig.kimiAPIKey`. If absent,
/// `request` throws and the orchestrator falls back to local rule templates.
final class CloudLLMService: @unchecked Sendable {
    let provider: LLMProvider
    let apiKey: String
    let baseURL: URL
    let model: String
    let timeout: TimeInterval

    enum CloudError: Error, LocalizedError {
        case missingAPIKey
        case badStatus(Int, String)
        case decoding(Error)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:    return "No LLM API key configured"
            case .badStatus(let s, let body): return "HTTP \(s): \(body.prefix(200))"
            case .decoding(let e):  return "Decoding failed: \(e.localizedDescription)"
            case .empty:            return "Empty response"
            }
        }
    }

    init(credentials: LLMCredentials? = SwinConfig.llmCredentials,
         timeout: TimeInterval = SwinConfig.timeout) throws
    {
        guard let creds = credentials else { throw CloudError.missingAPIKey }
        self.provider = creds.provider
        self.apiKey = creds.apiKey
        self.baseURL = creds.provider.baseURL
        self.model = creds.provider.defaultModel
        self.timeout = timeout
        print("[CloudLLMService] using \(creds.provider.displayName) (\(self.model))")
    }

    /// Feedback shape — `live` gives a single short cue for voice playback,
    /// `deep` gives the full summary + 1-3 event tips for the upload panel.
    enum Mode: Sendable {
        case live      // ≤25 char single sentence, max_tokens 80, no tips, target <2 s
        case deep      // 100-150 char summary + tips, max_tokens 800, target 3-5 s
    }

    func request(signals: SignalsPayload, mode: Mode = .deep) async throws -> FeedbackResponse {
        try await requestStreaming(signals: signals, mode: mode, onSummaryUpdate: { _ in })
    }

    // MARK: - Session report streaming

    /// Stream a session report. Hands the partial accumulated JSON to the
    /// caller on every token delta so it can extract fields as they fill.
    /// Caller is responsible for falling back to a deterministic report on error.
    func streamSessionReport(
        systemPrompt: String,
        userPrompt: String,
        onPartialJSON: @escaping @Sendable (String) -> Void
    ) async throws {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            "stream": true,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt],
            ],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"),
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in asyncBytes.lines { body += line + "\n" }
            throw CloudError.badStatus(http.statusCode, body)
        }
        var acc = ""
        for try await line in asyncBytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
            else { continue }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                acc += delta
                let snap = acc
                onPartialJSON(snap)
            }
        }
    }

    // MARK: - Coaching-line endpoint (live feedback per swing)

    /// One-shot coaching sentence for the live HUD/TTS. Plain text, no JSON,
    /// no event-tips — just the line the TTS will speak. Targets <2 s first
    /// byte. Caller is responsible for falling back to a local template if
    /// the call times out — see `requestCoachingLineWithFallback` for the
    /// combined helper.
    ///
    /// `directive` and `context` come straight from `SessionCoach`. They give
    /// the LLM everything it needs to talk about streaks ("again — third
    /// time"), praise vs fix, etc., WITHOUT shipping raw pose / metrics.
    func requestCoachingLine(
        directive: CoachingDirective,
        context: CoachingContext,
        onPartial: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        let userText = Self.buildCoachingUserMessage(directive: directive, context: context)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 80,
            "stream": true,
            "messages": [
                ["role": "system", "content": Self.coachingSystemPrompt],
                ["role": "user",   "content": userText],
            ],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"),
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in asyncBytes.lines { body += line + "\n" }
            throw CloudError.badStatus(http.statusCode, body)
        }
        var acc = ""
        for try await line in asyncBytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
            else { continue }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                acc += delta
                let snap = acc
                await MainActor.run { onPartial(snap) }
            }
        }
        return acc.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wrapper: tries the LLM with a wall-clock deadline. If the first
    /// streamed token doesn't arrive within `firstByteDeadlineSeconds`, the
    /// task is cancelled and the fallback string is returned instead.
    ///
    /// This is the function the live-coach pipeline should call: the
    /// guarantee is "we will return *something* within roughly the deadline".
    func requestCoachingLineWithFallback(
        directive: CoachingDirective,
        context: CoachingContext,
        fallback: String,
        firstByteDeadlineSeconds: Double = 2.0,
        onPartial: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> String {
        // We race: (a) the streaming LLM call; (b) a deadline timer.
        // First first-byte that the call produces cancels the timer.
        let llmTask = Task<String, Error> {
            try await requestCoachingLine(directive: directive, context: context, onPartial: onPartial)
        }
        let deadline = Task<Void, Error> {
            try await Task.sleep(for: .seconds(firstByteDeadlineSeconds))
        }
        // Wait for either: LLM finishes, OR deadline fires.
        // Simplification: race using a continuation that resolves first.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { (try? await llmTask.value) }
            group.addTask {
                _ = try? await deadline.value
                llmTask.cancel()
                return nil
            }
            for await result in group {
                if let r = result, !r.isEmpty {
                    deadline.cancel()
                    group.cancelAll()
                    return r
                }
            }
            return fallback
        }
    }

    /// Streaming variant. `onSummaryUpdate` is called on the main actor with a
    /// progressively-extending summary string as tokens come back over SSE.
    /// Returns the final structured FeedbackResponse once the stream ends.
    /// LLM as a PURE POLISHER, not a diagnostician. Given the faults the
    /// rule-based engine already detected + ranked, it just phrases the root
    /// cause as warm, plain-English coaching. It must NOT emit numbers/degrees
    /// or invent measurements — that's what produced "X-factor is 11.6°,
    /// should be ~90°" garbage when we fed it raw metrics. Returns the summary
    /// string only; the caller builds tips deterministically from the faults.
    private static var qualitativeSystemPrompt: String {
        let langLine = prefersChinese
            ? "Write the summary in natural spoken Simplified Chinese (简体中文), addressing the student as \"你\"."
            : "Write the summary in natural spoken English, addressing the student as \"you\"."
        return """
    You are a warm, encouraging golf coach talking to an AMATEUR golfer. The
    app's analysis engine has ALREADY diagnosed, ranked, and linked the swing
    problems for you. Each line is tagged: severity (minor/noticeable/
    significant), causal role (root cause / contributing factor / symptom),
    sometimes "tentative" (low confidence), and sometimes "likely caused by
    <X>" (the causal chain). You do NOT diagnose or measure — you explain and
    encourage, using this structure.

    Write a VERY SHORT coach summary — 2 sentences, ~35 words MAX. Brevity is
    critical; the full problem list is shown separately, so do NOT enumerate.
    - Sentence 1: the #1 root cause in plain words + the one feel/fix.
    - Sentence 2 (optional): one word of encouragement, or tie in a symptom it
      causes ("which is also folding your arm"). Nothing more.
    - NO numbers, degrees, or jargon (never "X-factor", never "should be 90°").
    - Skip tentative findings. If the swing is clean, one short compliment.
    \(langLine)
    Output JSON only: {"summary": "<text>"}
    """
    }

    func requestQualitativeSummary(
        faultDescriptions: [String],
        onSummaryUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let list = faultDescriptions.isEmpty
            ? "The swing is clean — no significant problems were found."
            : faultDescriptions.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let userText = """
        Diagnosed swing problems, most-important-first:
        \(list)

        Write the coach summary per the system prompt. Output JSON {"summary":"..."}.
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 110,
            "stream": true,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Self.qualitativeSystemPrompt],
                ["role": "user", "content": userText],
            ],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"),
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var b = ""; for try await line in asyncBytes.lines { b += line + "\n" }
            throw CloudError.badStatus(http.statusCode, b)
        }
        var accumulated = "", lastEmitted = ""
        for try await line in asyncBytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
            else { continue }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                accumulated += delta
                if let s = Self.extractPartialSummary(from: accumulated), s != lastEmitted {
                    lastEmitted = s
                    let snap = s
                    await MainActor.run { onSummaryUpdate(snap) }
                }
            }
        }
        guard !accumulated.isEmpty else { throw CloudError.empty }
        return Self.extractPartialSummary(from: accumulated) ?? accumulated
    }

    func requestStreaming(
        signals: SignalsPayload,
        mode: Mode = .deep,
        onSummaryUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> FeedbackResponse {
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        let payloadData = (try? payloadEncoder.encode(signals)) ?? Data("{}".utf8)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"

        let userText = """
        2D swing signals (8 events × joint angles):
        \(payloadJSON)

        Notes: elbow/knee values are interior angles (180° = straight).
        spineTilt = forward spine tilt at Address. xFactor = shoulder turn − hip turn at Top.
        Output strictly as the JSON schema in the system prompt.
        """
        let systemPrompt = (mode == .live) ? Self.liveSystemPrompt : Self.deepSystemPrompt
        let maxTokens = (mode == .live) ? 80 : 800
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userText],
            ],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"),
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in asyncBytes.lines { body += line + "\n" }
            throw CloudError.badStatus(http.statusCode, body)
        }

        var accumulated = ""
        var lastSummaryEmitted = ""
        for try await line in asyncBytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
            else { continue }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                accumulated += delta
                if let partialSummary = Self.extractPartialSummary(from: accumulated),
                   partialSummary != lastSummaryEmitted
                {
                    lastSummaryEmitted = partialSummary
                    let snapshot = partialSummary
                    await MainActor.run { onSummaryUpdate(snapshot) }
                }
            }
        }

        guard !accumulated.isEmpty else { throw CloudError.empty }
        if let parsed = Self.parseStructured(accumulated) {
            return FeedbackResponse(
                summary: parsed.summary,
                eventTips: (parsed.eventTips ?? []).map(\.toTip),
                source: .cloud
            )
        }
        // Final fallback: parse failed entirely. Try to at least pull the summary
        // out of the raw text so the UI doesn't show JSON markup.
        print("[CloudLLM] JSON parse failed; first 300 chars of raw: \(accumulated.prefix(300))")
        let cleanSummary = Self.extractPartialSummary(from: accumulated) ?? accumulated
        return FeedbackResponse(summary: cleanSummary, eventTips: [], source: .cloud)
    }

    /// While streaming, extract the partial `"summary": "..."` text from
    /// in-progress JSON so we can show the user text as it arrives.
    private static func extractPartialSummary(from raw: String) -> String? {
        guard let key = raw.range(of: "\"summary\"") else { return nil }
        // skip "summary":
        var i = key.upperBound
        while i < raw.endIndex, raw[i] != "\"" {
            if raw[i] == "{" || raw[i] == "[" { return nil }
            i = raw.index(after: i)
        }
        guard i < raw.endIndex else { return nil }
        i = raw.index(after: i)   // skip opening quote
        var out = ""
        var escape = false
        while i < raw.endIndex {
            let c = raw[i]
            if escape {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(c)
                }
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                return out             // closing quote — done
            } else {
                out.append(c)
            }
            i = raw.index(after: i)
        }
        return out                      // still streaming, return what we have
    }

    /// Parse structured JSON tolerantly. Tries (1) raw text, (2) text with code
    /// fence stripped, (3) substring between the first `{` and last `}`.
    private static func parseStructured(_ raw: String) -> LLMResponseJSON? {
        let dec = JSONDecoder()

        let candidates: [String] = [
            raw,
            stripCodeFence(raw),
            substringBetweenBraces(raw) ?? "",
        ]
        for c in candidates {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let parsed = try? dec.decode(LLMResponseJSON.self, from: data)
            else { continue }
            return parsed
        }
        return nil
    }

    private static func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func substringBetweenBraces(_ s: String) -> String? {
        guard let first = s.firstIndex(of: "{"),
              let last  = s.lastIndex(of: "}"),
              first < last
        else { return nil }
        return String(s[first...last])
    }

    // MARK: - prompt + payload shaping (mirrors PC `swing_analyze/feedback.py`)

    /// 输出语言跟随 app 当前界面语言：中文环境→中文，其它（海外）→英文。
    /// 用 preferredLocalizations（实际加载的 .lproj），与界面文案一致。
    private static var prefersChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }

    /// Upload-mode deep analysis. Full summary + structured event tips for UI cards.
    private static var deepSystemPrompt: String {
        let lang = prefersChinese
            ? "Simplified Chinese (简体中文). Address the student as \"你\""
            : "natural, spoken English. Address the student as \"you\""
        let unreadable = prefersChinese ? "这一杆没看清楚" : "Couldn't read this swing clearly."
        return """
        You are a PGA golf coach. Based on 2D pose data (8 swing events × 8 joint angles),
        output strict JSON. ALL human-readable text values (summary, tip, fix) MUST be in
        \(lang). Be practical, no jargon dump:

        {
          "summary": "2-3 sentences (~50-80 words). First name the most critical issue with the actual numbers and which event it shows up at. Then give one immediately-executable adjustment.",
          "event_tips": [
            {"event": "<event name>", "metric": "x_factor|spine_tilt|shoulder_tilt|hip_tilt|lead_elbow|trail_elbow|lead_knee|trail_knee", "tip": "≤14 words including the number — what's wrong", "fix": "≤14 words — exactly what to do next swing"}
          ]
        }

        1-3 event_tips ranked by importance. tip.metric must be one of the 8 listed values
        (frontend highlights the matching joint). If signals look noisy / incomplete, summary
        should say "\(unreadable)" and leave event_tips empty.
        """
    }

    // MARK: - Coaching prompt (live per-swing path used by SessionCoach)

    /// Short, fixed system prompt. Mostly tells the model: ONE short English
    /// sentence, no formatting, no apology, no JSON. Directive-specific
    /// wording lives in `buildCoachingUserMessage`.
    private static var coachingSystemPrompt: String {
        let langLine = prefersChinese
            ? "Reply with a single Simplified Chinese (简体中文) sentence, ≤20 Chinese characters, plain text only — no JSON, no quotes, no markdown, no greetings. ALWAYS respond in Chinese."
            : "Reply with a single English sentence, ≤16 words, plain text only — no JSON, no quotes, no markdown, no greetings. ALWAYS respond in English."
        let you = prefersChinese ? "你" : "you"
        return """
    You are a golf coach speaking ONE short line to a student who just hit a swing. \(langLine)

    Tone: warm, encouraging, like a supportive coach courtside. Use "\(you)". No jargon dump.
    ALWAYS stay positive and patient — never sound impatient, critical, or harsh,
    ESPECIALLY when the same issue repeats. If something keeps happening, that's a
    cue to reassure and re-explain more simply, NOT to scold.

    Match the tone to the `directive`:
      - goodOne / goodStreak: praise briefly, name what worked if possible
      - fixOne: name the issue + give ONE specific action for next swing, kindly
      - focusLocked / focusReinforce: acknowledge it's repeating ("again"/"still") + the same fix, but stay upbeat and encouraging — open with a touch of reassurance
      - focusStuck: they've tried several times without success and may be frustrated. Reassure FIRST ("no worries, this one's tricky"), then give an EASY analogy or simple drill feel from fix_hint. Light and supportive — never "you're still doing it wrong".
      - focusBestEffort: they IMPROVED this and plateaued at their personal best. Warmly acknowledge the progress and tell them to move on — do NOT give another correction or imply they failed. People have different bodies; this is good enough for now.
      - focusReleased: celebrate, tell them to stay there

    Never invent metrics. Only cite numbers that appear in the user message.
    """
    }

    /// Compose a tiny user message from the structured directive + context.
    /// Stays under ~200 tokens by construction.
    private static func buildCoachingUserMessage(
        directive: CoachingDirective,
        context: CoachingContext
    ) -> String {
        var lines: [String] = []
        lines.append("directive: \(directiveKind(directive))")
        lines.append("swing_number: \(context.swingNumber)")
        lines.append("score: \(context.currentScore)")
        if !context.currentFaults.isEmpty {
            lines.append("faults: [\(context.currentFaults.joined(separator: ", "))]")
        }
        if let pf = context.primaryFault { lines.append("primary_fault: \(pf)") }
        if !context.faultStreak.isEmpty {
            let pairs = context.faultStreak
                .filter { $0.value > 0 }
                .sorted(by: { $0.value > $1.value })
                .map { "\($0.key)=\($0.value)" }
            lines.append("fault_streak: { \(pairs.joined(separator: ", ")) }")
        }
        if context.goodStreak > 0 { lines.append("good_streak: \(context.goodStreak)") }
        if let f = context.focusedFault { lines.append("focused_fault: \(f)") }
        if !context.last3Scores.isEmpty {
            lines.append("last_3_scores: \(context.last3Scores)")
        }
        lines.append("session_avg: \(Int(context.sessionAvgScore.rounded()))")

        // Add a concrete fix hint based on directive (gives the LLM a strong seed
        // without forcing the words).
        switch directive {
        case .fixOne(let fault, _),
             .focusLocked(let fault, _),
             .focusReinforce(let fault, _):
            lines.append("fix_hint: \"\(fault.fix)\"")
        case .focusStuck(let fault):
            // Student is stuck + likely frustrated. Steer the model toward an
            // easy analogy / drill feel and explicit reassurance — NOT another
            // repeat of the same correction in a firmer tone.
            let drill = DrillLibrary.drill(for: fault)?.howTo ?? fault.fix
            lines.append("fix_hint: \"\(drill)\"")
            lines.append("note: \"they've tried this several times without success — reassure them, keep it light, give an easy feel/analogy, do NOT sound impatient\"")
        case .focusImproving(let fault, _):
            // Improvement signal: lean praise but still nudge the fault.
            lines.append("fix_hint: \"praise improvement, then nudge: \(fault.label)\"")
        case .focusReleased(let fault, _):
            lines.append("fix_hint: \"resolved: \(fault.label)\"")
        case .focusBestEffort(let fault):
            lines.append("fix_hint: \"praise the improvement on \(fault.label); this is their best for now; tell them to move on, no correction\"")
            lines.append("note: \"they improved this from where they started and plateaued — acknowledge their effort warmly and move on, do NOT give another fix\"")
        default: break
        }
        return lines.joined(separator: "\n")
    }

    private static func directiveKind(_ d: CoachingDirective) -> String {
        switch d {
        case .skipUnreadable:        return "skipUnreadable"
        case .firstSwingNeutral:     return "firstSwingNeutral"
        case .goodOne:               return "goodOne"
        case .goodStreak:            return "goodStreak"
        case .fixOne:                return "fixOne"
        case .focusLocked:           return "focusLocked"
        case .focusReinforce:        return "focusReinforce"
        case .focusStuck:            return "focusStuck"
        case .focusBestEffort:       return "focusBestEffort"
        case .focusImproving:        return "focusImproving"
        case .focusWaiting:          return "focusWaiting"
        case .focusReleased:         return "focusReleased"
        case .neutralProgress:       return "neutralProgress"
        }
    }

    /// Live-mode voice cue. ONE short sentence for TTS immediately after a swing.
    /// Optimized for speed + spoken delivery — read aloud, no punctuation pauses, no jargon.
    private static var liveSystemPrompt: String {
        let limit = prefersChinese ? "≤20 Chinese characters" : "≤16 words"
        let langLine = prefersChinese
            ? "The sentence MUST be in spoken Simplified Chinese (简体中文), no jargon, no greetings, no apologies."
            : "The sentence MUST be in spoken English, no jargon, no greetings, no apologies."
        let jsonHint = prefersChinese
            ? "{\"summary\": \"<一句话，≤20 个汉字，简体中文>\"}"
            : "{\"summary\": \"<one short spoken English sentence, ≤16 words>\"}"
        return """
        You are a golf coach. The student just finished one swing — you have time for exactly
        ONE short spoken sentence (\(limit)). Look at the 8 events and joint angles,
        name the single biggest issue (you may quote a number), then give one micro-adjustment
        to try next swing. \(langLine)

        Output JSON: \(jsonHint)
        """
    }

    private static func buildMetricsPayload(_ signals: SignalsPayload) -> [String: Any] {
        var summary: [String: [String: Double]] = [:]
        if let m = signals.metrics {
            summary["Top"] = [
                "x_factor_deg": m.xFactor,
                "shoulder_tilt_deg": m.shoulderTurn,
                "hip_tilt_deg": m.hipTurn,
            ]
            summary["Address"] = ["spine_tilt_deg": m.spineTilt]
            summary["Impact"] = ["tempo_ratio": m.tempoRatio]
        }
        return [
            "summary": summary,
            "events": signals.events,
            "handedness": signals.handedness,
            "fps": signals.captureFrameRate,
            "total_frames": signals.totalFrames,
        ]
    }

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - response decoding

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
    }
    struct Message: Decodable {
        let content: String?
        let reasoningContent: String?
        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }
}

/// SSE chunk: data: { choices: [{delta: {content: "..."}}] }
private struct StreamChunk: Decodable {
    let choices: [StreamChoice]
}
private struct StreamChoice: Decodable {
    let delta: StreamDelta
}
private struct StreamDelta: Decodable {
    let content: String?
}

/// The structured JSON the system prompt asks the LLM to produce. All optional
/// to tolerate schema variation across providers and trimmed prompts.
private struct LLMResponseJSON: Decodable {
    let summary: String
    let eventTips: [LLMTipJSON]?
    enum CodingKeys: String, CodingKey {
        case summary
        case eventTips = "event_tips"
    }
}

private struct LLMTipJSON: Decodable {
    let event: String?
    let metric: String?
    let userFrame: Int?
    let tip: String?
    let cause: String?
    let fix: String?
    let drill: String?
    enum CodingKeys: String, CodingKey {
        case event, metric, tip, cause, fix, drill
        case userFrame = "user_frame"
    }
    var toTip: FeedbackTip {
        FeedbackTip(
            event: event,
            userFrame: userFrame,
            metric: metric,
            tip: tip ?? fix ?? "",
            cause: cause ?? "",
            fix: fix ?? "",
            drill: drill
        )
    }
}
