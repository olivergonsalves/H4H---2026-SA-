import Vision
import CoreVideo

final class OCRService {
    private let queue = DispatchQueue(label: "ocr.queue", qos: .userInitiated)

    func recognizeText(from pixelBuffer: CVPixelBuffer, completion: @escaping ([String]) -> Void) {
        queue.async {
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    print("❌ OCR error:", error)
                    completion([])
                    return
                }

                guard let results = request.results as? [VNRecognizedTextObservation] else {
                    completion([])
                    return
                }

                var words: [String] = []

                for obs in results {
                    guard let top = obs.topCandidates(1).first else { continue }

                    // Keep only confident text
                    if top.confidence >= 0.6 {
                        let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            words.append(text)
                        }
                    }
                }

                completion(words)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.02

            // Orientation: back camera in portrait usually matches .right
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

            do {
                try handler.perform([request])
            } catch {
                print("❌ Failed to perform OCR:", error)
                completion([])
            }
        }
    }
}
