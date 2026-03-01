//  ClaudeService.swift
//  SceneAssist

import Foundation

final class ClaudeService {

    private let endpoint  = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model     = "claude-haiku-4-5-20251001"
    private let maxTokens = 1024
    private let timeout: TimeInterval = 20

    // MARK: - Vision (scanning) – image → VisionScene

    func analyze(jpegData: Data, language: AppLanguage = .english) async throws -> VisionScene {
        let b64 = jpegData.base64EncodedString()
        let system = """
        You are a vision assistant for a visually impaired user. Analyze the image and respond with ONLY a raw JSON object, no other text, no markdown, no explanation.
        JSON must have exactly this structure:
        {
          "utterances": ["short phrase 1", "short phrase 2"],
          "items": [
            {
              "kind": "PERSON" | "ANIMAL" | "OBJECT" | "SIGN",
              "label": "specific noun e.g. chair, door, person",
              "position": "LEFT" | "CENTER" | "RIGHT",
              "proximity": "FAR" | "NEAR" | "CLOSE",
              "salience_rank": 1,
              "confidence": 0.9,
              "approx_distance_ft": 5.0 or null,
              "utterance": "A chair is to your left, near."
            }
          ],
          "sign_texts": ["EXIT"]
        }
        RULES: Use specific labels (chair, table, door), not "object". At most 3 items, 2 utterances, 1 sign_text. Sort by salience (most visible first). position LEFT/CENTER/RIGHT, proximity FAR/NEAR/CLOSE. Short, calm utterances.
        DISTANCE: Think in STEPS, then set approx_distance_ft so the app can speak that step count. Bands: close = 1–2 steps (approx_distance_ft 3–6), medium = 3–5 steps (8–14 ft), far = 6–8 steps (15–22 ft), very far = 9+ steps (24+ ft). Pick a specific step count (e.g. 4 or 7) and set the matching feet. Do not default to 2 or 3 steps for everything; use 4, 5, 6, 7, 8 when the object is further away.
        LANGUAGE RULE: \(language.claudeInstruction)
        OUTPUT: Raw JSON only. No text before or after the JSON object.
        """
        let userText = "Analyze this scene and return the JSON object only, no markdown or explanation."

        let body = buildMessagesBody(system: system, userText: userText, imageBase64: b64)
        let data = try await performRequest(body: body)

        let raw        = extractTextFromResponse(data: data)
        let jsonString = bestJSONObject(in: raw, containing: "utterances") ?? firstJSONObject(in: raw)

        guard let jsonString = jsonString, !jsonString.isEmpty else {
            throw NSError(domain: "ClaudeVision", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No JSON in response: \(raw.prefix(300))"])
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ClaudeVision", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        do {
            return try JSONDecoder().decode(VisionScene.self, from: jsonData)
        } catch {
            throw NSError(domain: "ClaudeVision", code: 0,
                userInfo: [NSLocalizedDescriptionKey:
                    "Decode failed: \(error.localizedDescription). Preview: \(jsonString.prefix(400))"])
        }
    }

    // MARK: - Q&A with image (single call) – image + question + state → BrainPlan

    func askWithImage(jpegData: Data,
                      userText: String,
                      stateJSON: String,
                      language: AppLanguage = .english) async throws -> BrainPlan {
        let b64 = jpegData.base64EncodedString()
        let system = """
        You are SceneAssist, an AI assistant for a completely blind user navigating indoor environments using their phone camera.

        CORE PRINCIPLES:
        - Be concise. Responses are spoken aloud — avoid long sentences or lists.
        - Prioritize safety. Always mention hazards (steps, obstacles, wet floors, etc.) first.
        - Be spatial. Use clock positions anchored to the user's body and step counts for orientation.
        - Think from the perspective of a completely blind person. They have no visual memory of the current space. Every response should help them build a mental map — where things are, how far, and whether it is safe to move.
        - ⚠️ CRITICAL: ALL RESPONSES MUST BE SPEAKABLE WITHIN 3 SECONDS. THIS IS NON-NEGOTIABLE.
        - ⚠️ CRITICAL: If your response takes longer than 3 seconds to speak aloud, it is WRONG. Shorten the response.
        - ⚠️ CRITICAL: A blind person is walking RIGHT NOW. They cannot wait. 4 seconds maximum. Always.

        TONE & SPEECH STYLE:
        - Speak like a calm, trusted guide walking beside the person — not like a robot reading a list.
        - Use natural pauses by breaking information into short sentences. One idea per sentence.
        - Never dump everything at once. Lead with what matters most RIGHT NOW, then add context.
        - Use natural guiding language, for example:
          - "There's a door to your left, at 9 o'clock, about 3 steps away."
          - "Watch out — there's a step down just in front of you."
          - "All clear ahead. You can walk forward safely."
          - "Looks like a waiting area. Chairs to your left, a reception desk straight ahead."
        - Acknowledge the user's situation naturally when needed (e.g., "You seem to be near the entrance.").
        - If nothing notable is visible, reassure them (e.g., "The space ahead looks clear. Keep going.").

        SPEECH PACING:
        - Never combine two separate observations into one sentence.
        - Each observation must be its own sentence with a clear pause after it.
        - In the 'say' field, use " ... " to indicate a natural pause between sentences, for example:
          - "Door to your left, at 9 o'clock, about 3 steps. ... Chair straight ahead at 12 o'clock, 2 steps away. ... Path to your right is clear."
        - Hazard alerts must always be a standalone sentence, never combined with anything else:
          - "Watch out. ... Step down, straight ahead."
          - NOT: "Watch out there is a step down ahead and a door to your left."

        SPATIAL ORIENTATION RULES:
        - Always use the user's body as the reference point:
          - 12 o'clock = directly ahead of you
          - 3 o'clock = to your right
          - 9 o'clock = to your left
          - 6 o'clock = directly behind you
        - EVERY object, person, or hazard you mention MUST have a clock position. No exceptions.
          - Do NOT say "There is a chair nearby."
          - Do NOT say "A door is ahead."
          - ALWAYS say "Chair to your left, at 9 o'clock, about 2 steps."
          - ALWAYS say "Door straight ahead, at 12 o'clock, about 4 steps."
        - If you are unsure of the clock position, make your best estimate. Never skip it.
        - Always anchor clock position with a body-relative word first, then the clock position:
          - "Chair to your left, at 9 o'clock."
          - "Person straight ahead, at 12 o'clock."
        - Never use clock position alone without a body-relative word (left, right, ahead, behind).
        - Always pair clock position with a step count so the user knows both direction AND distance.

        DISTANCE & STEPS — MANDATORY:
        - The app may send distance_candidates in APP_STATE_JSON. Each entry has label, position, approx_feet, approx_steps.
        - When distance_candidates is present, you MUST use the exact approx_steps for every object you mention. Do not default to 2 or 3 steps; use the number from the data.
        - WRONG: "A door is ahead" (no steps). WRONG: "About 2 steps" when the data says approx_steps is 7.
        - RIGHT: "There is a door 7 steps ahead." RIGHT: "A chair to your left, about 6 steps away."
        - Use varied step counts (4, 5, 6, 7, 8 steps) in your responses when the data provides them. Never always say "2 steps" or "3 steps" for every object.
        - If distance_candidates is missing, estimate steps using: close = 1–2 steps, medium = 3–5 steps, far = 6–8 steps, very far = 9+ steps, and say that number explicitly.

        SCENE DESCRIPTION:
        - As soon as something is visible, describe it immediately using clock position and steps.
        - Lead with the most prominent object or hazard in view.
        - Include any visible signage or text (signs, labels, door names) — this is critical for navigation.
        - Use simple, confident language. Avoid hedging unless genuinely uncertain.
        - When multiple objects are visible, do NOT list them all. Instead:
          - Mention the most important object or hazard first.
          - Then describe up to 2 nearby objects using clock positions and step counts.
          - If a path is clear, say so explicitly (e.g., "Path ahead is clear for about 5 steps.").

        PEOPLE & ACTIONS:
        - If a person is visible, always mention them first before objects — people are unpredictable and the user must be aware.
        - You MUST always describe what the person is doing. Never just say "there is a person" or "someone is standing there." That is not enough information.
          - Do NOT say "There is a person to your right."
          - Do NOT say "Someone is standing ahead."
          - ALWAYS say "A person to your right, at 3 o'clock, is opening a door."
          - ALWAYS say "Someone straight ahead, at 12 o'clock, is waving at you."
          - ALWAYS say "A person to your left, at 9 o'clock, is sitting and talking on a phone."
        - Describe the action in simple present tense. Be specific:
          - Movement: walking toward you, walking away, rushing, turning around
          - Gestures: waving, pointing, raising hand
          - Interactions: opening a door, pressing a button, picking something up, pushing a cart
          - Stationary: sitting, standing, leaning against a wall, waiting
        - If you cannot clearly tell what the person is doing, say your best guess with low confidence:
          - "Someone to your right, at 3 o'clock, appears to be reaching for something."
          - "A person ahead, at 12 o'clock, seems to be waiting."
        - If a person is moving toward the user, always flag it as a priority:
          - "Someone is walking toward you — about 3 steps away. ... Be aware."
        - If multiple people are visible, mention the closest one first.

        ACTIONS — respond with the correct action type when triggered:
        | Trigger | Action |
        |---|---|
        | User asks to remember or retrieve something | ANSWER_FROM_MEMORY (include memoryKey) |
        | User says "set target [X]" or similar | SET_TARGET (include target="X") |
        | User asks to repeat | REPEAT_LAST |
        | All responses | Always populate 'say' with the spoken response |

        Respond with ONLY a raw JSON object, no other text, no markdown, no explanation:
        {"say": "One short sentence to speak aloud.", "action": "NONE"|"REPEAT_LAST"|"SET_TARGET"|"ANSWER_FROM_MEMORY"|"CLEAR_TRANSCRIPTS", "target": null or "string", "memoryKey": null or "string"}
        - say: always fill with what should be spoken aloud.
        - action: NONE usually; REPEAT_LAST if user wants to hear last thing again; SET_TARGET if user sets a target; ANSWER_FROM_MEMORY for memory; CLEAR_TRANSCRIPTS to clear.
        - target: use with SET_TARGET (e.g. "door"). null otherwise.
        - memoryKey: use with ANSWER_FROM_MEMORY. null otherwise.
        For distance/steps: use APP_STATE_JSON.distance_candidates when present (use exact approx_steps per object). When absent, estimate with step bands (close 1–2, medium 3–5, far 6–8, very far 9+).
        LANGUAGE RULE: \(language.claudeInstruction)
        OUTPUT: Raw JSON only. No text before or after the JSON object.
        """
        let userMessage = """
        USER: \(userText)

        APP_STATE_JSON (context from the app):
        \(stateJSON)

        Reply with only the JSON object (say, action, target, memoryKey).
        """

        let body = buildMessagesBody(system: system, userText: userMessage, imageBase64: b64)
        let data = try await performRequest(body: body)

        let raw        = extractTextFromResponse(data: data)
        let jsonString = bestJSONObject(in: raw, containing: "say") ?? firstJSONObject(in: raw)

        guard let jsonString = jsonString, !jsonString.isEmpty else {
            throw NSError(domain: "ClaudeBrain", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No JSON in response: \(raw.prefix(300))"])
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ClaudeBrain", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        do {
            return try JSONDecoder().decode(BrainPlan.self, from: jsonData)
        } catch {
            throw NSError(domain: "ClaudeBrain", code: 0,
                userInfo: [NSLocalizedDescriptionKey:
                    "Decode failed: \(error.localizedDescription). Preview: \(jsonString.prefix(400))"])
        }
    }
    
    func askWithPerception(userText: String,
                           perceptionJSON: String,
                           stateJSON: String,
                           language: AppLanguage = .english) async throws -> BrainPlan {

        let system = """
        You are SceneAssist, an AI assistant for a completely blind user navigating indoor environments.

        You will NOT receive an image.
        You will receive VISION_JSON derived from on-device detectors, normalized by another model.
        Treat VISION_JSON as your scene context.

        - Be concise (<= ~3 seconds spoken).
        - Safety first.
        - Give actionable guidance.

        Output ONLY a raw JSON object:
        {"say":"...","action":"NONE"|"REPEAT_LAST"|"SET_TARGET"|"ANSWER_FROM_MEMORY"|"CLEAR_TRANSCRIPTS","target":null or "string","memoryKey":null or "string"}

        LANGUAGE RULE: \(language.claudeInstruction)
        OUTPUT: Raw JSON only.
        """

        let userMessage = """
        USER: \(userText)

        VISION_JSON:
        \(perceptionJSON)

        APP_STATE_JSON:
        \(stateJSON)

        Reply with only the JSON object.
        """

        let body = buildMessagesBodyTextOnly(system: system, userText: userMessage)
        let data = try await performRequest(body: body)

        let raw        = extractTextFromResponse(data: data)
        let jsonString = bestJSONObject(in: raw, containing: "say") ?? firstJSONObject(in: raw)

        guard let jsonString = jsonString, !jsonString.isEmpty else {
            throw NSError(domain: "ClaudeBrain", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No JSON in response: \(raw.prefix(300))"])
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ClaudeBrain", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        return try JSONDecoder().decode(BrainPlan.self, from: jsonData)
    }

    // MARK: - Request helpers

    private func buildMessagesBody(system: String,
                                   userText: String,
                                   imageBase64: String) -> [String: Any] {
        let content: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type":       "base64",
                    "media_type": "image/jpeg",
                    "data":       imageBase64
                ] as [String: Any]
            ],
            ["type": "text", "text": userText]
        ]
        return [
            "model":      model,
            "max_tokens": maxTokens,
            "system":     system,
            "messages":   [["role": "user", "content": content]]
        ] as [String: Any]
    }
    
    private func buildMessagesBodyTextOnly(system: String,
                                          userText: String) -> [String: Any] {
        let content: [[String: Any]] = [
            ["type": "text", "text": userText]
        ]
        return [
            "model":      model,
            "max_tokens": maxTokens,
            "system":     system,
            "messages":   [["role": "user", "content": content]]
        ] as [String: Any]
    }

    private func performRequest(body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod      = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.anthropicApiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Claude", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("❌ Claude HTTP \(http.statusCode): \(bodyStr)")
            throw NSError(domain: "Claude", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr)"])
        }
        return data
    }

    private func extractTextFromResponse(data: Data) -> String {
        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }
        struct MessagesResponse: Decodable {
            let content: [ContentBlock]?
        }
        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data),
              let blocks  = decoded.content, !blocks.isEmpty else { return "" }
        return blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined()
    }

    private func firstJSONObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{"      { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(s[start...i]) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private func bestJSONObject(in s: String, containing substring: String) -> String? {
        var fallback: String?
        var idx = s.startIndex
        while idx < s.endIndex {
            guard let start = s[idx...].firstIndex(of: "{") else { break }
            var depth = 0
            var i = start
            while i < s.endIndex {
                let ch = s[i]
                if ch == "{"      { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(s[start...i])
                        if candidate.contains(substring) { return candidate }
                        if fallback == nil { fallback = candidate }
                        idx = s.index(after: i)
                        break
                    }
                }
                i = s.index(after: i)
            }
            if i >= s.endIndex { break }
        }
        return fallback
    }
}





////  ClaudeService.swift
////  SceneAssist
//
//import Foundation
//
//final class ClaudeService {
//
//    private let endpoint  = URL(string: "https://api.anthropic.com/v1/messages")!
//    private let model     = "claude-haiku-4-5-20251001"
//    private let maxTokens = 1024
//    private let timeout: TimeInterval = 20
//
//    // MARK: - Vision (scanning) – image → VisionScene
//
//    func analyze(jpegData: Data, language: AppLanguage = .english) async throws -> VisionScene {
//        let b64 = jpegData.base64EncodedString()
//        let system = """
//        \(language.claudeInstruction)
//        You are a vision assistant for a visually impaired user. Analyze the image and respond with ONLY a single JSON object, no other text.
//        JSON must have exactly this structure:
//        {
//          "utterances": ["short phrase 1", "short phrase 2"],
//          "items": [
//            {
//              "kind": "PERSON" | "ANIMAL" | "OBJECT" | "SIGN",
//              "label": "specific noun e.g. chair, door, person",
//              "position": "LEFT" | "CENTER" | "RIGHT",
//              "proximity": "FAR" | "NEAR" | "CLOSE",
//              "salience_rank": 1,
//              "confidence": 0.9,
//              "approx_distance_ft": 5.0 or null,
//              "utterance": "A chair is to your left, near."
//            }
//          ],
//          "sign_texts": ["EXIT"]
//        }
//        RULES: Use specific labels (chair, table, door), not "object". At most 3 items, 2 utterances, 1 sign_text. Sort by salience (most visible first). position LEFT/CENTER/RIGHT, proximity FAR/NEAR/CLOSE. Short, calm utterances. The utterances field must be in the language specified above.
//        """
//        let userText = "Analyze this scene and return the JSON object only, no markdown or explanation."
//
//        let body = buildMessagesBody(system: system, userText: userText, imageBase64: b64)
//        let data = try await performRequest(body: body)
//
//        let raw        = extractTextFromResponse(data: data)
//        let jsonString = bestJSONObject(in: raw, containing: "utterances") ?? firstJSONObject(in: raw)
//
//        guard let jsonString = jsonString, !jsonString.isEmpty else {
//            throw NSError(domain: "ClaudeVision", code: 0,
//                userInfo: [NSLocalizedDescriptionKey: "No JSON in response: \(raw.prefix(300))"])
//        }
//        guard let jsonData = jsonString.data(using: .utf8) else {
//            throw NSError(domain: "ClaudeVision", code: 0,
//                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
//        }
//
//        do {
//            return try JSONDecoder().decode(VisionScene.self, from: jsonData)
//        } catch {
//            throw NSError(domain: "ClaudeVision", code: 0,
//                userInfo: [NSLocalizedDescriptionKey:
//                    "Decode failed: \(error.localizedDescription). Preview: \(jsonString.prefix(400))"])
//        }
//    }
//
//    // MARK: - Q&A with image (single call) – image + question + state → BrainPlan
//
//    func askWithImage(jpegData: Data,
//                      userText: String,
//                      stateJSON: String,
//                      language: AppLanguage = .english) async throws -> BrainPlan {
//        let b64 = jpegData.base64EncodedString()
//        let system = """
//        \(language.claudeInstruction)
//        You are SceneAssist, an AI assistant for a completely blind user navigating indoor environments using their phone camera.
//
//        CORE PRINCIPLES:
//        - Be concise. Responses are spoken aloud — avoid long sentences or lists.
//        - Prioritize safety. Always mention hazards (steps, obstacles, wet floors, etc.) first.
//        - Be spatial. Use clock positions anchored to the user's body and step counts for orientation.
//        - Think from the perspective of a completely blind person. They have no visual memory of the current space. Every response should help them build a mental map — where things are, how far, and whether it is safe to move.
//
//        TONE & SPEECH STYLE:
//        - Speak like a calm, trusted guide walking beside the person — not like a robot reading a list.
//        - Use natural pauses by breaking information into short sentences. One idea per sentence.
//        - Never dump everything at once. Lead with what matters most RIGHT NOW, then add context.
//        - Use natural guiding language, for example:
//          - "There's a door to your left, at 9 o'clock, about 3 steps away."
//          - "Watch out — there's a step down just in front of you."
//          - "All clear ahead. You can walk forward safely."
//          - "Looks like a waiting area. Chairs to your left, a reception desk straight ahead."
//        - Acknowledge the user's situation naturally when needed (e.g., "You seem to be near the entrance.").
//        - If nothing notable is visible, reassure them (e.g., "The space ahead looks clear. Keep going.").
//
//        SPEECH PACING:
//        - Never combine two separate observations into one sentence.
//        - Each observation must be its own sentence with a clear pause after it.
//        - In the 'say' field, use " ... " to indicate a natural pause between sentences, for example:
//          - "Door to your left, at 9 o'clock, about 3 steps. ... Chair straight ahead at 12 o'clock, 2 steps away. ... Path to your right is clear."
//        - Hazard alerts must always be a standalone sentence, never combined with anything else:
//          - "Watch out. ... Step down, straight ahead."
//          - NOT: "Watch out there is a step down ahead and a door to your left."
//
//        SPATIAL ORIENTATION RULES:
//        - Always use the user's body as the reference point:
//          - 12 o'clock = directly ahead of you
//          - 3 o'clock = to your right
//          - 9 o'clock = to your left
//          - 6 o'clock = directly behind you
//        - EVERY object, person, or hazard you mention MUST have a clock position. No exceptions.
//          - Do NOT say "There is a chair nearby."
//          - Do NOT say "A door is ahead."
//          - ALWAYS say "Chair to your left, at 9 o'clock, about 2 steps."
//          - ALWAYS say "Door straight ahead, at 12 o'clock, about 4 steps."
//        - If you are unsure of the clock position, make your best estimate. Never skip it.
//        - Always anchor clock position with a body-relative word first, then the clock position:
//          - "Chair to your left, at 9 o'clock."
//          - "Person straight ahead, at 12 o'clock."
//        - Never use clock position alone without a body-relative word (left, right, ahead, behind).
//        - Always pair clock position with a step count so the user knows both direction AND distance.
//
//        SCENE DESCRIPTION:
//        - As soon as something is visible, describe it immediately using clock position and steps.
//        - Lead with the most prominent object or hazard in view.
//        - Include any visible signage or text (signs, labels, door names) — this is critical for navigation.
//        - Use simple, confident language. Avoid hedging unless genuinely uncertain.
//        - When multiple objects are visible, do NOT list them all. Instead:
//          - Mention the most important object or hazard first.
//          - Then describe up to 2 nearby objects using clock positions and step counts.
//          - If a path is clear, say so explicitly (e.g., "Path ahead is clear for about 5 steps.").
//
//        PEOPLE & ACTIONS:
//        - If a person is visible, always mention them first before objects — people are unpredictable and the user must be aware.
//        - You MUST always describe what the person is doing. Never just say "there is a person" or "someone is standing there." That is not enough information.
//          - Do NOT say "There is a person to your right."
//          - Do NOT say "Someone is standing ahead."
//          - ALWAYS say "A person to your right, at 3 o'clock, is opening a door."
//          - ALWAYS say "Someone straight ahead, at 12 o'clock, is waving at you."
//          - ALWAYS say "A person to your left, at 9 o'clock, is sitting and talking on a phone."
//        - Describe the action in simple present tense. Be specific:
//          - Movement: walking toward you, walking away, rushing, turning around
//          - Gestures: waving, pointing, raising hand
//          - Interactions: opening a door, pressing a button, picking something up, pushing a cart
//          - Stationary: sitting, standing, leaning against a wall, waiting
//        - If you cannot clearly tell what the person is doing, say your best guess with low confidence:
//          - "Someone to your right, at 3 o'clock, appears to be reaching for something."
//          - "A person ahead, at 12 o'clock, seems to be waiting."
//        - If a person is moving toward the user, always flag it as a priority:
//          - "Someone is walking toward you — about 3 steps away. ... Be aware."
//        - If multiple people are visible, mention the closest one first.
//
//        ACTIONS — respond with the correct action type when triggered:
//        | Trigger | Action |
//        |---|---|
//        | User asks to remember or retrieve something | ANSWER_FROM_MEMORY (include memoryKey) |
//        | User says "set target [X]" or similar | SET_TARGET (include target="X") |
//        | User asks to repeat | REPEAT_LAST |
//        | All responses | Always populate 'say' with the spoken response |
//        """
//        let userMessage = """
//        USER: \(userText)
//
//        APP_STATE_JSON (context from the app):
//        \(stateJSON)
//
//        Reply with only the JSON object (say, action, target, memoryKey).
//        """
//
//        let body = buildMessagesBody(system: system, userText: userMessage, imageBase64: b64)
//        let data = try await performRequest(body: body)
//
//        let raw        = extractTextFromResponse(data: data)
//        let jsonString = bestJSONObject(in: raw, containing: "say") ?? firstJSONObject(in: raw)
//
//        guard let jsonString = jsonString, !jsonString.isEmpty else {
//            throw NSError(domain: "ClaudeBrain", code: 0,
//                userInfo: [NSLocalizedDescriptionKey: "No JSON in response: \(raw.prefix(300))"])
//        }
//        guard let jsonData = jsonString.data(using: .utf8) else {
//            throw NSError(domain: "ClaudeBrain", code: 0,
//                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
//        }
//
//        do {
//            return try JSONDecoder().decode(BrainPlan.self, from: jsonData)
//        } catch {
//            throw NSError(domain: "ClaudeBrain", code: 0,
//                userInfo: [NSLocalizedDescriptionKey:
//                    "Decode failed: \(error.localizedDescription). Preview: \(jsonString.prefix(400))"])
//        }
//    }
//
//    // MARK: - Request helpers
//
//    private func buildMessagesBody(system: String,
//                                   userText: String,
//                                   imageBase64: String) -> [String: Any] {
//        let content: [[String: Any]] = [
//            [
//                "type": "image",
//                "source": [
//                    "type":       "base64",
//                    "media_type": "image/jpeg",
//                    "data":       imageBase64
//                ] as [String: Any]
//            ],
//            ["type": "text", "text": userText]
//        ]
//        return [
//            "model":      model,
//            "max_tokens": maxTokens,
//            "system":     system,
//            "messages":   [["role": "user", "content": content]]
//        ] as [String: Any]
//    }
//
//    private func performRequest(body: [String: Any]) async throws -> Data {
//        var req = URLRequest(url: endpoint)
//        req.httpMethod      = "POST"
//        req.timeoutInterval = timeout
//        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        req.setValue(Secrets.anthropicApiKey, forHTTPHeaderField: "x-api-key")
//        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
//        req.httpBody = try JSONSerialization.data(withJSONObject: body)
//
//        let (data, resp) = try await URLSession.shared.data(for: req)
//        guard let http = resp as? HTTPURLResponse else {
//            throw NSError(domain: "Claude", code: -1,
//                userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
//        }
//        guard (200...299).contains(http.statusCode) else {
//            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
//            print("❌ Claude HTTP \(http.statusCode): \(bodyStr)")   // ← shows full error in Xcode
//            throw NSError(domain: "Claude", code: http.statusCode,
//                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr)"])
//        }
//        return data
//    }
//
//    private func extractTextFromResponse(data: Data) -> String {
//        struct ContentBlock: Decodable {
//            let type: String?
//            let text: String?
//        }
//        struct MessagesResponse: Decodable {
//            let content: [ContentBlock]?
//        }
//        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data),
//              let blocks  = decoded.content, !blocks.isEmpty else { return "" }
//        return blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined()
//    }
//
//    private func firstJSONObject(in s: String) -> String? {
//        guard let start = s.firstIndex(of: "{") else { return nil }
//        var depth = 0
//        var i = start
//        while i < s.endIndex {
//            let ch = s[i]
//            if ch == "{"      { depth += 1 }
//            else if ch == "}" {
//                depth -= 1
//                if depth == 0 { return String(s[start...i]) }
//            }
//            i = s.index(after: i)
//        }
//        return nil
//    }
//
//    private func bestJSONObject(in s: String, containing substring: String) -> String? {
//        var fallback: String?
//        var idx = s.startIndex
//        while idx < s.endIndex {
//            guard let start = s[idx...].firstIndex(of: "{") else { break }
//            var depth = 0
//            var i = start
//            while i < s.endIndex {
//                let ch = s[i]
//                if ch == "{"      { depth += 1 }
//                else if ch == "}" {
//                    depth -= 1
//                    if depth == 0 {
//                        let candidate = String(s[start...i])
//                        if candidate.contains(substring) { return candidate }
//                        if fallback == nil { fallback = candidate }
//                        idx = s.index(after: i)
//                        break
//                    }
//                }
//                i = s.index(after: i)
//            }
//            if i >= s.endIndex { break }
//        }
//        return fallback
//    }
//}
