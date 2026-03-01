//  VoiceInputService.swift
//  SceneAssist
//
//  Runs EN + ZH recognizers in parallel.
//  Picks winner by detecting which transcript is actually that language,
//  not just by length (length-wins caused EN speech to be misread as ZH).

import Foundation
import Speech
import AVFoundation

final class VoiceInputService {

    var onFinal: ((String) -> Void)?
    var finalText: String = ""

    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let recognizerZH = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
    private let detector     = LanguageDetector()

    private let audioEngine = AVAudioEngine()

    private var requestEN: SFSpeechAudioBufferRecognitionRequest?
    private var requestZH: SFSpeechAudioBufferRecognitionRequest?
    private var taskEN: SFSpeechRecognitionTask?
    private var taskZH: SFSpeechRecognitionTask?

    private var latestTextEN: String = ""
    private var latestTextZH: String = ""

    private(set) var latestText: String = ""

    // Guard so fireFinal only fires once per session
    private var hasFired = false

    // MARK: - Permissions

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Start

    func startListening(onFinal: @escaping (String) -> Void) throws {
        self.onFinal      = onFinal
        self.finalText    = ""
        self.latestText   = ""
        self.latestTextEN = ""
        self.latestTextZH = ""
        self.hasFired     = false

        stopListening()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let rEN = SFSpeechAudioBufferRecognitionRequest()
        let rZH = SFSpeechAudioBufferRecognitionRequest()
        rEN.shouldReportPartialResults = true
        rZH.shouldReportPartialResults = true
        if #available(iOS 13, *) {
            rEN.requiresOnDeviceRecognition = false
            rZH.requiresOnDeviceRecognition = false
        }
        self.requestEN = rEN
        self.requestZH = rZH

        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.requestEN?.append(buffer)
            self?.requestZH?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        if let rec = recognizerEN, rec.isAvailable {
            taskEN = rec.recognitionTask(with: rEN) { [weak self] result, _ in
                guard let self = self else { return }
                if let result = result {
                    self.latestTextEN = result.bestTranscription.formattedString
                    self.updateBest()
                    if result.isFinal { self.fireFinal() }
                }
            }
        }

        if let rec = recognizerZH, rec.isAvailable {
            taskZH = rec.recognitionTask(with: rZH) { [weak self] result, _ in
                guard let self = self else { return }
                if let result = result {
                    self.latestTextZH = result.bestTranscription.formattedString
                    self.updateBest()
                    if result.isFinal { self.fireFinal() }
                }
            }
        }
    }

    // MARK: - Stop

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        requestEN?.endAudio()
        requestZH?.endAudio()
        requestEN = nil
        requestZH = nil
        taskEN?.cancel()
        taskZH?.cancel()
        taskEN = nil
        taskZH = nil
        hasFired = false

        try? AVAudioSession.sharedInstance().setActive(false,
              options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func updateBest() {
        // Ask LanguageDetector which transcript actually matches its own language.
        // EN recognizer output should detect as .english.
        // ZH recognizer output should detect as .mandarin.
        // If EN text detects as English → use EN.
        // If ZH text detects as Mandarin → use ZH.
        // Tiebreak: prefer whichever is longer.

        let enIsEnglish  = !latestTextEN.isEmpty && detector.detect(text: latestTextEN) == .english
        let zhIsMandarin = !latestTextZH.isEmpty && detector.detect(text: latestTextZH) == .mandarin

        if enIsEnglish && !zhIsMandarin {
            latestText = latestTextEN
        } else if zhIsMandarin && !enIsEnglish {
            latestText = latestTextZH
        } else if enIsEnglish && zhIsMandarin {
            // Both look correct for their language — pick the longer one
            latestText = latestTextZH.count >= latestTextEN.count ? latestTextZH : latestTextEN
        } else {
            // Neither looks right yet (still processing) — pick longer as fallback
            latestText = latestTextZH.count > latestTextEN.count ? latestTextZH : latestTextEN
        }
    }

    private func fireFinal() {
        guard !hasFired else { return }   // only fire once — first isFinal wins
        hasFired = true
        updateBest()
        let best = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !best.isEmpty else { return }
        finalText = best
        print("🎤 Final transcript: '\(best)' (EN: '\(latestTextEN)' ZH: '\(latestTextZH)')")
        DispatchQueue.main.async { self.onFinal?(best) }
    }
}




////  VoiceInputService.swift
////  SceneAssist
////
////  Runs English AND Mandarin recognizers in parallel.
////  Whichever produces more text wins.
//
//import Foundation
//import Speech
//import AVFoundation
//
//final class VoiceInputService {
//
//    var onFinal: ((String) -> Void)?
//    var finalText: String = ""
//
//    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
//    private let recognizerZH = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
//
//    private let audioEngine = AVAudioEngine()
//
//    private var requestEN: SFSpeechAudioBufferRecognitionRequest?
//    private var requestZH: SFSpeechAudioBufferRecognitionRequest?
//    private var taskEN: SFSpeechRecognitionTask?
//    private var taskZH: SFSpeechRecognitionTask?
//
//    private var latestTextEN: String = ""
//    private var latestTextZH: String = ""
//
//    /// The best current transcription (longer of EN / ZH).
//    private(set) var latestText: String = ""
//
//    // MARK: - Permissions
//
//    func requestPermissions(completion: @escaping (Bool) -> Void) {
//        SFSpeechRecognizer.requestAuthorization { status in
//            DispatchQueue.main.async {
//                completion(status == .authorized)
//            }
//        }
//    }
//
//    // MARK: - Start
//
//    func startListening(onFinal: @escaping (String) -> Void) throws {
//        self.onFinal      = onFinal
//        self.finalText    = ""
//        self.latestText   = ""
//        self.latestTextEN = ""
//        self.latestTextZH = ""
//
//        stopListening()
//
//        let audioSession = AVAudioSession.sharedInstance()
//        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
//        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
//
//        let rEN = SFSpeechAudioBufferRecognitionRequest()
//        let rZH = SFSpeechAudioBufferRecognitionRequest()
//        rEN.shouldReportPartialResults = true
//        rZH.shouldReportPartialResults = true
//        if #available(iOS 13, *) {
//            rEN.requiresOnDeviceRecognition = false
//            rZH.requiresOnDeviceRecognition = false
//        }
//        self.requestEN = rEN
//        self.requestZH = rZH
//
//        // One audio tap feeds both requests
//        let inputNode = audioEngine.inputNode
//        let format    = inputNode.outputFormat(forBus: 0)
//        inputNode.removeTap(onBus: 0)
//        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
//            self?.requestEN?.append(buffer)
//            self?.requestZH?.append(buffer)
//        }
//
//        audioEngine.prepare()
//        try audioEngine.start()
//
//        // English task
//        if let rec = recognizerEN, rec.isAvailable {
//            taskEN = rec.recognitionTask(with: rEN) { [weak self] result, error in
//                guard let self = self else { return }
//                if let result = result {
//                    self.latestTextEN = result.bestTranscription.formattedString
//                    self.updateBest()
//                    if result.isFinal { self.fireFinal() }
//                }
//                if error != nil { self.latestTextEN = self.latestTextEN }
//            }
//        }
//
//        // Mandarin task
//        if let rec = recognizerZH, rec.isAvailable {
//            taskZH = rec.recognitionTask(with: rZH) { [weak self] result, error in
//                guard let self = self else { return }
//                if let result = result {
//                    self.latestTextZH = result.bestTranscription.formattedString
//                    self.updateBest()
//                    if result.isFinal { self.fireFinal() }
//                }
//                if error != nil { self.latestTextZH = self.latestTextZH }
//            }
//        }
//    }
//
//    // MARK: - Stop
//
//    func stopListening() {
//        if audioEngine.isRunning {
//            audioEngine.stop()
//            audioEngine.inputNode.removeTap(onBus: 0)
//        }
//        requestEN?.endAudio()
//        requestZH?.endAudio()
//        requestEN = nil
//        requestZH = nil
//        taskEN?.cancel()
//        taskZH?.cancel()
//        taskEN = nil
//        taskZH = nil
//
//        try? AVAudioSession.sharedInstance().setActive(false,
//              options: .notifyOthersOnDeactivation)
//    }
//
//    // MARK: - Private
//
//    private func updateBest() {
//        latestText = latestTextZH.count >= latestTextEN.count
//            ? latestTextZH
//            : latestTextEN
//    }
//
//    private func fireFinal() {
//        updateBest()
//        let best = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
//        guard !best.isEmpty else { return }
//        finalText = best
//        DispatchQueue.main.async { self.onFinal?(best) }
//    }
//}
