import SwiftUI

struct ContentView: View {
    
    @StateObject private var controller = SceneAssistController()
    @State private var showTranscripts = false
    
    @StateObject private var profile = UserProfileStore()
    @State private var showOnboarding = false
    @AppStorage("hasSeenStartGuide") private var hasSeenStartGuide: Bool = false
    @State private var showStartGuide = false
    @State private var hasStartedController = false
    
    var heightCm: Double? = nil
    
    var body: some View {
        Group {
            if showStartGuide {
                StartGuideView {
                    hasSeenStartGuide = true
                    showStartGuide = false
                    startControllerAndMaybeOnboard()
                }
            } else {
                ZStack(alignment: .bottom) {
                    CameraPreview(session: controller.camera.session)
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
                    
                    Button(action: {
                        showTranscripts = true
                    }) {
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
            controller.heightCm = profile.heightCm
            if hasSeenStartGuide {
                startControllerAndMaybeOnboard()
            } else {
                showStartGuide = true
            }
        }
        .onDisappear {
            controller.stop()
        }
        .sheet(isPresented: $showTranscripts) {
            TranscriptView(store: controller.transcriptStore)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(profile: profile)
        }
        .onChange(of: profile.heightCm) { newHeight in
            controller.heightCm = newHeight
            if profile.hasHeight {
                showOnboarding = false
                startControllerAndMaybeOnboard()
            }
        }
    }
    
    private func startControllerAndMaybeOnboard() {
        // Start scanning only after height is stored (so we don't talk over the height prompt).
        if profile.hasHeight, !hasStartedController {
            controller.start()
            hasStartedController = true
        }
        showOnboarding = !profile.hasHeight
    }
}
