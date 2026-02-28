import AVFoundation

final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {

    enum Mode {
        case apple
        case elevenlabs
    }

    // Choose mode here (default: apple)
    var mode: Mode = .apple

    // ElevenLabs settings (set from Secrets)
    var apiKey: String = ""
    var voiceId: String = ""

    // Callbacks
    var onFinished: (() -> Void)?

    // Apple TTS
    private let synthesizer = AVSpeechSynthesizer()

    // ElevenLabs TTS
    private let tts = ElevenLabsTTSService()
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        switch mode {
        case .apple:
            return synthesizer.isSpeaking
        case .elevenlabs:
            return player?.isPlaying ?? false
        }
    }

    /// Stop any current speech (Apple or ElevenLabs). Safe to call from anywhere.
    func stop() {
        onFinished = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    func speak(_ text: String) {
        // Force playback session (important after recording)
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
        } catch {
            print("⚠️ Audio session error:", error)
        }
        
        print("SpeechManager mode:", mode)

        switch mode {
        case .apple:
            speakApple(text)
        case .elevenlabs:
            speakElevenLabs(text)
        }
    }

    private func speakApple(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.4
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    private func speakElevenLabs(_ text: String) {
        
        print("ElevenLabs TTS voiceId:", voiceId)
        
        // If you didn’t set key/id yet, fallback to Apple so demo doesn't break
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

                        // Trigger onFinished when playback ends
                        self.player?.delegate = self
                    } catch {
                        print("Audio player error:", error)
                        self.onFinished?()
                    }
                }
            } catch {
                print("ElevenLabs TTS error:", error)
                // fallback
                DispatchQueue.main.async {
                    self.speakApple(text)
                }
            }
        }
    }

    // Apple synthesizer finished
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinished?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinished?()
    }
}

// MARK: - AVAudioPlayerDelegate for ElevenLabs
extension SpeechManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }
}




//import AVFoundation
//
//final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
//    private let synthesizer = AVSpeechSynthesizer()
//    var onFinished: (() -> Void)?
//
//    override init() {
//        super.init()
//        synthesizer.delegate = self
//    }
//
//    var isSpeaking: Bool { synthesizer.isSpeaking }
//
//    func speak(_ text: String) {
//        // Force audio session back to playback each time (important after recording)
//        do {
//            let audio = AVAudioSession.sharedInstance()
//            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
//            try audio.setActive(true)
//        } catch {
//            print("⚠️ Audio session error:", error)
//        }
//
//        let utterance = AVSpeechUtterance(string: text)
//        utterance.rate = 0.4
//        utterance.volume = 1.0
//        synthesizer.speak(utterance)
//    }
//
//    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
//        onFinished?()
//    }
//
//    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
//        onFinished?()
//    }
//}
