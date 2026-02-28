//import Foundation
//
//struct TranscriptEntry: Codable, Identifiable {
//    let id: UUID
//    let timestamp: Date
//    let text: String
//}
//
//final class TranscriptStore: ObservableObject {
//    @Published var entries: [TranscriptEntry] = []
//
//    private let fileName = "transcripts.json"
//
//    init() {
//        load()
//    }
//
//    func add(_ text: String) {
//        let entry = TranscriptEntry(id: UUID(), timestamp: Date(), text: text)
//        entries.insert(entry, at: 0) // newest on top
//        save()
//    }
//
//    func clear() {
//        entries = []
//        save()
//    }
//
//    private func fileURL() -> URL {
//        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
//        return dir.appendingPathComponent(fileName)
//    }
//
//    private func save() {
//        do {
//            let data = try JSONEncoder().encode(entries)
//            try data.write(to: fileURL(), options: .atomic)
//        } catch {
//            print("❌ Failed to save transcripts:", error)
//        }
//    }
//
//    private func load() {
//        let url = fileURL()
//        guard FileManager.default.fileExists(atPath: url.path) else {
//            entries = []
//            return
//        }
//        do {
//            let data = try Data(contentsOf: url)
//            entries = try JSONDecoder().decode([TranscriptEntry].self, from: data)
//        } catch {
//            print("❌ Failed to load transcripts:", error)
//            entries = []
//        }
//    }
//}

import Foundation
import Combine

struct TranscriptEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let text: String
}

final class TranscriptStore: ObservableObject {
    @Published var entries: [TranscriptEntry] = []

    private let fileName = "transcripts.json"

    init() {
        load()
    }

    func add(_ text: String) {
        let entry = TranscriptEntry(id: UUID(), timestamp: Date(), text: text)
        entries.insert(entry, at: 0) // newest first
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func fileURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(fileName)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL(), options: .atomic)
        } catch {
            print("❌ Failed to save transcripts:", error)
        }
    }

    private func load() {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([TranscriptEntry].self, from: data)
        } catch {
            print("❌ Failed to load transcripts:", error)
            entries = []
        }
    }
}
