import Foundation

/// Calls an OpenAI-compatible vLLM server (text-only model).
/// Used as a *compression/normalization* layer:
/// SENSOR_SNAPSHOT (from on-device OCR/YOLO) -> VisionScene JSON
final class VLLMQwenService {

    /// Must include `/v1`, e.g. "http://165.245.139.104:443/v1"
    private var baseURL: URL? { URL(string: Secrets.vllmBaseURL) }

    private let timeout: TimeInterval = 20

    // MARK: - Compression layer (text-only): SENSOR_SNAPSHOT -> VisionScene

    func compressSnapshotToVisionScene(
        sensorSnapshot: String,
        language: AppLanguage = .english
    ) async throws -> VisionScene {

        guard let baseURL else {
            throw NSError(
                domain: "VLLM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid vLLM base URL: \(Secrets.vllmBaseURL)"]
            )
        }

        let url = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let key = Secrets.vllmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let system = """
        You are a perception COMPRESSION module for an accessibility navigation app.
        You will be given SENSOR_SNAPSHOT text derived from on-device detectors (OCR + object detection).

        Your job:
        - Normalize that snapshot into a small structured JSON object.
        - Do NOT hallucinate objects not present in SENSOR_SNAPSHOT.
        - If uncertain, omit the item.

        Return ONLY a raw JSON object. No markdown. No extra text. Do NOT output <think> blocks.

        JSON schema (must match exactly; keys & enums are case-sensitive):
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
              "utterance": "Short speakable phrase."
            }
          ],
          "sign_texts": ["EXIT"]
        }

        RULES:
        - At most 3 items, 2 utterances, 1 sign_text.
        - label must be a specific noun. NEVER "object"/"item"/"thing".
        - PERSON label should be "person". ANIMAL label should be "animal".
        - position must be LEFT/CENTER/RIGHT and proximity must be FAR/NEAR/CLOSE (uppercase).
        - Sort items by importance: closest + center + highest confidence.
        - utterances must be calm and <= 10 words each.

        LANGUAGE RULE: \(language.claudeInstruction)
        OUTPUT: Raw JSON only.
        """

        let userText = """
        SENSOR_SNAPSHOT:
        \(sensorSnapshot)
        """

        let body: [String: Any] = [
            "model": Secrets.vllmQwenModel,
            "temperature": 0.1,
            "max_tokens": 420,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userText]
            ]
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"

        guard (200...299).contains(status) else {
            throw NSError(
                domain: "VLLM",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(bodyText)"]
            )
        }

        // vLLM returns OpenAI-compatible chat.completions JSON
        let assistant = try extractAssistantText(from: data)
        let cleaned = cleanModelText(assistant)

        // Extract the first JSON object (or best containing "utterances")
        let json = bestJSONObject(in: cleaned, containing: "\"utterances\"") ?? firstJSONObject(in: cleaned)

        guard let json, let jsonData = json.data(using: .utf8) else {
            throw NSError(
                domain: "VLLM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No JSON found. Raw: \(cleaned.prefix(300))"]
            )
        }

        do {
            return try JSONDecoder().decode(VisionScene.self, from: jsonData)
        } catch {
            throw NSError(
                domain: "VLLM",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Decode failed: \(error.localizedDescription). JSON: \(json.prefix(300))"]
            )
        }
    }

    // MARK: - Parsing helpers

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private func extractAssistantText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    /// Remove <think>...</think> blocks (Qwen often emits these).
    private func cleanModelText(_ s: String) -> String {
        // Quick, robust strip without heavy regex dependencies
        var out = s
        while let start = out.range(of: "<think>"),
              let end = out.range(of: "</think>") {
            // Remove from start to end inclusive
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstJSONObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{" { depth += 1 }
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
                if ch == "{" { depth += 1 }
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
