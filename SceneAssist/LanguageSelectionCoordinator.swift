//  LanguageSelectionCoordinator.swift
//  SceneAssist
//
//  Speaks the language prompt using Apple TTS (language unknown at this point),
//  listens with BOTH EN and ZH recognizers, parses the response,
//  and calls onSelect with the chosen language.

import Foundation
import AVFoundation
import Speech
import Combine  // ← Add this line

@MainActor
final class LanguageSelectionCoordinator: NSObject, ObservableObject {
    
    private var speechFinishDelegate: SpeechFinishDelegate?

    @Published var statusText: String  = "Starting..."
    @Published var isListening: Bool   = false

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()

    private var recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognizerZH = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))

    private var requestEN: SFSpeechAudioBufferRecognitionRequest?
    private var requestZH: SFSpeechAudioBufferRecognitionRequest?
    private var taskEN: SFSpeechRecognitionTask?
    private var taskZH: SFSpeechRecognitionTask?

    private var listenWorkItem: DispatchWorkItem?
    private var onSelect: ((AppLanguage) -> Void)?
    private var hasFired = false
    private var preferredLanguage: AppLanguage? = nil

    // MARK: - Start

    func start(onSelect: @escaping (AppLanguage) -> Void) {
        self.onSelect = onSelect
        speakPrompt()
    }

    func cancel() {
        listenWorkItem?.cancel()
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Speak prompt using Apple TTS (bilingual so both users understand)

//    private func speakPrompt() {
//        statusText = "Please say English or Chinese.\n请说英语或中文。"
//
//        // Set audio session for playback
//        do {
//            try AVAudioSession.sharedInstance().setCategory(.playback,
//                mode: .spokenAudio, options: [.duckOthers])
//            try AVAudioSession.sharedInstance().setActive(true)
//        } catch {
//            print("⚠️ Audio session error:", error)
//        }
//
//        // Speak English part first
//        let en = AVSpeechUtterance(string: "Please say English or Chinese.")
//        en.voice  = AVSpeechSynthesisVoice(language: "en-US")
//        en.rate   = 0.45
//        en.volume = 1.0
//        en.postUtteranceDelay = 0.4
//
//        // Then Mandarin part
//        let zh = AVSpeechUtterance(string: "请说英语或中文。")
//        zh.voice  = AVSpeechSynthesisVoice(language: "zh-CN")
//        zh.rate   = 0.45
//        zh.volume = 1.0
//
//        // Use delegate to know when both have finished
//        speechFinishDelegate = SpeechFinishDelegate {
//            Task { @MainActor in
//                self.beginListening()
//            }
//        }
//        synthesizer.delegate = speechFinishDelegate
//
//        synthesizer.speak(en)
//        synthesizer.speak(zh)
//    }
    private func speakPrompt() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ Audio session error:", error)
        }

        speechFinishDelegate = SpeechFinishDelegate {
            Task { @MainActor in
                self.beginListening()
            }
        }
        synthesizer.delegate = speechFinishDelegate

        switch preferredLanguage {
        case .mandarin:
            statusText = "请说英语或中文。"
            let zh = AVSpeechUtterance(string: "请说英语或中文。")
            zh.voice  = AVSpeechSynthesisVoice(language: "zh-CN")
            zh.rate   = 0.45
            zh.volume = 1.0
            synthesizer.speak(zh)

        case .english:
            statusText = "Please say English or Chinese."
            let en = AVSpeechUtterance(string: "Please say English or Chinese.")
            en.voice  = AVSpeechSynthesisVoice(language: "en-US")
            en.rate   = 0.45
            en.volume = 1.0
            synthesizer.speak(en)

        case nil:
            // First launch — speak both
            statusText = "Please say English or Chinese.\n请说英语或中文。"
            let en = AVSpeechUtterance(string: "Please say English or Chinese.")
            en.voice  = AVSpeechSynthesisVoice(language: "en-US")
            en.rate   = 0.45
            en.volume = 1.0
            en.postUtteranceDelay = 0.4

            let zh = AVSpeechUtterance(string: "请说英语或中文。")
            zh.voice  = AVSpeechSynthesisVoice(language: "zh-CN")
            zh.rate   = 0.45
            zh.volume = 1.0

            synthesizer.speak(en)
            synthesizer.speak(zh)
        }
    }

    // MARK: - Listen

    private func beginListening() {
        guard !isListening else { return }
        isListening = true
        hasFired    = false
        statusText  = "Listening... say English or Chinese.\n请说英语或中文。"

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized else {
                Task { @MainActor in
                    self.statusText = "Speech recognition not authorized. Please enable in Settings."
                }
                return
            }

            do {
                try self.startRecognition()
            } catch {
                print("❌ Recognition start error:", error)
            }

            // Give user 6 seconds to respond
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.finishListening()
                }
            }
            self.listenWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
        }
    }

    private func startRecognition() throws {
        stopListening()

        try AVAudioSession.sharedInstance().setCategory(.record,
            mode: .measurement, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true,
            options: .notifyOthersOnDeactivation)

        let rEN = SFSpeechAudioBufferRecognitionRequest()
        let rZH = SFSpeechAudioBufferRecognitionRequest()
        rEN.shouldReportPartialResults = true
        rZH.shouldReportPartialResults = true
        if #available(iOS 13, *) {
            rEN.requiresOnDeviceRecognition = false
            rZH.requiresOnDeviceRecognition = false
        }
        requestEN = rEN
        requestZH = rZH

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
                guard let self = self, let result = result else { return }
                let text = result.bestTranscription.formattedString
                if let lang = self.parseLanguage(from: text) {
                    Task { @MainActor in self.confirm(lang) }
                }
            }
        }

        if let rec = recognizerZH, rec.isAvailable {
            taskZH = rec.recognitionTask(with: rZH) { [weak self] result, _ in
                guard let self = self, let result = result else { return }
                let text = result.bestTranscription.formattedString
                if let lang = self.parseLanguage(from: text) {
                    Task { @MainActor in self.confirm(lang) }
                }
            }
        }
    }

    private func stopListening() {
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
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
    }

    // MARK: - Parse what the user said

    private func parseLanguage(from text: String) -> AppLanguage? {
        let lower = text.lowercased()

        // English triggers
        if lower.contains("english") || lower.contains("英语") || lower.contains("英文") {
            return .english
        }

        // Mandarin triggers — spoken English words + Chinese characters
        if lower.contains("chinese") || lower.contains("mandarin")
            || lower.contains("中文") || lower.contains("普通话")
            || lower.contains("汉语") || lower.contains("国语") {
            return .mandarin
        }

        return nil
    }

    // MARK: - Confirm and finish

    private func confirm(_ language: AppLanguage) {
        guard !hasFired else { return }
        hasFired = true
        preferredLanguage = language

        listenWorkItem?.cancel()
        stopListening()
        isListening = false

        let confirmText: String
        let utteranceText: String
        let voiceLang: String

        switch language {
        case .english:
            confirmText   = "English selected."
            utteranceText = "English selected. Starting SceneAssist."
            voiceLang     = "en-US"
        case .mandarin:
            confirmText   = "已选择中文。"
            utteranceText = "已选择中文。正在启动。"
            voiceLang     = "zh-CN"
        }

        statusText = confirmText

        // Speak confirmation then call onSelect
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        let utterance = AVSpeechUtterance(string: utteranceText)
        utterance.voice  = AVSpeechSynthesisVoice(language: voiceLang)
        utterance.rate   = 0.45
        utterance.volume = 1.0

        speechFinishDelegate = SpeechFinishDelegate {
            Task { @MainActor in
                self.onSelect?(language)
            }
        }
        synthesizer.delegate = speechFinishDelegate
        synthesizer.speak(utterance)
    }

    private func finishListening() {
        guard !hasFired else { return }
        // Timed out without a valid answer — retry
        stopListening()
        isListening = false
        statusText  = "Sorry, I didn't catch that. Please try again."

        // Wait a moment then speak the prompt again
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.speakPrompt()
        }
    }
}

// MARK: - Minimal AVSpeechSynthesizerDelegate helper

/// Fires a closure when the last queued utterance finishes.
private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: () -> Void
    init(_ onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) {
        // Only fire on the last utterance in the queue
        if !synthesizer.isSpeaking {
            onFinish()
        }
    }
}
