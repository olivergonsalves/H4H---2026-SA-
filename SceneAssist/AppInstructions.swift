import Foundation

/// Shared “how to use the app” text for the start guide and for in-app “repeat instructions” requests.
enum AppInstructions {
    static let text = """
        Welcome to SceneAssist.
        First, we will ask for your height in centimeters. This helps estimate distances.
        Then, point your phone around. SceneAssist will describe what is around you and warn you about obstacles.
        To ask a question, press and hold anywhere on the screen and speak. While you hold, SceneAssist pauses scanning and listens.
        When you release, SceneAssist will respond.
        To resume scanning, you can say, start scanning again.
        If you want to start the app now, you can say, start.
        If you want to hear these instructions again, you can say, repeat instructions.
        Remember, SceneAssist is an assistive tool. Always use your cane or guide and stay aware of your surroundings.
        """
}
