import Foundation
import Combine

final class SceneAssistController: ObservableObject {
    
    private let autoResumeDelaySeconds: TimeInterval = 3.0
    private var autoResumeWorkItem: DispatchWorkItem?
    private var autoResumeArmed: Bool = false   // set true when we ask AI a question
    
    private let ocr = OCRService()
//    private let signKeywords: [String] = ["EXIT","ENTRANCE","RESTROOM","TOILET","ELEVATOR","LIFT","STAIRS","STAIRWAY",
//                                          "DANGER","WARNING","CAUTION","NOTICE","FIRE","NO","SMOKING","PUSH","PULL",
//                                          "EMERGENCY","FIRST","AID","AED","AUTHORIZED","ONLY","DO","NOT","STOP","SLOW"]

    // MARK: - Timing / Speech control
    private var lastSpokeAt: Date = .distantPast
    private let scanIntervalSeconds: TimeInterval = 2.0
    private let minSecondsBetweenSpeech: TimeInterval = 2.0

    // MARK: - Services
    private let cloudVision = CloudVisionService()
    private let brain = LLMBrainService()
    private let voice = VoiceInputService()
    private let speech = SpeechManager()

    // MARK: - Memory / State for Q&A
    private var memory: [String: String] = [:]
    private var lastSeenSign: String = ""
    private var lastObstacle: String = ""

    // Store latest extra lines for Q&A (“what else do you see?”)
    private var pendingUtterances: [String] = []

    // MARK: - Published UI state
    @Published var lastGuidance: String = ""
    @Published var scanningEnabled: Bool = true
    @Published var isListening: Bool = false

    // Prevent repeating the same spoken line every scan
    private var lastSpokenEvent: String = ""
    private var lastScanLogAt: Date = .distantPast

    // MARK: - Camera / Transcripts
    let camera = CameraService()
    let transcriptStore = TranscriptStore()

    // MARK: - Run loop
    private var timer: Timer?
    private var isProcessing = false

    // Set from ContentView
    var heightCm: Double? = nil
    
    private func cancelAutoResume() {
        autoResumeWorkItem?.cancel()
        autoResumeWorkItem = nil
    }
    
    // MARK: - Distance / steps helpers (approx)

    private func isDistanceIntent(_ lower: String) -> Bool {
        let triggers = [
            "how far", "distance", "how many steps", "steps", "feet", "foot", "meters", "metre",
            "how long", "walk", "reach", "get to", "close", "near"
        ]
        return triggers.contains(where: { lower.contains($0) })
    }

    private func stepLengthCm(using heightCm: Double?) -> Double {
        // Average step length ≈ 0.415 * height (good enough for demo)
        let h = heightCm ?? 165.0
        return max(45.0, min(h * 0.415, 90.0))
    }

    private func approxFeet(for proximity: Proximity) -> Double {
        // Tune for your demo space
        switch proximity {
        case .CLOSE: return 2.5   // ~0.8m
        case .NEAR:  return 7.0   // ~2.1m
        case .FAR:   return 16.0  // ~4.9m
        }
    }

    private func approxSteps(feet: Double, heightCm: Double?) -> Int {
        let stepFt = stepLengthCm(using: heightCm) / 30.48
        return max(1, Int(ceil(feet / max(stepFt, 0.5))))
    }

    private func buildDistanceCandidates(scene: VisionScene, heightCm: Double?) -> [[String: Any]] {
        // Take top visible non-sign items
        let items = scene.items
            .filter { $0.kind != .SIGN }
            .filter { $0.confidence >= 0.60 }
            .sorted { $0.salience_rank < $1.salience_rank }
            .prefix(6)

        return items.map { it in
            let feet = it.approx_distance_ft ?? approxFeet(for: it.proximity)
            let steps = approxSteps(feet: feet, heightCm: heightCm)

            return [
                "label": it.label.lowercased(),
                "kind": it.kind.rawValue,
                "position": it.position.rawValue,
                "proximity": it.proximity.rawValue,
                "confidence": it.confidence,
                "salience_rank": it.salience_rank,
                "approx_feet": feet,
                "approx_steps": steps
            ]
        }
    }

    private func handleSpeechFinished() {
        // Only auto-resume if we just answered a user question
        guard autoResumeArmed else { return }
        autoResumeArmed = false

        cancelAutoResume()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // If user started talking again, don't resume
            if self.isListening { return }

            self.scanningEnabled = true
            self.isProcessing = false

            // Kick off a scan immediately (don’t wait for timer)
            self.tick()
        }

        autoResumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoResumeDelaySeconds, execute: work)
    }
    
    init() {
        // Use ElevenLabs for speaking
        speech.mode = .elevenlabs
        speech.apiKey = Secrets.elevenLabsApiKey
        speech.voiceId = Secrets.elevenLabsVoiceId
        
        print("TTS = ElevenLabs, voiceId = \(speech.voiceId)")
        
        speech.onFinished = { [weak self] in
            self?.handleSpeechFinished()
        }
    }

    // MARK: - Start / Stop
//    func start() {
//        camera.start()
//
//        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
//            self?.tick()
//        }
//    }
    func start() {
        camera.start()

        // ✅ Speak instantly (so user knows it’s alive)
        DispatchQueue.main.async {
            self.speech.speak("Scene Assist Launched.")
            self.transcriptStore.add("Scene Assist Launched.")
        }

        // ✅ Run the first scan immediately (don’t wait for timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tick()
        }

        // Then keep scanning on your interval
        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        camera.stop()
    }

    // MARK: - Tick
    private func tick() {
        // If paused or listening, do nothing
        if !scanningEnabled || isListening {
            isProcessing = false
            return
        }

        if isProcessing { return }
        guard let frame = camera.currentFrame() else { return }
        isProcessing = true

        guard let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
            isProcessing = false
            return
        }

//        Task { [weak self] in
//            guard let self = self else { return }
//
//            do {
//                let scene = try await self.cloudVision.analyze(jpegData: jpeg)
//
//                DispatchQueue.main.async {
//                    // Save facts for Q&A
//                    self.lastSeenSign = scene.sign_texts.first ?? ""
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
//                    // Store short list for Q&A only (not for speaking)
//                    let shortList = scene.utterances
//                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//                        .filter { !$0.isEmpty }
//                    self.pendingUtterances = Array(shortList.prefix(6))
//
//                    // Speak exactly ONE prominent sentence per scan
//                    if let line = self.primaryUtterance(from: scene) {
//                        let now = Date()
//
//                        if !self.speech.isSpeaking,
//                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
//                           line != self.lastSpokenEvent {
//
//                            self.lastSpokeAt = now
//                            self.lastSpokenEvent = line
//                            self.lastGuidance = line
//                            self.speech.speak(line)
//                            self.transcriptStore.add(line)
//                        } else {
//                            // optional: keep silent if same or too soon
//                        }
//                    } else {
//                        // No good detections → log scanning every 10s, no audio
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
        
        Task { [weak self] in
            guard let self = self else { return }

            // OCR uses the pixel buffer directly (no network)
            let foundSign: String? = await withCheckedContinuation { cont in
                self.ocr.recognizeText(from: frame) { words in
                    let upper = words.joined(separator: " ").uppercased()
                    let normalized = upper.filter { $0.isLetter }   // "E X I T" -> "EXIT"
                    let found = SignCatalog.shared.match(normalizedLettersOnly: normalized)
//                    let sign = self.signKeywords.first { normalized.contains($0) }
                    cont.resume(returning: found)
                }
            }

            do {
                let scene = try await self.cloudVision.analyze(jpegData: jpeg)

                DispatchQueue.main.async {
                    // Save OCR sign as the “truth”
                    self.lastSeenSign = foundSign ?? ""

                    // Save obstacle from cloud
                    if let firstNonSign = scene.items.first(where: { $0.kind != .SIGN }) {
                        self.lastObstacle =
                            "\(firstNonSign.kind.rawValue.lowercased()):" +
                            "\(firstNonSign.label.lowercased()):" +
                            "\(firstNonSign.position.rawValue.lowercased()):" +
                            "\(firstNonSign.proximity.rawValue.lowercased())"
                    } else {
                        self.lastObstacle = ""
                    }

                    // Store short list for Q&A
                    let shortList = scene.utterances
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    self.pendingUtterances = Array(shortList.prefix(6))

                    // Decide what to speak:
                    // 1) if OCR found a sign → speak it (once per scan rules)
                    // 2) else speak best object/person
                    let spoken: String?
                    if let s = foundSign {
                        spoken = "Exit sign ahead." == s ? "Exit sign ahead." : "\(s.capitalized) sign ahead."
                    } else {
                        spoken = self.primaryUtterance(from: scene)
                    }

                    if let line = spoken {
                        let now = Date()
                        if !self.speech.isSpeaking,
                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
                           line != self.lastSpokenEvent {

                            self.lastSpokeAt = now
                            self.lastSpokenEvent = line
                            self.lastGuidance = line
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

    // MARK: - Human sentence generator (ONE best item)
    private func article(for noun: String) -> String {
        let first = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
        let vowels: Set<Character> = ["a","e","i","o","u"]
        return (first != nil && vowels.contains(first!)) ? "an" : "a"
    }

    private func primaryUtterance(from scene: VisionScene) -> String? {
        let generic: Set<String> = ["object", "item", "thing", "stuff"]

        // Pick confident, non-sign items
        let candidates = scene.items
            .filter { $0.kind != .SIGN }
            .filter { $0.confidence >= 0.65 }

        // Prominence score: center is strongest; close is strongest
        func score(_ it: VisionItem) -> Int {
            let posScore = (it.position == .CENTER) ? 30 : 10
            let proxScore: Int = (it.proximity == .CLOSE) ? 30 : (it.proximity == .NEAR ? 20 : 0)
            return posScore + proxScore
        }

        let sorted = candidates.sorted { score($0) > score($1) }

        // Choose first specific (non-generic) label
        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
            // If no objects, optionally mention sign
//            if let sign = scene.sign_texts.first, !sign.isEmpty {
//                return "I see an \(sign) sign ahead."
//            }
            return nil
        }

        // Don’t speak FAR
        if top.proximity == .FAR { return nil }

        // Position phrase
        let whereText: String
        switch top.position {
        case .CENTER: whereText = "in front of you"
        case .LEFT:   whereText = "to your left"
        case .RIGHT:  whereText = "to your right"
        }

        // Only say “very close” if CLOSE
        let closeText = (top.proximity == .CLOSE) ? ", very close" : ""

        // Exact label (animals generic only)
        let labelText: String
        if top.kind == .ANIMAL { labelText = "animal" }
        else if top.kind == .PERSON { labelText = "person" }
        else { labelText = top.label.lowercased() }

        // Action hint only when close
        let action: String = {
            guard top.proximity == .CLOSE else { return "" }
            switch top.position {
            case .CENTER: return " Please move slightly left or right."
            case .LEFT:   return " Please move slightly right."
            case .RIGHT:  return " Please move slightly left."
            }
        }()
        
        // ✅ Add STOP prefix when very close (and we’re telling user to move)
        let stopPrefix = (top.proximity == .CLOSE) ? "STOP! " : ""

        if labelText == "person" {
            return "\(stopPrefix)A person is \(whereText)\(closeText).\(action)"
        } else if labelText == "animal" {
            return "\(stopPrefix)An animal is \(whereText)\(closeText).\(action)"
        } else {
            return "\(stopPrefix)\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(closeText).\(action)"
        }
    }

    // MARK: - Speech helper (used by Q&A + errors)
    private func say(_ text: String) {
        lastGuidance = text
        speech.speak(text)
        transcriptStore.add(text)
    }

    // MARK: - Voice controls
    func beginVoice() {
        cancelAutoResume()
        scanningEnabled = false
        isListening = true
        isProcessing = false

        voice.requestPermissions { [weak self] ok in
            guard let self = self else { return }

            if !ok {
                self.isListening = false
                self.say("Please allow speech recognition in Settings.")
                return
            }

            do {
                try self.voice.startListening { [weak self] final in
                    DispatchQueue.main.async {
                        self?.handleFinalVoiceText(final)
                    }
                }
            } catch {
                self.isListening = false
                self.say("Sorry, I could not start listening.")
            }
        }
    }
    
    private func handleFinalVoiceText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptStore.add("You: \(cleaned)")

        let lower = cleaned.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")

        // Resume scanning commands
        if lower.contains("start scanning") || lower.contains("resume scanning")
            || lower.contains("scan again")
            || compact.contains("startscanningagain") {

            scanningEnabled = true
            isProcessing = false
            lastScanLogAt = .distantPast
            lastSpokeAt = .distantPast
            lastSpokenEvent = ""

            transcriptStore.add("Scanning resumed.")
            speech.speak("Okay.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
            return
        }

        // "What is this" command (works even if user says only "what is")
        if compact == "whatis" || lower.contains("what is") || lower.contains("what's this") || lower.contains("what is this") {
            describeWhatIsInView()
            return
        }

        // Otherwise use LLM Q&A
        handleUserQuestion(cleaned, heightCm: heightCm)
    }
    
    private func describeWhatIsInView() {
        // pause scanning during this one-shot answer
        scanningEnabled = false
        isProcessing = false

        guard let frame = camera.currentFrame(),
              let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) else {
            say("I can't see clearly right now.")
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let scene = try await self.cloudVision.analyze(jpegData: jpeg)
                DispatchQueue.main.async {
                    // Pick the most prominent non-sign item
                    let nonSigns = scene.items.filter { $0.kind != .SIGN }
                    guard let top = nonSigns.first else {
                        self.say("I'm not sure what that is.")
                        self.scanningEnabled = true
                        return
                    }

                    let label = (top.kind == .PERSON) ? "person" : (top.kind == .ANIMAL ? "animal" : top.label.lowercased())

                    let whereText: String = {
                        switch top.position {
                        case .CENTER: return "in front of you"
                        case .LEFT: return "to your left"
                        case .RIGHT: return "to your right"
                        }
                    }()

                    let closeText = (top.proximity == .CLOSE) ? ", very close" : ""
                    self.say("It looks like a \(label) \(whereText)\(closeText).")

                    // resume scanning after answering
                    self.scanningEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.say("I couldn't analyze that right now.")
                    self.scanningEnabled = true
                }
            }
        }
    }

    func endVoice() {
        voice.stopListening()
        isListening = false

        let text = voice.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            say("Sorry, I didn’t catch that. Please try again.")
            return
        }

        let lower = text.lowercased()

//        if lower.contains("start scanning") || lower.contains("resume scanning") || lower.contains("scan again") {
//            scanningEnabled = true
//            lastScanLogAt = .distantPast
//            transcriptStore.add("Scanning resumed.")
//            speech.speak("Okay.")
//            return
//        }
        let compact = lower.replacingOccurrences(of: " ", with: "")

        if lower.contains("start scanning")
            || lower.contains("resume scanning")
            || lower.contains("scan again")
            || compact.contains("startscanningagain")
            || compact.contains("resumescanning")
            || compact.contains("startscanning") {

            scanningEnabled = true

            // Reset scan state so it immediately starts talking again
            isProcessing = false
            lastScanLogAt = .distantPast
            lastSpokeAt = .distantPast
            lastSpokenEvent = ""

            transcriptStore.add("Scanning resumed.")
            speech.speak("Okay.")

            // Kick off a scan immediately (don’t wait for the next timer tick)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.tick()
            }
            return
        }

        if lower.contains("stop scanning") || lower.contains("pause scanning") {
            scanningEnabled = false
            isProcessing = false
            transcriptStore.add("Scanning paused.")
            speech.speak("Okay.")
            return
        }

        // User asked for instructions / how to use the app — speak the same instructions as the start guide.
        if wantsInstructionsAgain(lower) {
            transcriptStore.add("Instructions.")
            speech.speak(AppInstructions.text)
            return
        }
        
        autoResumeArmed = true
        handleUserQuestion(text, heightCm: heightCm)
    }

    private func wantsInstructionsAgain(_ lower: String) -> Bool {
        let phrases = [
            "repeat instruction",
            "repeat instructions",
            "hear instruction",
            "hear instructions",
            "tell me how to use",
            "how to use the app",
            "how to use this app",
            "how does the app work",
            "how does this app work",
            "instructions again",
            "explain the app",
            "how do i use",
            "how do i use this"
        ]
        return phrases.contains { lower.contains($0) }
    }

    // MARK: - LLM Q&A
    func handleUserQuestion(_ userText: String, heightCm: Double?) {
        transcriptStore.add("You: \(userText)")

        Task {
            do {
                var distanceCandidates: [[String: Any]]? = nil

                // If this looks like a distance/steps/walk question, grab a fresh frame and compute candidates
                if isDistanceIntent(userText.lowercased()),
                   let frame = camera.currentFrame(),
                   let jpeg = CloudVisionService.jpegFromPixelBuffer(frame) {

                    do {
                        let scene = try await cloudVision.analyze(jpegData: jpeg)
                        distanceCandidates = buildDistanceCandidates(scene: scene, heightCm: heightCm)
                        
                        // ✅ DEBUG: log top item proximity + label
                        if let top = scene.items.first(where: { $0.kind != .SIGN }) {
                            transcriptStore.add("DEBUG top=\(top.label) proximity=\(top.proximity.rawValue)")
                        }
                    } catch {
                        // If vision fails, still proceed to LLM with no candidates
                        transcriptStore.add("VISION(for distance) ERROR: \(error.localizedDescription)")
                    }
                }

                let stateJSON = buildStateJSON(heightCm: heightCm, distanceCandidates: distanceCandidates)
                let plan = try await brain.askBrain(userText: userText, stateJSON: stateJSON)

                DispatchQueue.main.async {
                    self.execute(plan: plan)
                }
            } catch {
                DispatchQueue.main.async {
                    self.transcriptStore.add("LLM ERROR: \(error.localizedDescription)")
                    self.say("I couldn’t reach the assistant. Please check internet or API key.")
                }
            }
        }
    }

    private func execute(plan: BrainPlan) {
        switch plan.action {
        case .none:
            break

        case .repeatLast:
            if lastGuidance.isEmpty { say("I have not said anything yet."); return }
            say(lastGuidance)
            return

        case .clearTranscripts:
            transcriptStore.clear()
            say("Transcripts cleared.")
            return

        case .setTarget:
            let t = (plan.target ?? "target").lowercased()
            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
            say("Target set to \(t).")
            return

        case .answerFromMemory:
            let key = plan.memoryKey ?? ""
            if let val = memory[key] { say(val) }
            else { say("I don’t have that saved yet.") }
            return
        }

        say(plan.say)
    }

    // MARK: - State JSON for Q&A
    private func buildStateJSON(heightCm: Double?, distanceCandidates: [[String: Any]]? = nil) -> String {
        let firstEight = Array(memory.prefix(8))
        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)

        let stepCm = stepLengthCm(using: heightCm)
        let stepFt = stepCm / 30.48

        var state: [String: Any] = [
            "height_cm": heightCm as Any,
            "user_step_length_cm": stepCm,
            "user_step_length_ft": stepFt,
            "last_guidance": lastGuidance,
            "last_seen_sign": lastSeenSign,
            "last_obstacle": lastObstacle,
            "pending_utterances": Array(pendingUtterances.prefix(6)),
            "memory_keys": Array(memory.keys).sorted(),
            "memory_preview": memoryPreview
        ]

        if let dc = distanceCandidates {
            state["distance_candidates"] = dc
        }

        let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }
}



//import Foundation
//import Combine
//
//final class SceneAssistController: ObservableObject {
//
//    // MARK: - Timing / Speech control
//    private var lastSpokeAt: Date = .distantPast
//    private let scanIntervalSeconds: TimeInterval = 2.0
//    private let minSecondsBetweenSpeech: TimeInterval = 2.0
//
//    // MARK: - Services
//    private let cloudVision = CloudVisionService()
//    private let brain = LLMBrainService()
//    private let voice = VoiceInputService()
//    private let speech = SpeechManager()
//
//    // MARK: - Memory / State for Q&A
//    private var memory: [String: String] = [:]
//    private var lastSeenSign: String = ""
//    private var lastObstacle: String = ""
//
//    // Store latest extra lines for Q&A (“what else do you see?”)
//    private var pendingUtterances: [String] = []
//
//    // MARK: - Published UI state
//    @Published var lastGuidance: String = ""
//    @Published var scanningEnabled: Bool = true
//    @Published var isListening: Bool = false
//
//    // Prevent repeating the same spoken line every scan
//    private var lastSpokenEvent: String = ""
//    private var lastScanLogAt: Date = .distantPast
//
//    // MARK: - Camera / Transcripts
//    let camera = CameraService()
//    let transcriptStore = TranscriptStore()
//
//    // MARK: - Run loop
//    private var timer: Timer?
//    private var isProcessing = false
//
//    // Set from ContentView
//    var heightCm: Double? = nil
//    
//    init() {
//        // Use ElevenLabs for speaking
//        speech.mode = .elevenlabs
//        speech.apiKey = Secrets.elevenLabsApiKey
//        speech.voiceId = Secrets.elevenLabsVoiceId
//        
//        print("TTS = ElevenLabs, voiceId = \(speech.voiceId)")
//    }
//
//    // MARK: - Start / Stop
////    func start() {
////        camera.start()
////
////        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
////            self?.tick()
////        }
////    }
//    func start() {
//        camera.start()
//
//        // ✅ Speak instantly (so user knows it’s alive)
//        DispatchQueue.main.async {
//            self.speech.speak("Scene Assist Launched.")
//            self.transcriptStore.add("Scene Assist Launched.")
//        }
//
//        // ✅ Run the first scan immediately (don’t wait for timer)
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//            self?.tick()
//        }
//
//        // Then keep scanning on your interval
//        timer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
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
//    // MARK: - Tick
//    private func tick() {
//        // If paused or listening, do nothing
//        if !scanningEnabled || isListening {
//            isProcessing = false
//            return
//        }
//
//        if isProcessing { return }
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
//            do {
//                let scene = try await self.cloudVision.analyze(jpegData: jpeg)
//
//                DispatchQueue.main.async {
//                    // Save facts for Q&A
//                    self.lastSeenSign = scene.sign_texts.first ?? ""
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
//                    // Store short list for Q&A only (not for speaking)
//                    let shortList = scene.utterances
//                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//                        .filter { !$0.isEmpty }
//                    self.pendingUtterances = Array(shortList.prefix(6))
//
//                    // Speak exactly ONE prominent sentence per scan
//                    if let line = self.primaryUtterance(from: scene) {
//                        let now = Date()
//
//                        if !self.speech.isSpeaking,
//                           now.timeIntervalSince(self.lastSpokeAt) >= self.minSecondsBetweenSpeech,
//                           line != self.lastSpokenEvent {
//
//                            self.lastSpokeAt = now
//                            self.lastSpokenEvent = line
//                            self.lastGuidance = line
//                            self.speech.speak(line)
//                            self.transcriptStore.add(line)
//                        } else {
//                            // optional: keep silent if same or too soon
//                        }
//                    } else {
//                        // No good detections → log scanning every 10s, no audio
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
//    // MARK: - Human sentence generator (ONE best item)
//    private func article(for noun: String) -> String {
//        let first = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first
//        let vowels: Set<Character> = ["a","e","i","o","u"]
//        return (first != nil && vowels.contains(first!)) ? "an" : "a"
//    }
//
//    private func primaryUtterance(from scene: VisionScene) -> String? {
//        let generic: Set<String> = ["object", "item", "thing", "stuff"]
//
//        // Pick confident, non-sign items
//        let candidates = scene.items
//            .filter { $0.kind != .SIGN }
//            .filter { $0.confidence >= 0.65 }
//
//        // Prominence score: center is strongest; close is strongest
//        func score(_ it: VisionItem) -> Int {
//            let posScore = (it.position == .CENTER) ? 30 : 10
//            let proxScore: Int = (it.proximity == .CLOSE) ? 30 : (it.proximity == .NEAR ? 20 : 0)
//            return posScore + proxScore
//        }
//
//        let sorted = candidates.sorted { score($0) > score($1) }
//
//        // Choose first specific (non-generic) label
//        guard let top = sorted.first(where: { !generic.contains($0.label.lowercased()) }) else {
//            // If no objects, optionally mention sign
////            if let sign = scene.sign_texts.first, !sign.isEmpty {
////                return "I see an \(sign) sign ahead."
////            }
//            return nil
//        }
//
//        // Don’t speak FAR
//        if top.proximity == .FAR { return nil }
//
//        // Position phrase
//        let whereText: String
//        switch top.position {
//        case .CENTER: whereText = "in front of you"
//        case .LEFT:   whereText = "to your left"
//        case .RIGHT:  whereText = "to your right"
//        }
//
//        // Only say “very close” if CLOSE
//        let closeText = (top.proximity == .CLOSE) ? ", very close" : ""
//
//        // Exact label (animals generic only)
//        let labelText: String
//        if top.kind == .ANIMAL { labelText = "animal" }
//        else if top.kind == .PERSON { labelText = "person" }
//        else { labelText = top.label.lowercased() }
//
//        // Action hint only when close
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
//            return "A person is \(whereText)\(closeText).\(action)"
//        } else if labelText == "animal" {
//            return "An animal is \(whereText)\(closeText).\(action)"
//        } else {
//            return "\(article(for: labelText).capitalized) \(labelText) is \(whereText)\(closeText).\(action)"
//        }
//    }
//
//    // MARK: - Speech helper (used by Q&A + errors)
//    private func say(_ text: String) {
//        lastGuidance = text
//        speech.speak(text)
//        transcriptStore.add(text)
//    }
//
//    // MARK: - Voice controls
//    func beginVoice() {
//        scanningEnabled = false
//        isListening = true
//        isProcessing = false
//
//        voice.requestPermissions { [weak self] ok in
//            guard let self = self else { return }
//
//            if !ok {
//                self.isListening = false
//                self.say("Please allow speech recognition in Settings.")
//                return
//            }
//
//            do {
//                try self.voice.startListening()
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
//        if text.isEmpty {
//            say("Sorry, I didn’t catch that. Please try again.")
//            return
//        }
//
//        let lower = text.lowercased()
//
////        if lower.contains("start scanning") || lower.contains("resume scanning") || lower.contains("scan again") {
////            scanningEnabled = true
////            lastScanLogAt = .distantPast
////            transcriptStore.add("Scanning resumed.")
////            speech.speak("Okay.")
////            return
////        }
//        let compact = lower.replacingOccurrences(of: " ", with: "")
//
//        if lower.contains("start scanning")
//            || lower.contains("resume scanning")
//            || lower.contains("scan again")
//            || compact.contains("startscanningagain")
//            || compact.contains("resumescanning")
//            || compact.contains("startscanning") {
//
//            scanningEnabled = true
//
//            // Reset scan state so it immediately starts talking again
//            isProcessing = false
//            lastScanLogAt = .distantPast
//            lastSpokeAt = .distantPast
//            lastSpokenEvent = ""
//
//            transcriptStore.add("Scanning resumed.")
//            speech.speak("Okay.")
//
//            // Kick off a scan immediately (don’t wait for the next timer tick)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
//                self?.tick()
//            }
//            return
//        }
//
//        if lower.contains("stop scanning") || lower.contains("pause scanning") {
//            scanningEnabled = false
//            isProcessing = false
//            transcriptStore.add("Scanning paused.")
//            speech.speak("Okay.")
//            return
//        }
//
//        // User asked for instructions / how to use the app — speak the same instructions as the start guide.
//        if wantsInstructionsAgain(lower) {
//            transcriptStore.add("Instructions.")
//            speech.speak(AppInstructions.text)
//            return
//        }
//
//        handleUserQuestion(text, heightCm: heightCm)
//    }
//
//    private func wantsInstructionsAgain(_ lower: String) -> Bool {
//        let phrases = [
//            "repeat instruction",
//            "repeat instructions",
//            "hear instruction",
//            "hear instructions",
//            "tell me how to use",
//            "how to use the app",
//            "how to use this app",
//            "how does the app work",
//            "how does this app work",
//            "instructions again",
//            "explain the app",
//            "how do i use",
//            "how do i use this"
//        ]
//        return phrases.contains { lower.contains($0) }
//    }
//
//    // MARK: - LLM Q&A
//    func handleUserQuestion(_ userText: String, heightCm: Double?) {
//        transcriptStore.add("You: \(userText)")
//
//        Task {
//            do {
//                let stateJSON = buildStateJSON(heightCm: heightCm)
//                let plan = try await brain.askBrain(userText: userText, stateJSON: stateJSON)
//
//                DispatchQueue.main.async {
//                    self.execute(plan: plan)
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    self.transcriptStore.add("LLM ERROR: \(error.localizedDescription)")
//                    self.say("I couldn’t reach the assistant. Please check internet or API key.")
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
//            if lastGuidance.isEmpty { say("I have not said anything yet."); return }
//            say(lastGuidance)
//            return
//
//        case .clearTranscripts:
//            transcriptStore.clear()
//            say("Transcripts cleared.")
//            return
//
//        case .setTarget:
//            let t = (plan.target ?? "target").lowercased()
//            memory["steps:\(t)"] = memory["steps:\(t)"] ?? "10"
//            say("Target set to \(t).")
//            return
//
//        case .answerFromMemory:
//            let key = plan.memoryKey ?? ""
//            if let val = memory[key] { say(val) }
//            else { say("I don’t have that saved yet.") }
//            return
//        }
//
//        say(plan.say)
//    }
//
//    // MARK: - State JSON for Q&A
//    private func buildStateJSON(heightCm: Double?) -> String {
//        let firstEight = Array(memory.prefix(8))
//        let memoryPreview = Dictionary(uniqueKeysWithValues: firstEight)
//
//        let state: [String: Any] = [
//            "height_cm": heightCm as Any,
//            "last_guidance": lastGuidance,
//            "last_seen_sign": lastSeenSign,
//            "last_obstacle": lastObstacle,
//            "pending_utterances": Array(pendingUtterances.prefix(6)),
//            "memory_keys": Array(memory.keys).sorted(),
//            "memory_preview": memoryPreview
//        ]
//
//        let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
//        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
//    }
//}
