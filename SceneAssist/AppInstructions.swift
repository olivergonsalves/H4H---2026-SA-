import Foundation

/// Shared "how to use the app" text for the start guide and for in-app "repeat instructions" requests.
enum AppInstructions {

    /// Full instructions in the given language (spoken by TTS and used for "repeat instructions").
    static func text(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return textEnglish
        case .mandarin:
            return textMandarin
        }
    }

    /// Legacy: English only. Prefer `text(for: language)`.
    static let text: String = textEnglish

    private static let textEnglish = """
        Welcome to SceneAssist

        Here's how to use the app:

        Point your phone around you.
        SceneAssist will describe what is nearby and warn you about obstacles.

        To ask a question, press and hold anywhere on the screen and speak.
        While you are holding, scanning will pause and the app will listen.

        When you lift your finger, SceneAssist will answer you.

        You can say "Start" to begin.
        You can say "Repeat instructions" to hear this again.

        Safety

        SceneAssist is a support tool.
        Always use your cane or guide.
        Stay aware of your surroundings at all times.

        """

    private static let textMandarin = """
        欢迎使用场景助手。

        使用方法如下：

        将手机对准周围。场景助手会描述您附近的事物并提醒您注意障碍物。

        若要提问，请在屏幕上长按并说话。长按期间，扫描会暂停，应用会聆听。

        当您松开手指，场景助手会回答您。

        您可以说「开始」以开始使用。您可以说「重复说明」再听一遍。

        安全提示

        场景助手是辅助工具。请始终使用手杖或导盲犬，并随时注意周围环境。

        """

    /// Short cue after instructions: "Say start to begin, or repeat instructions to hear again."
    static func listeningCue(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return "Say start to begin, or repeat instructions to hear again."
        case .mandarin:
            return "请说「开始」以开始，或说「重复说明」再听一遍。"
        }
    }

    /// "I didn't catch that. Say start to begin, or repeat instructions to hear again."
    static func didntCatchThat(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return "I didn't catch that. Say start to begin, or repeat instructions to hear again."
        case .mandarin:
            return "没听清。请说「开始」以开始，或说「重复说明」再听一遍。"
        }
    }

    // MARK: - Start guide UI strings (for on-screen text when language is chosen)

    static func welcomeTitle(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Welcome to SceneAssist"
        case .mandarin: return "欢迎使用场景助手"
        }
    }

    static func howItWorksSubtitle(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Here's how it works:"
        case .mandarin: return "使用方法如下："
        }
    }

    static func step1(for language: AppLanguage) -> String {
        switch language {
        case .english: return "1. Point your phone around you. SceneAssist will describe what is nearby and warn you about obstacles."
        case .mandarin: return "1. 将手机对准周围。场景助手会描述您附近的事物并提醒您注意障碍物。"
        }
    }

    static func step2(for language: AppLanguage) -> String {
        switch language {
        case .english: return "2. To ask a question, press and hold anywhere on the screen and speak. While you are holding, scanning will pause and the app will listen."
        case .mandarin: return "2. 若要提问，请在屏幕上长按并说话。长按期间，扫描会暂停，应用会聆听。"
        }
    }

    static func step3(for language: AppLanguage) -> String {
        switch language {
        case .english: return "3. When you lift your finger, SceneAssist will answer you"
        case .mandarin: return "3. 当您松开手指，场景助手会回答您。"
        }
    }

    static func step4(for language: AppLanguage) -> String {
        switch language {
        case .english: return "4. You can say \"Start\" to begin. You can say \"Repeat instructions\" to hear this again."
        case .mandarin: return "4. 您可以说「开始」以开始使用。您可以说「重复说明」再听一遍。"
        }
    }

    static func safetyTitle(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Safety"
        case .mandarin: return "安全提示"
        }
    }

    static func safetyBody(for language: AppLanguage) -> String {
        switch language {
        case .english: return "SceneAssist is an assistive tool. Always use your cane or guide and stay aware of your surroundings."
        case .mandarin: return "场景助手是辅助工具。请始终使用手杖或导盲犬，并随时注意周围环境。"
        }
    }

    static func startButtonTitle(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Start SceneAssist"
        case .mandarin: return "开始使用场景助手"
        }
    }

    static func hearAgainButtonTitle(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Hear Instructions Again"
        case .mandarin: return "再听一遍说明"
        }
    }
}
