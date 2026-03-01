//  LanguageDetector.swift
//  SceneAssist

import NaturalLanguage

enum AppLanguage: String, Equatable {
    case english  = "en"
    case mandarin = "zh"

    var claudeInstruction: String {
        switch self {
        case .english:
            return "The 'say' field and any spoken utterances must be in English."
        case .mandarin:
            return "The 'say' field and any spoken utterances must be in Mandarin Chinese (简体中文). All JSON structure, keys, and enum values must remain exactly as specified in English. Do NOT wrap the response in any explanation or text — output only the raw JSON object."
        }
    }

    var displayName: String {
        switch self {
        case .english:  return "English"
        case .mandarin: return "Mandarin"
        }
    }
}

final class LanguageDetector {
    private let recognizer = NLLanguageRecognizer()

    /// Returns .mandarin if Mandarin is confidently detected, otherwise defaults to .english.
    func detect(text: String) -> AppLanguage {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .english
        }

        recognizer.reset()
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let zhScore    = hypotheses[NLLanguage.simplifiedChinese]  ?? 0
        let twScore    = hypotheses[NLLanguage.traditionalChinese] ?? 0
        let mandarinScore = max(zhScore, twScore)
        let englishScore  = hypotheses[NLLanguage.english] ?? 0

        if mandarinScore > 0.3 && mandarinScore >= englishScore {
            return .mandarin
        }
        return .english
    }
}
