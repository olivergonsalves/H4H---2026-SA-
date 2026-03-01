import SwiftUI

struct OnboardingView: View {
    @ObservedObject var profile: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EmptyView()
            .onAppear {
                // Height onboarding disabled — set a default height and dismiss immediately
                profile.saveHeightCm(170.0)
                dismiss()
            }
    }
}


