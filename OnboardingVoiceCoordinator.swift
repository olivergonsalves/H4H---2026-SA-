import Foundation
import Combine
import AVFoundation
import Speech

// Coordinator that runs the voice-only onboarding flow:
// speak prompt → listen → parse → confirm → dismiss.
@MainActor
final class OnboardingVoiceCoordinator: ObservableObject {

    enum SpeechPhase {
        case idle
        case initialPrompt
        case retryPrompt
        case confirmation
        case fatalError
    }

    @Published var statusText: String = ""
    @Published var recognizedText: String = ""
    @Published var isListening: Bool = false

    private let speech = SpeechManager()
    private let voiceInput = VoiceInputService()
    private var currentPhase: SpeechPhase = .idle
    private weak var profile: UserProfileStore?
    private var completion: (() -> Void)?
    private var listenWorkItem: DispatchWorkItem?

    // NEW: store final recognized text (prevents “What is” partials)
    private var finalHeardText: String = ""

    init() {
        // If you’re still on Apple TTS, this is harmless.
        // If you are using the hybrid SpeechManager, it will switch to ElevenLabs.
        speech.mode = .elevenlabs
        speech.apiKey = Secrets.elevenLabsApiKey
        speech.voiceId = Secrets.elevenLabsVoiceId
    }

    func start(profile: UserProfileStore, onComplete: @escaping () -> Void) {
        guard currentPhase == .idle else { return }
        self.profile = profile
        self.completion = onComplete
        speak(text: "What is your height in centimeters?", phase: .initialPrompt)
    }

    func cancel() {
        listenWorkItem?.cancel()
        voiceInput.stopListening()
        speech.stop()
        isListening = false
        currentPhase = .idle
        finalHeardText = ""
    }

    private func speak(text: String, phase: SpeechPhase) {
        currentPhase = phase
        statusText = text

        // When speech finishes, move to next step
        speech.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                switch self.currentPhase {
                case .initialPrompt, .retryPrompt:
                    self.beginListening()
                case .confirmation:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.currentPhase = .idle
                        self.completion?()
                    }
                case .fatalError, .idle:
                    break
                }
            }
        }

        speech.speak(text)
    }

    private func beginListening() {
        isListening = true
        recognizedText = ""
        statusText = "Listening for your height..."
        listenWorkItem?.cancel()
        finalHeardText = ""

        voiceInput.requestPermissions { [weak self] ok in
            guard let self = self else { return }

            guard ok else {
                self.isListening = false
                self.speak(
                    text: "Speech recognition is not allowed. Please enable it in Settings.",
                    phase: .fatalError
                )
                return
            }

            do {
                // IMPORTANT: updated startListening now requires onFinal callback.
                try self.voiceInput.startListening { [weak self] finalText in
                    guard let self = self else { return }
                    self.finalHeardText = finalText
                }
            } catch {
                self.isListening = false
                self.speak(
                    text: "I could not start listening. Please try again.",
                    phase: .fatalError
                )
                return
            }

            // Stop listening after 4 seconds (or adjust as needed)
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishListeningAndProcess()
            }
            self.listenWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
        }
    }

    private func finishListeningAndProcess() {
        isListening = false
        voiceInput.stopListening()

        // Use final text if available, otherwise fallback to latest partial
        let raw = (finalHeardText.isEmpty ? voiceInput.latestText : finalHeardText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        recognizedText = raw

        guard let height = parseSpokenHeight(raw) else {
            speak(
                text: "That doesn't seem valid. Please say your height in centimeters.",
                phase: .retryPrompt
            )
            return
        }

        guard 80...250 ~= height else {
            speak(
                text: "That doesn't seem valid. Please say a height between eighty and two hundred fifty centimeters.",
                phase: .retryPrompt
            )
            return
        }

        profile?.saveHeightCm(Double(height))

        let confirmation = "Thank you, your height has been stored as \(height) centimeters."
        speak(text: confirmation, phase: .confirmation)
    }
}

// Minimal parser for spoken heights like:
// "one eighty", "one hundred eighty", "one hundred and eighty", or "180".
func parseSpokenHeight(_ text: String) -> Int? {
    if text.isEmpty { return nil }

    // If user said digits: "180"
    let digitChars = text.compactMap { $0.isNumber ? $0 : nil }
    if !digitChars.isEmpty, let n = Int(String(digitChars)) {
        return n
    }

    let normalizedTokens = text
        .lowercased()
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: " and ", with: " ")
        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
        .filter { !$0.isEmpty }

    if normalizedTokens.isEmpty { return nil }

    let wordToValue: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    var tokens: [String] = []
    for w in normalizedTokens {
        if w == "hundred" || wordToValue[w] != nil {
            tokens.append(w)
        }
    }

    if tokens.isEmpty { return nil }

    // Handle "one eighty" → 180
    if tokens.count == 2,
       let first = wordToValue[tokens[0]],
       let tens = wordToValue[tokens[1]],
       tens >= 20 {
        return first * 100 + tens
    }

    var current = 0

    for w in tokens {
        if w == "hundred" {
            if current == 0 {
                current = 100
            } else {
                current *= 100
            }
        } else if let v = wordToValue[w] {
            current += v
        }
    }

    return current > 0 ? current : nil
}



//import Foundation
//import Combine
//import AVFoundation
//import Speech
//
//// Coordinator that runs the voice-only onboarding flow:
//// speak prompt → listen → parse → confirm → dismiss. Uses ElevenLabs TTS.
//@MainActor
//final class OnboardingVoiceCoordinator: ObservableObject {
//
//    enum SpeechPhase {
//        case idle
//        case initialPrompt
//        case retryPrompt
//        case confirmation
//        case fatalError
//    }
//
//    @Published var statusText: String = ""
//    @Published var recognizedText: String = ""
//    @Published var isListening: Bool = false
//
//    private let speech = SpeechManager()
//    private let voiceInput = VoiceInputService()
//    private var currentPhase: SpeechPhase = .idle
//    private weak var profile: UserProfileStore?
//    private var completion: (() -> Void)?
//    private var listenWorkItem: DispatchWorkItem?
//
//    init() {
//        speech.mode = .elevenlabs
//        speech.apiKey = Secrets.elevenLabsApiKey
//        speech.voiceId = Secrets.elevenLabsVoiceId
//    }
//
//    func start(profile: UserProfileStore, onComplete: @escaping () -> Void) {
//        guard currentPhase == .idle else { return }
//        self.profile = profile
//        self.completion = onComplete
//        speak(text: "What is your height in centimeters?", phase: .initialPrompt)
//    }
//
//    func cancel() {
//        listenWorkItem?.cancel()
//        voiceInput.stopListening()
//        speech.stop()
//        isListening = false
//        currentPhase = .idle
//    }
//
//    private func speak(text: String, phase: SpeechPhase) {
//        currentPhase = phase
//        statusText = text
//
//        speech.onFinished = { [weak self] in
//            Task { @MainActor in
//                guard let self = self else { return }
//                switch self.currentPhase {
//                case .initialPrompt, .retryPrompt:
//                    self.beginListening()
//                case .confirmation:
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
//                        self.currentPhase = .idle
//                        self.completion?()
//                    }
//                case .fatalError, .idle:
//                    break
//                }
//            }
//        }
//        speech.speak(text)
//    }
//
//    private func beginListening() {
//        isListening = true
//        recognizedText = ""
//        statusText = "Listening for your height..."
//        listenWorkItem?.cancel()
//
//        voiceInput.requestPermissions { [weak self] ok in
//            guard let self = self else { return }
//
//            guard ok else {
//                self.isListening = false
//                self.speak(
//                    text: "Speech recognition is not allowed. Please enable it in Settings.",
//                    phase: .fatalError
//                )
//                return
//            }
//
//            do {
//                try self.voiceInput.startListening()
//            } catch {
//                self.isListening = false
//                self.speak(
//                    text: "I could not start listening. Please try again.",
//                    phase: .fatalError
//                )
//                return
//            }
//
//            let workItem = DispatchWorkItem { [weak self] in
//                self?.finishListeningAndProcess()
//            }
//            self.listenWorkItem = workItem
//            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
//        }
//    }
//
//    private func finishListeningAndProcess() {
//        isListening = false
//        voiceInput.stopListening()
//
//        let raw = voiceInput.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
//        recognizedText = raw
//
//        guard let height = parseSpokenHeight(raw) else {
//            speak(
//                text: "That doesn't seem valid. Please say your height in centimeters.",
//                phase: .retryPrompt
//            )
//            return
//        }
//
//        guard 80...250 ~= height else {
//            speak(
//                text: "That doesn't seem valid. Please say a height between eighty and two hundred fifty centimeters.",
//                phase: .retryPrompt
//            )
//            return
//        }
//
//        profile?.saveHeightCm(Double(height))
//
//        let confirmation = "Thank you, your height has been stored as \(height) centimeters."
//        speak(text: confirmation, phase: .confirmation)
//    }
//}
//
//// Minimal parser for spoken heights like:
//// "one eighty", "one hundred eighty", "one hundred and eighty", or "180".
//func parseSpokenHeight(_ text: String) -> Int? {
//    if text.isEmpty { return nil }
//
//    let digitChars = text.compactMap { $0.isNumber ? $0 : nil }
//    if !digitChars.isEmpty, let n = Int(String(digitChars)) {
//        return n
//    }
//
//    let normalizedTokens = text
//        .lowercased()
//        .replacingOccurrences(of: "-", with: " ")
//        .replacingOccurrences(of: " and ", with: " ")
//        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
//        .filter { !$0.isEmpty }
//
//    if normalizedTokens.isEmpty { return nil }
//
//    let wordToValue: [String: Int] = [
//        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
//        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
//        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
//        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
//        "eighteen": 18, "nineteen": 19,
//        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
//        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
//    ]
//
//    var tokens: [String] = []
//    for w in normalizedTokens {
//        if w == "hundred" || wordToValue[w] != nil {
//            tokens.append(w)
//        }
//    }
//
//    if tokens.isEmpty { return nil }
//
//    // Handle "one eighty" → 180 style input
//    if tokens.count == 2,
//       let first = wordToValue[tokens[0]],
//       let tens = wordToValue[tokens[1]],
//       tens >= 20 {
//        return first * 100 + tens
//    }
//
//    var total = 0
//    var current = 0
//
//    for w in tokens {
//        if w == "hundred" {
//            if current == 0 {
//                current = 100
//            } else {
//                current *= 100
//            }
//        } else if let v = wordToValue[w] {
//            current += v
//        }
//    }
//
//    total += current
//    return total > 0 ? total : nil
//}
//

