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
    private var language: AppLanguage = .english
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

    func configure(onStart: @escaping () -> Void, language: AppLanguage = .english) {
        self.onStartCommand = onStart
        self.language = language
        speech.language = language
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
        speech.speak(AppInstructions.text(for: language))
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
        let cue = AppInstructions.listeningCue(for: language)
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

        guard !raw.isEmpty else { return }

        if isStartCommand(raw) {
            pollTimer?.invalidate()
            pollTimer = nil
            listenWorkItem?.cancel()
            isListening = false
            voiceInput.stopListening()
            phase = .idle
            onStartCommand?()
            return
        }

        if isRepeatCommand(raw) {
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

    private func isStartCommand(_ text: String) -> Bool {
        switch language {
        case .english:
            let p = text.lowercased()
            return p.contains("start") || p.contains("begin")
        case .mandarin:
            return text.contains("开始")
        }
    }

    private func isRepeatCommand(_ text: String) -> Bool {
        switch language {
        case .english:
            let p = text.lowercased()
            return p.contains("repeat")
                || (p.contains("hear") && (p.contains("instruction") || p.contains("instruct")))
                || (p.contains("read") && (p.contains("instruction") || p.contains("instruct")))
                || p.contains("instruction again")
                || p.contains("instructions again")
        case .mandarin:
            return text.contains("重复") || text.contains("再听一遍") || text.contains("再说一遍")
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

        if heard.isEmpty {
            if listenRetryCount < 1 {
                listenRetryCount += 1
                phase = .listeningCue
                speech.onFinished = { [weak self] in
                    Task { @MainActor in
                        self?.didFinishCue()
                    }
                }
                isSpeaking = true
                speech.speak(AppInstructions.didntCatchThat(for: language))
            } else {
                phase = .idle
            }
            return
        }

        if isStartCommand(heard) {
            phase = .idle
            onStartCommand?()
            return
        }

        if isRepeatCommand(heard) {
            phase = .idle
            speakInstructions()
            return
        }

        phase = .idle
    }
}

struct StartGuideView: View {
    let language: AppLanguage
    let onStart: () -> Void

    @StateObject private var speaker = StartGuideSpeaker()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 12) {
                Text(AppInstructions.welcomeTitle(for: language))
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                Text(AppInstructions.howItWorksSubtitle(for: language))
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {

                Text(AppInstructions.step1(for: language))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppInstructions.step2(for: language))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppInstructions.step3(for: language))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppInstructions.step4(for: language))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text(AppInstructions.safetyTitle(for: language))
                    .font(.headline)
                Text(AppInstructions.safetyBody(for: language))
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
                    Text(AppInstructions.startButtonTitle(for: language))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
                .accessibilityLabel(AppInstructions.startButtonTitle(for: language))
                .accessibilityHint("Begins scanning mode.")

                Button(action: {
                    speaker.speakInstructions()
                }) {
                    Text(AppInstructions.hearAgainButtonTitle(for: language))
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                }
                .accessibilityLabel(AppInstructions.hearAgainButtonTitle(for: language))
                .accessibilityHint("Plays the instructions out loud.")
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            speaker.configure(onStart: onStart, language: language)
            speaker.speakInstructions()
        }
        .onDisappear {
            speaker.stop()
        }
    }
}

