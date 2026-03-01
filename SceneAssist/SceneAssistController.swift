//  SceneAssistController.swift
//  SceneAssist
//
//  Central coordinator: runs the scanning loop (camera → vision → guidance TTS),
//  handles press-and-hold voice Q&A (STT → LLM with scene context → TTS), and
//  responds to voice commands (e.g. repeat instructions, start/stop scanning).

import Foundation
import Combine
import CoreVideo

final class SceneAssistController: ObservableObject {

    // MARK: - Timing
    private var lastSpokeAt:              Date          = .distantPast
    private let scanIntervalSeconds:      TimeInterval  = 4.0
    private let minSecondsBetweenSpeech:  TimeInterval  = 4.0
    private let autoResumeDelaySeconds:   TimeInterval  = 6.0
    private var autoResumeWorkItem:       DispatchWorkItem?
    private var autoResumeArmed:          Bool          = false

    // MARK: - Services
    private let claude  = ClaudeService()
    private let ocr     = OCRService()
    private let voice   = VoiceInputService()
    private let speech  = SpeechManager()
    private let qwen     = VLLMQwenService()
    private let detector = ObjectDetector()

    // MARK: - Language
    private let languageDetector = LanguageDetector()
    private var currentLanguage: AppLanguage = .english

    // MARK: - Memory / State
    private var memory:            [String: String] = [:]
    private var lastSeenSign:      String           = ""
    private var lastObstacle:      String           = ""
    private var pendingUtterances: [String]         = []

    // MARK: - Published
    @Published var lastGuidance:    String = ""
    @Published var scanningEnabled: Bool   = true
    @Published var isListening:     Bool   = false

    private var lastSpokenEvent: String = ""
    private var lastScanLogAt:   Date   = .distantPast

    // MARK: - Camera / Transcripts
    let camera          = SceneCameraProvider()
    let transcriptStore = TranscriptStore()

    // MARK: - Run loop
    private var timer:        Timer? = nil
    private var isProcessing: Bool   = false

    var heightCm: Double? = nil

    // MARK: - Init

    init() {
        speech.mode    = .elevenlabs
        speech.apiKey  = Secrets.elevenLabsApiKey
        speech.voiceId = Secrets.elevenLabsVoiceId

        speech.onFinished = { [weak self] in
            self?.handleSpeechFinished()
        }
    }

    /// Called once from ContentView right after language is chosen. Never changes after.
    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
        speech.language = language
        print("🌐 Language locked to: \(language.displayName)")
    }

    // MARK: - Start / Stop

    func start() {
        camera.start()

        DispatchQueue.main.async {
            let launchText = self.currentLanguage == .mandarin
                ? "场景助手已启动。"
                : "Scene Assist Launched."
            self.speech.speak(launchText)
            self.transcriptStore.add(launchText)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tick()
        }

        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds,
                                     repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        camera.stop()
    }

    // MARK: - Auto-resume

    private func cancelAutoResume() {
        autoResumeWorkItem?.cancel()
        autoResumeWorkItem = nil
    }

    private func handleSpeechFinished() {
        guard autoResumeArmed else { return }
        autoResumeArmed = false
        cancelAutoResume()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.isListening { return }
            self.scanningEnabled = true
            self.isProcessing    = false
            self.tick()
        }
        autoResumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoResumeDelaySeconds, execute: work)
    }

    // MARK: - Scan tick
    /// Fires every scanIntervalSeconds: grab frame → OCR for signs, Claude for scene → pick salient guidance → speak one sentence.

    private func tick() {
        guard scanningEnabled, !isListening else { isProcessing = false; return }
        guard !Secrets.anthropicApiKey.isEmpty else { isProcessing = false; return }
        guard !isProcessing else { return }
        guard let frame = camera.currentFrame() else { return }
        isProcessing = true

        guard let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
            isProcessing = false
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            let foundSign: String? = await withCheckedContinuation { cont in
                self.ocr.recognizeText(from: frame) { words in
                    let upper      = words.joined(separator: " ").uppercased()
                    let normalized = upper.filter { $0.isLetter }
                    let found      = SignCatalog.shared.match(normalizedLettersOnly: normalized)
                    cont.resume(returning: found)
                }
            }

            do {
                let scene = try await self.claude.analyze(jpegData: jpeg,
                                                          language: self.currentLanguage)

                DispatchQueue.main.async {
                    self.lastSeenSign = foundSign ?? ""

                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
                        self.lastObstacle =
                            "\(firstNonSign.kind.rawValue.lowercased()):" +
                            "\(firstNonSign.label.lowercased()):" +
                            "\(firstNonSign.position.rawValue.lowercased()):" +
                            "\(firstNonSign.proximity.rawValue.lowercased())"
                    } else {
                        self.lastObstacle = ""
                    }

                    let shortList = scene.utterances
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    self.pendingUtterances = Array(shortList.prefix(6))

                    let arkitMeters = self.camera.currentCenterDistanceMeters()
                    let spoken: String?
                    if let s = foundSign {
                        spoken = self.currentLanguage == .mandarin
                            ? "\(s.capitalized) 标志在前方。"
                            : "\(s.capitalized) sign ahead."
                    } else {
                        spoken = self.primaryUtterance(from: scene, arkitCenterDistanceMeters: arkitMeters)
                    }

                    if let line = spoken {
                        let now = Date()
                        if !self.speech.isSpeaking,
                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
                           line != self.lastSpokenEvent {

                            self.lastSpokeAt     = now
                            self.lastSpokenEvent  = line
                            self.lastGuidance     = line
                            self.speech.speak(line)
                            self.transcriptStore.add(line)
                        }
                    } else {
                        let t = Date()
                        if t.timeIntervalSince(self.lastScanLogAt) >= 10 {
                            self.lastScanLogAt = t
                            self.transcriptStore.add("Scanning.")
                        }
                    }

                    self.isProcessing = false
                }

            } catch {
                DispatchQueue.main.async {
                    self.transcriptStore.add("VISION ERROR: \(error.localizedDescription)")
                    self.isProcessing = false
                }
            }
        }
    }
    
    // MARK: - AMD compression helpers (do NOT change scan logic)

    private func detectSignAsync(from pixelBuffer: CVPixelBuffer) async -> String? {
        await withCheckedContinuation { cont in
            ocr.recognizeText(from: pixelBuffer) { words in
                let upper      = words.joined(separator: " ").uppercased()
                let normalized = upper.filter { $0.isLetter }
                let found      = SignCatalog.shared.match(normalizedLettersOnly: normalized)
                cont.resume(returning: found)
            }
        }
    }

    private func detectThingsAsync(from pixelBuffer: CVPixelBuffer) async -> [DetectedThing] {
        await withCheckedContinuation { cont in
            detector.detect(from: pixelBuffer) { dets in
                cont.resume(returning: dets)
            }
        }
    }

    /// Text-only snapshot that Qwen3 can normalize into VisionScene JSON.
    /// Uses ONLY local detector outputs (no hallucination).
    private func buildSensorSnapshot(foundSign: String?, detections: [DetectedThing]) -> String {
        let top = Array(detections.prefix(6))
        let detLines = top.enumerated().map { (idx, d) in
            let c = String(format: "%.2f", d.confidence)
            return "\(idx+1). kind=\(d.kind.uppercased()) label=\(d.label) position=\(d.position.uppercased()) proximity=\(d.proximity.uppercased()) confidence=\(c)"
        }

        return """
        language=\(currentLanguage.rawValue)
        sign_keyword=\(foundSign ?? "none")
        detections_count=\(detections.count)
        detections_top:
        \(detLines.isEmpty ? "none" : detLines.joined(separator: "\n"))

        Constraints:
        - position must be LEFT/CENTER/RIGHT
        - proximity must be FAR/NEAR/CLOSE
        - do not invent objects not listed
        """
    }

    // MARK: - Primary utterance

    private func article(for noun: String) -> String {
        let first  = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
        let vowels: Set<Character> = ["a","e","i","o","u"]
        return (first != nil && vowels.contains(first!)) ? "an" : "a"
    }

    private func primaryUtterance(from scene: VisionScene, arkitCenterDistanceMeters: Double? = nil) -> String? {
        let generic: Set<String> = ["object", "item", "thing", "stuff"]

        let candidates = scene.items
            .filter { $0.kind != .SIGN }
            .filter { $0.confidence >= 0.65 }

        func score(_ it: VisionItem) -> Int {
            let posScore  = (it.position == .CENTER) ? 30 : 10
            let proxScore = (it.proximity == .CLOSE)  ? 30 : (it.proximity == .NEAR ? 20 : 0)
            return posScore + proxScore
        }

        let sorted = candidates.sorted { score($0) > score($1) }

        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
            return nil
        }

        if top.proximity == .FAR { return nil }

        let steps: Int = {
            let feet: Double
            if top.position == .CENTER, let m = arkitCenterDistanceMeters, m > 0 {
                feet = m * 3.28084
            } else {
                feet = top.approx_distance_ft ?? approxFeet(for: top.proximity)
            }
            return approxSteps(feet: feet, heightCm: heightCm)
        }()
        let stepsPhraseEn = ", about \(steps) steps away"
        let stepsPhraseZh = "，约\(steps)步远"

        if currentLanguage == .mandarin {
            let labelText: String = {
                if top.kind == .ANIMAL { return "动物" }
                if top.kind == .PERSON { return "人" }
                return top.label.lowercased()
            }()
            let whereText: String = {
                switch top.position {
                case .CENTER: return "在你正前方"
                case .LEFT:   return "在你左边"
                case .RIGHT:  return "在你右边"
                }
            }()
            let closeText  = (top.proximity == .CLOSE) ? "，非常近" : ""
            let stopPrefix = (top.proximity == .CLOSE) ? "停！" : ""
            let action: String = {
                guard top.proximity == .CLOSE else { return "" }
                switch top.position {
                case .CENTER: return "请稍微向左或向右移动。"
                case .LEFT:   return "请稍微向右移动。"
                case .RIGHT:  return "请稍微向左移动。"
                }
            }()
            return "\(stopPrefix)\(whereText)有\(labelText)\(closeText)\(stepsPhraseZh)。\(action)"
        } else {
            let labelText: String = {
                if top.kind == .ANIMAL { return "animal" }
                if top.kind == .PERSON { return "person" }
                return top.label.lowercased()
            }()
            let whereText: String = {
                switch top.position {
                case .CENTER: return "in front of you"
                case .LEFT:   return "to your left"
                case .RIGHT:  return "to your right"
                }
            }()
            let closeText  = (top.proximity == .CLOSE) ? ", very close" : ""
            let stopPrefix = (top.proximity == .CLOSE) ? "STOP! " : ""
            let action: String = {
                guard top.proximity == .CLOSE else { return "" }
                switch top.position {
                case .CENTER: return " Please move slightly left or right."
                case .LEFT:   return " Please move slightly right."
                case .RIGHT:  return " Please move slightly left."
                }
            }()
            if labelText == "person" {
                return "\(stopPrefix)A person is \(whereText)\(stepsPhraseEn).\(action)"
            } else if labelText == "animal" {
                return "\(stopPrefix)An animal is \(whereText)\(stepsPhraseEn).\(action)"
            } else {
                return "\(stopPrefix)\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(stepsPhraseEn).\(action)"
            }
        }
    }

    // MARK: - Speech helper

    private func say(_ text: String) {
        lastGuidance = text
        speech.speak(text)
        transcriptStore.add(text)
    }

    // MARK: - Language (fixed at launch, auto-detection disabled)

    private func applyDetectedLanguage(from text: String) {
        // Language is fixed at first launch by the user's explicit choice.
    }

    // MARK: - Voice input

    func beginVoice() {
        cancelAutoResume()
        scanningEnabled = false
        isListening     = true
        isProcessing    = false

        voice.requestPermissions { [weak self] ok in
            guard let self = self else { return }

            guard ok else {
                self.isListening = false
                self.say(self.currentLanguage == .mandarin
                    ? "请在设置中允许语音识别。"
                    : "Please allow speech recognition in Settings.")
                return
            }

            do {
                try self.voice.startListening { [weak self] finalText in
                    DispatchQueue.main.async {
                        self?.handleFinalVoiceText(finalText)
                    }
                }
                self.transcriptStore.add("🎤 Listening…")
            } catch {
                self.isListening = false
                self.say(self.currentLanguage == .mandarin
                    ? "抱歉，无法开始录音。"
                    : "Sorry, I could not start listening.")
            }
        }
    }

    func endVoice() {
        voice.stopListening()
        isListening = false

        let text = voice.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            say(currentLanguage == .mandarin
                ? "抱歉，没有听清楚。请再试一次。"
                : "Sorry, I didn't catch that. Please try again.")
            return
        }

        let lower   = text.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")

        if lower.contains("start scanning") || lower.contains("resume scanning")
            || lower.contains("scan again")
            || compact.contains("startscanningagain")
            || compact.contains("resumescanning")
            || compact.contains("startscanning")
            || text.contains("开始扫描") || text.contains("继续扫描") {
            resumeScanning()
            return
        }

        if lower.contains("stop scanning") || lower.contains("pause scanning")
            || text.contains("停止扫描") || text.contains("暂停扫描") {
            pauseScanning()
            return
        }

        if wantsInstructionsAgain(lower) {
            transcriptStore.add("Instructions.")
            speech.speak(AppInstructions.text(for: currentLanguage))
            return
        }

        autoResumeArmed = true
        handleUserQuestion(text, heightCm: heightCm)
    }

    private func handleFinalVoiceText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptStore.add("You: \(cleaned)")

        let lower   = cleaned.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")

        if lower.contains("start scanning") || lower.contains("resume scanning")
            || lower.contains("scan again")
            || compact.contains("startscanningagain")
            || cleaned.contains("开始扫描") || cleaned.contains("继续扫描") {
            resumeScanning()
            return
        }

        if lower.contains("stop scanning") || lower.contains("pause scanning")
            || cleaned.contains("停止扫描") || cleaned.contains("暂停扫描") {
            pauseScanning()
            return
        }

        if compact == "whatis" || lower.contains("what is") || lower.contains("what's this")
            || lower.contains("what is this")
            || cleaned.contains("这是什么") || cleaned.contains("那是什么") {
            describeWhatIsInView()
            return
        }

        if wantsInstructionsAgain(lower) {
            transcriptStore.add("Instructions.")
            speech.speak(AppInstructions.text(for: currentLanguage))
            return
        }

        autoResumeArmed = true
        handleUserQuestion(cleaned, heightCm: heightCm)
    }

    // MARK: - Scanning state helpers

    private func resumeScanning() {
        scanningEnabled  = true
        isProcessing     = false
        lastScanLogAt    = .distantPast
        lastSpokeAt      = .distantPast
        lastSpokenEvent  = ""

        transcriptStore.add("Scanning resumed.")
        speech.speak(currentLanguage == .mandarin ? "好的。" : "Okay.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tick()
        }
    }

    private func pauseScanning() {
        scanningEnabled = false
        isProcessing    = false
        transcriptStore.add("Scanning paused.")
        speech.speak(currentLanguage == .mandarin ? "已暂停。" : "Okay.")
    }

    // MARK: - Describe what is in view

    private func describeWhatIsInView() {
        scanningEnabled = false
        isProcessing    = false

        guard let frame = camera.currentFrame(),
              let jpeg  = CloudVisionService.jpegFromPixelBuffer(frame) else {
            say(currentLanguage == .mandarin ? "现在看不清楚。" : "I can't see clearly right now.")
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let scene = try await self.claude.analyze(jpegData: jpeg,
                                                          language: self.currentLanguage)
                DispatchQueue.main.async {
                    let nonSigns = scene.items.filter { $0.kind != .SIGN }
                    guard let top = nonSigns.first else {
                        self.say(self.currentLanguage == .mandarin
                            ? "我不确定那是什么。"
                            : "I'm not sure what that is.")
                        self.scanningEnabled = true
                        return
                    }

                    let label: String = {
                        if top.kind == .PERSON { return self.currentLanguage == .mandarin ? "人" : "person" }
                        if top.kind == .ANIMAL { return self.currentLanguage == .mandarin ? "动物" : "animal" }
                        return top.label.lowercased()
                    }()

                    let whereText: String = {
                        switch top.position {
                        case .CENTER: return self.currentLanguage == .mandarin ? "在你正前方" : "in front of you"
                        case .LEFT:   return self.currentLanguage == .mandarin ? "在你左边"   : "to your left"
                        case .RIGHT:  return self.currentLanguage == .mandarin ? "在你右边"   : "to your right"
                        }
                    }()

                    let closeText = (top.proximity == .CLOSE)
                        ? (self.currentLanguage == .mandarin ? "，很近" : ", very close")
                        : ""

                    let desc = self.currentLanguage == .mandarin
                        ? "看起来是\(whereText)的\(label)\(closeText)。"
                        : "It looks like a \(label) \(whereText)\(closeText)."

                    self.say(desc)
                    self.scanningEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.say(self.currentLanguage == .mandarin
                        ? "现在无法分析。"
                        : "I couldn't analyze that right now.")
                    self.scanningEnabled = true
                }
            }
        }
    }

    // MARK: - Instructions check

    private func wantsInstructionsAgain(_ lower: String) -> Bool {
        let phrases = [
            "repeat instruction", "repeat instructions",
            "hear instruction",   "hear instructions",
            "tell me how to use", "how to use the app",
            "how to use this app","how does the app work",
            "how does this app work", "instructions again",
            "explain the app",    "how do i use",
            "how do i use this"
        ]
        return phrases.contains { lower.contains($0) }
    }

    // MARK: - LLM Q&A

//    func handleUserQuestion(_ userText: String, heightCm: Double?) {
//        transcriptStore.add("You: \(userText)")
//
//        guard !Secrets.anthropicApiKey.isEmpty else {
//            say(currentLanguage == .mandarin
//                ? "请设置您的API密钥。"
//                : "Please set your Anthropic API key in Secrets.")
//            return
//        }
//
//        guard let frame = camera.currentFrame(),
//              let jpeg  = CloudVisionService.jpegFromPixelBuffer(frame) else {
//            say(currentLanguage == .mandarin
//                ? "没有摄像头画面，请对准摄像头再试。"
//                : "I don't have a camera frame. Point the camera and try again.")
//            return
//        }
//
//        Task {
//            do {
//                let scene = try await self.claude.analyze(jpegData: jpeg, language: self.currentLanguage)
//                let arkitMeters = self.camera.currentCenterDistanceMeters()
//                let distanceCandidates = self.buildDistanceCandidates(scene: scene,
//                                                                     heightCm: heightCm,
//                                                                     arkitCenterDistanceMeters: arkitMeters)
//                let stateJSON = self.buildStateJSON(heightCm: heightCm, distanceCandidates: distanceCandidates)
//                let plan = try await claude.askWithImage(jpegData: jpeg,
//                                                        userText: userText,
//                                                        stateJSON: stateJSON,
//                                                        language: currentLanguage)
//                DispatchQueue.main.async {
//                    self.execute(plan: plan)
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    let detail = error.localizedDescription
//                    self.transcriptStore.add("CLAUDE ERROR: \(detail)")
//                    print("❌ Claude askWithImage error: \(detail)")
//
//                    let spoken: String
//                    if detail.contains("401") || detail.contains("403") {
//                        spoken = self.currentLanguage == .mandarin
//                            ? "API密钥被拒绝，请检查您的密钥。"
//                            : "API key rejected. Please check your Anthropic key."
//                    } else if detail.contains("429") {
//                        spoken = self.currentLanguage == .mandarin
//                            ? "请求过于频繁，请稍后再试。"
//                            : "Rate limit hit. Please wait a moment and try again."
//                    } else if detail.contains("timed out") || detail.contains("timeout") {
//                        spoken = self.currentLanguage == .mandarin
//                            ? "请求超时，请检查网络连接。"
//                            : "Request timed out. Check your internet connection."
//                    } else if detail.contains("No JSON") || detail.contains("Decode failed") {
//                        spoken = self.currentLanguage == .mandarin
//                            ? "收到错误响应，请再试一次。"
//                            : "Got a bad response from Claude. Try again."
//                    } else if detail.contains("camera") || detail.contains("frame") {
//                        spoken = self.currentLanguage == .mandarin
//                            ? "没有摄像头画面。"
//                            : "No camera frame available."
//                    } else {
//                        spoken = "Error: \(detail)"
//                    }
//                    self.say(spoken)
//                }
//            }
//        }
//    }
    
    
    func handleUserQuestion(_ userText: String, heightCm: Double?) {
        transcriptStore.add("You: \(userText)")

        guard !Secrets.anthropicApiKey.isEmpty else {
            say(currentLanguage == .mandarin
                ? "请设置您的API密钥。"
                : "Please set your Anthropic API key in Secrets.")
            return
        }

        guard let frame = camera.currentFrame(),
              let jpeg  = CloudVisionService.jpegFromPixelBuffer(frame) else {
            say(currentLanguage == .mandarin
                ? "没有摄像头画面，请对准摄像头再试。"
                : "I don't have a camera frame. Point the camera and try again.")
            return
        }

        let amdEnabled = !Secrets.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Task {
            do {
                // ============================================================
                // ✅ AMD FEATURE (does NOT disturb existing flow):
                // Try: OCR + YOLO -> Qwen compress -> Claude text-only reasoning
                // If anything fails -> fall back to your original Claude image flow.
                // ============================================================
                if amdEnabled {
                    do {
                        async let signTask: String? = self.detectSignAsync(from: frame)
                        async let detTask: [DetectedThing] = self.detectThingsAsync(from: frame)

                        let foundSign  = await signTask
                        let detections = await detTask

                        let snapshot = self.buildSensorSnapshot(foundSign: foundSign, detections: detections)

                        // Qwen returns VisionScene JSON (your existing schema)
                        let perception = try await self.qwen.compressSnapshotToVisionScene(
                            sensorSnapshot: snapshot,
                            language: self.currentLanguage
                        )

                        let enc = JSONEncoder()
                        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let perceptionData = try enc.encode(perception)
                        let perceptionJSON = String(data: perceptionData, encoding: .utf8) ?? "{}"

                        // Keep your existing distance pipeline (ARKit-aware)
                        let arkitMeters = self.camera.currentCenterDistanceMeters()
                        let distanceCandidates = self.buildDistanceCandidates(scene: perception,
                                                                             heightCm: heightCm,
                                                                             arkitCenterDistanceMeters: arkitMeters)
                        let stateJSON = self.buildStateJSON(heightCm: heightCm, distanceCandidates: distanceCandidates)

                        // Claude answers from VISION_JSON (no image)
                        let plan = try await self.claude.askWithPerception(
                            userText: userText,
                            perceptionJSON: perceptionJSON,
                            stateJSON: stateJSON,
                            language: self.currentLanguage
                        )

                        DispatchQueue.main.async {
                            self.execute(plan: plan)
                        }
                        return
                    } catch {
                        DispatchQueue.main.async {
                            self.transcriptStore.add("AMD/QWEN ERROR (fallback to Claude image): \(error.localizedDescription)")
                        }
                        // continue to fallback below
                    }
                }

                // ============================================================
                // ✅ ORIGINAL LOGIC (UNCHANGED)
                // ============================================================
                let scene = try await self.claude.analyze(jpegData: jpeg, language: self.currentLanguage)

                let arkitMeters = self.camera.currentCenterDistanceMeters()
                let distanceCandidates = self.buildDistanceCandidates(scene: scene,
                                                                     heightCm: heightCm,
                                                                     arkitCenterDistanceMeters: arkitMeters)
                let stateJSON = self.buildStateJSON(heightCm: heightCm, distanceCandidates: distanceCandidates)

                let plan = try await claude.askWithImage(jpegData: jpeg,
                                                        userText: userText,
                                                        stateJSON: stateJSON,
                                                        language: currentLanguage)

                DispatchQueue.main.async {
                    self.execute(plan: plan)
                }

            } catch {
                DispatchQueue.main.async {
                    let detail = error.localizedDescription
                    self.transcriptStore.add("CLAUDE ERROR: \(detail)")
                    print("❌ Claude askWithImage error: \(detail)")

                    let spoken: String
                    if detail.contains("401") || detail.contains("403") {
                        spoken = self.currentLanguage == .mandarin
                            ? "API密钥被拒绝，请检查您的密钥。"
                            : "API key rejected. Please check your Anthropic key."
                    } else if detail.contains("429") {
                        spoken = self.currentLanguage == .mandarin
                            ? "请求过于频繁，请稍后再试。"
                            : "Rate limit hit. Please wait a moment and try again."
                    } else if detail.contains("timed out") || detail.contains("timeout") {
                        spoken = self.currentLanguage == .mandarin
                            ? "请求超时，请检查网络连接。"
                            : "Request timed out. Check your internet connection."
                    } else if detail.contains("No JSON") || detail.contains("Decode failed") {
                        spoken = self.currentLanguage == .mandarin
                            ? "收到错误响应，请再试一次。"
                            : "Got a bad response from Claude. Try again."
                    } else if detail.contains("camera") || detail.contains("frame") {
                        spoken = self.currentLanguage == .mandarin
                            ? "没有摄像头画面。"
                            : "No camera frame available."
                    } else {
                        spoken = "Error: \(detail)"
                    }
                    self.say(spoken)
                }
            }
        }
    }

    private func execute(plan: BrainPlan) {
        switch plan.action {
        case .none:
            break

        case .repeatLast:
            if lastGuidance.isEmpty {
                say(currentLanguage == .mandarin ? "我还没有说过任何话。" : "I have not said anything yet.")
                return
            }
            say(lastGuidance)
            return

        case .clearTranscripts:
            transcriptStore.clear()
            say(currentLanguage == .mandarin ? "记录已清除。" : "Transcripts cleared.")
            return

        case .setTarget:
            let t = (plan.target ?? "target").lowercased()
            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
            say(currentLanguage == .mandarin ? "目标已设置为\(t)。" : "Target set to \(t).")
            return

        case .answerFromMemory:
            let key = plan.memoryKey ?? ""
            if let val = memory[key] { say(val) }
            else {
                say(currentLanguage == .mandarin ? "我还没有保存那个。" : "I don't have that saved yet.")
            }
            return
        }

        say(plan.say)
    }

    // MARK: - State JSON

    private func buildStateJSON(heightCm: Double?,
                                distanceCandidates: [[String: Any]]? = nil) -> String {
        let firstEight    = Array(memory.prefix(8))
        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)

        let stepCm = stepLengthCm(using: heightCm)
        let stepFt = stepCm / 30.48

        var state: [String: Any] = [
            "height_cm":             heightCm as Any,
            "user_step_length_cm":   stepCm,
            "user_step_length_ft":   stepFt,
            "last_guidance":         lastGuidance,
            "last_seen_sign":        lastSeenSign,
            "last_obstacle":         lastObstacle,
            "pending_utterances":    Array(pendingUtterances.prefix(6)),
            "memory_keys":           Array(memory.keys).sorted(),
            "memory_preview":        memoryPreview,
            "language":              currentLanguage.rawValue
        ]

        if let dc = distanceCandidates { state["distance_candidates"] = dc }

        let data = try? JSONSerialization.data(withJSONObject: state,
                                               options: [.prettyPrinted])
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    // MARK: - Distance helpers

    private func isDistanceIntent(_ lower: String) -> Bool {
        let triggers = ["how far", "distance", "how many steps", "steps", "feet",
                        "foot", "meters", "metre", "how long", "walk",
                        "reach", "get to", "close", "near"]
        return triggers.contains { lower.contains($0) }
    }

    private func stepLengthCm(using heightCm: Double?) -> Double {
        let h = heightCm ?? 165.0
        return max(45.0, min(h * 0.415, 90.0))
    }

    /// Feet values chosen so that with stepLength formula, steps fall in: CLOSE 1–2, NEAR 3–5, FAR 6–8.
    private func approxFeet(for proximity: Proximity) -> Double {
        switch proximity {
        case .CLOSE: return 4.0   // ~1–2 steps
        case .NEAR:  return 11.0   // ~3–5 steps
        case .FAR:   return 18.0   // ~6–8 steps
        }
    }

    private func approxSteps(feet: Double, heightCm: Double?) -> Int {
        let stepFt = stepLengthCm(using: heightCm) / 30.48
        return max(1, Int(ceil(feet / max(stepFt, 0.5))))
    }

    private func buildDistanceCandidates(scene: VisionScene,
                                         heightCm: Double?,
                                         arkitCenterDistanceMeters: Double? = nil) -> [[String: Any]] {
        let items = scene.items
            .filter { $0.kind != .SIGN }
            .filter { $0.confidence >= 0.60 }
            .sorted { $0.salience_rank < $1.salience_rank }
            .prefix(6)

        return items.map { it in
            let feet: Double
            if it.position == .CENTER, let m = arkitCenterDistanceMeters, m > 0 {
                feet = m * 3.28084
            } else {
                feet = it.approx_distance_ft ?? approxFeet(for: it.proximity)
            }
            let steps = approxSteps(feet: feet, heightCm: heightCm)
            return [
                "label":         it.label.lowercased(),
                "kind":          it.kind.rawValue,
                "position":      it.position.rawValue,
                "proximity":     it.proximity.rawValue,
                "confidence":    it.confidence,
                "salience_rank": it.salience_rank,
                "approx_feet":   feet,
                "approx_steps":  steps
            ]
        }
    }
}




////  SceneAssistController.swift
////  SceneAssist
//
//import Foundation
//import Combine
//
//final class SceneAssistController: ObservableObject {
//
//    // MARK: - Timing
//    private var lastSpokeAt:              Date          = .distantPast
//    private let scanIntervalSeconds:      TimeInterval  = 4.0
//    private let minSecondsBetweenSpeech:  TimeInterval  = 4.0
//    private let autoResumeDelaySeconds:   TimeInterval  = 6.0
//    private var autoResumeWorkItem:       DispatchWorkItem?
//    private var autoResumeArmed:          Bool          = false
//
//    // MARK: - Services
//    private let claude  = ClaudeService()
//    private let ocr     = OCRService()
//    private let voice   = VoiceInputService()
//    private let speech  = SpeechManager()
//
//    // MARK: - Language
//    private let languageDetector = LanguageDetector()
//    private var currentLanguage: AppLanguage = .english
//
//    // MARK: - Memory / State
//    private var memory:            [String: String] = [:]
//    private var lastSeenSign:      String           = ""
//    private var lastObstacle:      String           = ""
//    private var pendingUtterances: [String]         = []
//
//    // MARK: - Published
//    @Published var lastGuidance:    String = ""
//    @Published var scanningEnabled: Bool   = true
//    @Published var isListening:     Bool   = false
//
//    private var lastSpokenEvent: String = ""
//    private var lastScanLogAt:   Date   = .distantPast
//
//    // MARK: - Camera / Transcripts
//    let camera          = CameraService()
//    let transcriptStore = TranscriptStore()
//
//    // MARK: - Run loop
//    private var timer:        Timer? = nil
//    private var isProcessing: Bool   = false
//
//    var heightCm: Double? = nil
//
//    // MARK: - Init
//
//    init() {
//        speech.mode    = .elevenlabs
//        speech.apiKey  = Secrets.elevenLabsApiKey
//        speech.voiceId = Secrets.elevenLabsVoiceId
//
//        speech.onFinished = { [weak self] in
//            self?.handleSpeechFinished()
//        }
//    }
//    
//    /// Locks the session language. Called once at startup, never changes after.
//    func setLanguage(_ language: AppLanguage) {
//        currentLanguage = language
//        speech.language = language
//        print("🌐 Language locked to: \(language.displayName)")
//    }
//
//    // MARK: - Start / Stop
//
//    func start() {
//        camera.start()
//
////        DispatchQueue.main.async {
////            self.speech.speak("Scene Assist Launched.")
////            self.transcriptStore.add("Scene Assist Launched.")
////        }
//        DispatchQueue.main.async {
//            let launchText = self.currentLanguage == .mandarin
//                ? "场景助手已启动。"
//                : "Scene Assist Launched."
//            self.speech.speak(launchText)
//            self.transcriptStore.add(launchText)
//        }
//
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//            self?.tick()
//        }
//
//        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds,
//                                     repeats: true) { [weak self] _ in
//            self?.tick()
//        }
//    }
//
//    func stop() {
//        timer?.invalidate()
//        timer = nil
//        camera.stop()
//    }
//
//    // MARK: - Auto-resume after answering a question
//
//    private func cancelAutoResume() {
//        autoResumeWorkItem?.cancel()
//        autoResumeWorkItem = nil
//    }
//
//    private func handleSpeechFinished() {
//        guard autoResumeArmed else { return }
//        autoResumeArmed = false
//        cancelAutoResume()
//
//        let work = DispatchWorkItem { [weak self] in
//            guard let self = self else { return }
//            if self.isListening { return }
//            self.scanningEnabled = true
//            self.isProcessing    = false
//            self.tick()
//        }
//        autoResumeWorkItem = work
//        DispatchQueue.main.asyncAfter(deadline: .now() + autoResumeDelaySeconds, execute: work)
//    }
//
//    // MARK: - Scan tick
//
//    private func tick() {
//        guard scanningEnabled, !isListening else { isProcessing = false; return }
//        guard !Secrets.anthropicApiKey.isEmpty else { isProcessing = false; return }
//        guard !isProcessing else { return }
//        guard let frame = camera.currentFrame() else { return }
//        isProcessing = true
//
//        guard let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
//            isProcessing = false
//            return
//        }
//
//        Task { [weak self] in
//            guard let self = self else { return }
//
//            let foundSign: String? = await withCheckedContinuation { cont in
//                self.ocr.recognizeText(from: frame) { words in
//                    let upper      = words.joined(separator: " ").uppercased()
//                    let normalized = upper.filter { $0.isLetter }
//                    let found      = SignCatalog.shared.match(normalizedLettersOnly: normalized)
//                    cont.resume(returning: found)
//                }
//            }
//
//            do {
//                // Pass current language so utterances come back in the right language
//                let scene = try await self.claude.analyze(jpegData: jpeg,
//                                                          language: self.currentLanguage)
//
//                DispatchQueue.main.async {
//                    self.lastSeenSign = foundSign ?? ""
//
//                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
//                        self.lastObstacle =
//                            "\(firstNonSign.kind.rawValue.lowercased()):" +
//                            "\(firstNonSign.label.lowercased()):" +
//                            "\(firstNonSign.position.rawValue.lowercased()):" +
//                            "\(firstNonSign.proximity.rawValue.lowercased())"
//                    } else {
//                        self.lastObstacle = ""
//                    }
//
//                    let shortList = scene.utterances
//                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//                        .filter { !$0.isEmpty }
//                    self.pendingUtterances = Array(shortList.prefix(6))
//
//                    let spoken: String?
//                    if let s = foundSign {
//                        spoken = "\(s.capitalized) sign ahead."
//                    } else {
//                        spoken = self.primaryUtterance(from: scene)
//                    }
//
//                    if let line = spoken {
//                        let now = Date()
//                        if !self.speech.isSpeaking,
//                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
//                           line != self.lastSpokenEvent {
//
//                            self.lastSpokeAt    = now
//                            self.lastSpokenEvent = line
//                            self.lastGuidance    = line
//                            self.speech.speak(line)
//                            self.transcriptStore.add(line)
//                        }
//                    } else {
//                        let t = Date()
//                        if t.timeIntervalSince(self.lastScanLogAt) >= 10 {
//                            self.lastScanLogAt = t
//                            self.transcriptStore.add("Scanning.")
//                        }
//                    }
//
//                    self.isProcessing = false
//                }
//
//            } catch {
//                DispatchQueue.main.async {
//                    self.transcriptStore.add("VISION ERROR: \(error.localizedDescription)")
//                    self.isProcessing = false
//                }
//            }
//        }
//    }
//
//    // MARK: - Primary utterance (obstacle / person alert)
//
//    private func article(for noun: String) -> String {
//        let first  = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
//        let vowels: Set<Character> = ["a","e","i","o","u"]
//        return (first != nil && vowels.contains(first!)) ? "an" : "a"
//    }
//
//    private func primaryUtterance(from scene: VisionScene) -> String? {
//        let generic: Set<String> = ["object", "item", "thing", "stuff"]
//
//        let candidates = scene.items
//            .filter { $0.kind != .SIGN }
//            .filter { $0.confidence >= 0.65 }
//
//        func score(_ it: VisionItem) -> Int {
//            let posScore  = (it.position == .CENTER) ? 30 : 10
//            let proxScore = (it.proximity == .CLOSE)  ? 30 : (it.proximity == .NEAR ? 20 : 0)
//            return posScore + proxScore
//        }
//
//        let sorted = candidates.sorted { score($0) > score($1) }
//
//        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
//            return nil
//        }
//
//        if top.proximity == .FAR { return nil }
//
//        let whereText: String = {
//            switch top.position {
//            case .CENTER: return "in front of you"
//            case .LEFT:   return "to your left"
//            case .RIGHT:  return "to your right"
//            }
//        }()
//
//        let closeText  = (top.proximity == .CLOSE) ? ", very close" : ""
//        let stopPrefix = (top.proximity == .CLOSE) ? "STOP! " : ""
//
//        let labelText: String = {
//            if top.kind == .ANIMAL { return "animal" }
//            if top.kind == .PERSON { return "person" }
//            return top.label.lowercased()
//        }()
//
//        let action: String = {
//            guard top.proximity == .CLOSE else { return "" }
//            switch top.position {
//            case .CENTER: return " Please move slightly left or right."
//            case .LEFT:   return " Please move slightly right."
//            case .RIGHT:  return " Please move slightly left."
//            }
//        }()
//
//        if labelText == "person" {
//            return "\(stopPrefix)A person is \(whereText)\(closeText).\(action)"
//        } else if labelText == "animal" {
//            return "\(stopPrefix)An animal is \(whereText)\(closeText).\(action)"
//        } else {
//            return "\(stopPrefix)\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(closeText).\(action)"
//        }
//    }
//
//    // MARK: - Speech helper
//
//    private func say(_ text: String) {
//        lastGuidance = text
//        speech.speak(text)
//        transcriptStore.add(text)
//    }
//
//    // MARK: - Language helpers
//
//    /// Detects language from spoken text and updates TTS routing.
////    private func applyDetectedLanguage(from text: String) {
////        let detected = languageDetector.detect(text: text)
////        if detected != currentLanguage {
////            currentLanguage  = detected
////            speech.language  = detected          // SpeechManager routes EN→ElevenLabs, ZH→Apple
////            print("🌐 Language switched to: \(detected.displayName)")
////        }
////    }
//    private func applyDetectedLanguage(from text: String) {
//        // Language is fixed at first launch by the user's explicit choice.
//        // Auto-detection permanently disabled.
//    }
//
//    // MARK: - Voice input
//
//    func beginVoice() {
//        cancelAutoResume()
//        scanningEnabled = false
//        isListening     = true
//        isProcessing    = false
//
//        voice.requestPermissions { [weak self] ok in
//            guard let self = self else { return }
//
//            guard ok else {
//                self.isListening = false
//                self.say("Please allow speech recognition in Settings.")
//                return
//            }
//
//            do {
//                try self.voice.startListening { [weak self] finalText in
//                    DispatchQueue.main.async {
//                        self?.handleFinalVoiceText(finalText)
//                    }
//                }
//                self.transcriptStore.add("🎤 Listening…")
//            } catch {
//                self.isListening = false
//                self.say("Sorry, I could not start listening.")
//            }
//        }
//    }
//
//    func endVoice() {
//        voice.stopListening()
//        isListening = false
//
//        let text = voice.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
//        guard !text.isEmpty else {
//            say("Sorry, I didn't catch that. Please try again.")
//            return
//        }
//
//        applyDetectedLanguage(from: text)
//
//        let lower   = text.lowercased()
//        let compact = lower.replacingOccurrences(of: " ", with: "")
//
//        if lower.contains("start scanning") || lower.contains("resume scanning")
//            || lower.contains("scan again")
//            || compact.contains("startscanningagain")
//            || compact.contains("resumescanning")
//            || compact.contains("startscanning")
//            || text.contains("开始扫描") || text.contains("继续扫描") {
//
//            resumeScanning()
//            return
//        }
//
//        if lower.contains("stop scanning") || lower.contains("pause scanning")
//            || text.contains("停止扫描") || text.contains("暂停扫描") {
//            pauseScanning()
//            return
//        }
//
//        if wantsInstructionsAgain(lower) {
//            transcriptStore.add("Instructions.")
//            speech.speak(AppInstructions.text(for: currentLanguage))
//            return
//        }
//
//        autoResumeArmed = true
//        handleUserQuestion(text, heightCm: heightCm)
//    }
//
//    private func handleFinalVoiceText(_ text: String) {
//        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
//        transcriptStore.add("You: \(cleaned)")
//
//        // Detect language first — this routes all subsequent speech correctly
//        applyDetectedLanguage(from: cleaned)
//
//        let lower   = cleaned.lowercased()
//        let compact = lower.replacingOccurrences(of: " ", with: "")
//
//        // Resume scanning (English + Mandarin phrases)
//        if lower.contains("start scanning") || lower.contains("resume scanning")
//            || lower.contains("scan again")
//            || compact.contains("startscanningagain")
//            || cleaned.contains("开始扫描") || cleaned.contains("继续扫描") {
//            resumeScanning()
//            return
//        }
//
//        // Pause scanning
//        if lower.contains("stop scanning") || lower.contains("pause scanning")
//            || cleaned.contains("停止扫描") || cleaned.contains("暂停扫描") {
//            pauseScanning()
//            return
//        }
//
//        // "What is this" (English + Mandarin)
//        if compact == "whatis" || lower.contains("what is") || lower.contains("what's this")
//            || lower.contains("what is this")
//            || cleaned.contains("这是什么") || cleaned.contains("那是什么") {
//            describeWhatIsInView()
//            return
//        }
//
//        // Instructions
//        if wantsInstructionsAgain(lower) {
//            transcriptStore.add("Instructions.")
//            speech.speak(AppInstructions.text(for: currentLanguage))
//            return
//        }
//        autoResumeArmed = true
//        handleUserQuestion(cleaned, heightCm: heightCm)
//    }
//
//    // MARK: - Scanning state helpers
//
//    private func resumeScanning() {
//        scanningEnabled  = true
//        isProcessing     = false
//        lastScanLogAt    = .distantPast
//        lastSpokeAt      = .distantPast
//        lastSpokenEvent  = ""
//
//        transcriptStore.add("Scanning resumed.")
//        speech.speak(currentLanguage == .mandarin ? "好的。" : "Okay.")
//
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
//            self?.tick()
//        }
//    }
//
//    private func pauseScanning() {
//        scanningEnabled = false
//        isProcessing    = false
//        transcriptStore.add("Scanning paused.")
//        speech.speak(currentLanguage == .mandarin ? "已暂停。" : "Okay.")
//    }
//
//    // MARK: - Describe what is in view ("what is this")
//
//    private func describeWhatIsInView() {
//        scanningEnabled = false
//        isProcessing    = false
//
//        guard let frame = camera.currentFrame(),
//              let jpeg  = CloudVisionService.jpegFromPixelBuffer(frame) else {
//            say(currentLanguage == .mandarin ? "现在看不清楚。" : "I can't see clearly right now.")
//            return
//        }
//
//        Task { [weak self] in
//            guard let self = self else { return }
//            do {
//                let scene = try await self.claude.analyze(jpegData: jpeg,
//                                                          language: self.currentLanguage)
//                DispatchQueue.main.async {
//                    let nonSigns = scene.items.filter { $0.kind != .SIGN }
//                    guard let top = nonSigns.first else {
//                        self.say(self.currentLanguage == .mandarin
//                            ? "我不确定那是什么。"
//                            : "I'm not sure what that is.")
//                        self.scanningEnabled = true
//                        return
//                    }
//
//                    let label = (top.kind == .PERSON) ? "person"
//                              : (top.kind == .ANIMAL) ? "animal"
//                              : top.label.lowercased()
//
//                    let whereText: String = {
//                        switch top.position {
//                        case .CENTER: return self.currentLanguage == .mandarin
//                                         ? "在你正前方" : "in front of you"
//                        case .LEFT:   return self.currentLanguage == .mandarin
//                                         ? "在你左边"   : "to your left"
//                        case .RIGHT:  return self.currentLanguage == .mandarin
//                                         ? "在你右边"   : "to your right"
//                        }
//                    }()
//
//                    let closeText = (top.proximity == .CLOSE)
//                        ? (self.currentLanguage == .mandarin ? "，很近" : ", very close")
//                        : ""
//
//                    let desc = self.currentLanguage == .mandarin
//                        ? "看起来是\(whereText)的\(label)\(closeText)。"
//                        : "It looks like a \(label) \(whereText)\(closeText)."
//
//                    self.say(desc)
//                    self.scanningEnabled = true
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    self.say(self.currentLanguage == .mandarin
//                        ? "现在无法分析。"
//                        : "I couldn't analyze that right now.")
//                    self.scanningEnabled = true
//                }
//            }
//        }
//    }
//
//    // MARK: - Instructions check
//
//    private func wantsInstructionsAgain(_ lower: String) -> Bool {
//        let phrases = [
//            "repeat instruction", "repeat instructions",
//            "hear instruction",   "hear instructions",
//            "tell me how to use", "how to use the app",
//            "how to use this app","how does the app work",
//            "how does this app work", "instructions again",
//            "explain the app",    "how do i use",
//            "how do i use this"
//        ]
//        return phrases.contains { lower.contains($0) }
//    }
//
//    // MARK: - LLM Q&A
//
//    func handleUserQuestion(_ userText: String, heightCm: Double?) {
//        transcriptStore.add("You: \(userText)")
//
//        guard !Secrets.anthropicApiKey.isEmpty else {
//            say("Please set your Anthropic API key in Secrets.")
//            return
//        }
//
//        guard let frame = camera.currentFrame(),
//              let jpeg  = CloudVisionService.jpegFromPixelBuffer(frame) else {
//            say(currentLanguage == .mandarin
//                ? "没有摄像头画面，请对准摄像头再试。"
//                : "I don't have a camera frame. Point the camera and try again.")
//            return
//        }
//
//        Task {
//            do {
//                let stateJSON = buildStateJSON(heightCm: heightCm)
//                let plan = try await claude.askWithImage(jpegData: jpeg,
//                                                        userText: userText,
//                                                        stateJSON: stateJSON,
//                                                        language: currentLanguage)
//                DispatchQueue.main.async {
//                    self.execute(plan: plan)
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    let detail = error.localizedDescription
//                    self.transcriptStore.add("CLAUDE ERROR: \(detail)")
//                    print("❌ Claude askWithImage error: \(detail)")
//
//                    // Speak the actual error so you can hear it on device without Xcode
//                    let spoken: String
//                    if detail.contains("401") || detail.contains("403") {
//                        spoken = "API key rejected. Please check your Anthropic key."
//                    } else if detail.contains("429") {
//                        spoken = "Rate limit hit. Please wait a moment and try again."
//                    } else if detail.contains("timed out") || detail.contains("timeout") {
//                        spoken = "Request timed out. Check your internet connection."
//                    } else if detail.contains("No JSON") || detail.contains("Decode failed") {
//                        spoken = "Got a bad response from Claude. Try again."
//                    } else if detail.contains("camera") || detail.contains("frame") {
//                        spoken = "No camera frame available."
//                    } else {
//                        spoken = "Error: \(detail)"   // speak the raw error so you can hear exactly what's wrong
//                    }
//                    self.say(spoken)
//                }
//            }
//        }
//    }
//
//    private func execute(plan: BrainPlan) {
//        switch plan.action {
//        case .none:
//            break
//
//        case .repeatLast:
//            if lastGuidance.isEmpty {
//                say(currentLanguage == .mandarin ? "我还没有说过任何话。" : "I have not said anything yet.")
//                return
//            }
//            say(lastGuidance)
//            return
//
//        case .clearTranscripts:
//            transcriptStore.clear()
//            say(currentLanguage == .mandarin ? "记录已清除。" : "Transcripts cleared.")
//            return
//
//        case .setTarget:
//            let t = (plan.target ?? "target").lowercased()
//            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
//            say(currentLanguage == .mandarin ? "目标已设置为\(t)。" : "Target set to \(t).")
//            return
//
//        case .answerFromMemory:
//            let key = plan.memoryKey ?? ""
//            if let val = memory[key] { say(val) }
//            else {
//                say(currentLanguage == .mandarin ? "我还没有保存那个。" : "I don't have that saved yet.")
//            }
//            return
//        }
//
//        say(plan.say)
//    }
//
//    // MARK: - State JSON
//
//    private func buildStateJSON(heightCm: Double?,
//                                distanceCandidates: [[String: Any]]? = nil) -> String {
//        let firstEight    = Array(memory.prefix(8))
//        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)
//
//        let stepCm = stepLengthCm(using: heightCm)
//        let stepFt = stepCm / 30.48
//
//        var state: [String: Any] = [
//            "height_cm":             heightCm as Any,
//            "user_step_length_cm":   stepCm,
//            "user_step_length_ft":   stepFt,
//            "last_guidance":         lastGuidance,
//            "last_seen_sign":        lastSeenSign,
//            "last_obstacle":         lastObstacle,
//            "pending_utterances":    Array(pendingUtterances.prefix(6)),
//            "memory_keys":           Array(memory.keys).sorted(),
//            "memory_preview":        memoryPreview,
//            "language":              currentLanguage.rawValue
//        ]
//
//        if let dc = distanceCandidates { state["distance_candidates"] = dc }
//
//        let data = try? JSONSerialization.data(withJSONObject: state,
//                                               options: [.prettyPrinted])
//        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
//    }
//
//    // MARK: - Distance helpers
//
//    private func isDistanceIntent(_ lower: String) -> Bool {
//        let triggers = ["how far", "distance", "how many steps", "steps", "feet",
//                        "foot", "meters", "metre", "how long", "walk",
//                        "reach", "get to", "close", "near"]
//        return triggers.contains { lower.contains($0) }
//    }
//
//    private func stepLengthCm(using heightCm: Double?) -> Double {
//        let h = heightCm ?? 165.0
//        return max(45.0, min(h * 0.415, 90.0))
//    }
//
//    private func approxFeet(for proximity: Proximity) -> Double {
//        switch proximity {
//        case .CLOSE: return 2.5
//        case .NEAR:  return 7.0
//        case .FAR:   return 16.0
//        }
//    }
//
//    private func approxSteps(feet: Double, heightCm: Double?) -> Int {
//        let stepFt = stepLengthCm(using: heightCm) / 30.48
//        return max(1, Int(ceil(feet / max(stepFt, 0.5))))
//    }
//
//    private func buildDistanceCandidates(scene: VisionScene,
//                                         heightCm: Double?) -> [[String: Any]] {
//        let items = scene.items
//            .filter { $0.kind != .SIGN }
//            .filter { $0.confidence >= 0.60 }
//            .sorted { $0.salience_rank < $1.salience_rank }
//            .prefix(6)
//
//        return items.map { it in
//            let feet  = it.approx_distance_ft ?? approxFeet(for: it.proximity)
//            let steps = approxSteps(feet: feet, heightCm: heightCm)
//            return [
//                "label":        it.label.lowercased(),
//                "kind":         it.kind.rawValue,
//                "position":     it.position.rawValue,
//                "proximity":    it.proximity.rawValue,
//                "confidence":   it.confidence,
//                "salience_rank":it.salience_rank,
//                "approx_feet":  feet,
//                "approx_steps": steps
//            ]
//        }
//    }
//}
//
//
//
////import Foundation
////import Combine
////
////final class SceneAssistController: ObservableObject {
////    
////    private let autoResumeDelaySeconds: TimeInterval = 3.0
////    private var autoResumeWorkItem: DispatchWorkItem?
////    private var autoResumeArmed: Bool = false   // set true when we ask AI a question
////    
////    private let ocr = OCRService()
//////    private let signKeywords: [String] = ["EXIT","ENTRANCE","RESTROOM","TOILET","ELEVATOR","LIFT","STAIRS","STAIRWAY",
//////                                          "DANGER","WARNING","CAUTION","NOTICE","FIRE","NO","SMOKING","PUSH","PULL",
//////                                          "EMERGENCY","FIRST","AID","AED","AUTHORIZED","ONLY","DO","NOT","STOP","SLOW"]
////
////    // MARK: - Timing / Speech control
////    private var lastSpokeAt: Date = .distantPast
////    private let scanIntervalSeconds: TimeInterval = 2.0
////    private let minSecondsBetweenSpeech: TimeInterval = 2.0
////
////    // MARK: - Services (Claude 3.5 Haiku for vision + single-call Q&A; set Secrets.anthropicApiKey)
////    private let claude = ClaudeService()
////    private let voice = VoiceInputService()
////    private let speech = SpeechManager()
////
////    // MARK: - Memory / State for Q&A
////    private var memory: [String: String] = [:]
////    private var lastSeenSign: String = ""
////    private var lastObstacle: String = ""
////
////    // Store latest extra lines for Q&A (“what else do you see?”)
////    private var pendingUtterances: [String] = []
////
////    // MARK: - Published UI state
////    @Published var lastGuidance: String = ""
////    @Published var scanningEnabled: Bool = true
////    @Published var isListening: Bool = false
////
////    // Prevent repeating the same spoken line every scan
////    private var lastSpokenEvent: String = ""
////    private var lastScanLogAt: Date = .distantPast
////
////    // MARK: - Camera / Transcripts
////    let camera = CameraService()
////    let transcriptStore = TranscriptStore()
////
////    // MARK: - Run loop
////    private var timer: Timer?
////    private var isProcessing = false
////
////    // Set from ContentView
////    var heightCm: Double? = nil
////    
////    private func cancelAutoResume() {
////        autoResumeWorkItem?.cancel()
////        autoResumeWorkItem = nil
////    }
////    
////    // MARK: - Distance / steps helpers (approx)
////
////    private func isDistanceIntent(_ lower: String) -> Bool {
////        let triggers = [
////            "how far", "distance", "how many steps", "steps", "feet", "foot", "meters", "metre",
////            "how long", "walk", "reach", "get to", "close", "near"
////        ]
////        return triggers.contains(where: { lower.contains($0) })
////    }
////
////    private func stepLengthCm(using heightCm: Double?) -> Double {
////        // Average step length ≈ 0.415 * height (good enough for demo)
////        let h = heightCm ?? 165.0
////        return max(45.0, min(h * 0.415, 90.0))
////    }
////
////    private func approxFeet(for proximity: Proximity) -> Double {
////        // Tune for your demo space
////        switch proximity {
////        case .CLOSE: return 2.5   // ~0.8m
////        case .NEAR:  return 7.0   // ~2.1m
////        case .FAR:   return 16.0  // ~4.9m
////        }
////    }
////
////    private func approxSteps(feet: Double, heightCm: Double?) -> Int {
////        let stepFt = stepLengthCm(using: heightCm) / 30.48
////        return max(1, Int(ceil(feet / max(stepFt, 0.5))))
////    }
////
////    private func buildDistanceCandidates(scene: VisionScene, heightCm: Double?) -> [[String: Any]] {
////        // Take top visible non-sign items
////        let items = scene.items
////            .filter { $0.kind != .SIGN }
////            .filter { $0.confidence >= 0.60 }
////            .sorted { $0.salience_rank < $1.salience_rank }
////            .prefix(6)
////
////        return items.map { it in
////            let feet = it.approx_distance_ft ?? approxFeet(for: it.proximity)
////            let steps = approxSteps(feet: feet, heightCm: heightCm)
////
////            return [
////                "label": it.label.lowercased(),
////                "kind": it.kind.rawValue,
////                "position": it.position.rawValue,
////                "proximity": it.proximity.rawValue,
////                "confidence": it.confidence,
////                "salience_rank": it.salience_rank,
////                "approx_feet": feet,
////                "approx_steps": steps
////            ]
////        }
////    }
////
////    private func handleSpeechFinished() {
////        // Only auto-resume if we just answered a user question
////        guard autoResumeArmed else { return }
////        autoResumeArmed = false
////
////        cancelAutoResume()
////
////        let work = DispatchWorkItem { [weak self] in
////            guard let self = self else { return }
////
////            // If user started talking again, don't resume
////            if self.isListening { return }
////
////            self.scanningEnabled = true
////            self.isProcessing = false
////
////            // Kick off a scan immediately (don’t wait for timer)
////            self.tick()
////        }
////
////        autoResumeWorkItem = work
////        DispatchQueue.main.asyncAfter(deadline: .now() + autoResumeDelaySeconds, execute: work)
////    }
////    
////    init() {
////        // Use ElevenLabs for speaking
////        speech.mode = .elevenlabs
////        speech.apiKey = Secrets.elevenLabsApiKey
////        speech.voiceId = Secrets.elevenLabsVoiceId
////        
////        print("TTS = ElevenLabs, voiceId = \(speech.voiceId)")
////        
////        speech.onFinished = { [weak self] in
////            self?.handleSpeechFinished()
////        }
////    }
////
////    // MARK: - Start / Stop
//////    func start() {
//////        camera.start()
//////
//////        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
//////            self?.tick()
//////        }
//////    }
////    func start() {
////        camera.start()
////
////        // ✅ Speak instantly (so user knows it’s alive)
////        DispatchQueue.main.async {
////            self.speech.speak("Scene Assist Launched.")
////            self.transcriptStore.add("Scene Assist Launched.")
////        }
////
////        // ✅ Run the first scan immediately (don’t wait for timer)
////        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
////            self?.tick()
////        }
////
////        // Then keep scanning on your interval
////        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
////            self?.tick()
////        }
////    }
////
////    func stop() {
////        timer?.invalidate()
////        timer = nil
////        camera.stop()
////    }
////
////    // MARK: - Tick
////    private func tick() {
////        // If paused or listening, do nothing
////        if !scanningEnabled || isListening {
////            isProcessing = false
////            return
////        }
////        if Secrets.anthropicApiKey.isEmpty {
////            isProcessing = false
////            return
////        }
////
////        if isProcessing { return }
////        guard let frame = camera.currentFrame() else { return }
////        isProcessing = true
////
////        guard let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
////            isProcessing = false
////            return
////        }
////
//////        Task { [weak self] in
//////            guard let self = self else { return }
//////
//////            do {
//////                let scene = try await self.cloudVision.analyze(jpegData: jpeg)
//////
//////                DispatchQueue.main.async {
//////                    // Save facts for Q&A
//////                    self.lastSeenSign = scene.sign_texts.first ?? ""
//////
//////                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
//////                        self.lastObstacle =
//////                            "\(firstNonSign.kind.rawValue.lowercased()):" +
//////                            "\(firstNonSign.label.lowercased()):" +
//////                            "\(firstNonSign.position.rawValue.lowercased()):" +
//////                            "\(firstNonSign.proximity.rawValue.lowercased())"
//////                    } else {
//////                        self.lastObstacle = ""
//////                    }
//////
//////                    // Store short list for Q&A only (not for speaking)
//////                    let shortList = scene.utterances
//////                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//////                        .filter { !$0.isEmpty }
//////                    self.pendingUtterances = Array(shortList.prefix(6))
//////
//////                    // Speak exactly ONE prominent sentence per scan
//////                    if let line = self.primaryUtterance(from: scene) {
//////                        let now = Date()
//////
//////                        if !self.speech.isSpeaking,
//////                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
//////                           line != self.lastSpokenEvent {
//////
//////                            self.lastSpokeAt = now
//////                            self.lastSpokenEvent = line
//////                            self.lastGuidance = line
//////                            self.speech.speak(line)
//////                            self.transcriptStore.add(line)
//////                        } else {
//////                            // optional: keep silent if same or too soon
//////                        }
//////                    } else {
//////                        // No good detections → log scanning every 10s, no audio
//////                        let t = Date()
//////                        if t.timeIntervalSince(self.lastScanLogAt) >= 10 {
//////                            self.lastScanLogAt = t
//////                            self.transcriptStore.add("Scanning.")
//////                        }
//////                    }
//////
//////                    self.isProcessing = false
//////                }
//////
//////            } catch {
//////                DispatchQueue.main.async {
//////                    self.transcriptStore.add("VISION ERROR: \(error.localizedDescription)")
//////                    self.isProcessing = false
//////                }
//////            }
//////        }
////        
////        Task { [weak self] in
////            guard let self = self else { return }
////
////            // OCR uses the pixel buffer directly (no network)
////            let foundSign: String? = await withCheckedContinuation { cont in
////                self.ocr.recognizeText(from: frame) { words in
////                    let upper = words.joined(separator: " ").uppercased()
////                    let normalized = upper.filter { $0.isLetter }   // "E X I T" -> "EXIT"
////                    let found = SignCatalog.shared.match(normalizedLettersOnly: normalized)
//////                    let sign = self.signKeywords.first { normalized.contains($0) }
////                    cont.resume(returning: found)
////                }
////            }
////
////            do {
////                let scene = try await self.claude.analyze(jpegData: jpeg)
////
////                DispatchQueue.main.async {
////                    // Save OCR sign as the “truth”
////                    self.lastSeenSign = foundSign ?? ""
////
////                    // Save obstacle from cloud
////                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
////                        self.lastObstacle =
////                            "\(firstNonSign.kind.rawValue.lowercased()):" +
////                            "\(firstNonSign.label.lowercased()):" +
////                            "\(firstNonSign.position.rawValue.lowercased()):" +
////                            "\(firstNonSign.proximity.rawValue.lowercased())"
////                    } else {
////                        self.lastObstacle = ""
////                    }
////
////                    // Store short list for Q&A
////                    let shortList = scene.utterances
////                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
////                        .filter { !$0.isEmpty }
////                    self.pendingUtterances = Array(shortList.prefix(6))
////
////                    // Decide what to speak:
////                    // 1) if OCR found a sign → speak it (once per scan rules)
////                    // 2) else speak best object/person
////                    let spoken: String?
////                    if let s = foundSign {
////                        spoken = "Exit sign ahead." == s ? "Exit sign ahead." : "\(s.capitalized) sign ahead."
////                    } else {
////                        spoken = self.primaryUtterance(from: scene)
////                    }
////
////                    if let line = spoken {
////                        let now = Date()
////                        if !self.speech.isSpeaking,
////                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
////                           line != self.lastSpokenEvent {
////
////                            self.lastSpokeAt = now
////                            self.lastSpokenEvent = line
////                            self.lastGuidance = line
////                            self.speech.speak(line)
////                            self.transcriptStore.add(line)
////                        }
////                    } else {
////                        let t = Date()
////                        if t.timeIntervalSince(self.lastScanLogAt) >= 10 {
////                            self.lastScanLogAt = t
////                            self.transcriptStore.add("Scanning.")
////                        }
////                    }
////
////                    self.isProcessing = false
////                }
////
////            } catch {
////                DispatchQueue.main.async {
////                    self.transcriptStore.add("VISION ERROR: \(error.localizedDescription)")
////                    self.isProcessing = false
////                }
////            }
////        }
////    }
////
////    // MARK: - Human sentence generator (ONE best item)
////    private func article(for noun: String) -> String {
////        let first = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
////        let vowels: Set<Character> = ["a","e","i","o","u"]
////        return (first != nil && vowels.contains(first!)) ? "an" : "a"
////    }
////
////    private func primaryUtterance(from scene: VisionScene) -> String? {
////        let generic: Set<String> = ["object", "item", "thing", "stuff"]
////
////        // Pick confident, non-sign items
////        let candidates = scene.items
////            .filter { $0.kind != .SIGN }
////            .filter { $0.confidence >= 0.65 }
////
////        // Prominence score: center is strongest; close is strongest
////        func score(_ it: VisionItem) -> Int {
////            let posScore = (it.position == .CENTER) ? 30 : 10
////            let proxScore: Int = (it.proximity == .CLOSE) ? 30 : (it.proximity == .NEAR ? 20 : 0)
////            return posScore + proxScore
////        }
////
////        let sorted = candidates.sorted { score($0) > score($1) }
////
////        // Choose first specific (non-generic) label
////        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
////            // If no objects, optionally mention sign
//////            if let sign = scene.sign_texts.first, !sign.isEmpty {
//////                return "I see an \(sign) sign ahead."
//////            }
////            return nil
////        }
////
////        // Don’t speak FAR
////        if top.proximity == .FAR { return nil }
////
////        // Position phrase
////        let whereText: String
////        switch top.position {
////        case .CENTER: whereText = "in front of you"
////        case .LEFT:   whereText = "to your left"
////        case .RIGHT:  whereText = "to your right"
////        }
////
////        // Only say “very close” if CLOSE
////        let closeText = (top.proximity == .CLOSE) ? ", very close" : ""
////
////        // Exact label (animals generic only)
////        let labelText: String
////        if top.kind == .ANIMAL { labelText = "animal" }
////        else if top.kind == .PERSON { labelText = "person" }
////        else { labelText = top.label.lowercased() }
////
////        // Action hint only when close
////        let action: String = {
////            guard top.proximity == .CLOSE else { return "" }
////            switch top.position {
////            case .CENTER: return " Please move slightly left or right."
////            case .LEFT:   return " Please move slightly right."
////            case .RIGHT:  return " Please move slightly left."
////            }
////        }()
////        
////        // ✅ Add STOP prefix when very close (and we’re telling user to move)
////        let stopPrefix = (top.proximity == .CLOSE) ? "STOP! " : ""
////
////        if labelText == "person" {
////            return "\(stopPrefix)A person is \(whereText)\(closeText).\(action)"
////        } else if labelText == "animal" {
////            return "\(stopPrefix)An animal is \(whereText)\(closeText).\(action)"
////        } else {
////            return "\(stopPrefix)\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(closeText).\(action)"
////        }
////    }
////
////    // MARK: - Speech helper (used by Q&A + errors)
////    private func say(_ text: String) {
////        lastGuidance = text
////        speech.speak(text)
////        transcriptStore.add(text)
////    }
////
////    // MARK: - Voice controls
////    func beginVoice() {
////        cancelAutoResume()
////        scanningEnabled = false
////        isListening = true
////        isProcessing = false
////
////        voice.requestPermissions { [weak self] ok in
////            guard let self = self else { return }
////
////            if !ok {
////                self.isListening = false
////                self.say("Please allow speech recognition in Settings.")
////                return
////            }
////
////            do {
////                try self.voice.startListening { [weak self] final in
////                    DispatchQueue.main.async {
////                        self?.handleFinalVoiceText(final)
////                    }
////                }
////            } catch {
////                self.isListening = false
////                self.say("Sorry, I could not start listening.")
////            }
////        }
////    }
////    
////    private func handleFinalVoiceText(_ text: String) {
////        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
////        transcriptStore.add("You: \(cleaned)")
////
////        let lower = cleaned.lowercased()
////        let compact = lower.replacingOccurrences(of: " ", with: "")
////
////        // Resume scanning commands
////        if lower.contains("start scanning") || lower.contains("resume scanning")
////            || lower.contains("scan again")
////            || compact.contains("startscanningagain") {
////
////            scanningEnabled = true
////            isProcessing = false
////            lastScanLogAt = .distantPast
////            lastSpokeAt = .distantPast
////            lastSpokenEvent = ""
////
////            transcriptStore.add("Scanning resumed.")
////            speech.speak("Okay.")
////            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
////            return
////        }
////
////        // "What is this" command (works even if user says only "what is")
////        if compact == "whatis" || lower.contains("what is") || lower.contains("what's this") || lower.contains("what is this") {
////            describeWhatIsInView()
////            return
////        }
////
////        // Otherwise use LLM Q&A
////        handleUserQuestion(cleaned, heightCm: heightCm)
////    }
////    
////    private func describeWhatIsInView() {
////        // pause scanning during this one-shot answer
////        scanningEnabled = false
////        isProcessing = false
////
////        guard let frame = camera.currentFrame(),
////              let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
////            say("I can't see clearly right now.")
////            return
////        }
////
////        Task { [weak self] in
////            guard let self = self else { return }
////            do {
////                let scene = try await self.claude.analyze(jpegData: jpeg)
////                DispatchQueue.main.async {
////                    // Pick the most prominent non-sign item
////                    let nonSigns = scene.items.filter { $0.kind != .SIGN }
////                    guard let top = nonSigns.first else {
////                        self.say("I'm not sure what that is.")
////                        self.scanningEnabled = true
////                        return
////                    }
////
////                    let label = (top.kind == .PERSON) ? "person" : (top.kind == .ANIMAL ? "animal" : top.label.lowercased())
////
////                    let whereText: String = {
////                        switch top.position {
////                        case .CENTER: return "in front of you"
////                        case .LEFT: return "to your left"
////                        case .RIGHT: return "to your right"
////                        }
////                    }()
////
////                    let closeText = (top.proximity == .CLOSE) ? ", very close" : ""
////                    self.say("It looks like a \(label) \(whereText)\(closeText).")
////
////                    // resume scanning after answering
////                    self.scanningEnabled = true
////                }
////            } catch {
////                DispatchQueue.main.async {
////                    self.say("I couldn't analyze that right now.")
////                    self.scanningEnabled = true
////                }
////            }
////        }
////    }
////
////    func endVoice() {
////        voice.stopListening()
////        isListening = false
////
////        let text = voice.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
////        if text.isEmpty {
////            say("Sorry, I didn’t catch that. Please try again.")
////            return
////        }
////
////        let lower = text.lowercased()
////
//////        if lower.contains("start scanning") || lower.contains("resume scanning") || lower.contains("scan again") {
//////            scanningEnabled = true
//////            lastScanLogAt = .distantPast
//////            transcriptStore.add("Scanning resumed.")
//////            speech.speak("Okay.")
//////            return
//////        }
////        let compact = lower.replacingOccurrences(of: " ", with: "")
////
////        if lower.contains("start scanning")
////            || lower.contains("resume scanning")
////            || lower.contains("scan again")
////            || compact.contains("startscanningagain")
////            || compact.contains("resumescanning")
////            || compact.contains("startscanning") {
////
////            scanningEnabled = true
////
////            // Reset scan state so it immediately starts talking again
////            isProcessing = false
////            lastScanLogAt = .distantPast
////            lastSpokeAt = .distantPast
////            lastSpokenEvent = ""
////
////            transcriptStore.add("Scanning resumed.")
////            speech.speak("Okay.")
////
////            // Kick off a scan immediately (don’t wait for the next timer tick)
////            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
////                self?.tick()
////            }
////            return
////        }
////
////        if lower.contains("stop scanning") || lower.contains("pause scanning") {
////            scanningEnabled = false
////            isProcessing = false
////            transcriptStore.add("Scanning paused.")
////            speech.speak("Okay.")
////            return
////        }
////
////        // User asked for instructions / how to use the app — speak the same instructions as the start guide.
////        if wantsInstructionsAgain(lower) {
////            transcriptStore.add("Instructions.")
////            speech.speak(AppInstructions.text(for: currentLanguage))
////            return
////        }
////        
////        autoResumeArmed = true
////        handleUserQuestion(text, heightCm: heightCm)
////    }
////
////    private func wantsInstructionsAgain(_ lower: String) -> Bool {
////        let phrases = [
////            "repeat instruction",
////            "repeat instructions",
////            "hear instruction",
////            "hear instructions",
////            "tell me how to use",
////            "how to use the app",
////            "how to use this app",
////            "how does the app work",
////            "how does this app work",
////            "instructions again",
////            "explain the app",
////            "how do i use",
////            "how do i use this"
////        ]
////        return phrases.contains { lower.contains($0) }
////    }
////
////    // MARK: - LLM Q&A (single Claude call: image + question + state → faster than vision then LLM)
////    func handleUserQuestion(_ userText: String, heightCm: Double?) {
////        transcriptStore.add("You: \(userText)")
////
////        guard !Secrets.anthropicApiKey.isEmpty else {
////            say("Please set your Anthropic API key in Secrets.")
////            return
////        }
////
////        guard let frame = camera.currentFrame(),
////              let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
////            say("I don't have a camera frame. Point the camera and try again.")
////            return
////        }
////
////        Task {
////            do {
////                let stateJSON = buildStateJSON(heightCm: heightCm, distanceCandidates: nil)
////                let plan = try await claude.askWithImage(jpegData: jpeg, userText: userText, stateJSON: stateJSON)
////                DispatchQueue.main.async {
////                    self.execute(plan: plan)
////                }
////            } catch {
////                DispatchQueue.main.async {
////                    self.transcriptStore.add("CLAUDE ERROR: \(error.localizedDescription)")
////                    self.say("I couldn’t reach the assistant. Please check internet or API key.")
////                }
////            }
////        }
////    }
////
////    private func execute(plan: BrainPlan) {
////        switch plan.action {
////        case .none:
////            break
////
////        case .repeatLast:
////            if lastGuidance.isEmpty { say("I have not said anything yet."); return }
////            say(lastGuidance)
////            return
////
////        case .clearTranscripts:
////            transcriptStore.clear()
////            say("Transcripts cleared.")
////            return
////
////        case .setTarget:
////            let t = (plan.target ?? "target").lowercased()
////            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
////            say("Target set to \(t).")
////            return
////
////        case .answerFromMemory:
////            let key = plan.memoryKey ?? ""
////            if let val = memory[key] { say(val) }
////            else { say("I don’t have that saved yet.") }
////            return
////        }
////
////        say(plan.say)
////    }
////
////    // MARK: - State JSON for Q&A
////    private func buildStateJSON(heightCm: Double?, distanceCandidates: [[String: Any]]? = nil) -> String {
////        let firstEight = Array(memory.prefix(8))
////        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)
////
////        let stepCm = stepLengthCm(using: heightCm)
////        let stepFt = stepCm / 30.48
////
////        var state: [String: Any] = [
////            "height_cm": heightCm as Any,
////            "user_step_length_cm": stepCm,
////            "user_step_length_ft": stepFt,
////            "last_guidance": lastGuidance,
////            "last_seen_sign": lastSeenSign,
////            "last_obstacle": lastObstacle,
////            "pending_utterances": Array(pendingUtterances.prefix(6)),
////            "memory_keys": Array(memory.keys).sorted(),
////            "memory_preview": memoryPreview
////        ]
////
////        if let dc = distanceCandidates {
////            state["distance_candidates"] = dc
////        }
////
////        let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
////        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
////    }
////}
////
////
////
//////import Foundation
//////import Combine
//////
//////final class SceneAssistController: ObservableObject {
//////
//////    // MARK: - Timing / Speech control
//////    private var lastSpokeAt: Date = .distantPast
//////    private let scanIntervalSeconds: TimeInterval = 2.0
//////    private let minSecondsBetweenSpeech: TimeInterval = 2.0
//////
//////    // MARK: - Services
//////    private let cloudVision = CloudVisionService()
//////    private let brain = LLMBrainService()
//////    private let voice = VoiceInputService()
//////    private let speech = SpeechManager()
//////
//////    // MARK: - Memory / State for Q&A
//////    private var memory: [String: String] = [:]
//////    private var lastSeenSign: String = ""
//////    private var lastObstacle: String = ""
//////
//////    // Store latest extra lines for Q&A (“what else do you see?”)
//////    private var pendingUtterances: [String] = []
//////
//////    // MARK: - Published UI state
//////    @Published var lastGuidance: String = ""
//////    @Published var scanningEnabled: Bool = true
//////    @Published var isListening: Bool = false
//////
//////    // Prevent repeating the same spoken line every scan
//////    private var lastSpokenEvent: String = ""
//////    private var lastScanLogAt: Date = .distantPast
//////
//////    // MARK: - Camera / Transcripts
//////    let camera = CameraService()
//////    let transcriptStore = TranscriptStore()
//////
//////    // MARK: - Run loop
//////    private var timer: Timer?
//////    private var isProcessing = false
//////
//////    // Set from ContentView
//////    var heightCm: Double? = nil
//////    
//////    init() {
//////        // Use ElevenLabs for speaking
//////        speech.mode = .elevenlabs
//////        speech.apiKey = Secrets.elevenLabsApiKey
//////        speech.voiceId = Secrets.elevenLabsVoiceId
//////        
//////        print("TTS = ElevenLabs, voiceId = \(speech.voiceId)")
//////    }
//////
//////    // MARK: - Start / Stop
////////    func start() {
////////        camera.start()
////////
////////        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
////////            self?.tick()
////////        }
////////    }
//////    func start() {
//////        camera.start()
//////
//////        // ✅ Speak instantly (so user knows it’s alive)
//////        DispatchQueue.main.async {
//////            self.speech.speak("Scene Assist Launched.")
//////            self.transcriptStore.add("Scene Assist Launched.")
//////        }
//////
//////        // ✅ Run the first scan immediately (don’t wait for timer)
//////        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//////            self?.tick()
//////        }
//////
//////        // Then keep scanning on your interval
//////        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
//////            self?.tick()
//////        }
//////    }
//////
//////    func stop() {
//////        timer?.invalidate()
//////        timer = nil
//////        camera.stop()
//////    }
//////
//////    // MARK: - Tick
//////    private func tick() {
//////        // If paused or listening, do nothing
//////        if !scanningEnabled || isListening {
//////            isProcessing = false
//////            return
//////        }
//////
//////        if isProcessing { return }
//////        guard let frame = camera.currentFrame() else { return }
//////        isProcessing = true
//////
//////        guard let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
//////            isProcessing = false
//////            return
//////        }
//////
//////        Task { [weak self] in
//////            guard let self = self else { return }
//////
//////            do {
//////                let scene = try await self.cloudVision.analyze(jpegData: jpeg)
//////
//////                DispatchQueue.main.async {
//////                    // Save facts for Q&A
//////                    self.lastSeenSign = scene.sign_texts.first ?? ""
//////
//////                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
//////                        self.lastObstacle =
//////                            "\(firstNonSign.kind.rawValue.lowercased()):" +
//////                            "\(firstNonSign.label.lowercased()):" +
//////                            "\(firstNonSign.position.rawValue.lowercased()):" +
//////                            "\(firstNonSign.proximity.rawValue.lowercased())"
//////                    } else {
//////                        self.lastObstacle = ""
//////                    }
//////
//////                    // Store short list for Q&A only (not for speaking)
//////                    let shortList = scene.utterances
//////                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//////                        .filter { !$0.isEmpty }
//////                    self.pendingUtterances = Array(shortList.prefix(6))
//////
//////                    // Speak exactly ONE prominent sentence per scan
//////                    if let line = self.primaryUtterance(from: scene) {
//////                        let now = Date()
//////
//////                        if !self.speech.isSpeaking,
//////                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
//////                           line != self.lastSpokenEvent {
//////
//////                            self.lastSpokeAt = now
//////                            self.lastSpokenEvent = line
//////                            self.lastGuidance = line
//////                            self.speech.speak(line)
//////                            self.transcriptStore.add(line)
//////                        } else {
//////                            // optional: keep silent if same or too soon
//////                        }
//////                    } else {
//////                        // No good detections → log scanning every 10s, no audio
//////                        let t = Date()
//////                        if t.timeIntervalSince(self.lastScanLogAt) >= 10 {
//////                            self.lastScanLogAt = t
//////                            self.transcriptStore.add("Scanning.")
//////                        }
//////                    }
//////
//////                    self.isProcessing = false
//////                }
//////
//////            } catch {
//////                DispatchQueue.main.async {
//////                    self.transcriptStore.add("VISION ERROR: \(error.localizedDescription)")
//////                    self.isProcessing = false
//////                }
//////            }
//////        }
//////    }
//////
//////    // MARK: - Human sentence generator (ONE best item)
//////    private func article(for noun: String) -> String {
//////        let first = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
//////        let vowels: Set<Character> = ["a","e","i","o","u"]
//////        return (first != nil && vowels.contains(first!)) ? "an" : "a"
//////    }
//////
//////    private func primaryUtterance(from scene: VisionScene) -> String? {
//////        let generic: Set<String> = ["object", "item", "thing", "stuff"]
//////
//////        // Pick confident, non-sign items
//////        let candidates = scene.items
//////            .filter { $0.kind != .SIGN }
//////            .filter { $0.confidence >= 0.65 }
//////
//////        // Prominence score: center is strongest; close is strongest
//////        func score(_ it: VisionItem) -> Int {
//////            let posScore = (it.position == .CENTER) ? 30 : 10
//////            let proxScore: Int = (it.proximity == .CLOSE) ? 30 : (it.proximity == .NEAR ? 20 : 0)
//////            return posScore + proxScore
//////        }
//////
//////        let sorted = candidates.sorted { score($0) > score($1) }
//////
//////        // Choose first specific (non-generic) label
//////        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
//////            // If no objects, optionally mention sign
////////            if let sign = scene.sign_texts.first, !sign.isEmpty {
////////                return "I see an \(sign) sign ahead."
////////            }
//////            return nil
//////        }
//////
//////        // Don’t speak FAR
//////        if top.proximity == .FAR { return nil }
//////
//////        // Position phrase
//////        let whereText: String
//////        switch top.position {
//////        case .CENTER: whereText = "in front of you"
//////        case .LEFT:   whereText = "to your left"
//////        case .RIGHT:  whereText = "to your right"
//////        }
//////
//////        // Only say “very close” if CLOSE
//////        let closeText = (top.proximity == .CLOSE) ? ", very close" : ""
//////
//////        // Exact label (animals generic only)
//////        let labelText: String
//////        if top.kind == .ANIMAL { labelText = "animal" }
//////        else if top.kind == .PERSON { labelText = "person" }
//////        else { labelText = top.label.lowercased() }
//////
//////        // Action hint only when close
//////        let action: String = {
//////            guard top.proximity == .CLOSE else { return "" }
//////            switch top.position {
//////            case .CENTER: return " Please move slightly left or right."
//////            case .LEFT:   return " Please move slightly right."
//////            case .RIGHT:  return " Please move slightly left."
//////            }
//////        }()
//////
//////        if labelText == "person" {
//////            return "A person is \(whereText)\(closeText).\(action)"
//////        } else if labelText == "animal" {
//////            return "An animal is \(whereText)\(closeText).\(action)"
//////        } else {
//////            return "\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(closeText).\(action)"
//////        }
//////    }
//////
//////    // MARK: - Speech helper (used by Q&A + errors)
//////    private func say(_ text: String) {
//////        lastGuidance = text
//////        speech.speak(text)
//////        transcriptStore.add(text)
//////    }
//////
//////    // MARK: - Voice controls
//////    func beginVoice() {
//////        scanningEnabled = false
//////        isListening = true
//////        isProcessing = false
//////
//////        voice.requestPermissions { [weak self] ok in
//////            guard let self = self else { return }
//////
//////            if !ok {
//////                self.isListening = false
//////                self.say("Please allow speech recognition in Settings.")
//////                return
//////            }
//////
//////            do {
//////                try self.voice.startListening()
//////                self.transcriptStore.add("🎤 Listening…")
//////            } catch {
//////                self.isListening = false
//////                self.say("Sorry, I could not start listening.")
//////            }
//////        }
//////    }
//////
//////    func endVoice() {
//////        voice.stopListening()
//////        isListening = false
//////
//////        let text = voice.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
//////        if text.isEmpty {
//////            say("Sorry, I didn’t catch that. Please try again.")
//////            return
//////        }
//////
//////        let lower = text.lowercased()
//////
////////        if lower.contains("start scanning") || lower.contains("resume scanning") || lower.contains("scan again") {
////////            scanningEnabled = true
////////            lastScanLogAt = .distantPast
////////            transcriptStore.add("Scanning resumed.")
////////            speech.speak("Okay.")
////////            return
////////        }
//////        let compact = lower.replacingOccurrences(of: " ", with: "")
//////
//////        if lower.contains("start scanning")
//////            || lower.contains("resume scanning")
//////            || lower.contains("scan again")
//////            || compact.contains("startscanningagain")
//////            || compact.contains("resumescanning")
//////            || compact.contains("startscanning") {
//////
//////            scanningEnabled = true
//////
//////            // Reset scan state so it immediately starts talking again
//////            isProcessing = false
//////            lastScanLogAt = .distantPast
//////            lastSpokeAt = .distantPast
//////            lastSpokenEvent = ""
//////
//////            transcriptStore.add("Scanning resumed.")
//////            speech.speak("Okay.")
//////
//////            // Kick off a scan immediately (don’t wait for the next timer tick)
//////            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
//////                self?.tick()
//////            }
//////            return
//////        }
//////
//////        if lower.contains("stop scanning") || lower.contains("pause scanning") {
//////            scanningEnabled = false
//////            isProcessing = false
//////            transcriptStore.add("Scanning paused.")
//////            speech.speak("Okay.")
//////            return
//////        }
//////
//////        // User asked for instructions / how to use the app — speak the same instructions as the start guide.
//////        if wantsInstructionsAgain(lower) {
//////            transcriptStore.add("Instructions.")
//////            speech.speak(AppInstructions.text(for: currentLanguage))
//////            return
//////        }
//////
//////        handleUserQuestion(text, heightCm: heightCm)
//////    }
//////
//////    private func wantsInstructionsAgain(_ lower: String) -> Bool {
//////        let phrases = [
//////            "repeat instruction",
//////            "repeat instructions",
//////            "hear instruction",
//////            "hear instructions",
//////            "tell me how to use",
//////            "how to use the app",
//////            "how to use this app",
//////            "how does the app work",
//////            "how does this app work",
//////            "instructions again",
//////            "explain the app",
//////            "how do i use",
//////            "how do i use this"
//////        ]
//////        return phrases.contains { lower.contains($0) }
//////    }
//////
//////    // MARK: - LLM Q&A
//////    func handleUserQuestion(_ userText: String, heightCm: Double?) {
//////        transcriptStore.add("You: \(userText)")
//////
//////        Task {
//////            do {
//////                let stateJSON = buildStateJSON(heightCm: heightCm)
//////                let plan = try await brain.askBrain(userText: userText, stateJSON: stateJSON)
//////
//////                DispatchQueue.main.async {
//////                    self.execute(plan: plan)
//////                }
//////            } catch {
//////                DispatchQueue.main.async {
//////                    self.transcriptStore.add("LLM ERROR: \(error.localizedDescription)")
//////                    self.say("I couldn’t reach the assistant. Please check internet or API key.")
//////                }
//////            }
//////        }
//////    }
//////
//////    private func execute(plan: BrainPlan) {
//////        switch plan.action {
//////        case .none:
//////            break
//////
//////        case .repeatLast:
//////            if lastGuidance.isEmpty { say("I have not said anything yet."); return }
//////            say(lastGuidance)
//////            return
//////
//////        case .clearTranscripts:
//////            transcriptStore.clear()
//////            say("Transcripts cleared.")
//////            return
//////
//////        case .setTarget:
//////            let t = (plan.target ?? "target").lowercased()
//////            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
//////            say("Target set to \(t).")
//////            return
//////
//////        case .answerFromMemory:
//////            let key = plan.memoryKey ?? ""
//////            if let val = memory[key] { say(val) }
//////            else { say("I don’t have that saved yet.") }
//////            return
//////        }
//////
//////        say(plan.say)
//////    }
//////
//////    // MARK: - State JSON for Q&A
//////    private func buildStateJSON(heightCm: Double?) -> String {
//////        let firstEight = Array(memory.prefix(8))
//////        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)
//////
//////        let state: [String: Any] = [
//////            "height_cm": heightCm as Any,
//////            "last_guidance": lastGuidance,
//////            "last_seen_sign": lastSeenSign,
//////            "last_obstacle": lastObstacle,
//////            "pending_utterances": Array(pendingUtterances.prefix(6)),
//////            "memory_keys": Array(memory.keys).sorted(),
//////            "memory_preview": memoryPreview
//////        ]
//////
//////        let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
//////        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
//////    }
//////}
