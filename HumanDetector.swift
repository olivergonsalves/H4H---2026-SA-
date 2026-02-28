import Vision
import CoreVideo
import Foundation

struct HumanDetection {
    // boundingBox is 0...1 (like a percent of the screen)
    let boundingBox: CGRect
    let confidence: Float

    // left / center / right
    let position: String

    // true if person looks close (big box)
    let isClose: Bool
}

final class HumanDetector {
    private let queue = DispatchQueue(label: "human.detect.queue", qos: .userInitiated)

    func detectHumans(from pixelBuffer: CVPixelBuffer, completion: @escaping ([HumanDetection]) -> Void) {
        queue.async {
            let request = VNDetectHumanRectanglesRequest { request, error in
                if let error = error {
                    print("❌ Human detection error:", error)
                    completion([])
                    return
                }

                guard let results = request.results as? [VNHumanObservation] else {
                    completion([])
                    return
                }
                
                let limited = Array(results.prefix(2))

                var detections: [HumanDetection] = []

                for obs in limited {
                    let box = obs.boundingBox              // normalized CGRect (0..1)
                    let conf = obs.confidence
                    if conf < 0.6 { continue }

                    // box.midX tells where the person is (left/center/right)
                    let midX = box.midX
                    let pos: String
                    if midX < 0.33 { pos = "left" }
                    else if midX > 0.66 { pos = "right" }
                    else { pos = "center" }

                    // simple “close” check: big area = closer
                    let area = box.width * box.height
                    let close = area > 0.18   // tweak later if needed

                    detections.append(
                        HumanDetection(
                            boundingBox: box,
                            confidence: conf,
                            position: pos,
                            isClose: close
                        )
                    )
                }

                completion(detections)
            }

            // Make it only return real results (less noise)
//            request.minimumConfidence = 0.6
//            request.maximumObservations = 2

            // Orientation: start with .up (most reliable)
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

            do {
                try handler.perform([request])
            } catch {
                print("❌ Human handler perform failed:", error)
                completion([])
            }
        }
    }
}
