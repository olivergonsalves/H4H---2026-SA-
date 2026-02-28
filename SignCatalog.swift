import Foundation

final class SignCatalog {
    static let shared = SignCatalog()
    private(set) var keywords: Set<String> = []

    private init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "sign_keywords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["keywords"] as? [String] else {
            keywords = []
            return
        }
        keywords = Set(arr.map { $0.uppercased() })
    }

    func match(normalizedLettersOnly: String) -> String? {
        // returns first keyword contained in OCR string
        for k in keywords {
            if normalizedLettersOnly.contains(k) { return k }
        }
        return nil
    }
}
