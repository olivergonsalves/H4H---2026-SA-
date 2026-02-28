# Scene-Assist

# SceneAssist

**Voice-first scene understanding and Q&A for blind and low-vision users.**

SceneAssist is an iOS app that helps people who are blind or have low vision understand their surroundings. Point your phone at a scene: the app describes what’s in front of you, warns about obstacles, and reads signs. Press and hold to ask questions in plain language and get spoken answers. Built with accessibility in mind—VoiceOver-friendly, hands-free onboarding, and a single consistent voice (ElevenLabs) throughout.

---

## Features

- **Continuous scene description** — Every few seconds the app speaks one clear sentence about the most important thing in view (e.g. *“A person is in front of you, very close. Please move slightly left.”*).
- **Obstacle and sign awareness** — Detects people, animals, objects, and text (signs) with position (left/center/right) and distance (far/near/close).
- **Voice Q&A** — Press and hold anywhere on the screen, speak your question, then release. The app uses your question plus the current scene and answers via an LLM, spoken aloud.
- **“Repeat instructions”** — Say *“Repeat instructions”*, *“How to use the app”*, or similar anytime to hear the full how-to-use guide again.
- **Scanning control** — Say *“Start scanning again”* to resume automatic descriptions; *“Stop scanning”* to pause.
- **Transcripts** — All spoken guidance and your questions are logged; open the Transcripts screen to review or clear them.
- **Height-based context** — Optional height (cm) is collected once via voice during onboarding and used for distance/step estimates in answers.
- **Accessible onboarding** — Welcome screen and height entry are voice-first: instructions and prompts are spoken (ElevenLabs), and you can say *“Start”* or *“Repeat instructions”* to navigate.

---

## How it works

1. **First launch** — A “How it works” (Start Guide) screen explains the app; you tap *Start SceneAssist* or say *“Start”*. If no height is stored, a voice-based onboarding flow asks for your height in centimeters and confirms once saved.
2. **Scanning** — After onboarding (or if height was already set), the camera runs and a timer (~2 s) grabs frames. Each frame is sent to a **vision model** (OpenAI Responses API) that returns structured scene data: objects, positions, proximity, and sign text. The app picks the most salient non-sign item and speaks one sentence (e.g. *“A chair is to your left, very close.”*). Scanning is rate-limited so it doesn’t talk over itself.
3. **Voice questions** — When you press and hold, the app pauses scanning and starts speech recognition. When you release, it stops listening and either:
   - Handles a command (*“Start scanning again”*, *“Stop scanning”*, *“Repeat instructions”* / *“How to use the app”*), or  
   - Sends your question plus current scene state (last guidance, last sign, last obstacle, height, etc.) to an **LLM** (OpenAI). The model returns a short answer and optional actions; the app speaks the answer and runs any action (e.g. repeat last sentence, clear transcripts).
4. **Audio** — All speech output uses **ElevenLabs** TTS (welcome, onboarding, scanning guidance, and Q&A) for a consistent, clear voice. Speech recognition uses Apple’s `SFSpeechRecognizer`.

---

## Tech stack

| Layer | Technology |
|-------|------------|
| **UI** | SwiftUI, SwiftData (minimal) |
| **Camera** | AVFoundation `AVCaptureSession`, `AVCaptureVideoDataOutput` |
| **Vision** | OpenAI Responses API (image + structured JSON schema) for scene analysis and sign text |
| **Speech out** | ElevenLabs TTS (with Apple TTS fallback in `SpeechManager`) |
| **Speech in** | Apple Speech framework (`SFSpeechRecognizer`, `AVAudioEngine`) |
| **Q&A** | OpenAI Responses API with structured `BrainPlan` (say, action, target, memory) |
| **Persistence** | UserDefaults (height, “has seen start guide”), JSON file (transcripts) |

---

## Requirements

- **iOS** 17.0+ (SwiftData, modern SwiftUI)
- **Xcode** 15+ (or latest)
- **API keys** (see Configuration):
  - OpenAI (for vision + LLM)
  - ElevenLabs (for TTS)

---

## Installation

1. Clone the repo:
   ```bash
   git clone https://github.com/YOUR_USERNAME/SceneAssist.git
   cd SceneAssist
   ```
2. Open `SceneAssist.xcodeproj` in Xcode.
3. Configure API keys in `SceneAssist/Secrets.swift` (see below).
4. Select the **SceneAssist** scheme and a simulator or device; run (⌘R).

---

## Configuration

The app reads API keys and voice ID from `SceneAssist/Secrets.swift`. **Do not commit real keys to version control.** Use a local override or environment-based config.

Edit `Secrets.swift`:

```swift
enum Secrets {
    static let openAIKey = "sk-..."           // OpenAI API key (vision + Responses API)
    static let elevenLabsApiKey = "sk_..."  // ElevenLabs API key
    static let elevenLabsVoiceId = "..."    // ElevenLabs voice ID (e.g. JTAucba3cC87UxrDYYsC)
}
```

- **OpenAI**: used for scene analysis (image → structured scene) and for Q&A (user question + state → answer + optional action). [API keys](https://platform.openai.com/api-keys)
- **ElevenLabs**: used for all spoken output. [API key](https://elevenlabs.io/) and a [voice ID](https://elevenlabs.io/voice-library) from your account.

If ElevenLabs keys are missing, the app falls back to Apple TTS so it still runs.

---

## Usage

- **Start** — Open the app → hear or read the Start Guide → tap *Start SceneAssist* or say *“Start”*. Complete height onboarding if prompted.
- **Scanning** — Point the camera; the app will describe the scene every few seconds. Use *Transcripts* to see history.
- **Ask something** — Press and hold on the screen, ask (e.g. *“What’s in front of me?”*, *“How many steps to the door?”*), then release.
- **Commands** — *“Start scanning again”*, *“Stop scanning”*, *“Repeat instructions”* / *“How to use the app”* are handled without calling the LLM.

---

## Accessibility

- **VoiceOver** — Labels and hints on buttons and key UI; instruction text grouped for sensible reading order.
- **Voice-first flows** — Start guide and height onboarding can be completed by voice (say *“Start”*, *“Repeat instructions”*, or speak height in cm).
- **Single TTS voice** — ElevenLabs used everywhere (welcome, onboarding, guidance, Q&A) for consistency.
- **Safety note** — The app reminds users that it is an assistive tool and to keep using a cane or guide and stay aware of surroundings.

---

## Project structure

```
SceneAssist/
├── SceneAssistApp.swift          # App entry, SwiftData container
├── ContentView.swift             # Root: Start Guide vs Camera; sheets (Transcripts, Onboarding)
├── StartGuideView.swift          # “How it works” + Start / Hear instructions again (voice)
├── OnboardingView.swift         # Height entry UI
├── OnboardingVoiceCoordinator.swift  # Voice-based height flow (ElevenLabs + speech recognition)
├── AppInstructions.swift        # Shared “how to use” text (start guide + in-app repeat)
├── SceneAssistController.swift   # Scanning loop, voice commands, LLM Q&A, scene → speech
├── CameraService.swift           # AVCaptureSession, frame delivery
├── CameraPreview.swift           # SwiftUI wrapper for camera layer
├── CloudVisionService.swift      # OpenAI image → VisionScene (items, signs, utterances)
├── LLMBrainService.swift        # OpenAI Q&A → BrainPlan (say, action, target, memory)
├── SpeechManager.swift          # ElevenLabs vs Apple TTS, playback, onFinished
├── ElevenLabsTTSService.swift   # ElevenLabs API → MP3
├── VoiceInputService.swift      # SFSpeechRecognizer, mic buffer → latestText
├── TranscriptStore.swift        # In-memory + file transcript list
├── TranscriptView.swift         # Transcript list UI
├── UserProfileStore.swift       # UserDefaults height (cm)
├── Secrets.swift                # API keys (do not commit)
├── ObjectDetector.swift         # (Optional) YOLO/on-device detection
├── HumanDetector.swift          # (Optional) Vision human rectangles
├── OCRService.swift             # (Optional) Vision text recognition
└── ...
```

---

## Contributing

Contributions are welcome. Please open an issue or a pull request; keep accessibility and minimal dependencies in mind.

---

## License

[Choose a license (e.g. MIT, Apache 2.0) and add it here.]
