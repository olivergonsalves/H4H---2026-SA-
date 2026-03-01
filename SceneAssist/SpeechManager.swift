//  SpeechManager.swift
//  SceneAssist
//
//  English  → ElevenLabs TTS
//  Mandarin → Apple TTS with zh-CN voice

import AVFoundation

final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {

    enum Mode {
        case apple
        case elevenlabs
    }

    var mode: Mode = .apple
    var apiKey: String  = ""
    var voiceId: String = ""
    var language: AppLanguage = .english
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let tts         = ElevenLabsTTSService()
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // Mandarin → Apple zh-CN always. English → ElevenLabs (fallback Apple en-US).
    private var effectiveMode: Mode {
        switch language {
        case .mandarin: return .apple
        case .english:  return mode
        }
    }

    var isSpeaking: Bool {
        switch effectiveMode {
        case .apple:      return synthesizer.isSpeaking
        case .elevenlabs: return player?.isPlaying ?? false
        }
    }

    func stop() {
        onFinished = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    func speak(_ text: String) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
        } catch {
            print("⚠️ Audio session error:", error)
        }

        print("SpeechManager effectiveMode: \(effectiveMode), language: \(language)")

        switch effectiveMode {
        case .apple:      speakApple(text)
        case .elevenlabs: speakElevenLabs(text)
        }
    }

    private func speakApple(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate   = 0.4
        utterance.volume = 1.0

        // Always set voice explicitly — never let system guess
        switch language {
        case .mandarin: utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        case .english:  utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        synthesizer.speak(utterance)
    }

    private func speakElevenLabs(_ text: String) {
        print("ElevenLabs TTS voiceId:", voiceId)

        guard !apiKey.isEmpty, !voiceId.isEmpty else {
            speakApple(text)
            return
        }

        Task {
            do {
                let mp3 = try await tts.synthesize(text: text, voiceId: voiceId, apiKey: apiKey)

                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp3")
                try mp3.write(to: tmp)

                DispatchQueue.main.async {
                    do {
                        self.player?.stop()
                        self.player = try AVAudioPlayer(contentsOf: tmp)
                        self.player?.prepareToPlay()
                        self.player?.play()
                        self.player?.delegate = self
                    } catch {
                        print("Audio player error:", error)
                        self.onFinished?()
                    }
                }
            } catch {
                print("ElevenLabs TTS error:", error)
                DispatchQueue.main.async { self.speakApple(text) }
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) { onFinished?() }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didCancel utterance: AVSpeechUtterance) { onFinished?() }
}

extension SpeechManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }
}




////  SpeechManager.swift
////  SceneAssist
////
////  English  → ElevenLabs TTS
////  Mandarin → Apple TTS with zh-CN voice
//
//import AVFoundation
//
//final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
//
//    enum Mode {
//        case apple
//        case elevenlabs
//    }
//
//    /// Base mode (used for English). Default: apple; set to .elevenlabs in init of controller.
//    var mode: Mode = .apple
//
//    /// ElevenLabs credentials (used only when effectiveMode == .elevenlabs).
//    var apiKey: String  = ""
//    var voiceId: String = ""
//
//    /// Current app language. Setting this automatically routes TTS correctly.
//    var language: AppLanguage = .english
//
//    var onFinished: (() -> Void)?
//
//    private let synthesizer = AVSpeechSynthesizer()
//    private let tts         = ElevenLabsTTSService()
//    private var player: AVAudioPlayer?
//
//    override init() {
//        super.init()
//        synthesizer.delegate = self
//    }
//
//    /// Mandarin always uses Apple. English uses whatever `mode` is set to.
//    private var effectiveMode: Mode {
//        switch language {
//        case .mandarin: return .apple
//        case .english:  return mode
//        }
//    }
//
//    var isSpeaking: Bool {
//        switch effectiveMode {
//        case .apple:      return synthesizer.isSpeaking
//        case .elevenlabs: return player?.isPlaying ?? false
//        }
//    }
//
//    func stop() {
//        onFinished = nil
//        synthesizer.stopSpeaking(at: .immediate)
//        player?.stop()
//        player = nil
//    }
//
//    func speak(_ text: String) {
//        do {
//            let audio = AVAudioSession.sharedInstance()
//            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
//            try audio.setActive(true)
//        } catch {
//            print("⚠️ Audio session error:", error)
//        }
//
//        print("SpeechManager effectiveMode: \(effectiveMode), language: \(language)")
//
//        switch effectiveMode {
//        case .apple:      speakApple(text)
//        case .elevenlabs: speakElevenLabs(text)
//        }
//    }
//
////    private func speakApple(_ text: String) {
////        synthesizer.stopSpeaking(at: .immediate)
////        let utterance = AVSpeechUtterance(string: text)
////        utterance.rate   = 0.4
////        utterance.volume = 1.0
////
////        // Use the Mandarin voice when language is set to .mandarin
////        if language == .mandarin {
////            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
////        }
////
////        synthesizer.speak(utterance)
////    }
//    private func speakApple(_ text: String) {
//        synthesizer.stopSpeaking(at: .immediate)
//        let utterance = AVSpeechUtterance(string: text)
//        utterance.rate   = 0.4
//        utterance.volume = 1.0
//
//        switch language {
//        case .mandarin:
//            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
//        case .english:
//            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
//        }
//
//        synthesizer.speak(utterance)
//    }
//
//    private func speakElevenLabs(_ text: String) {
//        print("ElevenLabs TTS voiceId:", voiceId)
//
//        guard !apiKey.isEmpty, !voiceId.isEmpty else {
//            speakApple(text)
//            return
//        }
//
//        Task {
//            do {
//                let mp3 = try await tts.synthesize(text: text, voiceId: voiceId, apiKey: apiKey)
//
//                let tmp = FileManager.default.temporaryDirectory
//                    .appendingPathComponent(UUID().uuidString)
//                    .appendingPathExtension("mp3")
//                try mp3.write(to: tmp)
//
//                DispatchQueue.main.async {
//                    do {
//                        self.player?.stop()
//                        self.player = try AVAudioPlayer(contentsOf: tmp)
//                        self.player?.prepareToPlay()
//                        self.player?.play()
//                        self.player?.delegate = self
//                    } catch {
//                        print("Audio player error:", error)
//                        self.onFinished?()
//                    }
//                }
//            } catch {
//                print("ElevenLabs TTS error:", error)
//                DispatchQueue.main.async { self.speakApple(text) }
//            }
//        }
//    }
//
//    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
//                            didFinish utterance: AVSpeechUtterance) { onFinished?() }
//
//    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
//                            didCancel utterance: AVSpeechUtterance) { onFinished?() }
//}
//
//extension SpeechManager: AVAudioPlayerDelegate {
//    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
//        onFinished?()
//    }
//}
//
//
////import AVFoundation
////
////final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
////
////    enum Mode {
////        case apple
////        case elevenlabs
////    }
////
////    // Choose mode here (default: apple)
////    var mode: Mode = .apple
////
////    // ElevenLabs settings (set from Secrets)
////    var apiKey: String = ""
////    var voiceId: String = ""
////
////    // Callbacks
////    var onFinished: (() -> Void)?
////
////    // Apple TTS
////    private let synthesizer = AVSpeechSynthesizer()
////
////    // ElevenLabs TTS
////    private let tts = ElevenLabsTTSService()
////    private var player: AVAudioPlayer?
////
////    override init() {
////        super.init()
////        synthesizer.delegate = self
////    }
////
////    var isSpeaking: Bool {
////        switch mode {
////        case .apple:
////            return synthesizer.isSpeaking
////        case .elevenlabs:
////            return player?.isPlaying ?? false
////        }
////    }
////
////    /// Stop any current speech (Apple or ElevenLabs). Safe to call from anywhere.
////    func stop() {
////        onFinished = nil
////        synthesizer.stopSpeaking(at: .immediate)
////        player?.stop()
////        player = nil
////    }
////
////    func speak(_ text: String) {
////        // Force playback session (important after recording)
////        do {
////            let audio = AVAudioSession.sharedInstance()
////            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
////            try audio.setActive(true)
////        } catch {
////            print("⚠️ Audio session error:", error)
////        }
////        
////        print("SpeechManager mode:", mode)
////
////        switch mode {
////        case .apple:
////            speakApple(text)
////        case .elevenlabs:
////            speakElevenLabs(text)
////        }
////    }
////
////    private func speakApple(_ text: String) {
////        synthesizer.stopSpeaking(at: .immediate)
////        let utterance = AVSpeechUtterance(string: text)
////        utterance.rate = 0.4
////        utterance.volume = 1.0
////        synthesizer.speak(utterance)
////    }
////
////    private func speakElevenLabs(_ text: String) {
////        
////        print("ElevenLabs TTS voiceId:", voiceId)
////        
////        // If you didn’t set key/id yet, fallback to Apple so demo doesn't break
////        guard !apiKey.isEmpty, !voiceId.isEmpty else {
////            speakApple(text)
////            return
////        }
////
////        Task {
////            do {
////                let mp3 = try await tts.synthesize(text: text, voiceId: voiceId, apiKey: apiKey)
////
////                let tmp = FileManager.default.temporaryDirectory
////                    .appendingPathComponent(UUID().uuidString)
////                    .appendingPathExtension("mp3")
////                try mp3.write(to: tmp)
////
////                DispatchQueue.main.async {
////                    do {
////                        self.player?.stop()
////                        self.player = try AVAudioPlayer(contentsOf: tmp)
////                        self.player?.prepareToPlay()
////                        self.player?.play()
////
////                        // Trigger onFinished when playback ends
////                        self.player?.delegate = self
////                    } catch {
////                        print("Audio player error:", error)
////                        self.onFinished?()
////                    }
////                }
////            } catch {
////                print("ElevenLabs TTS error:", error)
////                // fallback
////                DispatchQueue.main.async {
////                    self.speakApple(text)
////                }
////            }
////        }
////    }
////
////    // Apple synthesizer finished
////    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
////        onFinished?()
////    }
////
////    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
////        onFinished?()
////    }
////}
////
////// MARK: - AVAudioPlayerDelegate for ElevenLabs
////extension SpeechManager: AVAudioPlayerDelegate {
////    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
////        onFinished?()
////    }
////}
////
////
////
////
//////import AVFoundation
//////
//////final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
//////    private let synthesizer = AVSpeechSynthesizer()
//////    var onFinished: (() -> Void)?
//////
//////    override init() {
//////        super.init()
//////        synthesizer.delegate = self
//////    }
//////
//////    var isSpeaking: Bool { synthesizer.isSpeaking }
//////
//////    func speak(_ text: String) {
//////        // Force audio session back to playback each time (important after recording)
//////        do {
//////            let audio = AVAudioSession.sharedInstance()
//////            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
//////            try audio.setActive(true)
//////        } catch {
//////            print("⚠️ Audio session error:", error)
//////        }
//////
//////        let utterance = AVSpeechUtterance(string: text)
//////        utterance.rate = 0.4
//////        utterance.volume = 1.0
//////        synthesizer.speak(utterance)
//////    }
//////
//////    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
//////        onFinished?()
//////    }
//////
//////    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
//////        onFinished?()
//////    }
//////}
