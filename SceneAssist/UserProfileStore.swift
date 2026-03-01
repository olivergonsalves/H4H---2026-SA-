//  UserProfileStore.swift
//  SceneAssist

import Foundation
import Combine

final class UserProfileStore: ObservableObject {

    private let heightKey   = "user_height_cm"
    private let languageKey = "user_selected_language"

    @Published var heightCm:      Double?      = nil
    @Published var savedLanguage: AppLanguage? = nil

    init() { load() }

    var hasHeight:   Bool { heightCm != nil }
    var hasLanguage: Bool { savedLanguage != nil }

    func saveHeightCm(_ cm: Double) {
        heightCm = cm
        UserDefaults.standard.set(cm, forKey: heightKey)
    }

    func saveLanguage(_ language: AppLanguage) {
        savedLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        print("🌐 Language saved permanently: \(language.displayName)")
    }

    private func load() {
        let cm = UserDefaults.standard.double(forKey: heightKey)
        heightCm = (cm > 0) ? cm : nil

        if let raw  = UserDefaults.standard.string(forKey: languageKey),
           let lang = AppLanguage(rawValue: raw) {
            savedLanguage = lang
        }
    }
}
