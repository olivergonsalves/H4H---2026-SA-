import Foundation

// What we want the model to return (always valid JSON)
struct BrainPlan: Codable {
    enum Action: String, Codable {
        case none = "NONE"
        case setTarget = "SET_TARGET"
        case answerFromMemory = "ANSWER_FROM_MEMORY"
        case repeatLast = "REPEAT_LAST"
        case clearTranscripts = "CLEAR_TRANSCRIPTS"
    }

    let say: String              // what the app should speak
    let action: Action           // optional action to run
    let target: String?          // e.g. "door"
    let memoryKey: String?       // e.g. "steps:door"
}

// Minimal parsing of Responses API output text
struct ResponsesAPIResponse: Decodable {
    struct OutputItem: Decodable {
        struct ContentItem: Decodable {
            let type: String
            let text: String?
        }
        let type: String
        let content: [ContentItem]?
    }

    let output: [OutputItem]
}

final class LLMBrainService {

    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    // Call the model with user text + state JSON and return a BrainPlan.
    func askBrain(userText: String, stateJSON: String) async throws -> BrainPlan {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")

        // JSON Schema for structured outputs
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "say": [
                    "type": "string",
                    "description": "One short sentence to speak aloud to the user."
                ],
                "action": [
                    "type": "string",
                    "enum": ["NONE", "SET_TARGET", "ANSWER_FROM_MEMORY", "REPEAT_LAST", "CLEAR_TRANSCRIPTS"]
                ],

                // IMPORTANT: these must exist even when empty, so allow null
                "target": [
                    "type": ["string", "null"],
                    "description": "Target name like 'door'. Use null if not needed."
                ],
                "memoryKey": [
                    "type": ["string", "null"],
                    "description": "Memory key like 'steps:door'. Use null if not needed."
                ]
            ],

            // IMPORTANT: strict mode requires ALL keys listed here
            "required": ["say", "action", "target", "memoryKey"],

            "additionalProperties": false
        ]

        let instructions = """
        You are SceneAssist, a helpful assistant for a visually impaired user.
        - Keep responses short, clear, and safe.
        - If user asks to remember or retrieve something, use action ANSWER_FROM_MEMORY with a memoryKey.
        - If user says "set target X" or similar, use SET_TARGET and target="X".
        - If user asks to repeat, use REPEAT_LAST.
        - Always fill 'say' with what should be spoken aloud.
        
        Distance questions:
        - If the user asks about distance (how far, distance, steps, feet, walk, reach, close/near), use APP_STATE_JSON.distance_candidates.
        - Each candidate has: label, position, approx_feet, approx_steps, salience_rank.
        - If the user names an object (e.g., "bed"), choose the candidate whose label best matches.
        - If the user says "this/that/it", choose the most salient candidate (lowest salience_rank).
        - Default: answer in steps (approx_steps). If user mentions feet/meters, include approx_feet too.
        - If no matching candidate exists, say you can’t see it clearly and ask them to point the camera at it.
        """

        let inputText = """
        USER: \(userText)

        APP_STATE_JSON:
        \(stateJSON)
        """

        let body: [String: Any] = [
            "model": "gpt-4.1-mini",
            "instructions": instructions,
            "input": [
                ["role": "user", "content": inputText]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "scene_assist_brain",
                    "strict": true,
                    "schema": schema
                ]
            ],
            "temperature": 0.2,
            "max_output_tokens": 120
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "OpenAI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"]
            )
        }
        
        let decoded = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)

        // Find first output_text
        let text = decoded.output
            .flatMap { $0.content ?? [] }
            .first(where: { $0.type == "output_text" })?
            .text ?? ""

        // Model returns JSON string in "text"
        guard let jsonData = text.data(using: .utf8) else {
            throw NSError(domain: "Brain", code: 0, userInfo: [NSLocalizedDescriptionKey: "No JSON returned"])
        }

        return try JSONDecoder().decode(BrainPlan.self, from: jsonData)
    }
}
