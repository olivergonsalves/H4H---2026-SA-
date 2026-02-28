import Foundation

final class ElevenLabsTTSService {
    private let baseURL = URL(string: "https://api.elevenlabs.io")!

    // choose a model (docs mention defaults like eleven_multilingual_v2)
    private let modelId = "eleven_multilingual_v2"

    func synthesize(text: String, voiceId: String, apiKey: String) async throws -> Data {
        // POST /v1/text-to-speech/:voice_id?output_format=mp3_44100_128
        var url = baseURL.appendingPathComponent("/v1/text-to-speech/\(voiceId)")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        url = comps.url!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "ElevenLabs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg)"])
        }
        return data // MP3 bytes
    }
}
