import SwiftUI
import Combine
import AVFoundation

// Simple speaker + listener dedicated to the start/how-it-works guide. Uses ElevenLabs TTS.
@MainActor
final class StartGuideSpeaker: ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var isListening: Bool = false
    /// Shown on screen so you can see what recognition heard (and we react to it live).
    @Published var lastHeardText: String = ""

    private let speech = SpeechManager()
    private let voiceInput = VoiceInputService()

    private enum Phase {
        case idle
        case instructions
        case listeningCue  // short "say start or repeat instructions" prompt
        case listeningForCommand
    }

    private var phase: Phase = .idle
    private var onStartCommand: (() -> Void)?
    private var listenWorkItem: DispatchWorkItem?
    private var listenDelayWorkItem: DispatchWorkItem?
    private var listenRetryCount: Int = 0
    private var pollTimer: Timer?

    // NEW: store final recognized text from onFinal callback
    private var finalHeardText: String = ""

    init() {
        speech.mode = .elevenlabs
        speech.apiKey = Secrets.elevenLabsApiKey
        speech.voiceId = Secrets.elevenLabsVoiceId
    }

    func configure(onStart: @escaping () -> Void) {
        self.onStartCommand = onStart
    }

    func speakInstructions() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        speech.stop()
        speech.onFinished = { [weak self] in
            Task { @MainActor in
                self?.didFinishInstructions()
            }
        }
        isSpeaking = true
        phase = .instructions
        speech.speak(AppInstructions.text)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        listenWorkItem?.cancel()
        listenDelayWorkItem?.cancel()
        if isListening {
            voiceInput.stopListening()
        }
        speech.stop()
        isSpeaking = false
        isListening = false
        lastHeardText = ""
        finalHeardText = ""
        phase = .idle
        listenRetryCount = 0
    }

    private func didFinishInstructions() {
        isSpeaking = false
        phase = .listeningCue
        listenRetryCount = 0
        let cue = "Say start to begin, or repeat instructions to hear again."
        speech.onFinished = { [weak self] in
            Task { @MainActor in
                self?.didFinishCue()
            }
        }
        isSpeaking = true
        speech.speak(cue)
    }

    private func didFinishCue() {
        isSpeaking = false
        listenDelayWorkItem?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let delay = DispatchWorkItem { [weak self] in
            self?.beginListeningForCommand()
        }
        listenDelayWorkItem = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: delay)
    }

    private func beginListeningForCommand() {
        listenDelayWorkItem?.cancel()
        isListening = true
        lastHeardText = ""
        finalHeardText = ""
        phase = .listeningForCommand
        listenWorkItem?.cancel()
        pollTimer?.invalidate()

        voiceInput.requestPermissions { [weak self] ok in
            guard let self = self else { return }

            guard ok else {
                self.isListening = false
                self.phase = .idle
                return
            }

            do {
                // ✅ FIX: startListening now requires onFinal callback
                try self.voiceInput.startListening(onFinal: { [weak self] finalText in
                    guard let self = self else { return }
                    self.finalHeardText = finalText
                })
            } catch {
                self.isListening = false
                self.phase = .idle
                return
            }

            // Timeout after 7 seconds if no match
            let work = DispatchWorkItem { [weak self] in
                self?.finishListeningAndHandleCommand()
            }
            self.listenWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: work)

            // Poll every 0.8s so we react as soon as we hear "start" or "repeat"
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkHeardAndReact()
                }
            }
            if let t = self.pollTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    /// Called every 0.8s while listening. React immediately if we hear a command.
    private func checkHeardAndReact() {
        guard phase == .listeningForCommand, isListening else { return }

        let raw = voiceInput.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastHeardText = raw

        let phrase = raw.lowercased()
        guard !phrase.isEmpty else { return }

        // start / begin
        if phrase.contains("start") || phrase.contains("begin") {
            pollTimer?.invalidate()
            pollTimer = nil
            listenWorkItem?.cancel()
            isListening = false
            voiceInput.stopListening()
            phase = .idle
            onStartCommand?()
            return
        }

        // "repeat" (e.g. "Repeat instructions") or "hear/read instruction(s)"
        if phrase.contains("repeat")
            || (phrase.contains("hear") && (phrase.contains("instruction") || phrase.contains("instruct")))
            || (phrase.contains("read") && (phrase.contains("instruction") || phrase.contains("instruct")))
            || phrase.contains("instruction again")
            || phrase.contains("instructions again") {

            pollTimer?.invalidate()
            pollTimer = nil
            listenWorkItem?.cancel()
            isListening = false
            voiceInput.stopListening()
            phase = .idle
            speakInstructions()
            return
        }
    }

    private func finishListeningAndHandleCommand() {
        pollTimer?.invalidate()
        pollTimer = nil
        listenWorkItem?.cancel()
        isListening = false
        voiceInput.stopListening()

        // Give the recognition callback time to run and update finalHeardText/latestText.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.processHeardPhrase()
        }
    }

    private func processHeardPhrase() {
        // Prefer final text if we got it
        let heard = (finalHeardText.isEmpty ? voiceInput.latestText : finalHeardText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        lastHeardText = heard

        let phrase = heard
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
        let compact = phrase.replacingOccurrences(of: " ", with: "")

        if phrase.isEmpty {
            if listenRetryCount < 1 {
                listenRetryCount += 1
                phase = .listeningCue
                speech.onFinished = { [weak self] in
                    Task { @MainActor in
                        self?.didFinishCue()
                    }
                }
                isSpeaking = true
                speech.speak("I didn't catch that. Say start to begin, or repeat instructions to hear again.")
            } else {
                phase = .idle
            }
            return
        }

        // start / begin
        if phrase.contains("start") || phrase.contains("begin") {
            phase = .idle
            onStartCommand?()
            return
        }

        // repeat instructions
        let wantsRepeat =
            phrase.contains("repeat")
            || (phrase.contains("hear") && phrase.contains("instruction"))
            || (phrase.contains("read") && phrase.contains("instruction"))
            || phrase.contains("instruction again")
            || phrase.contains("instructions again")
            || compact.contains("repeatinstructions")

        if wantsRepeat {
            phase = .idle
            speakInstructions()
            return
        }

        phase = .idle
    }
}

struct StartGuideView: View {
    let onStart: () -> Void

    @StateObject private var speaker = StartGuideSpeaker()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to SceneAssist")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                Text("Here’s how it works:")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("1. First, we’ll ask for your height in centimeters. This helps estimate distances.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("2. Then, point your phone around. SceneAssist will describe what is around you and warn you about obstacles.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("3. To ask a question, press and hold anywhere on the screen and speak. While you hold, SceneAssist will pause scanning and listen.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("4. When you release, SceneAssist will respond.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("5. To resume scanning, say “Start scanning again.”")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can also say “start” to begin, or “repeat instructions” to hear this page again.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text("Safety")
                    .font(.headline)
                Text("SceneAssist is an assistive tool. Always use your cane or guide and stay aware of your surroundings.")
                    .font(.body)
            }

            Spacer()

            if !speaker.lastHeardText.isEmpty {
                Text("Heard: \"\(speaker.lastHeardText)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Heard: \(speaker.lastHeardText)")
            }

            VStack(spacing: 12) {
                Button(action: onStart) {
                    Text("Start SceneAssist")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
                .accessibilityLabel("Start SceneAssist")
                .accessibilityHint("Begins scanning mode.")

                Button(action: {
                    speaker.speakInstructions()
                }) {
                    Text("Hear Instructions Again")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                }
                .accessibilityLabel("Hear instructions again")
                .accessibilityHint("Plays the instructions out loud.")
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            speaker.configure(onStart: onStart)
            speaker.speakInstructions()
        }
        .onDisappear {
            speaker.stop()
        }
    }
}



//import SwiftUI
//import Combine
//import AVFoundation
//
//// Simple speaker + listener dedicated to the start/how-it-works guide. Uses ElevenLabs TTS.
//@MainActor
//final class StartGuideSpeaker: ObservableObject {
//    @Published var isSpeaking: Bool = false
//    @Published var isListening: Bool = false
//    /// Shown on screen so you can see what recognition heard (and we react to it live).
//    @Published var lastHeardText: String = ""
//    
//    private let speech = SpeechManager()
//    private let voiceInput = VoiceInputService()
//    
//    private enum Phase {
//        case idle
//        case instructions
//        case listeningCue  // short "say start or repeat instructions" prompt
//        case listeningForCommand
//    }
//    
//    private var phase: Phase = .idle
//    private var onStartCommand: (() -> Void)?
//    private var listenWorkItem: DispatchWorkItem?
//    private var listenDelayWorkItem: DispatchWorkItem?
//    private var listenRetryCount: Int = 0
//    private var pollTimer: Timer?
//    
//    init() {
//        speech.mode = .elevenlabs
//        speech.apiKey = Secrets.elevenLabsApiKey
//        speech.voiceId = Secrets.elevenLabsVoiceId
//    }
//    
//    func configure(onStart: @escaping () -> Void) {
//        self.onStartCommand = onStart
//    }
//    
//    func speakInstructions() {
//        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
//        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
//        
//        speech.stop()
//        speech.onFinished = { [weak self] in
//            Task { @MainActor in
//                self?.didFinishInstructions()
//            }
//        }
//        isSpeaking = true
//        phase = .instructions
//        speech.speak(AppInstructions.text)
//    }
//    
//    func stop() {
//        pollTimer?.invalidate()
//        pollTimer = nil
//        listenWorkItem?.cancel()
//        listenDelayWorkItem?.cancel()
//        if isListening {
//            voiceInput.stopListening()
//        }
//        speech.stop()
//        isSpeaking = false
//        isListening = false
//        lastHeardText = ""
//        phase = .idle
//        listenRetryCount = 0
//    }
//    
//    private func didFinishInstructions() {
//        isSpeaking = false
//        phase = .listeningCue
//        listenRetryCount = 0
//        let cue = "Say start to begin, or repeat instructions to hear again."
//        speech.onFinished = { [weak self] in
//            Task { @MainActor in
//                self?.didFinishCue()
//            }
//        }
//        isSpeaking = true
//        speech.speak(cue)
//    }
//    
//    private func didFinishCue() {
//        isSpeaking = false
//        listenDelayWorkItem?.cancel()
//        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
//        let delay = DispatchWorkItem { [weak self] in
//            self?.beginListeningForCommand()
//        }
//        listenDelayWorkItem = delay
//        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: delay)
//    }
//    
//    private func beginListeningForCommand() {
//        listenDelayWorkItem?.cancel()
//        isListening = true
//        lastHeardText = ""
//        phase = .listeningForCommand
//        listenWorkItem?.cancel()
//        pollTimer?.invalidate()
//        
//        voiceInput.requestPermissions { [weak self] ok in
//            guard let self = self else { return }
//            
//            guard ok else {
//                self.isListening = false
//                self.phase = .idle
//                return
//            }
//            
//            do {
//                try self.voiceInput.startListening()
//            } catch {
//                self.isListening = false
//                self.phase = .idle
//                return
//            }
//            
//            // Timeout after 7 seconds if no match
//            let work = DispatchWorkItem { [weak self] in
//                self?.finishListeningAndHandleCommand()
//            }
//            self.listenWorkItem = work
//            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: work)
//            
//            // Poll every 0.8s so we react as soon as we hear "start" or "repeat"
//            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
//                Task { @MainActor in
//                    self?.checkHeardAndReact()
//                }
//            }
//            RunLoop.main.add(self.pollTimer!, forMode: .common)
//        }
//    }
//    
//    /// Called every 0.8s while listening. React immediately if we hear a command.
//    private func checkHeardAndReact() {
//        guard phase == .listeningForCommand, isListening else { return }
//        
//        let raw = voiceInput.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
//        lastHeardText = raw
//        
//        let phrase = raw.lowercased()
//        guard !phrase.isEmpty else { return }
//        
//        if phrase.contains("start") {
//            pollTimer?.invalidate()
//            pollTimer = nil
//            listenWorkItem?.cancel()
//            isListening = false
//            voiceInput.stopListening()
//            phase = .idle
//            onStartCommand?()
//            return
//        }
//        
//        // "repeat" (e.g. "Repeat instruct") or "hear/read instruction(s)"
//        if phrase.contains("repeat")
//            || (phrase.contains("hear") && (phrase.contains("instruction") || phrase.contains("instruct")))
//            || (phrase.contains("read") && (phrase.contains("instruction") || phrase.contains("instruct")))
//            || phrase.contains("instruction again")
//            || phrase.contains("instructions again") {
//            pollTimer?.invalidate()
//            pollTimer = nil
//            listenWorkItem?.cancel()
//            isListening = false
//            voiceInput.stopListening()
//            phase = .idle
//            speakInstructions()
//            return
//        }
//    }
//    
//    private func finishListeningAndHandleCommand() {
//        pollTimer?.invalidate()
//        pollTimer = nil
//        listenWorkItem?.cancel()
//        isListening = false
//        voiceInput.stopListening()
//        
//        // Give the recognition callback time to run and update latestText on main.
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//            self?.processHeardPhrase()
//        }
//    }
//    
//    private func processHeardPhrase() {
//        lastHeardText = voiceInput.latestText
//        let phrase = voiceInput.latestText
//            .trimmingCharacters(in: .whitespacesAndNewlines)
//            .lowercased()
//            .replacingOccurrences(of: "  ", with: " ")
//        
//        if phrase.isEmpty {
//            if listenRetryCount < 1 {
//                listenRetryCount += 1
//                phase = .listeningCue
//                speech.onFinished = { [weak self] in
//                    Task { @MainActor in
//                        self?.didFinishCue()
//                    }
//                }
//                isSpeaking = true
//                speech.speak("I didn't catch that. Say start to begin, or repeat instructions to hear again.")
//            } else {
//                phase = .idle
//            }
//            return
//        }
//        
//        // "start" (alone or in "start the app", "start scene assist", etc.)
//        if phrase.contains("start") {
//            phase = .idle
//            onStartCommand?()
//            return
//        }
//        
//        // "repeat" / "repeat instructions" / "hear instructions" / "read instructions" etc.
//        let wantsRepeat = phrase.contains("repeat")
//            || (phrase.contains("hear") && phrase.contains("instruction"))
//            || (phrase.contains("read") && phrase.contains("instruction"))
//            || phrase.contains("instruction again")
//            || phrase.contains("instructions again")
//        if wantsRepeat {
//            phase = .idle
//            speakInstructions()
//            return
//        }
//        
//        phase = .idle
//    }
//}
//
//struct StartGuideView: View {
//    let onStart: () -> Void
//    
//    @StateObject private var speaker = StartGuideSpeaker()
//    
//    var body: some View {
//        VStack(alignment: .leading, spacing: 24) {
//            Spacer(minLength: 20)
//            
//            VStack(alignment: .leading, spacing: 12) {
//                Text("Welcome to SceneAssist")
//                    .font(.largeTitle.bold())
//                    .accessibilityAddTraits(.isHeader)
//                
//                Text("Here’s how it works:")
//                    .font(.headline)
//            }
//            
//            VStack(alignment: .leading, spacing: 12) {
//                Text("1. First, we’ll ask for your height in centimeters. This helps estimate distances.")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//                Text("2. Then, point your phone around. SceneAssist will describe what is around you and warn you about obstacles.")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//                Text("3. To ask a question, press and hold anywhere on the screen and speak. While you hold, SceneAssist will pause scanning and listen.")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//                Text("4. When you release, SceneAssist will respond.")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//                Text("5. To resume scanning, say “Start scanning again.”")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//                Text("You can also say “start” to begin, or “repeat instructions” to hear this page again.")
//                    .font(.body)
//                    .lineLimit(nil)
//                    .fixedSize(horizontal: false, vertical: true)
//            }
//            .accessibilityElement(children: .combine)
//            
//            VStack(alignment: .leading, spacing: 8) {
//                Text("Safety")
//                    .font(.headline)
//                Text("SceneAssist is an assistive tool. Always use your cane or guide and stay aware of your surroundings.")
//                    .font(.body)
//            }
//            
//            Spacer()
//            
//            if !speaker.lastHeardText.isEmpty {
//                Text("Heard: \"\(speaker.lastHeardText)\"")
//                    .font(.subheadline)
//                    .foregroundColor(.secondary)
//                    .lineLimit(2)
//                    .accessibilityLabel("Heard: \(speaker.lastHeardText)")
//            }
//            
//            VStack(spacing: 12) {
//                Button(action: onStart) {
//                    Text("Start SceneAssist")
//                        .font(.headline)
//                        .frame(maxWidth: .infinity)
//                        .padding()
//                        .background(Color.accentColor)
//                        .foregroundColor(.white)
//                        .cornerRadius(16)
//                }
//                .accessibilityLabel("Start SceneAssist")
//                .accessibilityHint("Begins scanning mode.")
//                
//                Button(action: {
//                    speaker.speakInstructions()
//                }) {
//                    Text("Hear Instructions Again")
//                        .font(.body)
//                        .frame(maxWidth: .infinity)
//                        .padding()
//                        .background(Color(.secondarySystemBackground))
//                        .foregroundColor(.primary)
//                        .cornerRadius(16)
//                }
//                .accessibilityLabel("Hear instructions again")
//                .accessibilityHint("Plays the instructions out loud.")
//            }
//        }
//        .padding()
//        .background(Color(.systemBackground))
//        .ignoresSafeArea(edges: .bottom)
//        .onAppear {
//            speaker.configure(onStart: onStart)
//            speaker.speakInstructions()
//        }
//        .onDisappear {
//            speaker.stop()
//        }
//    }
//}
//
