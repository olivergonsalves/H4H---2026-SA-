//  ContentView.swift
//  SceneAssist

import SwiftUI

struct ContentView: View {

    @StateObject private var profile    = UserProfileStore()
    @StateObject private var controller = SceneAssistController()

    @AppStorage("hasSeenStartGuide") private var hasSeenStartGuide: Bool = false
    @State private var showStartGuide       = false
    @State private var hasStartedController = false
    @State private var showTranscripts      = false

    var body: some View {
        Group {
            if !profile.hasLanguage {
                // First ever launch — voice language selection
                LanguageSelectionView { chosen in
                    profile.saveLanguage(chosen)
                    controller.setLanguage(chosen)
                    proceedToNextStep()
                }

            } else if showStartGuide {
                // First ever launch — start guide
                StartGuideView(language: profile.savedLanguage ?? .english) {
                    hasSeenStartGuide = true
                    showStartGuide    = false
                    startController()
                }

            } else {
                // Every launch after setup — camera view
                ZStack(alignment: .bottom) {
                    Group {
                        if let avSession = controller.camera.avCaptureSession {
                            CameraPreview(session: avSession)
                        } else if let arSession = controller.camera.arSession {
                            ARSessionPreview(session: arSession)
                        } else {
                            Color.black
                        }
                    }
                    .ignoresSafeArea()
                        .overlay(
                            Color.clear
                                .contentShape(Rectangle())
                                .onLongPressGesture(minimumDuration: 0.2, pressing: { pressing in
                                    if pressing {
                                        controller.beginVoice()
                                    } else {
                                        controller.endVoice()
                                    }
                                }, perform: {})
                        )

                    Button(action: { showTranscripts = true }) {
                        Text("Transcripts")
                            .font(.headline)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 24)
                            .background(.black.opacity(0.7))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .onAppear {
            if let lang = profile.savedLanguage {
                controller.setLanguage(lang)
            }
            if !profile.hasHeight {
                profile.saveHeightCm(170.0)
            }
            controller.heightCm = profile.heightCm

            if profile.hasLanguage {
                if hasSeenStartGuide {
                    startController()
                } else {
                    showStartGuide = true
                }
            }
        }
        .onDisappear {
            controller.stop()
        }
        .sheet(isPresented: $showTranscripts) {
            TranscriptView(store: controller.transcriptStore)
        }
    }

    private func proceedToNextStep() {
        if !profile.hasHeight {
            profile.saveHeightCm(170.0)
        }
        controller.heightCm = profile.heightCm

        if hasSeenStartGuide {
            startController()
        } else {
            showStartGuide = true
        }
    }

    private func startController() {
        guard !hasStartedController else { return }
        hasStartedController = true
        controller.heightCm  = profile.heightCm
        controller.start()
    }
}

