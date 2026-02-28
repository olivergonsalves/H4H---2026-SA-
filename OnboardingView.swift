import SwiftUI

struct OnboardingView: View {
    @ObservedObject var profile: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var coordinator = OnboardingVoiceCoordinator()

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome!")
                .font(.title2).bold()

            Text("We will capture your height using your voice.")
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.headline)

                Text(coordinator.statusText.isEmpty ? "Preparing..." : coordinator.statusText)
                    .foregroundColor(.primary)
                    .accessibilityLabel(coordinator.statusText.isEmpty ? "Preparing" : coordinator.statusText)
            }
            .padding(.horizontal)

            if !coordinator.recognizedText.isEmpty {
                Text("Heard: \(coordinator.recognizedText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            if coordinator.isListening {
                Text("Listening…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.top, 30)
        .onAppear {
            // Delay height prompt so it comes after
            // "Scene Assist Launched." has finished speaking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                coordinator.start(profile: profile) {
                    dismiss()
                }
            }
        }
        .onDisappear {
            coordinator.cancel()
        }
    }
}
