import Foundation
import Combine

final class UserProfileStore: ObservableObject {
    private let heightKey = "user_height_cm"

    @Published var heightCm: Double? = nil

    init() {
        load()
    }

    var hasHeight: Bool { heightCm != nil }

    func saveHeightCm(_ cm: Double) {
        heightCm = cm
        UserDefaults.standard.set(cm, forKey: heightKey)
    }

    private func load() {
        let cm = UserDefaults.standard.double(forKey: heightKey)
        heightCm = (cm > 0) ? cm : nil
    }
}
