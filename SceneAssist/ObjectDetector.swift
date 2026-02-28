import Foundation
import Vision
import CoreML
import CoreVideo

struct DetectedThing: Hashable {
    let label: String          // e.g. "person", "chair"
    let kind: String           // "person" / "animal" / "object"
    let confidence: Float
    let position: String       // "left" / "center" / "right"
    let proximity: String      // "far" / "near" / "close"
    let score: Float           // ranking score
    let utterance: String      // what to speak
}

final class ObjectDetector {
    private let queue = DispatchQueue(label: "yolo.detect.queue", qos: .userInitiated)

    private lazy var vnModel: VNCoreMLModel? = {
        // IMPORTANT: this name must match your model filename (yolov8n.mlpackage)
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            print("❌ Could not find yolov8n.mlmodelc in bundle. Check target membership and build.")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: url)
            return try VNCoreMLModel(for: mlModel)
        } catch {
            print("❌ Failed to load YOLO model:", error)
            return nil
        }
    }()

    // COCO animals (we will just say "animal")
    private let animalLabels: Set<String> = [
        "bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe"
    ]

    func detect(from pixelBuffer: CVPixelBuffer, completion: @escaping ([DetectedThing]) -> Void) {
        queue.async {
            guard let vnModel = self.vnModel else {
                completion([])
                return
            }

            let request = VNCoreMLRequest(model: vnModel) { req, err in
                if let err = err {
                    print("❌ VNCoreMLRequest error:", err)
                    completion([])
                    return
                }

                // Many CoreML detection models return VNRecognizedObjectObservation here
                let observations = (req.results as? [VNRecognizedObjectObservation]) ?? []
                let detections = self.postProcess(observations: observations)
                completion(detections)
            }

            request.imageCropAndScaleOption = .scaleFill

            // Orientation: you previously used .right/.up; if left/right looks wrong, switch this
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

            do {
                try handler.perform([request])
            } catch {
                print("❌ Handler perform failed:", error)
                completion([])
            }
        }
    }

    private func postProcess(observations: [VNRecognizedObjectObservation]) -> [DetectedThing] {
        var out: [DetectedThing] = []

        for obs in observations {
            guard let top = obs.labels.first else { continue }
            let conf = top.confidence
            if conf < 0.35 { continue }

            // boundingBox is 0..1 coords
            let box = obs.boundingBox
            let midX = box.midX

            let position: String
            if midX < 0.33 { position = "left" }
            else if midX > 0.66 { position = "right" }
            else { position = "center" }

            let area = Float(box.width * box.height)

            let proximity: String
            if area > 0.22 { proximity = "close" }
            else if area > 0.10 { proximity = "near" }
            else { proximity = "far" }

            let rawLabel = top.identifier.lowercased()
            let kind: String = animalLabels.contains(rawLabel) ? "animal" : (rawLabel == "person" ? "person" : "object")

            let speakLabel: String
            if kind == "animal" { speakLabel = "animal" }
            else { speakLabel = prettify(rawLabel) }

            // Rank: bigger + confident + center bonus
            let centerBonus: Float = (position == "center") ? 0.08 : 0.0
            let score: Float = (0.65 * area) + (0.35 * conf) + centerBonus

            let utterance: String
            if kind == "person" {
                utterance = "Person on the \(position), \(proximity)."
            } else if kind == "animal" {
                utterance = "Animal on the \(position), \(proximity)."
            } else {
                utterance = "\(speakLabel.capitalized) on the \(position), \(proximity)."
            }

            out.append(DetectedThing(
                label: speakLabel,
                kind: kind,
                confidence: conf,
                position: position,
                proximity: proximity,
                score: score,
                utterance: utterance
            ))
        }

        // Sort by “most visible”
        out.sort { $0.score > $1.score }
        return out
    }

    private func prettify(_ s: String) -> String {
        // YOLO/COCO labels are usually already pretty, but keep this for safety
        return s.replacingOccurrences(of: "_", with: " ")
    }
}
