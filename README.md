# SceneAssist

**Voice-first scene understanding for blind and low-vision users.**

Point your phone at a scene: the app describes what’s in front of you, warns about obstacles, and reads signs. Press and hold to ask questions in plain language and get spoken answers. VoiceOver-friendly, with hands-free onboarding and a single consistent voice throughout.

---

## Features

- **Scene descriptions** — Speaks what’s in view (people, objects, text) with position and distance.
- **Voice Q&A** — Press and hold, ask a question, release; get a spoken answer.
- **Commands** — *“Repeat instructions”*, *“Start scanning”*, *“Stop scanning”*.
- **Transcripts** — Review or clear spoken guidance and questions.
- **Accessible onboarding** — Voice-first welcome and optional height entry for better distance hints.

---

## How to run

1. Clone the repo and open `SceneAssist.xcodeproj` in Xcode.
2. Add your API keys in `SceneAssist/Secrets.swift` (Anthropic, ElevenLabs). See `Secrets.example.swift` for the format.
3. Run on a device or simulator (iOS 17+).

---

## Usage

Open the app → complete the start guide (tap *Start* or say *“Start”*) → point the camera. Descriptions play automatically. Press and hold to ask questions; say *“Repeat instructions”* anytime for the guide again.

---

## Tech

SwiftUI, AVFoundation (camera), Claude for vision and Q&A, ElevenLabs TTS, Apple Speech for voice input.

---

## License

[Choose a license and add here.]
