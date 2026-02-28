import Foundation
import UIKit
import CoreVideo
import CoreImage

// MARK: - Structured output types (must match schema)
//struct VisionScene: Codable {
//    let utterances: [String]      // ranked: most visible first
//    let items: [VisionItem]       // full list, ordered by salience
//    let sign_texts: [String]      // e.g. ["EXIT"]
//}
struct VisionScene: Codable {
    let utterances: [String]
    let items: [VisionItem]
    let sign_texts: [String]

    enum CodingKeys: String, CodingKey { case utterances, items, sign_texts }

    init(utterances: [String] = [], items: [VisionItem] = [], sign_texts: [String] = []) {
        self.utterances = utterances
        self.items = items
        self.sign_texts = sign_texts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utterances = (try? c.decode([String].self, forKey: .utterances)) ?? []
        items = (try? c.decode([VisionItem].self, forKey: .items)) ?? []
        sign_texts = (try? c.decode([String].self, forKey: .sign_texts)) ?? []
    }
}

struct VisionItem: Codable, Hashable {
    let kind: Kind                // PERSON / ANIMAL / OBJECT / SIGN
    let label: String             // e.g. "person", "animal", "chair", "exit sign"
    let position: Position        // LEFT / CENTER / RIGHT
    let proximity: Proximity      // FAR / NEAR / CLOSE
    let salience_rank: Int        // 1 is most visible
    let confidence: Double        // 0..1
    let approx_distance_ft: Double?
    let utterance: String         // short phrase to speak
}

enum Kind: String, Codable { case PERSON, ANIMAL, OBJECT, SIGN }
enum Position: String, Codable { case LEFT, CENTER, RIGHT }
enum Proximity: String, Codable { case FAR, NEAR, CLOSE }

// MARK: - Responses API minimal parsing
private struct VisionResponsesAPIResponse: Decodable {
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

final class CloudVisionService {

    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let model = "gpt-4.1-nano"   // or "gpt-4.1-nano" for less accuracy

    func analyze(jpegData: Data) async throws -> VisionScene {
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 12
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")

        let b64 = jpegData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"

        // Strict JSON schema (small outputs = fewer truncation/parse issues)
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "utterances": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 2 //4
                ],
                "sign_texts": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 1 //4
                ],
                "items": [
                    "type": "array",
                    "maxItems": 3, //8
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "kind": ["type": "string", "enum": ["PERSON","ANIMAL","OBJECT","SIGN"]],
                            "label": ["type": "string"],
                            "position": ["type": "string", "enum": ["LEFT","CENTER","RIGHT"]],
                            "proximity": ["type": "string", "enum": ["FAR","NEAR","CLOSE"]],
                            "salience_rank": ["type": "integer"],
                            "confidence": ["type": "number"],
                            "approx_distance_ft": ["type": ["number", "null"]],
                            "utterance": ["type": "string"]
                        ],
                        "required": ["kind","label","position","proximity","salience_rank","confidence","utterance"]
                    ]
                ]
            ],
            "required": ["utterances","items","sign_texts"]
        ]
//~ 1–4 ft, NEAR ~ 4–10 ft, FAR ~ 10–25 ft.
        let instructions = """
        You are a vision assistant for a visually impaired user. Output JSON only.
        RULES:
        - IMPORTANT: label must be a specific noun (e.g., "table", "chair", "bottle", "door", "laptop").
        - Do NOT use generic labels like "object", "item", or "thing".
        - If you are not sure what it is, omit it from items.
        - Detect PERSON, ANIMAL (do NOT name species; just say "animal"), OBJECT, and SIGN text.
        - Return at most 5 items and at most 3 utterances.
        - Sort by salience (most visible/closest/clearest first; center beats edges).
        - position: LEFT/CENTER/RIGHT. Only if the object/person/animal is super close then warn the user after telling what the object is.
        - If a sign is readable, include it in sign_texts and as an item kind SIGN.
        - Utterances must be short, calm, actionable.
        - For each item, estimate approx_distance_ft (in feet) and the number of steps it will take the user as per their height in cm that they mention initially when they install the app from the camera: CLOSE
        - If you truly can’t estimate, set approx_distance_ft to null.
        """

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Analyze this scene and return ranked detections."],
                    ["type": "input_image", "image_url": dataURL, "detail": "auto"]
                ]
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "scene_detect",
                    "strict": true,
                    "schema": schema
                ]
            ],
            "temperature": 0.0,
            "max_output_tokens": 240
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "OpenAI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr)"])
        }

        let decoded = try JSONDecoder().decode(VisionResponsesAPIResponse.self, from: data)

        // Collect all output_text chunks
        let pieces = decoded.output
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap { $0.text }

        // Choose the longest chunk (most likely full JSON)
        let raw = pieces.max(by: { $0.count < $1.count }) ?? ""

        // Extract the first complete JSON object (guards against stray text)
        let jsonString = Self.firstJSONObject(in: raw) ?? raw

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "Vision", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No JSON string"])
        }

        do {
            return try JSONDecoder().decode(VisionScene.self, from: jsonData)
        } catch {
            let preview = String(jsonString.prefix(500))
            throw NSError(domain: "VisionDecode", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Decode failed. Preview: \(preview)"])
        }
    }

    // Extract a balanced JSON object {...} from a string
    private static func firstJSONObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(s[start...i])
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: - Image helpers
extension CloudVisionService {
    static func jpegFromPixelBuffer(_ pb: CVPixelBuffer, maxWidth: CGFloat = 640, quality: CGFloat = 0.55) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pb)
        let context = CIContext()

        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let ui = UIImage(cgImage: cg, scale: 1.0, orientation: .right)

        let scale = maxWidth / max(ui.size.width, 1)
        let newSize = CGSize(width: maxWidth, height: ui.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        ui.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized?.jpegData(compressionQuality: quality)
    }
}




//import Foundation
//import UIKit
//import CoreVideo
//import CoreImage
//
//// MARK: - Structured output types (must match schema)
//struct VisionScene: Codable {
//    let utterances: [String]      // ranked: most visible first
//    let items: [VisionItem]       // full list, ordered by salience
//    let sign_texts: [String]      // e.g. ["EXIT"]
//}
//
//struct VisionItem: Codable, Hashable {
//    let kind: Kind                // PERSON / ANIMAL / OBJECT / SIGN
//    let label: String             // e.g. "person", "animal", "chair", "exit sign"
//    let position: Position        // LEFT / CENTER / RIGHT
//    let proximity: Proximity      // FAR / NEAR / CLOSE
//    let salience_rank: Int        // 1 is most visible
//    let confidence: Double        // 0..1
//    let utterance: String         // short phrase to speak
//}
//
//enum Kind: String, Codable { case PERSON, ANIMAL, OBJECT, SIGN }
//enum Position: String, Codable { case LEFT, CENTER, RIGHT }
//enum Proximity: String, Codable { case FAR, NEAR, CLOSE }
//
//// MARK: - Responses API minimal parsing
//private struct VisionResponsesAPIResponse: Decodable {
//    struct OutputItem: Decodable {
//        struct ContentItem: Decodable {
//            let type: String
//            let text: String?
//        }
//        let type: String
//        let content: [ContentItem]?
//    }
//    let output: [OutputItem]
//}
//
//final class CloudVisionService {
//
//    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
//    private let model = "gpt-4.1-nano"   // or "gpt-4.1-nano" for less accuracy
//
//    func analyze(jpegData: Data) async throws -> VisionScene {
//        var req = URLRequest(url: endpoint)
//        req.timeoutInterval = 12
//        req.httpMethod = "POST"
//        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        req.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
//
//        let b64 = jpegData.base64EncodedString()
//        let dataURL = "data:image/jpeg;base64,\(b64)"
//
//        // Strict JSON schema (small outputs = fewer truncation/parse issues)
//        let schema: [String: Any] = [
//            "type": "object",
//            "additionalProperties": false,
//            "properties": [
//                "utterances": [
//                    "type": "array",
//                    "items": ["type": "string"],
//                    "maxItems": 2 //4
//                ],
//                "sign_texts": [
//                    "type": "array",
//                    "items": ["type": "string"],
//                    "maxItems": 1 //4
//                ],
//                "items": [
//                    "type": "array",
//                    "maxItems": 3, //8
//                    "items": [
//                        "type": "object",
//                        "additionalProperties": false,
//                        "properties": [
//                            "kind": ["type": "string", "enum": ["PERSON","ANIMAL","OBJECT","SIGN"]],
//                            "label": ["type": "string"],
//                            "position": ["type": "string", "enum": ["LEFT","CENTER","RIGHT"]],
//                            "proximity": ["type": "string", "enum": ["FAR","NEAR","CLOSE"]],
//                            "salience_rank": ["type": "integer"],
//                            "confidence": ["type": "number"],
//                            "utterance": ["type": "string"]
//                        ],
//                        "required": ["kind","label","position","proximity","salience_rank","confidence","utterance"]
//                    ]
//                ]
//            ],
//            "required": ["utterances","items","sign_texts"]
//        ]
//
//        let instructions = """
//        You are a vision assistant for a visually impaired user. Output JSON only.
//        RULES:
//        - IMPORTANT: label must be a specific noun (e.g., "table", "chair", "bottle", "door", "laptop").
//        - Do NOT use generic labels like "object", "item", or "thing".
//        - If you are not sure what it is, omit it from items.
//        - Detect PERSON, ANIMAL (do NOT name species; just say "animal"), OBJECT, and SIGN text.
//        - Return at most 5 items and at most 3 utterances.
//        - Sort by salience (most visible/closest/clearest first; center beats edges).
//        - position: LEFT/CENTER/RIGHT. Only if the object/person/animal is super close then warn the user after telling what the object is.
//        - If a sign is readable, include it in sign_texts and as an item kind SIGN.
//        - Utterances must be short, calm, actionable.
//        """
//
//        let body: [String: Any] = [
//            "model": model,
//            "instructions": instructions,
//            "input": [[
//                "role": "user",
//                "content": [
//                    ["type": "input_text", "text": "Analyze this scene and return ranked detections."],
//                    ["type": "input_image", "image_url": dataURL, "detail": "auto"]
//                ]
//            ]],
//            "text": [
//                "format": [
//                    "type": "json_schema",
//                    "name": "scene_detect",
//                    "strict": true,
//                    "schema": schema
//                ]
//            ],
//            "temperature": 0.0,
//            "max_output_tokens": 160 //240
//        ]
//
//        req.httpBody = try JSONSerialization.data(withJSONObject: body)
//
//        let (data, resp) = try await URLSession.shared.data(for: req)
//
//        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
//            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
//            throw NSError(domain: "OpenAI", code: http.statusCode,
//                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr)"])
//        }
//
//        let decoded = try JSONDecoder().decode(VisionResponsesAPIResponse.self, from: data)
//
//        // Collect all output_text chunks
//        let pieces = decoded.output
//            .flatMap { $0.content ?? [] }
//            .filter { $0.type == "output_text" }
//            .compactMap { $0.text }
//
//        // Choose the longest chunk (most likely full JSON)
//        let raw = pieces.max(by: { $0.count < $1.count }) ?? ""
//
//        // Extract the first complete JSON object (guards against stray text)
//        let jsonString = Self.firstJSONObject(in: raw) ?? raw
//
//        guard let jsonData = jsonString.data(using: .utf8) else {
//            throw NSError(domain: "Vision", code: 0,
//                          userInfo: [NSLocalizedDescriptionKey: "No JSON string"])
//        }
//
//        do {
//            return try JSONDecoder().decode(VisionScene.self, from: jsonData)
//        } catch {
//            let preview = String(jsonString.prefix(500))
//            throw NSError(domain: "VisionDecode", code: 0,
//                          userInfo: [NSLocalizedDescriptionKey: "Decode failed. Preview: \(preview)"])
//        }
//    }
//
//    // Extract a balanced JSON object {...} from a string
//    private static func firstJSONObject(in s: String) -> String? {
//        guard let start = s.firstIndex(of: "{") else { return nil }
//        var depth = 0
//        var i = start
//        while i < s.endIndex {
//            let ch = s[i]
//            if ch == "{" { depth += 1 }
//            else if ch == "}" {
//                depth -= 1
//                if depth == 0 {
//                    return String(s[start...i])
//                }
//            }
//            i = s.index(after: i)
//        }
//        return nil
//    }
//}
//
//// MARK: - Image helpers
//extension CloudVisionService {
//    static func jpegFromPixelBuffer(_ pb: CVPixelBuffer, maxWidth: CGFloat = 640, quality: CGFloat = 0.55) -> Data? {
//        let ciImage = CIImage(cvPixelBuffer: pb)
//        let context = CIContext()
//
//        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
//        let ui = UIImage(cgImage: cg, scale: 1.0, orientation: .right)
//
//        let scale = maxWidth / max(ui.size.width, 1)
//        let newSize = CGSize(width: maxWidth, height: ui.size.height * scale)
//
//        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
//        ui.draw(in: CGRect(origin: .zero, size: newSize))
//        let resized = UIGraphicsGetImageFromCurrentImageContext()
//        UIGraphicsEndImageContext()
//
//        return resized?.jpegData(compressionQuality: quality)
//    }
//}
