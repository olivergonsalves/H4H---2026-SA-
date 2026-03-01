//  LanguageSelectionView.swift
//  SceneAssist
//
//  Voice-only language selection shown once ever on first launch.
//  Speaks a prompt, listens for "English" or "Chinese"/"Mandarin"/普通话,
//  saves the choice permanently, never shown again.

import SwiftUI

struct LanguageSelectionView: View {
    var onSelect: (AppLanguage) -> Void

    @StateObject private var coordinator = LanguageSelectionCoordinator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Text("SceneAssist")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text(coordinator.statusText)
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut, value: coordinator.statusText)

                if coordinator.isListening {
                    // Simple pulsing mic indicator
                    Circle()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 24, height: 24)
                }

                Spacer()
            }
        }
        .onAppear {
            coordinator.start(onSelect: onSelect)
        }
        .onDisappear {
            coordinator.cancel()
        }
    }
}

