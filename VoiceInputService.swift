//import Foundation
//import Speech
//import AVFoundation
//
//final class VoiceInputService {
//    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
//    private let audioEngine = AVAudioEngine()
//
//    private var request: SFSpeechAudioBufferRecognitionRequest?
//    private var task: SFSpeechRecognitionTask?
//
//    func requestPermissions(completion: @escaping (Bool) -> Void) {
//        SFSpeechRecognizer.requestAuthorization { status in
//            DispatchQueue.main.async {
//                completion(status == .authorized)
//            }
//        }
//    }
//
//    func startListening(onFinal: @escaping (String) -> Void) throws {
//        stopListening()
//
//        let audioSession = AVAudioSession.sharedInstance()
//        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
//        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
//
//        let request = SFSpeechAudioBufferRecognitionRequest()
//        request.shouldReportPartialResults = true
//        self.request = request
//
//        let inputNode = audioEngine.inputNode
//        let format = inputNode.outputFormat(forBus: 0)
//
//        inputNode.removeTap(onBus: 0)
//        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
//            request.append(buffer)
//        }
//
//        audioEngine.prepare()
//        try audioEngine.start()
//
//        guard let recognizer = recognizer, recognizer.isAvailable else {
//            throw NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
//        }
//
//        task = recognizer.recognitionTask(with: request) { result, error in
//            if let result = result, result.isFinal {
//                onFinal(result.bestTranscription.formattedString)
//            }
//            if error != nil {
//                self.stopListening()
//            }
//        }
//    }
//
//    func stopListening() {
//        if audioEngine.isRunning {
//            audioEngine.stop()
//            audioEngine.inputNode.removeTap(onBus: 0)
//        }
//        request?.endAudio()
//        request = nil
//        task?.cancel()
//        task = nil
//
//        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
//    }
//}

import Foundation
import Speech
import AVFoundation

final class VoiceInputService {
    
    var onFinal: ((String) -> Void)?
    var finalText: String = ""
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // This will always hold the latest recognized words
    private(set) var latestText: String = ""

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func startListening(onFinal: @escaping (String) -> Void) throws {
        self.onFinal = onFinal
        self.finalText = ""
        self.latestText = ""
        stopListening()
        latestText = ""

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer server-side recognition so partial results arrive reliably (on-device can be flaky).
        if #available(iOS 13, *) {
            request.requiresOnDeviceRecognition = false
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
//                let text = result.bestTranscription.formattedString
//                DispatchQueue.main.async {
//                    self.latestText = text
                self.latestText = result.bestTranscription.formattedString

                    if result.isFinal {
                        self.finalText = self.latestText
                        self.onFinal?(self.finalText)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    self.stopListening()
                }
            }
        }
    }

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
