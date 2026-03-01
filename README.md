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
- **Height-based context** — Optional height (cm) is stored and used for distance/step estimates in answers.
- **Language selection** — Choose **English** or **Mandarin** at first launch; instructions, guidance, and Q&A follow that language.
- **Accessible onboarding** — Welcome screen and start guide are voice-first: instructions are spoken (ElevenLabs), and you can say *“Start”* or *“Repeat instructions”* to navigate.

---

## How it works

1. **First launch** — Pick your language (English or Mandarin). A “How it works” (Start Guide) screen explains the app; you tap *Start SceneAssist* or say *“Start”*. If no height is stored, a default is used (you can change it later).
2. **Scanning** — The camera runs and a timer (~4 s) grabs frames. Each frame is sent to a **vision model** (Claude) that returns structured scene data: objects, positions, proximity, and sign text. The app picks the most salient item and speaks one sentence (e.g. *“A chair is to your left, very close.”*). Scanning is rate-limited so it doesn’t talk over itself.
3. **Optional AMD/vLLM path** — If a vLLM base URL is configured, the app can use local OCR + object detection (YOLO) and a Qwen model to compress a “sensor snapshot” into the same scene format, then Claude does text-only reasoning. If that path fails, it falls back to the standard Claude image flow.
4. **Voice questions** — When you press and hold, the app pauses scanning and starts speech recognition. When you release, it stops listening and either:
   - Handles a command (*“Start scanning again”*, *“Stop scanning”*, *“Repeat instructions”* / *“How to use the app”*), or  
   - Sends your question plus current scene state (last guidance, last sign, last obstacle, height, etc.) to **Claude**. The model returns a short answer and optional actions; the app speaks the answer and runs any action (e.g. repeat last sentence, clear transcripts).
5. **Audio** — All speech output uses **ElevenLabs** TTS (start guide, scanning guidance, and Q&A) for a consistent, clear voice. Speech recognition uses Apple’s `SFSpeechRecognizer`.

---

## Tech stack

| Layer | Technology |
|-------|------------|
| **UI** | SwiftUI |
| **Camera** | **ARKit** (when supported, with depth for distance); otherwise **AVFoundation** `AVCaptureSession` |
| **Vision** | **Claude** (Anthropic Messages API, `claude-haiku-4-5-20251001`) for scene analysis and Q&A; optional **vLLM + Qwen** path (OCR + YOLO → Qwen → Claude text-only) |
| **Speech out** | ElevenLabs TTS (with Apple TTS fallback in `SpeechManager`) |
| **Speech in** | Apple Speech framework (`SFSpeechRecognizer`, `AVAudioEngine`) |
| **Language** | English / Mandarin; `LanguageDetector` (NaturalLanguage) for optional detection; instructions and LLM output follow selected language |
| **Persistence** | UserDefaults (language, height, “has seen start guide”), JSON file (transcripts) |

---

## Requirements

- **iOS** 17.0+
- **Xcode** 15+ (or latest)
- **API keys** (see Configuration):
  - **Anthropic** — required for vision + Q&A (Claude)
  - **ElevenLabs** — required for TTS (API key + voice ID)
  - **vLLM** — optional; base URL, API key, and model name for the AMD/Qwen pipeline

---

## Installation

1. Clone the repo:
   ```bash
   git clone https://github.com/olivergonsalves/H4H---2026-SA-.git
   cd "H4H---2026-SA-"
   ```
2. Open `SceneAssist.xcodeproj` in Xcode.
3. Add your API keys in `SceneAssist/Secrets.swift` (see Configuration). This file is in `.gitignore`; create it if it doesn’t exist.
4. Select the **SceneAssist** scheme and a simulator or device; run (⌘R).

---

## Configuration

The app reads API keys and options from `SceneAssist/Secrets.swift`. **Do not commit real keys** — `Secrets.swift` is listed in `.gitignore`. Create `SceneAssist/Secrets.swift` with the following structure and fill in your values:

```swift
import Foundation

enum Secrets {
    static let elevenLabsApiKey   = ""  // Required for TTS
    static let elevenLabsVoiceId  = ""  // ElevenLabs voice ID

    /// Anthropic API key for Claude (vision + Q&A). Get one at https://console.anthropic.com/
    static let anthropicApiKey     = ""

    // Optional: AMD vLLM (OpenAI-compatible) — include /v1 in base URL
    static let vllmBaseURL        = ""
    static let vllmApiKey         = ""
    static let vllmQwenModel      = ""  // e.g. "Qwen3-30B-A3B"
}
```

- **Anthropic** — Used for scene analysis (image → structured scene) and for Q&A (image + question → answer, or text-only when using the vLLM path). [Get an API key](https://console.anthropic.com/). Model: Claude Haiku 4.5.
- **ElevenLabs** — Used for all spoken output. [API key](https://elevenlabs.io/) and a [voice ID](https://elevenlabs.io/voice-library) from your account.
- **vLLM** — Optional. When `vllmBaseURL` is set, the app can use OCR + object detection + Qwen to build a scene, then Claude for text-only reasoning. Leave empty to use only Claude with the camera image.

If ElevenLabs keys are missing, the app falls back to Apple TTS. If `anthropicApiKey` is empty, scanning and voice Q&A will not run until you set it.

---

## Usage

- **Start** — Open the app → choose language (English or Mandarin) → hear or read the Start Guide → tap *Start SceneAssist* or say *“Start”*.
- **Scanning** — Point the camera; the app will describe the scene every few seconds. Use *Transcripts* to see history.
- **Ask something** — Press and hold on the screen, ask (e.g. *“What’s in front of me?”*, *“How many steps to the door?”*), then release.
- **Commands** — *“Start scanning again”*, *“Stop scanning”*, *“Repeat instructions”* / *“How to use the app”* are handled without calling the LLM.

---

## Accessibility

- **VoiceOver** — Labels and hints on buttons and key UI; instruction text grouped for sensible reading order.
- **Voice-first flows** — Start guide can be completed by voice (say *“Start”*, *“Repeat instructions”*).
- **Single TTS voice** — ElevenLabs used everywhere (start guide, guidance, Q&A) for consistency.
- **Safety note** — The app reminds users that it is an assistive tool and to keep using a cane or guide and stay aware of surroundings.

---

## Project structure

```
SceneAssist/           # Main app
  AppInstructions.swift
  CameraPreview.swift
  ClaudeService.swift      # Anthropic vision + Q&A
  ContentView.swift
  LanguageDetector.swift
  LanguageSelectionView.swift
  SceneAssistController.swift
  SceneCameraProvider.swift # ARKit or AVFoundation
  SpeechManager.swift
  StartGuideView.swift
  TranscriptStore.swift
  VLLMQwenService.swift    # Optional vLLM/Qwen
  ... (camera, OCR, TTS, etc.)
SceneAssistTests/
SceneAssistUITests/
```

---

## Contributing

Contributions are welcome. Please open an issue or a pull request; keep accessibility and minimal dependencies in mind.

---

## License

[Choose a license (e.g. MIT, Apache 2.0) and add it here.]
